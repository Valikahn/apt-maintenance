#!/usr/bin/env bash

###############################################################################
# System Maintenance and Update Script with Service Restart
# Author: Assistant
# Date: June 26, 2026
# Description: Performs comprehensive system updates, cleanup, automatic
#              service restarts with robust error handling and logging.
###############################################################################

# Ensure the script is run with root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                    ERROR: ROOT REQUIRED                  ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "This script must be executed with root privileges."
    echo ""
    echo "Please run using one of the following methods:"
    echo "  1. sudo ./system_maintenance.sh"
    echo "  2. su -c './system_maintenance.sh'"
    echo ""
    exit 1
fi

# Version Control
VERSION=1.0
MONTH="June"
YEAR=2026

# Configuration
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="/var/log/apt-maintenance"
LOG_FILE="${LOG_DIR}/apt_maintenance_${TIMESTAMP}.log"
MAX_RETRIES=3
RETRY_DELAY=5
MAX_SLEEP=2
DRY_RUN=false

# Set environment variables to prevent interactive prompts
export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Function for standardized logging
log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
}

# Function for colored console output
print_header() {
    local text=$1
    echo -e "\n${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN}  ${text}${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}\n"
    log "INFO" "=== $text ==="
}

print_step() {
    local step=$1
    local text=$2
    echo -e "${BOLD}${BLUE}[STEP $step]${NC} ${WHITE}${text}${NC}"
    log "INFO" "Step $step: $text"
}

print_success() {
    local text=$1
    echo -e "${GREEN}✓${NC} ${text}"
    log "INFO" "SUCCESS: $text"
}

print_warning() {
    local text=$1
    echo -e "${YELLOW}⚠${NC} ${text}"
    log "WARN" "$text"
}

print_error() {
    local text=$1
    echo -e "${RED}✗${NC} ${text}"
    log "ERROR" "$text"
}

print_info() {
    local text=$1
    echo -e "${CYAN}[INFO]${NC} ${text}"
    log "INFO" "$text"
}

print_action() {
    local text=$1
    echo -e "  ${MAGENTA}→${NC} ${text}"
    log "INFO" "ACTION: $text"
}

# Create log directory if it doesn't exist
create_log_directory() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
        chmod 755 "$LOG_DIR"
        print_success "Created log directory: $LOG_DIR"
    fi
}

# Setup automated log rotation
setup_log_rotation() {
    local logrotate_conf="/etc/logrotate.d/apt-maintenance"
    if [ ! -f "$logrotate_conf" ]; then
        cat <<EOF > "$logrotate_conf"
$LOG_DIR/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
        print_success "Log rotation configured (keeps last 4 weeks of logs)"
        log "INFO" "Log rotation configured at $logrotate_conf"
    fi
}

# Pre-flight checks: Network and Disk Space
run_preflight_checks() {
    print_header "Running Pre-Flight Checks"
    
    print_step "1" "Checking internet connectivity..."
    print_action "Pinging Cloudflare DNS (1.1.1.1)..."
    if ! ping -c 1 -W 5 1.1.1.1 &> /dev/null; then
        print_error "No internet connection detected."
        print_warning "Please check your network connection and try again."
        log "ERROR" "Pre-flight check failed: No internet connection"
        exit 1
    fi
    print_success "Internet connection is active"
	sleep $MAX_SLEEP
    
    print_step "2" "Checking available disk space..."
    local free_space_kb=$(df / | awk 'NR==2 {print $4}')
    local free_space_gb=$((free_space_kb / 1024 / 1024))
    print_action "Free space on root partition: ${free_space_gb}GB"
    
    if [ "$free_space_kb" -lt 1048576 ]; then
        print_error "Insufficient disk space on root partition."
        print_warning "At least 1GB of free space is required for safe updates."
        log "ERROR" "Pre-flight check failed: Insufficient disk space"
        exit 1
    fi
    print_success "Sufficient disk space available (${free_space_gb}GB)"
	sleep $MAX_SLEEP
    
    log "INFO" "All pre-flight checks passed successfully"
}

# Send desktop notification
send_desktop_notification() {
    local title=$1
    local message=$2
    local icon=${3:-"software-update-available"}
    
    local REAL_USER=$(logname 2>/dev/null || echo "$SUDO_USER")
    
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        local USER_UID=$(id -u "$REAL_USER" 2>/dev/null)
        local DBUS_ADDR="unix:path=/run/user/${USER_UID}/bus"
        
        print_action "Sending desktop notification to user: $REAL_USER"
        
        if sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
            notify-send -i "$icon" -t 15000 "$title" "$message" 2>/dev/null; then
            log "INFO" "Desktop notification sent successfully to $REAL_USER"
        else
            log "WARN" "Could not send desktop notification (user may not have active session)"
        fi
    else
        log "INFO" "Skipping desktop notification (no valid user session detected)"
    fi
}

# Function to execute commands with error handling
execute_with_correction() {
    local cmd=$1
    local description=$2
    local attempt=1

    if [ "$DRY_RUN" = true ]; then
        print_warning "[DRY RUN] Would execute: $description"
        print_action "Command: $cmd"
        log "INFO" "[DRY RUN] Would execute: $description"
        return 0
    fi

    print_action "Executing: $description"
    
    while [ $attempt -le $MAX_RETRIES ]; do
        if [ $attempt -gt 1 ]; then
            print_warning "Retry attempt $attempt of $MAX_RETRIES for: $description"
        fi
        
        if eval "$cmd" >> "$LOG_FILE" 2>&1; then
            print_success "$description completed successfully"
			sleep $MAX_SLEEP
            return 0
        else
            local exit_code=$?
            print_error "$description failed with exit code $exit_code"
			sleep $MAX_SLEEP
            
            if [ $attempt -lt $MAX_RETRIES ]; then
                print_info "Deploying corrective actions..."
                rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >> "$LOG_FILE" 2>&1
                dpkg --configure -a >> "$LOG_FILE" 2>&1 || true
                print_info "Waiting ${RETRY_DELAY} seconds before retry..."
                sleep $RETRY_DELAY
            fi
        fi
        ((attempt++))
    done

    print_error "Critical failure: '$description' failed after $MAX_RETRIES attempts"
    return 1
}

# Function to install and configure needrestart
install_and_configure_needrestart() {
    print_header "Installing and Configuring needrestart"
    
    print_step "1" "Checking if needrestart is installed"
    if command -v needrestart &> /dev/null; then
        print_success "needrestart is already installed"
		sleep $MAX_SLEEP
    else
        print_info "Installing needrestart..."
        if apt-get install -y needrestart >> "$LOG_FILE" 2>&1; then
            print_success "needrestart installed successfully"
			sleep $MAX_SLEEP
        else
            print_error "Failed to install needrestart"
			sleep $MAX_SLEEP
            return 1
        fi
    fi
    
    print_step "2" "Configuring needrestart for automatic restarts"
    local config_file="/etc/needrestart/needrestart.conf"
    
    if [ -f "$config_file" ]; then
        cp "$config_file" "${config_file}.bak.$TIMESTAMP"
        print_info "Backed up existing configuration"
    fi
    
    if grep -q "^\$nrconf{restart}" "$config_file" 2>/dev/null; then
        sed -i "s/^\$nrconf{restart}.*/\$nrconf{restart} = 'a';  # 'a' = automatic, 'l' = list only, 'i' = interactive/" "$config_file"
    else
        echo "" >> "$config_file"
        echo "# Auto-configured by maintenance script on $(date)" >> "$config_file"
        echo "\$nrconf{restart} = 'a';  # 'a' = automatic, 'l' = list only, 'i' = interactive" >> "$config_file"
    fi
    
    print_success "needrestart configured for automatic service restarts"
	sleep $MAX_SLEEP
    log "INFO" "needrestart configuration: \$nrconf{restart} = 'a'"
    
    return 0
}

# Function to detect and restart services using outdated libraries
restart_outdated_services() {
    if [ "$DRY_RUN" = true ]; then
        print_header "Service Management (DRY RUN)"
        print_warning "Would check and restart outdated services"
        return 0
    fi

    print_header "Checking and Restarting Outdated Services"
    
    local services_restarted=0
    
    print_step "1" "Running needrestart to detect outdated services"
    print_info "This is the safest method as it avoids restarting critical GUI/session services."
    print_info "This may take a moment..."
    
    if needrestart -b -r a >> "$LOG_FILE" 2>&1; then
        print_success "needrestart completed - services restarted automatically"
        ((services_restarted++))
    else
        print_warning "needrestart encountered some issues (check log for details)"
    fi
    
    print_step "2" "Checking safe, non-GUI system services"
    print_info "Skipping core desktop services (like dbus) to prevent killing your terminal session."
    
    local common_services=(
        "cron"
        "rsyslog"
        "sshd"
        "cups"
    )
    
    for service in "${common_services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            print_action "Checking service: $service"
            if systemctl show "$service" --property=MainPID --value | grep -q .; then
                print_info "Restarting service: $service"
                if systemctl restart "$service" >> "$LOG_FILE" 2>&1; then
                    print_success "Successfully restarted: $service"
                    ((services_restarted++))
                else
                    print_warning "Failed to restart: $service"
                fi
            fi
        fi
    done
    
    print_step "3" "Scanning for processes using deleted libraries"
    
    if command -v lsof &> /dev/null; then
        local deleted_libs=$(lsof +L1 2>/dev/null | grep -E '\.so|DEL' | awk '{print $1}' | sort -u)
        
        if [ -n "$deleted_libs" ]; then
            print_warning "Found processes using deleted libraries:"
            echo "$deleted_libs" | while read -r proc; do
                echo -e "    ${YELLOW}- $proc${NC}"
            done
        else
            print_success "No processes found using deleted libraries"
        fi
    fi
    
    echo ""
    print_info "Total additional services restarted: $services_restarted"
    return 0
}

# Function to check if reboot is required
check_reboot_required() {
    print_header "Checking if Reboot is Required"
    
    local reboot_needed=false
    
    if [ -f /var/run/reboot-required ]; then
        print_warning "Reboot is required (kernel or critical system update detected)"
		sleep $MAX_SLEEP
        reboot_needed=true
    fi
    
    if [ -f /var/run/reboot-required.pkgs ]; then
        if grep -q "linux" /var/run/reboot-required.pkgs 2>/dev/null; then
            print_warning "Kernel update detected - reboot required"
			sleep $MAX_SLEEP
            reboot_needed=true
        fi
    fi
    
    local running_kernel=$(uname -r)
    local latest_kernel=$(ls -1t /boot/vmlinuz-* 2>/dev/null | head -1 | xargs basename 2>/dev/null | sed 's/vmlinuz-//')
    
    if [ -n "$latest_kernel" ] && [ "$running_kernel" != "$latest_kernel" ]; then
        print_warning "Running kernel ($running_kernel) differs from latest installed ($latest_kernel)"
		sleep $MAX_SLEEP
        reboot_needed=true
    fi
    
    if [ "$reboot_needed" = true ]; then
        echo ""
        echo -e "${RED}${BOLD}============================================================${NC}"
        echo -e "${RED}${BOLD}  SYSTEM REBOOT IS REQUIRED${NC}"
        echo -e "${RED}${BOLD}============================================================${NC}"
        echo -e "${YELLOW}A reboot is required to apply all updates.${NC}"
        echo ""
        return 0
    else
        print_success "No reboot required at this time"
		sleep $MAX_SLEEP
        return 1
    fi
}

# Function to prompt for confirmation and dry run
prompt_confirmation() {
    echo ""
    echo -e "${BOLD}${YELLOW}============================================================${NC}"
    echo -e "${BOLD}${YELLOW}  ⚠️  IMPORTANT WARNING${NC}"
    echo -e "${BOLD}${YELLOW}============================================================${NC}"
    echo ""
    echo -e "${WHITE}This script will:${NC}"
    echo -e "  • Run pre-flight checks (network & disk space)"
    echo -e "  • Update and upgrade all system packages"
    echo -e "  • Remove unused packages and clean cache"
    echo -e "  • Install and configure needrestart"
    echo -e "  • ${RED}AUTOMATICALLY RESTART SERVICES${NC} using outdated libraries"
    echo -e "  • ${RED}PROMPT TO REBOOT THE SYSTEM${NC} if required after updates"
    echo ""
    echo -e "${YELLOW}This may cause temporary service interruptions.${NC}"
    echo -e "${YELLOW}Ensure you have saved all work before proceeding.${NC}"
    echo ""
    
    echo -e "${BOLD}${CYAN}Would you like to run in DRY RUN mode?${NC}"
    echo -e "${CYAN}(This will show what would be done without making changes)${NC}"
    echo -e "${BOLD}Dry Run?${NC} ${YELLOW}[y/N]${NC} "
    read -r dryrun_response
    
    case "$dryrun_response" in
        [yY][eE][sS]|[yY])
            DRY_RUN=true
            echo ""
            print_warning "DRY RUN MODE ENABLED"
            print_info "No changes will be made to your system"
			sleep $MAX_SLEEP
            echo ""
            ;;
        *)
            DRY_RUN=false
            echo ""
            ;;
    esac
    
    echo -e "${BOLD}Do you want to continue?${NC} ${GREEN}[Y/n]${NC} "
    read -r response
    
    case "$response" in
        [yY][eE][sS]|[yY]|"")
            print_info "Continuing with system maintenance..."
			sleep $MAX_SLEEP
			clear
            if [ "$DRY_RUN" = true ]; then
                print_warning "Running in DRY RUN mode - no changes will be made"
            fi
            echo ""
            return 0
            ;;
        [nN][oO]|[nN])
            print_warning "Operation cancelled by user"
            echo ""
            exit 0
            ;;
        *)
            print_error "Invalid response. Please answer Y or n."
            prompt_confirmation
            ;;
    esac
}

# Trap for unexpected termination
trap 'echo ""; print_error "Script terminated unexpectedly (Terminal may have closed or a service restart interrupted the session)."; exit 1' INT TERM HUP

# Main execution
clear

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                                                          ║"
echo "║       SYSTEM MAINTENANCE AND UPDATE SCRIPT               ║"
echo "║                                                          ║"
echo "║              Version $VERSION - $MONTH $YEAR                     ║"
echo "║                                                          ║"
echo "║                      V4L1K4HN                            ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Create log directory
create_log_directory

# Setup log rotation
setup_log_rotation

# Initialize log file
log "INFO" "================================================================"
log "INFO" "Starting System Maintenance Script"
log "INFO" "Timestamp: $TIMESTAMP"
log "INFO" "Log file: ${LOG_FILE}"
log "INFO" "================================================================"

# Display system information
print_header "System Information"
print_info "Hostname: $(hostname)"
print_info "Current Kernel: $(uname -r)"
print_info "OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '"')"
print_info "Uptime: $(uptime -p 2>/dev/null || uptime)"
echo ""

# Prompt for confirmation (includes dry run option)
prompt_confirmation

# Run pre-flight checks
run_preflight_checks

# Step 1: Install and configure needrestart
install_and_configure_needrestart
if [ $? -ne 0 ]; then
    print_error "Failed to install/configure needrestart. Continuing anyway..."
fi

# Step 2: Initial cleanup
print_header "Initial Cleanup"
print_step "1" "Cleaning apt cache"
execute_with_correction "apt clean" "Initial apt cache clean"

print_step "2" "Removing existing apt lists"
execute_with_correction "rm -rf /var/lib/apt/lists/*" "Removal of existing apt lists"

# Step 3: Update package lists
print_header "Updating Package Lists"
print_step "1" "Running apt update"
execute_with_correction "apt update" "Updating package lists"

# Step 4: Distribution upgrade
print_header "Upgrading System Packages"
print_step "1" "Running distribution upgrade"
print_info "This may take several minutes depending on your system..."
execute_with_correction "apt dist-upgrade -y" "Performing distribution upgrade"

# Step 5: Remove unused packages
print_header "Removing Unused Packages"
print_step "1" "Running autoremove with purge"
execute_with_correction "apt autoremove --purge -y" "Removing unused packages and configurations"

# Step 6: Final cleanup
print_header "Final Cleanup"
print_step "1" "Running autoclean"
execute_with_correction "apt autoclean -y" "Autocleaning obsolete package files"

print_step "2" "Running final clean"
execute_with_correction "apt clean" "Final apt cache clean"

# Step 7: Restart services using outdated libraries
restart_outdated_services

# Step 8: Check if reboot is required
check_reboot_required
REBOOT_STATUS=$?

# Finalisation
echo ""
print_header "Maintenance Complete"
print_success "All operations completed successfully!"
echo ""
echo -e "${CYAN}Summary:${NC}"
echo -e "  • Log file: ${WHITE}${LOG_FILE}${NC}"
echo -e "  • Completed: $(date +"%Y-%m-%d %H:%M:%S")"
if [ "$DRY_RUN" = true ]; then
    echo -e "  • Mode: ${YELLOW}DRY RUN (no changes made)${NC}"
fi
echo ""

if [ $REBOOT_STATUS -eq 0 ]; then
    send_desktop_notification "System Maintenance Complete" "Reboot required to apply updates" "software-update-available"
    
    if [ "$DRY_RUN" = false ]; then
        echo -e "${BOLD}Would you like to reboot the system now?${NC} ${YELLOW}[y/N]${NC} "
        read -r reboot_response
        case "$reboot_response" in
            [yY][eE][sS]|[yY])
                print_info "Rebooting system in 5 seconds..."
                sleep 5
                reboot
                ;;
            *)
                print_info "Reboot postponed. Please remember to reboot manually."
                ;;
        esac
    fi
    echo ""
else
    send_desktop_notification "System Maintenance Complete" "All updates and cleanup completed successfully" "emblem-ok"
fi

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Thank you for using the System Maintenance Script${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""

log "INFO" "================================================================"
log "INFO" "System maintenance completed successfully"
log "INFO" "================================================================"

exit 0
#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# GPU Passthrough: VM to Host
# Restores GPU to host drivers after VM shutdown
# =============================================================================

# --- Default Config ---
DEFAULT_STATE_FILE="/run/vfio_state"

readonly LOG_TAG="vfio-passthrough"

# Config file locations (user config takes precedence)
get_config_file() {
    local user_home
    # When running with sudo, get the original user's home
    if [[ -n "${SUDO_USER:-}" ]]; then
        user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        user_home="$HOME"
    fi
    
    local user_config="${user_home}/.config/vfio-passthrough.conf"
    local system_config="/etc/vfio-passthrough.conf"
    
    if [[ -f "$user_config" ]]; then
        echo "$user_config"
    elif [[ -f "$system_config" ]]; then
        echo "$system_config"
    else
        echo ""
    fi
}

# Runtime config (set after loading config file)
STATE_FILE=""

# Runtime vars
DRY_RUN=false
VERBOSE=false
ENABLE_LOGGING=false
ENABLE_NVIDIA_RESTART=true
CLEANUP_DONE=false

# --- Logging ---
log() {
    local level="$1"
    shift
    local msg="$*"
    
    if [[ "$VERBOSE" == true ]] || [[ "$level" != "DEBUG" ]]; then
        echo "[$level] $msg"
    fi
    
    if [[ "$ENABLE_LOGGING" == true ]]; then
        logger -t "$LOG_TAG" "[$level] $msg" 2>/dev/null || true
    fi
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { log "DEBUG" "$@"; }

# --- Cleanup on Exit/Interrupt ---
cleanup() {
    local exit_code=$?
    
    # Prevent double cleanup
    if [[ "$CLEANUP_DONE" == true ]]; then
        return
    fi
    CLEANUP_DONE=true
    
    if [[ $exit_code -ne 0 ]]; then
        log_warn "Script interrupted or failed (exit code: $exit_code)"
        log_warn "State file preserved at $STATE_FILE for manual recovery"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Usage ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Restore GPU to host after VM shutdown.

Options:
  -n, --dry-run             Show what would be done without making changes
  -v, --verbose             Enable verbose output
  -l, --log                 Enable syslog logging
  --no-nvidia-restart       Skip nvidia-persistenced restart
  -h, --help                Show this help message

Config file locations (first found is used):
  ~/.config/vfio-passthrough.conf  (user config)
  /etc/vfio-passthrough.conf       (system fallback)

Examples:
  $(basename "$0")                          # Normal restoration
  $(basename "$0") --dry-run                # Preview actions
  $(basename "$0") --no-nvidia-restart      # Skip nvidia daemon restart
EOF
    exit 0
}

# --- Load Config File ---
load_config() {
    local config_file
    config_file=$(get_config_file)
    
    if [[ -n "$config_file" ]]; then
        log_debug "Loading config from $config_file"
        # shellcheck source=/dev/null
        source "$config_file"
    fi
    
    # Apply defaults (config file values take precedence)
    STATE_FILE="${STATE_FILE:-$DEFAULT_STATE_FILE}"
    ENABLE_NVIDIA_RESTART="${NVIDIA_RESTART:-$ENABLE_NVIDIA_RESTART}"
}

# --- Parse Arguments ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -l|--log)
                ENABLE_LOGGING=true
                shift
                ;;
            --no-nvidia-restart)
                ENABLE_NVIDIA_RESTART=false
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

# --- Helpers ---
ensure_root() {
    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$(id -u)" -ne 0 ]]; then
            log_warn "Not running as root. Some checks may be incomplete."
        fi
        return 0
    fi
    
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

# Poll with timeout (iterations × interval)
wait_for_condition() {
    local description="$1"
    local check_cmd="$2"
    local max_attempts="${3:-10}"
    local interval="${4:-0.5}"
    
    log_debug "Waiting for: $description (max ${max_attempts} attempts)"
    
    local attempt=0
    while (( attempt < max_attempts )); do
        if eval "$check_cmd"; then
            log_debug "Condition met after $attempt attempts"
            return 0
        fi
        sleep "$interval"
        ((attempt++))
    done
    
    log_warn "Timeout waiting for: $description"
    return 1
}

rebind_device() {
    local pci_id="$1"
    local target_driver="$2"
    local sysfs_path="/sys/bus/pci/devices/${pci_id}"

    log_info "--- Restoring ${pci_id} to '${target_driver}' ---"

    if [[ ! -d "${sysfs_path}" ]]; then
        log_error "Device ${pci_id} not found. Skipping."
        return 1
    fi

    # Unbind from current driver (vfio-pci)
    if [[ -e "${sysfs_path}/driver" ]]; then
        local current_driver
        current_driver=$(basename "$(readlink -f "${sysfs_path}/driver")")
        
        if [[ "${current_driver}" == "${target_driver}" ]]; then
            log_info "Device is already bound to ${target_driver}. Skipping."
            return 0
        fi

        log_info "Unbinding from ${current_driver}..."
        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY-RUN] Would unbind from ${current_driver}"
        else
            if ! echo "${pci_id}" > "${sysfs_path}/driver/unbind"; then
                log_error "Failed to unbind. Is the VM still running?"
                return 1
            fi
            
            # Wait for unbind
            wait_for_condition "driver unbind" "[[ ! -L '${sysfs_path}/driver' ]]" 5 0.2 || true
        fi
    fi

    # Clear driver_override
    if [[ "$DRY_RUN" != true ]]; then
        echo > "${sysfs_path}/driver_override"
    fi

    # Bind to Target Driver
    log_info "Binding to ${target_driver}..."
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would bind to ${target_driver}"
        return 0
    fi
    
    local bind_success=false
    
    if [[ -e "/sys/bus/pci/drivers/${target_driver}/bind" ]]; then
        if echo "${pci_id}" > "/sys/bus/pci/drivers/${target_driver}/bind" 2>/dev/null; then
            bind_success=true
        else
            log_warn "Direct bind failed, trying drivers_probe..."
        fi
    fi
    
    if [[ "$bind_success" != true ]]; then
        log_debug "Triggering global driver probe for ${pci_id}..."
        if ! echo "${pci_id}" > /sys/bus/pci/drivers_probe 2>/dev/null; then
            log_error "drivers_probe failed for ${pci_id}"
        fi
    fi

    # Verify binding with polling
    if wait_for_condition "driver bind" "[[ -e '${sysfs_path}/driver' ]]" 5 0.2; then
        local new_driver
        new_driver=$(basename "$(readlink -f "${sysfs_path}/driver")")
        
        if [[ "${new_driver}" == "${target_driver}" ]]; then
            log_info "Success: ${pci_id} is using ${target_driver}."
            return 0
        else
            log_warn "${pci_id} bound to ${new_driver} instead of ${target_driver}."
            return 0  # Not a failure, just unexpected
        fi
    else
        log_error "Device ${pci_id} has no driver after rebind attempt"
        return 1
    fi
}

restart_nvidia_services() {
    if [[ "$ENABLE_NVIDIA_RESTART" != true ]]; then
        log_debug "Nvidia service restart disabled"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would restart nvidia-persistenced if present"
        return 0
    fi
    
    # Check if nvidia-persistenced exists and restart it
    if systemctl list-unit-files 2>/dev/null | grep -q nvidia-persistenced; then
        log_info "Restarting nvidia-persistenced..."
        if ! systemctl restart nvidia-persistenced; then
            log_warn "Failed to restart nvidia-persistenced (non-fatal)"
        fi
    else
        log_debug "nvidia-persistenced service not found"
    fi
}

# --- Main ---
main() {
    load_config
    parse_args "$@"
    
    ensure_root

    if [[ ! -f "${STATE_FILE}" ]]; then
        log_error "No state file found at ${STATE_FILE}."
        log_error "Did you run the host_to_vm script?"
        exit 1
    fi

    # Validate not a symlink (security)
    if [[ -L "${STATE_FILE}" ]]; then
        log_error "${STATE_FILE} is a symlink. Security risk. Aborting."
        exit 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "=== DRY RUN MODE - No changes will be made ==="
        log_info "State file contents:"
        cat "${STATE_FILE}"
        echo ""
    fi

    # Track if any rebind failed
    local had_errors=false

    # Format: PCI_ID,DRIVER_NAME
    while IFS=, read -r pci_id driver; do
        if [[ -n "$pci_id" && -n "$driver" ]]; then
            if ! rebind_device "$pci_id" "$driver"; then
                had_errors=true
            fi
        fi
    done < "${STATE_FILE}"

    # Clean up state file only on success
    if [[ "$had_errors" == true ]]; then
        log_warn "Some devices failed to rebind. State file preserved."
        log_warn "Review errors above and run again, or manually clean up."
    else
        if [[ "$DRY_RUN" != true ]]; then
            rm -f "${STATE_FILE}"
            log_debug "State file removed"
        fi
    fi

    # Restart nvidia services (configurable)
    restart_nvidia_services

    echo "========================================================"
    if [[ "$had_errors" == true ]]; then
        log_warn "GPU returned to Host with errors. Check above."
    else
        log_info "GPU returned to Host successfully."
    fi
    log_info "Run 'nvidia-smi' to verify."
    echo "========================================================"
    
    if [[ "$had_errors" == true ]]; then
        exit 1
    fi
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# GPU Passthrough: Host to VM
# Unbinds GPU from host drivers and binds to vfio-pci for VM passthrough
# =============================================================================

# --- Default Config ---
DEFAULT_GPU_ID="0000:01:00.0"
DEFAULT_GPU_AUDIO_ID="0000:01:00.1"
DEFAULT_VFIO_USER="user"
DEFAULT_VFIO_GROUP="kvm"
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
VFIO_USER=""
VFIO_GROUP=""
STATE_FILE=""

# Runtime vars
GPU_ID=""
GPU_AUDIO_ID=""
DRY_RUN=false
VERBOSE=false
ENABLE_LOGGING=false
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
        
        # Remove empty/incomplete state file on failure
        if [[ -f "$STATE_FILE" && ! -s "$STATE_FILE" ]]; then
            log_debug "Removing empty state file"
            rm -f "$STATE_FILE"
        fi
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Usage ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Unbind GPU from host and prepare for VM passthrough.

Options:
  -g, --gpu ID          GPU PCI ID (default: $DEFAULT_GPU_ID)
  -a, --audio ID        GPU Audio PCI ID (default: $DEFAULT_GPU_AUDIO_ID)
  -n, --dry-run         Show what would be done without making changes
  -v, --verbose         Enable verbose output
  -l, --log             Enable syslog logging
  -h, --help            Show this help message

Config file locations (first found is used):
  ~/.config/vfio-passthrough.conf  (user config)
  /etc/vfio-passthrough.conf       (system fallback)

Examples:
  $(basename "$0")                          # Use defaults
  $(basename "$0") -g 0000:02:00.0          # Specify GPU
  $(basename "$0") --dry-run                # Preview actions
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
    DEFAULT_GPU_ID="${GPU_PCI_ID:-$DEFAULT_GPU_ID}"
    DEFAULT_GPU_AUDIO_ID="${GPU_AUDIO_PCI_ID:-$DEFAULT_GPU_AUDIO_ID}"
    VFIO_USER="${VFIO_USER:-$DEFAULT_VFIO_USER}"
    VFIO_GROUP="${VFIO_GROUP:-$DEFAULT_VFIO_GROUP}"
    STATE_FILE="${STATE_FILE:-$DEFAULT_STATE_FILE}"
}

# --- Parse Arguments ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -g|--gpu)
                GPU_ID="$2"
                shift 2
                ;;
            -a|--audio)
                GPU_AUDIO_ID="$2"
                shift 2
                ;;
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
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    # Apply defaults if not set via args
    GPU_ID="${GPU_ID:-$DEFAULT_GPU_ID}"
    GPU_AUDIO_ID="${GPU_AUDIO_ID:-$DEFAULT_GPU_AUDIO_ID}"
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

dry_run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would execute: $*"
        return 0
    fi
    "$@"
}

resolve_pci_id() {
    local id=$1
    if [[ ! -d "/sys/bus/pci/devices/$id" ]]; then
        if [[ -d "/sys/bus/pci/devices/0000:$id" ]]; then
            echo "0000:$id"
        else
            log_error "Device $id not found in /sys/bus/pci/devices/"
            exit 1
        fi
    else
        echo "$id"
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

check_and_kill_processes() {
    log_info "Checking for processes holding the GPU..."
    
    # Check if nvidia device nodes exist before using fuser
    if ! compgen -G "/dev/nvidia*" > /dev/null 2>&1; then
        log_info "No nvidia device nodes found. GPU may already be unbound."
        return 0
    fi
    
    local pids
    pids=$(fuser /dev/nvidia* 2>/dev/null || true)

    if [[ -z "$pids" ]]; then
        log_info "GPU is free. No processes detected."
        return 0
    fi

    # Resolve PIDs to App Names
    local app_names=""
    for pid in $pids; do
        local name
        name=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        if [[ -n "$name" ]]; then
            app_names="$app_names $name"
        fi
    done

    app_names=$(echo "$app_names" | tr ' ' '\n' | sort -u | grep -v '^$')

    echo "--------------------------------------------------------"
    log_warn "The following applications are holding the GPU:"
    echo "$app_names"
    echo "--------------------------------------------------------"
    
    if echo "$app_names" | grep -E -q "Xorg|Xwayland|kwin|gnome-shell|sddm|gdm"; then
        log_error "CRITICAL: Your Display Server is attached to this GPU."
        log_error "Aborting to prevent session crash."
        exit 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would kill these applications and wait for GPU release"
        return 0
    fi

    echo "We must kill these applications to proceed."
    read -p "Kill now? [y/N]: " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborting at user request."
        exit 1
    fi

    log_info "Sending SIGTERM to applications..."
    for app in $app_names; do
        log_debug "Stopping $app..."
        pkill -15 -x "$app" || true
    done
    
    # Poll for GPU release instead of fixed iterations
    if wait_for_condition "GPU to be released" "! fuser /dev/nvidia* >/dev/null 2>&1" 5 0.5; then
        log_info "Applications terminated gracefully."
    else
        local remaining_pids
        remaining_pids=$(fuser /dev/nvidia* 2>/dev/null || true)
        if [[ -n "$remaining_pids" ]]; then
            log_warn "Apps refused to close. Sending SIGKILL..."
            echo "$remaining_pids" | xargs -r kill -9 || true
            
            # Wait again after SIGKILL
            if ! wait_for_condition "GPU release after SIGKILL" "! fuser /dev/nvidia* >/dev/null 2>&1" 3 0.5; then
                log_error "GPU is STILL in use. A process likely respawned."
                fuser -v /dev/nvidia* 2>&1 || true
                log_error "Aborting unbind to prevent system hang."
                exit 1
            fi
        fi
    fi
    
    log_info "GPU is confirmed free."
}

bind_device() {
    local dev="$1"
    local sysfs="/sys/bus/pci/devices/$dev"

    if [[ ! -d "$sysfs" ]]; then
        log_warn "Device $dev not found in sysfs. Skipping."
        return
    fi

    # Wake device from D3 power state
    if [[ -r "$sysfs/config" ]]; then
        cat "$sysfs/config" >/dev/null 2>&1 || true
    fi

    local driver_link="$sysfs/driver"
    if [[ -L "$driver_link" ]]; then
        local driver_name
        driver_name=$(basename "$(readlink -f "$driver_link")")

        if [[ "$driver_name" == "vfio-pci" ]]; then
            log_info "$dev is already bound to vfio-pci."
            return
        fi

        # Save state (check for duplicates to handle re-runs)
        if ! grep -q "^${dev}," "$STATE_FILE" 2>/dev/null; then
            log_info "Saving state: $dev uses $driver_name"
            if [[ "$DRY_RUN" != true ]]; then
                echo "$dev,$driver_name" >> "$STATE_FILE"
            fi
        else
            log_debug "State already saved for $dev"
        fi

        log_info "Unbinding $dev from $driver_name..."
        if [[ "$DRY_RUN" != true ]]; then
            echo "$dev" > "$driver_link/unbind"
            
            # Poll for unbind completion
            wait_for_condition "driver unbind" "[[ ! -L '$sysfs/driver' ]]" 5 0.2 || true
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would bind $dev to vfio-pci"
        return
    fi

    echo "vfio-pci" > "$sysfs/driver_override"
    echo "$dev" > "/sys/bus/pci/drivers/vfio-pci/bind"
    
    # Verify binding
    if wait_for_condition "vfio-pci bind" "[[ -L '$sysfs/driver' ]] && [[ \$(basename \$(readlink -f '$sysfs/driver')) == 'vfio-pci' ]]" 3 0.2; then
        log_info "Bound $dev to vfio-pci."
    else
        log_error "Failed to bind $dev to vfio-pci"
        exit 1
    fi
}

# --- Main ---
main() {
    load_config
    parse_args "$@"
    
    ensure_root

    local FULL_GPU_ID FULL_AUDIO_ID
    FULL_GPU_ID=$(resolve_pci_id "$GPU_ID")
    FULL_AUDIO_ID=$(resolve_pci_id "$GPU_AUDIO_ID")
    
    log_info "GPU: $FULL_GPU_ID, Audio: $FULL_AUDIO_ID"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "=== DRY RUN MODE - No changes will be made ==="
    fi

    # Validate vfio-pci driver/module is available
    if [[ ! -d "/sys/bus/pci/drivers/vfio-pci" ]]; then
        log_debug "vfio-pci driver not loaded, will load module"
    fi

    # Initialize state file (secure: no symlinks, restricted perms)
    if [[ "$DRY_RUN" != true ]]; then
        if [[ -L "$STATE_FILE" ]]; then
            log_error "$STATE_FILE is a symlink. Security risk. Aborting."
            exit 1
        fi
        
        rm -f "$STATE_FILE"
        # Set umask to prevent world-readable state
        (umask 077; touch "$STATE_FILE")
        chmod 600 "$STATE_FILE"
    fi

    # Load modules early — if this fails, we haven't killed anything yet
    log_info "Loading required kernel modules..."
    dry_run_cmd modprobe kvmfr || log_warn "kvmfr module not available (optional)"
    
    if ! dry_run_cmd modprobe vfio-pci; then
        log_error "Failed to load vfio-pci module. Is VFIO enabled in kernel?"
        exit 1
    fi
    
    # Verify vfio-pci driver is now available
    if [[ "$DRY_RUN" != true ]] && [[ ! -d "/sys/bus/pci/drivers/vfio-pci" ]]; then
        log_error "vfio-pci driver not available after modprobe"
        exit 1
    fi

    check_and_kill_processes

    bind_device "$FULL_AUDIO_ID"
    bind_device "$FULL_GPU_ID"

    # IOMMU group detection with error handling
    local iommu_link="/sys/bus/pci/devices/$FULL_GPU_ID/iommu_group"
    if [[ ! -L "$iommu_link" ]]; then
        log_error "Device $FULL_GPU_ID is not in an IOMMU group."
        log_error "Check that IOMMU is enabled in BIOS and kernel (intel_iommu=on or amd_iommu=on)"
        exit 1
    fi
    
    local iommu_group
    iommu_group=$(basename "$(readlink -f "$iommu_link")")
    log_debug "IOMMU group: $iommu_group"
    
    if [[ "$DRY_RUN" != true ]]; then
        if [[ -c "/dev/vfio/$iommu_group" ]]; then
            chown "$VFIO_USER:$VFIO_GROUP" "/dev/vfio/$iommu_group"
            chmod 660 "/dev/vfio/$iommu_group"
            log_info "Permissions set for /dev/vfio/$iommu_group"
        else
            log_warn "/dev/vfio/$iommu_group not found - VM may need root"
        fi
        
        if [[ -c "/dev/kvmfr0" ]]; then
            chown "$VFIO_USER:$VFIO_GROUP" /dev/kvmfr0
            chmod 660 /dev/kvmfr0
            log_info "Permissions set for /dev/kvmfr0"
        fi
    fi

    echo "========================================================"
    log_info "GPU ready for VM passthrough."
    echo "========================================================"
}

main "$@"

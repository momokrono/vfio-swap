#!/usr/bin/env bash
# =============================================================================
# vfio-swap common library
# =============================================================================

# Prevent double-sourcing
[[ -n "${_VFIO_COMMON_LOADED:-}" ]] && return
readonly _VFIO_COMMON_LOADED=1

# --- Constants ---
readonly LOG_TAG="vfio-passthrough"
readonly PCI_ID_REGEX='^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$'

# --- Default Config ---
DEFAULT_GPU_ID="0000:01:00.0"
DEFAULT_GPU_AUDIO_ID="0000:01:00.1"
DEFAULT_VFIO_USER="user"
DEFAULT_VFIO_GROUP="kvm"
DEFAULT_STATE_FILE="/run/vfio_state"
DEFAULT_NVIDIA_RESTART="true"

# --- Runtime State (set by scripts) ---
DRY_RUN=false
VERBOSE=false
ENABLE_LOGGING=false
CLEANUP_DONE=false

# =============================================================================
# LOGGING
# =============================================================================

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

# =============================================================================
# CONFIG FILE HANDLING (SAFE - NO SOURCE)
# =============================================================================

# Get the config file path (user config takes precedence)
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

# Parse config file
# Usage: load_config
# Sets: CONFIG_GPU_PCI_ID, CONFIG_GPU_AUDIO_PCI_ID, CONFIG_VFIO_USER, 
#       CONFIG_VFIO_GROUP, CONFIG_STATE_FILE, CONFIG_NVIDIA_RESTART
load_config() {
    local config_file
    config_file=$(get_config_file)
    
    # Initialize with defaults
    CONFIG_GPU_PCI_ID=""
    CONFIG_GPU_AUDIO_PCI_ID=""
    CONFIG_VFIO_USER=""
    CONFIG_VFIO_GROUP=""
    CONFIG_STATE_FILE=""
    CONFIG_NVIDIA_RESTART=""
    
    if [[ -z "$config_file" ]]; then
        log_debug "No config file found, using defaults"
        return 0
    fi
    
    # Refuse to read symlinks
    if [[ -L "$config_file" ]]; then
        log_warn "Config file $config_file is a symlink. Ignoring for security."
        return 0
    fi
    
    log_debug "Loading config from $config_file"
    
    # Parse key=value pairs
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Remove leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        
        # Skip if not a valid assignment
        [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
        
        # Extract key and value
        local key="${line%%=*}"
        local value="${line#*=}"
        
        # Remove surrounding quotes from value
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"
        
        case "$key" in
            GPU_PCI_ID)       CONFIG_GPU_PCI_ID="$value" ;;
            GPU_AUDIO_PCI_ID) CONFIG_GPU_AUDIO_PCI_ID="$value" ;;
            VFIO_USER)        CONFIG_VFIO_USER="$value" ;;
            VFIO_GROUP)       CONFIG_VFIO_GROUP="$value" ;;
            STATE_FILE)       CONFIG_STATE_FILE="$value" ;;
            NVIDIA_RESTART)   CONFIG_NVIDIA_RESTART="$value" ;;
            *)                log_debug "Unknown config key: $key" ;;
        esac
    done < "$config_file"
}

# =============================================================================
# VALIDATION
# =============================================================================

# Validate PCI ID format (DDDD:BB:DD.F)
validate_pci_id() {
    local id="$1"
    local name="${2:-PCI ID}"
    
    if [[ ! "$id" =~ $PCI_ID_REGEX ]]; then
        log_error "Invalid $name format: '$id'"
        log_error "Expected format: DDDD:BB:DD.F (e.g., 0000:01:00.0)"
        return 1
    fi
    return 0
}

# Resolve PCI ID (add 0000: prefix if needed) and validate existence
resolve_pci_id() {
    local id="$1"
    local name="${2:-device}"
    
    # Add domain prefix if missing
    if [[ "$id" =~ ^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$ ]]; then
        id="0000:$id"
    fi
    
    # Validate format
    if ! validate_pci_id "$id" "$name"; then
        exit 1
    fi
    
    # Check device exists
    if [[ ! -d "/sys/bus/pci/devices/$id" ]]; then
        log_error "Device $id not found in /sys/bus/pci/devices/"
        log_error "Use 'lspci -nn' to find valid PCI IDs"
        exit 1
    fi
    
    echo "$id"
}

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

# =============================================================================
# GPU VENDOR DETECTION
# =============================================================================

# Detect GPU vendor from PCI ID
# Returns: nvidia, amd, intel, or unknown
get_gpu_vendor() {
    local pci_id="$1"
    local vendor_file="/sys/bus/pci/devices/$pci_id/vendor"
    
    if [[ ! -f "$vendor_file" ]]; then
        echo "unknown"
        return
    fi
    
    local vendor_id
    vendor_id=$(cat "$vendor_file" 2>/dev/null)
    
    case "$vendor_id" in
        0x10de) echo "nvidia" ;;
        0x1002) echo "amd" ;;
        0x8086) echo "intel" ;;
        *)      echo "unknown" ;;
    esac
}

# Get device nodes that might be in use by a GPU
# Args: vendor, pci_id
# Returns: space-separated list of device nodes to check
get_gpu_device_nodes() {
    local vendor="$1"
    local pci_id="$2"
    local nodes=""
    
    case "$vendor" in
        nvidia)
            # NVIDIA uses /dev/nvidia* device nodes
            if compgen -G "/dev/nvidia*" > /dev/null 2>&1; then
                nodes=$(echo /dev/nvidia*)
            fi
            ;;
        amd|intel)
            # AMD and Intel use DRM subsystem
            # Find the render node for this specific PCI device
            local drm_path="/sys/bus/pci/devices/$pci_id/drm"
            if [[ -d "$drm_path" ]]; then
                for card_dir in "$drm_path"/card* "$drm_path"/renderD*; do
                    if [[ -d "$card_dir" ]]; then
                        local card_name
                        card_name=$(basename "$card_dir")
                        if [[ -e "/dev/dri/$card_name" ]]; then
                            nodes="$nodes /dev/dri/$card_name"
                        fi
                    fi
                done
            fi
            ;;
    esac
    
    echo "$nodes"
}

# Get the kernel driver name for a GPU vendor
get_expected_driver() {
    local vendor="$1"
    
    case "$vendor" in
        nvidia) echo "nvidia" ;;
        amd)    echo "amdgpu" ;;
        intel)  echo "i915" ;;
        *)      echo "" ;;
    esac
}

# =============================================================================
# PROCESS MANAGEMENT
# =============================================================================

# Check for processes using device nodes and optionally kill them
# Args: device_nodes (space-separated), dry_run (true/false)
# Returns: 0 if GPU is free, 1 if still in use
check_and_release_gpu() {
    local device_nodes="$1"
    local dry_run="${2:-false}"
    
    if [[ -z "$device_nodes" ]]; then
        log_info "No device nodes to check."
        return 0
    fi
    
    log_info "Checking for processes holding the GPU..."
    log_debug "Checking nodes: $device_nodes"
    
    local pids
    # shellcheck disable=SC2086
    pids=$(fuser $device_nodes 2>/dev/null | tr -s ' ' '\n' | sort -u | grep -v '^$' || true)
    
    if [[ -z "$pids" ]]; then
        log_info "GPU is free. No processes detected."
        return 0
    fi
    
    # Resolve PIDs to app names
    local app_names=""
    for pid in $pids; do
        local name
        name=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        if [[ -n "$name" ]]; then
            app_names="$app_names $name"
        fi
    done
    
    app_names=$(echo "$app_names" | tr ' ' '\n' | sort -u | grep -v '^$' || true)
    
    echo "--------------------------------------------------------"
    log_warn "The following applications are holding the GPU:"
    echo "$app_names"
    echo "PIDs: $pids"
    echo "--------------------------------------------------------"
    
    # Check for display server
    if echo "$app_names" | grep -E -q "Xorg|Xwayland|kwin|gnome-shell|sddm|gdm|mutter|weston|sway"; then
        log_error "CRITICAL: Your Display Server is attached to this GPU."
        log_error "Aborting to prevent session crash."
        log_error "Ensure your desktop uses a different GPU (iGPU or secondary dGPU)."
        return 1
    fi
    
    if [[ "$dry_run" == true ]]; then
        log_info "[DRY-RUN] Would kill these applications and wait for GPU release"
        return 0
    fi
    
    echo "We must terminate these applications to proceed."
    read -r -t 30 -p "Kill now? [y/N]: " reply || reply=""
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        log_info "Aborting at user request."
        return 1
    fi
    
    # Strategy: try SIGTERM by PID, then use pkill with name if the process respawns
    # This takes care of apps like Spotify/Discord where parent respawns GPU-using children
    
    log_info "Sending SIGTERM to processes..."
    for pid in $pids; do
        kill -15 "$pid" 2>/dev/null || true
    done
    
    # Wait for GPU release
    # shellcheck disable=SC2086
    if wait_for_condition "GPU to be released" "! fuser $device_nodes >/dev/null 2>&1" 5 0.5; then
        log_info "Applications terminated gracefully."
        return 0
    fi
    
    # Processes respawned or refused to die - escalate to killing by name
    # This catches parent processes that respawn GPU-using children
    log_warn "Processes still holding GPU. Killing by application name..."
    for app in $app_names; do
        log_debug "Stopping all '$app' processes..."
        pkill -15 "$app" 2>/dev/null || true
    done
    
    # shellcheck disable=SC2086
    if wait_for_condition "GPU to be released" "! fuser $device_nodes >/dev/null 2>&1" 5 0.5; then
        log_info "Applications terminated after escalation."
        return 0
    fi
    
    # Dropping nuke: SIGKILL by name
    log_warn "Apps refused to close. Sending SIGKILL..."
    for app in $app_names; do
        pkill -9 "$app" 2>/dev/null || true
    done
    
    # shellcheck disable=SC2086
    if ! wait_for_condition "GPU release after SIGKILL" "! fuser $device_nodes >/dev/null 2>&1" 3 0.5; then
        log_error "GPU is STILL in use. A process likely respawned or is unkillable."
        # shellcheck disable=SC2086
        fuser -v $device_nodes 2>&1 || true
        log_error "Aborting unbind to prevent system hang."
        return 1
    fi
    
    log_info "GPU is confirmed free."
    return 0
}

# =============================================================================
# WAIT/POLLING UTILITIES
# =============================================================================

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

# =============================================================================
# STATE FILE MANAGEMENT
# =============================================================================

# Check if GPU is already in passthrough mode
is_gpu_in_passthrough() {
    local state_file="$1"
    
    [[ -f "$state_file" && -s "$state_file" ]]
}

# Validate state file security
validate_state_file() {
    local state_file="$1"
    
    if [[ -L "$state_file" ]]; then
        log_error "$state_file is a symlink. Security risk. Aborting."
        return 1
    fi
    return 0
}

# Initialize state file with proper permissions
init_state_file() {
    local state_file="$1"
    
    if ! validate_state_file "$state_file"; then
        return 1
    fi
    
    rm -f "$state_file"
    (umask 077; touch "$state_file")
    chmod 600 "$state_file"
}

# Atomically append to state file
append_state() {
    local state_file="$1"
    local pci_id="$2"
    local driver="$3"
    
    # Check for duplicates
    if grep -q "^${pci_id}," "$state_file" 2>/dev/null; then
        log_debug "State already saved for $pci_id"
        return 0
    fi
    
    log_info "Saving state: $pci_id uses $driver"
    
    # Atomic write: append to temp, then copy back
    local temp_file="${state_file}.tmp.$$"
    cp "$state_file" "$temp_file"
    echo "$pci_id,$driver" >> "$temp_file"
    mv "$temp_file" "$state_file"
    chmod 600 "$state_file"
}

# =============================================================================
# DRY RUN HELPER
# =============================================================================

dry_run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would execute: $*"
        return 0
    fi
    "$@"
}


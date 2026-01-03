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
DEFAULT_EXTRA_SERVICES=""

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
#       CONFIG_VFIO_GROUP, CONFIG_STATE_FILE, CONFIG_EXTRA_SERVICES
load_config() {
    local config_file
    config_file=$(get_config_file)
    
    # Initialize with defaults
    CONFIG_GPU_PCI_ID=""
    CONFIG_GPU_AUDIO_PCI_ID=""
    CONFIG_VFIO_USER=""
    CONFIG_VFIO_GROUP=""
    CONFIG_STATE_FILE=""
    CONFIG_EXTRA_SERVICES=""
    
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
            EXTRA_SERVICES)   CONFIG_EXTRA_SERVICES="$value" ;;
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
# SERVICE DETECTION
# =============================================================================

# Detect if a PID belongs to a systemd service (system or user)
# Returns: "system:<service_name>" or "user:<uid>:<service_name>" or empty string
# System services run under /system.slice/
# User services run under /user.slice/user-<UID>.slice/user@<UID>.service/
get_service_for_pid() {
    local pid="$1"
    local cgroup_file="/proc/$pid/cgroup"
    
    if [[ ! -f "$cgroup_file" ]]; then
        echo ""
        return
    fi
    
    # Parse cgroup file - systemd v2 format: 0::/path/to/slice/foo.service
    local cgroup_path
    cgroup_path=$(cat "$cgroup_file" 2>/dev/null | grep -oP '(?<=::).*' | head -1)
    
    # Check for system service first
    if [[ "$cgroup_path" =~ ^/system\.slice/(.+\.service)$ ]]; then
        echo "system:${BASH_REMATCH[1]}"
        return
    elif [[ "$cgroup_path" =~ /([^/]+\.service)$ ]] && [[ "$cgroup_path" == *"system.slice"* ]]; then
        # Handle nested paths like /system.slice/system-foo.slice/bar.service
        echo "system:${BASH_REMATCH[1]}"
        return
    fi
    
    # Check for user service: /user.slice/user-1000.slice/user@1000.service/app.slice/foo.service
    if [[ "$cgroup_path" =~ /user\.slice/user-([0-9]+)\.slice/user@[0-9]+\.service/.*/([^/]+\.service)$ ]]; then
        local uid="${BASH_REMATCH[1]}"
        local service="${BASH_REMATCH[2]}"
        
        # Check for transient app scopes (desktop apps launched via D-Bus/XDG)
        # These have names like: app-spotify@4063222268a84e27a52b258177c5b24a.service
        # They CAN be stopped via systemctl --user, which cleanly terminates the app
        if [[ "$service" =~ ^app-.*@.*\.service$ ]]; then
            echo "app:${uid}:${service}"  # Transient app - can stop but don't restart
            return
        fi
        
        echo "user:${uid}:${service}"
        return
    fi
    
    echo ""
}

# Get a friendly/human-readable name for a process
# Tries multiple sources to find the best name:
#   1. Transient app scope from cgroup (app-cursor@xxx → cursor)
#   2. Basename from cmdline (for bundled apps)
#   3. Fallback to process comm name
get_friendly_process_name() {
    local pid="$1"
    
    # 1. Try cgroup - extract name from transient app scope (modern DEs)
    local cgroup_path
    cgroup_path=$(cat "/proc/$pid/cgroup" 2>/dev/null | grep -oP '(?<=::).*' | head -1)
    if [[ "$cgroup_path" =~ app-([^@]+)@.*\.service ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # 2. Try cmdline - get basename of first argument
    # This works for bundled apps like /opt/cursor/cursor or /usr/share/spotify/spotify
    local cmdline
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | awk '{print $1}')
    if [[ -n "$cmdline" ]]; then
        local binary_name="${cmdline##*/}"
        # Skip generic runtime names, they're not helpful
        if [[ "$binary_name" != "electron" && "$binary_name" != "python" && \
              "$binary_name" != "python3" && "$binary_name" != "node" && \
              "$binary_name" != "bash" && "$binary_name" != "sh" ]]; then
            echo "$binary_name"
            return
        fi
    fi
    
    # 3. Fallback to comm (process name from kernel, max 15 chars)
    ps -p "$pid" -o comm= 2>/dev/null
}

# Parse service type from get_service_for_pid output
# Returns: "system", "user", "app", or ""
get_service_type() {
    local service_info="$1"
    echo "${service_info%%:*}"
}

# Parse service name from get_service_for_pid output
# Returns the service name (e.g., "nvidia-persistenced.service")
get_service_name() {
    local service_info="$1"
    local type="${service_info%%:*}"
    
    if [[ "$type" == "system" ]]; then
        echo "${service_info#system:}"
    elif [[ "$type" == "user" || "$type" == "app" ]]; then
        # user:1000:foo.service -> foo.service
        # app:1000:app-cursor@xxx.service -> app-cursor@xxx.service
        echo "${service_info##*:}"
    else
        echo ""
    fi
}

# Parse user UID from get_service_for_pid output (for user services and apps)
# Returns the UID or empty string
get_service_uid() {
    local service_info="$1"
    if [[ "$service_info" =~ ^(user|app):([0-9]+): ]]; then
        echo "${BASH_REMATCH[2]}"
    else
        echo ""
    fi
}

# Stop a service or transient app (handles system, user services, and transient apps)
# Args: service_info (from get_service_for_pid), timeout_secs (optional, default 10)
# Returns: 0 on success, 1 on failure/timeout
stop_service() {
    local service_info="$1"
    local timeout_secs="${2:-10}"
    local type
    type=$(get_service_type "$service_info")
    local name
    name=$(get_service_name "$service_info")
    
    if [[ "$type" == "system" ]]; then
        log_info "Stopping system service: $name"
        if ! timeout "$timeout_secs" systemctl stop "$name" 2>/dev/null; then
            log_warn "Service stop timed out or failed: $name"
            return 1
        fi
    elif [[ "$type" == "user" ]]; then
        local uid
        uid=$(get_service_uid "$service_info")
        local username
        username=$(id -nu "$uid" 2>/dev/null || echo "")
        
        if [[ -z "$username" ]]; then
            log_warn "Could not resolve UID $uid to username"
            return 1
        fi
        
        log_info "Stopping user service: $name (user: $username)"
        if ! timeout "$timeout_secs" sudo -u "$username" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user stop "$name" 2>/dev/null; then
            log_warn "User service stop timed out or failed: $name"
            return 1
        fi
    elif [[ "$type" == "app" ]]; then
        local uid
        uid=$(get_service_uid "$service_info")
        local username
        username=$(id -nu "$uid" 2>/dev/null || echo "")
        
        if [[ -z "$username" ]]; then
            log_warn "Could not resolve UID $uid to username"
            return 1
        fi
        
        # Extract friendly app name from app-cursor@xxx.service -> cursor
        local friendly_name="$name"
        if [[ "$name" =~ ^app-([^@]+)@ ]]; then
            friendly_name="${BASH_REMATCH[1]}"
        fi
        
        log_info "Stopping transient app: $friendly_name (user: $username)"
        if ! timeout "$timeout_secs" sudo -u "$username" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user stop "$name" 2>/dev/null; then
            log_warn "App stop timed out or failed: $friendly_name (will use kill chain)"
            return 1
        fi
    else
        return 1
    fi
}

# Start a service (handles both system and user services)
# Args: service_info (formatted as stored in state file)
# Returns: 0 on success, 1 on failure
start_service() {
    local service_info="$1"
    local type
    type=$(get_service_type "$service_info")
    local name
    name=$(get_service_name "$service_info")
    
    if [[ "$type" == "system" ]]; then
        log_info "Starting system service: $name"
        systemctl start "$name" 2>/dev/null
    elif [[ "$type" == "user" ]]; then
        local uid
        uid=$(get_service_uid "$service_info")
        local username
        username=$(id -nu "$uid" 2>/dev/null || echo "")
        
        if [[ -z "$username" ]]; then
            log_warn "Could not resolve UID $uid to username"
            return 1
        fi
        
        log_info "Starting user service: $name (user: $username)"
        sudo -u "$username" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user start "$name" 2>/dev/null
    else
        return 1
    fi
}

# =============================================================================
# PROCESS MANAGEMENT
# =============================================================================

# Global array to track stopped services (populated by check_and_release_gpu)
STOPPED_SERVICES=()

# Kill GPU-holding programs using an escalation chain
# Tries progressively more aggressive strategies until GPU is released
# Args: device_nodes, pids (space-separated), program_names (space-separated)
# Returns: 0 if GPU released, 1 if still in use after all strategies
kill_gpu_programs() {
    local device_nodes="$1"
    local pids="$2"
    local program_names="$3"
    
    # Collect process group IDs for the detected PIDs
    local pgids=""
    for pid in $pids; do
        local pgid
        pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
        if [[ -n "$pgid" && ! " $pgids " =~ " $pgid " ]]; then
            pgids="$pgids $pgid"
        fi
    done
    pgids="${pgids# }"  # Trim leading space
    
    # Define escalation strategies
    local strategies=(
        "sigterm_pids:SIGTERM to detected PIDs"
        "sigterm_pgid:SIGTERM to process groups"
        "pkill_name:pkill by process name"
        "pkill_full:pkill by command line pattern"
        "sigkill_pgid:SIGKILL to process groups"
        "sigkill_name:SIGKILL by process name"
    )
    
    for strategy_entry in "${strategies[@]}"; do
        local strategy="${strategy_entry%%:*}"
        local description="${strategy_entry#*:}"
        
        log_info "Kill strategy: $description"
        
        case "$strategy" in
            sigterm_pids)
                for pid in $pids; do
                    kill -TERM "$pid" 2>/dev/null || true
                done
                ;;
            sigterm_pgid)
                for pgid in $pgids; do
                    # Negative PGID kills the entire process group
                    kill -TERM -"$pgid" 2>/dev/null || true
                done
                ;;
            pkill_name)
                for name in $program_names; do
                    pkill -TERM "$name" 2>/dev/null || true
                done
                ;;
            pkill_full)
                # Match against full command line (catches electron apps by path)
                for name in $program_names; do
                    pkill -TERM -f "$name" 2>/dev/null || true
                done
                ;;
            sigkill_pgid)
                for pgid in $pgids; do
                    kill -KILL -"$pgid" 2>/dev/null || true
                done
                ;;
            sigkill_name)
                for name in $program_names; do
                    pkill -KILL "$name" 2>/dev/null || true
                    pkill -KILL -f "$name" 2>/dev/null || true
                done
                ;;
        esac
        
        # Check if GPU is now free
        # shellcheck disable=SC2086
        if wait_for_condition "GPU release" "! fuser $device_nodes >/dev/null 2>&1" 3 0.5; then
            log_info "GPU released after: $description"
            return 0
        fi
        
        log_debug "Strategy didn't fully release GPU, escalating..."
    done
    
    log_error "All kill strategies exhausted. GPU still in use."
    return 1
}

# Check for processes using device nodes and optionally kill them
# Args: device_nodes (space-separated), dry_run (true/false), extra_services (space-separated, optional)
# Returns: 0 if GPU is free, 1 if still in use
# Side effect: Populates STOPPED_SERVICES array with services that were stopped
check_and_release_gpu() {
    local device_nodes="$1"
    local dry_run="${2:-false}"
    local extra_services="${3:-}"
    
    STOPPED_SERVICES=()
    
    if [[ -z "$device_nodes" ]]; then
        log_info "No device nodes to check."
        return 0
    fi
    
    log_info "Checking for processes holding the GPU..."
    log_debug "Checking nodes: $device_nodes"
    
    local pids
    # shellcheck disable=SC2086
    pids=$(fuser $device_nodes 2>/dev/null | tr -s ' ' '\n' | sort -u | grep -v '^$' || true)
    
    if [[ -z "$pids" && -z "$extra_services" ]]; then
        log_info "GPU is free. No processes detected."
        return 0
    fi
    
    # Classify PIDs into services, transient apps, and programs
    local services=()       # System/user services (stop + restart later)
    local apps=()           # Transient apps (stop via systemctl, no restart)
    local programs=()       # Regular programs (kill)
    local program_pids=()   # PIDs for kill strategies
    
    for pid in $pids; do
        local name
        name=$(get_friendly_process_name "$pid")
        [[ -z "$name" ]] && continue
        
        local service_info
        service_info=$(get_service_for_pid "$pid")
        
        if [[ -n "$service_info" ]]; then
            local svc_type
            svc_type=$(get_service_type "$service_info")
            
            if [[ "$svc_type" == "app" ]]; then
                # Transient app - can stop via systemctl but don't restart
                # Deduplicate by friendly name (cursor, spotify) not full scope ID
                local app_scope_name
                app_scope_name=$(get_service_name "$service_info")
                local friendly_app_name="$app_scope_name"
                if [[ "$app_scope_name" =~ ^app-([^@]+)@ ]]; then
                    friendly_app_name="${BASH_REMATCH[1]}"
                fi
                
                # Check if we already have this app (by friendly name)
                local already_have=false
                for existing in "${apps[@]}"; do
                    local existing_name
                    existing_name=$(get_service_name "$existing")
                    if [[ "$existing_name" =~ ^app-([^@]+)@ ]]; then
                        if [[ "${BASH_REMATCH[1]}" == "$friendly_app_name" ]]; then
                            already_have=true
                            break
                        fi
                    fi
                done
                
                if [[ "$already_have" == false ]]; then
                    apps+=("$service_info")
                fi
            else
                # Real service (system or user) - stop and restart later
                if [[ ! " ${services[*]} " =~ " ${service_info} " ]]; then
                    services+=("$service_info")
                fi
            fi
        else
            # Regular program - will be killed
            if [[ ! " ${programs[*]} " =~ " ${name} " ]]; then
                programs+=("$name")
            fi
            program_pids+=("$pid")
        fi
    done
    
    # Add extra services from config (if not already detected)
    # Extra services are assumed to be system services
    for svc in $extra_services; do
        # Normalize: add .service suffix if missing
        [[ "$svc" != *.service ]] && svc="${svc}.service"
        local svc_info="system:${svc}"
        if [[ ! " ${services[*]} " =~ " ${svc_info} " ]]; then
            # Check if the service exists and is active
            if systemctl is-active "$svc" >/dev/null 2>&1; then
                services+=("$svc_info")
                log_debug "Added extra service from config: $svc"
            else
                log_debug "Extra service $svc is not active, skipping"
            fi
        fi
    done
    
    # Check for display server before proceeding
    for prog in "${programs[@]}"; do
        if [[ "$prog" =~ ^(Xorg|Xwayland|kwin|gnome-shell|sddm|gdm|mutter|weston|sway)$ ]]; then
            log_error "CRITICAL: Your Display Server ($prog) is attached to this GPU."
            log_error "Aborting to prevent session crash."
            log_error "Ensure your desktop uses a different GPU (iGPU or secondary dGPU)."
            return 1
        fi
    done
    
    # Display what we found
    echo "--------------------------------------------------------"
    if [[ ${#services[@]} -gt 0 ]]; then
        log_warn "Services holding the GPU (will be stopped and restarted later):"
        for svc_info in "${services[@]}"; do
            local svc_type svc_name
            svc_type=$(get_service_type "$svc_info")
            svc_name=$(get_service_name "$svc_info")
            if [[ "$svc_type" == "user" ]]; then
                local svc_uid
                svc_uid=$(get_service_uid "$svc_info")
                printf "  - %s (user service, uid=%s)\n" "$svc_name" "$svc_uid"
            else
                printf "  - %s (system service)\n" "$svc_name"
            fi
        done
    fi
    if [[ ${#apps[@]} -gt 0 ]]; then
        log_warn "Desktop apps holding the GPU (will be stopped):"
        for app_info in "${apps[@]}"; do
            local app_name
            app_name=$(get_service_name "$app_info")
            # Extract friendly name from app-cursor@xxx.service -> cursor
            if [[ "$app_name" =~ ^app-([^@]+)@ ]]; then
                printf "  - %s\n" "${BASH_REMATCH[1]}"
            else
                printf "  - %s\n" "$app_name"
            fi
        done
    fi
    if [[ ${#programs[@]} -gt 0 ]]; then
        log_warn "Programs holding the GPU (will be terminated):"
        printf "  - %s\n" "${programs[@]}"
    fi
    if [[ ${#program_pids[@]} -gt 0 ]]; then
        echo "Program PIDs: ${program_pids[*]}"
    fi
    echo "--------------------------------------------------------"
    
    if [[ ${#services[@]} -eq 0 && ${#apps[@]} -eq 0 && ${#programs[@]} -eq 0 ]]; then
        log_info "GPU is free. No processes detected."
        return 0
    fi
    
    if [[ "$dry_run" == true ]]; then
        log_info "[DRY-RUN] Would stop services: ${services[*]:-none}"
        log_info "[DRY-RUN] Would stop apps: ${apps[*]:-none}"
        log_info "[DRY-RUN] Would kill programs: ${programs[*]:-none}"
        STOPPED_SERVICES=("${services[@]}")
        return 0
    fi
    
    echo "We must stop these services/applications to proceed."
    read -r -t 30 -p "Proceed? [y/N]: " reply || reply=""
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        log_info "Aborting at user request."
        return 1
    fi
    
    # Step 1: Stop services via systemctl (clean shutdown, save for restart)
    # Check GPU status between services - if already free, skip remaining
    for svc_info in "${services[@]}"; do
        # Check if GPU is already free - skip remaining services
        # shellcheck disable=SC2086
        if ! fuser $device_nodes >/dev/null 2>&1; then
            log_info "GPU already released, skipping remaining services/apps"
            break
        fi
        
        if stop_service "$svc_info"; then
            STOPPED_SERVICES+=("$svc_info")
        else
            log_warn "Failed to stop service (may already be stopped)"
        fi
    done
    
    # Step 2: Stop transient apps via systemctl (clean shutdown, no restart)
    # Track apps that fail to stop so we can kill them
    # Check GPU status between apps - if already free, skip remaining
    local failed_apps=()
    for app_info in "${apps[@]}"; do
        # Check if GPU is already free - skip remaining apps
        # shellcheck disable=SC2086
        if ! fuser $device_nodes >/dev/null 2>&1; then
            log_info "GPU already released, skipping remaining apps"
            break
        fi
        
        if ! stop_service "$app_info" 5; then  # 5 second timeout for apps
            # Extract friendly name for kill chain
            local app_name
            app_name=$(get_service_name "$app_info")
            if [[ "$app_name" =~ ^app-([^@]+)@ ]]; then
                failed_apps+=("${BASH_REMATCH[1]}")
            fi
        fi
    done
    
    # Check if GPU is now free after stopping services/apps
    # shellcheck disable=SC2086
    if wait_for_condition "GPU release" "! fuser $device_nodes >/dev/null 2>&1" 2 0.5; then
        log_info "GPU released after stopping services/apps."
        return 0
    fi
    
    # Step 3: Kill remaining programs using escalation chain
    # Include any apps that failed to stop gracefully
    local all_programs=("${programs[@]}" "${failed_apps[@]}")
    
    if [[ ${#program_pids[@]} -gt 0 || ${#all_programs[@]} -gt 0 ]]; then
        # Re-detect PIDs since apps may have spawned new processes
        local current_pids
        # shellcheck disable=SC2086
        current_pids=$(fuser $device_nodes 2>/dev/null | tr -s ' ' '\n' | sort -u | grep -v '^$' || true)
        
        local pid_list="$current_pids"
        local name_list="${all_programs[*]}"
        
        if ! kill_gpu_programs "$device_nodes" "$pid_list" "$name_list"; then
            # All strategies exhausted
            # shellcheck disable=SC2086
            fuser -v $device_nodes 2>&1 || true
            log_error "Aborting unbind to prevent system hang."
            return 1
        fi
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

# Append stopped services to state file
# Args: state_file, services (array of service_info strings like "system:foo.service" or "user:1000:bar.service")
append_services_to_state() {
    local state_file="$1"
    shift
    local services=("$@")
    
    if [[ ${#services[@]} -eq 0 ]]; then
        log_debug "No services to save to state file"
        return 0
    fi
    
    local temp_file="${state_file}.tmp.$$"
    cp "$state_file" "$temp_file"
    
    for svc_info in "${services[@]}"; do
        # Check for duplicates
        if grep -q "^SERVICE:${svc_info}$" "$temp_file" 2>/dev/null; then
            log_debug "Service $svc_info already in state file"
            continue
        fi
        local svc_name
        svc_name=$(get_service_name "$svc_info")
        log_info "Saving stopped service: $svc_name"
        echo "SERVICE:${svc_info}" >> "$temp_file"
    done
    
    mv "$temp_file" "$state_file"
    chmod 600 "$state_file"
}

# Read services from state file
# Returns: newline-separated list of service_info strings
get_services_from_state() {
    local state_file="$1"
    
    if [[ ! -f "$state_file" ]]; then
        echo ""
        return
    fi
    
    grep "^SERVICE:" "$state_file" 2>/dev/null | sed 's/^SERVICE://' || true
}

# Restart services that were saved in state file
# Args: state_file, dry_run
restart_saved_services() {
    local state_file="$1"
    local dry_run="${2:-false}"
    
    local services
    services=$(get_services_from_state "$state_file")
    
    if [[ -z "$services" ]]; then
        log_debug "No services to restart from state file"
        return 0
    fi
    
    log_info "Restarting saved services..."
    
    local had_errors=false
    while IFS= read -r svc_info; do
        [[ -z "$svc_info" ]] && continue
        
        local svc_name svc_type
        svc_name=$(get_service_name "$svc_info")
        svc_type=$(get_service_type "$svc_info")
        
        if [[ "$dry_run" == true ]]; then
            if [[ "$svc_type" == "user" ]]; then
                local svc_uid
                svc_uid=$(get_service_uid "$svc_info")
                log_info "[DRY-RUN] Would restart user service: $svc_name (uid=$svc_uid)"
            else
                log_info "[DRY-RUN] Would restart system service: $svc_name"
            fi
            continue
        fi
        
        if ! start_service "$svc_info"; then
            had_errors=true
        fi
    done <<< "$services"
    
    if [[ "$had_errors" == true ]]; then
        return 1
    fi
    return 0
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


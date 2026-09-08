#!/bin/sh
#
# Runtime configuration loader for Outdoor Backup.
# Defaults are overridden by the legacy root-managed file, then by explicitly
# present options in the named UCI section outdoor-backup.config.
#

config_error() {
    printf 'outdoor-backup: configuration error: %s\n' "$1" >&2
    return 1
}

# Normalize an absolute path after rejecting ambiguous or unsafe forms.
# Arguments: $1 path value, $2 human-readable option name.
# Output: normalized path without a trailing slash (except root, which is invalid).
config_normalize_path() {
    local path="$1"
    local option_name="$2"

    case "$path" in
        ""|/)
            config_error "$option_name must be an absolute non-root path"
            return 1
            ;;
        /*)
            ;;
        *)
            config_error "$option_name must be an absolute non-root path"
            return 1
            ;;
    esac

    case "$path" in
        *[[:cntrl:]]*|*//*|*/./*|*/../*|*/.|*/..)
            config_error "$option_name contains an unsafe path segment"
            return 1
            ;;
    esac

    while [ "${path%/}" != "$path" ]; do
        path=${path%/}
    done

    printf '%s\n' "$path"
}

# Reject equal paths and either direction of ancestry before manager operations.
# Arguments: $1 backup root, $2 temporary mount point.
config_paths_are_disjoint() {
    local backup_root="$1"
    local mount_point="$2"

    case "$backup_root" in
        "$mount_point"|"$mount_point"/*)
            config_error "backup_root and mount_point must not be equal or nested"
            return 1
            ;;
    esac

    case "$mount_point" in
        "$backup_root"|"$backup_root"/*)
            config_error "backup_root and mount_point must not be equal or nested"
            return 1
            ;;
    esac

    return 0
}

# Apply one UCI option only when the CLI reports that it explicitly exists.
# Arguments: $1 UCI configuration directory, $2 option name.
config_apply_uci_option() {
    local uci_dir="$1"
    local option_name="$2"
    local option_value

    if ! option_value=$(uci -q -c "$uci_dir" get "outdoor-backup.config.$option_name"); then
        return 0
    fi

    case "$option_name" in
        enabled)
            ENABLED="$option_value"
            ;;
        backup_root)
            BACKUP_ROOT="$option_value"
            ;;
        mount_point)
            MOUNT_POINT="$option_value"
            ;;
        debug)
            DEBUG="$option_value"
            ;;
        led_green)
            LED_GREEN="$option_value"
            ;;
        led_red)
            LED_RED="$option_value"
            ;;
    esac
}

# Load and validate the effective runtime configuration.
# Argument: optional legacy shell configuration path; defaults to the package path.
# Returns: zero when all values are valid, nonzero before caller side effects.
config_load() {
    local legacy_file="${1:-/opt/outdoor-backup/conf/backup.conf}"
    local uci_dir="${UCI_CONFIG_DIR:-/etc/config}"
    local uci_file="$uci_dir/outdoor-backup"

    ENABLED=1
    BACKUP_ROOT="/mnt/ssd/SDMirrors"
    MOUNT_POINT="/mnt/sdcard"
    DEBUG=0
    LED_GREEN="/sys/class/leds/green:lan"
    LED_RED="/sys/class/leds/red:sys"

    # The legacy file is root-managed and remains the compatibility source for
    # options that this first UCI migration does not model.
    if [ -f "$legacy_file" ]; then
        # shellcheck disable=SC1090
        . "$legacy_file"
    fi

    if [ -f "$uci_file" ]; then
        if ! command -v uci >/dev/null 2>&1; then
            config_error "uci CLI is required while $uci_file exists"
            return 1
        fi
        if ! uci -c "$uci_dir" show outdoor-backup >/dev/null; then
            config_error "cannot parse $uci_file"
            return 1
        fi
        if uci -q -c "$uci_dir" get outdoor-backup.config >/dev/null; then
            config_apply_uci_option "$uci_dir" enabled
            config_apply_uci_option "$uci_dir" backup_root
            config_apply_uci_option "$uci_dir" mount_point
            config_apply_uci_option "$uci_dir" debug
            config_apply_uci_option "$uci_dir" led_green
            config_apply_uci_option "$uci_dir" led_red
        fi
    fi

    case "$ENABLED" in
        0|1)
            ;;
        *)
            config_error "enabled must be 0 or 1"
            return 1
            ;;
    esac
    case "$DEBUG" in
        0|1)
            ;;
        *)
            config_error "debug must be 0 or 1"
            return 1
            ;;
    esac

    BACKUP_ROOT=$(config_normalize_path "$BACKUP_ROOT" backup_root) || return 1
    MOUNT_POINT=$(config_normalize_path "$MOUNT_POINT" mount_point) || return 1
    config_paths_are_disjoint "$BACKUP_ROOT" "$MOUNT_POINT"
}

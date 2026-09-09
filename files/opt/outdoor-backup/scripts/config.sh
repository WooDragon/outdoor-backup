#!/bin/sh
#
# Runtime configuration loader for Outdoor Backup.
# Defaults are overridden by the legacy root-managed file, then by explicitly
# present options in the named UCI section outdoor-backup.config.
#
# config_load assigns and validates every field EXCEPT the three
# CARD_READER_* whitelist fields, which it only assigns. Those three have a
# single consumer (the hotplug trigger) and are validated separately by
# config_validate_card_reader, called only from there -- see that function's
# comment for why.
#

config_notice() {
    printf 'outdoor-backup: %s\n' "$1" >&2
    logger -t outdoor-backup "$1" 2>/dev/null || :
}

config_error() {
    config_notice "configuration error: $1"
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
        target_mount)
            TARGET_MOUNT="$option_value"
            ;;
        target_uuid)
            TARGET_UUID="$option_value"
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
        card_reader_usb_ids)
            CARD_READER_USB_IDS="$option_value"
            ;;
        card_reader_path_prefixes)
            CARD_READER_PATH_PREFIXES="$option_value"
            ;;
        card_reader_heuristic_fallback)
            CARD_READER_HEURISTIC_FALLBACK="$option_value"
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
    TARGET_MOUNT="/mnt/ssd"
    TARGET_UUID=""
    DEBUG=0
    LED_GREEN="/sys/class/leds/green:lan"
    LED_RED="/sys/class/leds/red:sys"
    CARD_READER_USB_IDS=""
    CARD_READER_PATH_PREFIXES=""
    CARD_READER_HEURISTIC_FALLBACK="yes"

    # The legacy file is root-managed and remains the compatibility source for
    # options that this first UCI migration does not model. `.` is a POSIX
    # special builtin: sourcing a file that cannot be opened terminates the
    # whole calling script, not just this function (verified on
    # openwrt/rootfs:x86_64-24.10.8). So a present-but-unreadable legacy file
    # must fail this call before reaching `.`, not be silently skipped like a
    # genuinely absent one -- a root-managed config that exists but can't be
    # read is a fail-closed condition, not a "use defaults" one.
    if [ -e "$legacy_file" ]; then
        if [ -f "$legacy_file" ] && [ -r "$legacy_file" ]; then
            # shellcheck disable=SC1090
            . "$legacy_file"
        else
            config_error "legacy configuration file $legacy_file exists but cannot be read"
            return 1
        fi
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
            config_apply_uci_option "$uci_dir" target_mount
            config_apply_uci_option "$uci_dir" target_uuid
            config_apply_uci_option "$uci_dir" debug
            config_apply_uci_option "$uci_dir" led_green
            config_apply_uci_option "$uci_dir" led_red
            config_apply_uci_option "$uci_dir" card_reader_usb_ids
            config_apply_uci_option "$uci_dir" card_reader_path_prefixes
            config_apply_uci_option "$uci_dir" card_reader_heuristic_fallback
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
    TARGET_MOUNT=$(config_normalize_path "$TARGET_MOUNT" target_mount) || return 1
    case "$TARGET_UUID" in
        ''|*[!A-Za-z0-9-]*)
            [ -z "$TARGET_UUID" ] || {
                config_error "target_uuid contains unsafe characters"
                return 1
            }
            ;;
    esac
    config_paths_are_disjoint "$BACKUP_ROOT" "$MOUNT_POINT"
}

# Validate the three card-reader whitelist fields: CARD_READER_USB_IDS,
# CARD_READER_PATH_PREFIXES, CARD_READER_HEURISTIC_FALLBACK. Reads the
# current values of those globals; does not take arguments and does not
# reassign anything but CARD_READER_USB_IDS (lowercase-normalized on
# success).
#
# Deliberately NOT called from config_load: these three fields have exactly
# one consumer, the hotplug trigger (90-outdoor-backup), which is also the
# only caller of this function. backup-manager.sh never reads them, so
# folding their validation into the shared config_load would make an
# invalid whitelist fail manager's own config_load call -- before its
# `trap cleanup`, `main()`, or `remove`-event handling are even installed --
# over a value the manager never consumes.
#
# Every return path, success or failure, restores `set -f`.
config_validate_card_reader() {
    case "$CARD_READER_HEURISTIC_FALLBACK" in
        yes|no)
            ;;
        *)
            config_error "card_reader_heuristic_fallback must be yes or no (got '$CARD_READER_HEURISTIC_FALLBACK')"
            return 1
            ;;
    esac

    if [ -n "$CARD_READER_USB_IDS" ]; then
        local usb_id_token
        set -f
        for usb_id_token in $CARD_READER_USB_IDS; do
            case "$usb_id_token" in
                [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
                    ;;
                *)
                    set +f
                    config_error "card_reader_usb_ids: invalid token '$usb_id_token' (must be a space-separated vvvv:pppp hex token)"
                    return 1
                    ;;
            esac
        done
        set +f
        CARD_READER_USB_IDS=$(printf '%s' "$CARD_READER_USB_IDS" | tr 'A-Z' 'a-z')
    fi

    if [ -n "$CARD_READER_PATH_PREFIXES" ]; then
        local prefix_token
        set -f
        for prefix_token in $CARD_READER_PATH_PREFIXES; do
            case "$prefix_token" in
                /)
                    set +f
                    config_error "card_reader_path_prefixes: '/' is not a valid entry (it would match every device path)"
                    return 1
                    ;;
                /*[*?[]*)
                    set +f
                    config_error "card_reader_path_prefixes: entry '$prefix_token' must not contain glob characters"
                    return 1
                    ;;
                */.|*/..|*/./*|*/../*)
                    set +f
                    config_error "card_reader_path_prefixes: entry '$prefix_token' must not contain a '.' or '..' path segment"
                    return 1
                    ;;
                /*)
                    ;;
                *)
                    set +f
                    config_error "card_reader_path_prefixes: entry '$prefix_token' must be an absolute path"
                    return 1
                    ;;
            esac
        done
        set +f
    fi

    return 0
}

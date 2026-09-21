#!/bin/sh
#
# Runtime configuration loader for Outdoor Backup.
# Defaults are overridden by the legacy root-managed file, then by explicitly
# present options in the named UCI section outdoor-backup.config.
#
# Unknown legacy assignments and unknown UCI options are intentionally ignored.
# This preserves upgrade compatibility without allowing unrecognized values to
# change manager behavior.
#

config_notice() {
    printf 'outdoor-backup: %s\n' "$1" >&2
    logger -t outdoor-backup "$1" 2>/dev/null || :
}

config_error() {
    config_notice "configuration error: $1"
    return 1
}

# Determine the specific reason a path is unsafe/ambiguous, without emitting
# any notice or touching syslog: purely computational, so both the mandatory
# path validator below and the optional (LED) one can each build their own
# single, accurate message from the same reason text instead of guessing at
# or hardcoding one particular failure class (PR #41 review finding 8).
# Arguments: $1 path value.
# Output: the reason phrase on failure (nothing on success).
# Returns: 0 if the path is safe, 1 otherwise.
config_path_safety_reason() {
    local path="$1"

    case "$path" in
        "")
            printf '%s' "must be an absolute non-root path (empty)"
            return 1
            ;;
        /)
            printf '%s' "must be an absolute non-root path (root)"
            return 1
            ;;
        /*)
            ;;
        *)
            printf '%s' "must be an absolute non-root path (relative)"
            return 1
            ;;
    esac

    case "$path" in
        *[[:cntrl:]]*)
            printf '%s' "contains a control character"
            return 1
            ;;
        *//*|*/./*|*/../*|*/.|*/..)
            printf '%s' "contains an unsafe path segment"
            return 1
            ;;
    esac

    return 0
}

# Normalize an absolute path after rejecting ambiguous or unsafe forms.
# Arguments: $1 path value, $2 human-readable option name.
# Output: normalized path without a trailing slash (except root, which is invalid).
config_normalize_path() {
    local path="$1"
    local option_name="$2"
    local reason

    if ! reason=$(config_path_safety_reason "$path"); then
        config_error "$option_name $reason"
        return 1
    fi

    while [ "${path%/}" != "$path" ]; do
        path=${path%/}
    done

    printf '%s\n' "$path"
}

# Normalize an optional path (LED sysfs paths): an explicitly empty value is
# a legal "unconfigured" state (see luci-app-outdoor-backup config.lua
# rmempty on led_green/led_red/led_green2/led_green3) and must pass through
# untouched, silently -- config_normalize_path's own empty-is-error rule
# only applies to the mandatory paths (backup_root/mount_point/target_mount).
#
# Unlike config_normalize_path, an unsafe/ambiguous non-empty value here is
# NOT fatal: LED paths only drive an indicator lamp, not data placement, so
# they must never veto the rest of config_load. A rejected value is logged
# exactly once via config_notice (fail-loud, logger-only -- never written to
# a file) and passed through unchanged, preserving whatever legacy/UCI value
# was already present (see EDGE05: "legacy red LED retained"). The notice
# uses config_path_safety_reason's real reason text instead of a single
# hardcoded phrase (PR #41 review finding 8): a relative or empty-looking
# LED path was previously always reported as "an unsafe path segment", which
# is misleading -- config_path_safety_reason is called directly here (not
# through config_normalize_path) precisely so no second, generic complaint
# gets logged underneath this one.
# Arguments: $1 path value, $2 human-readable option name.
config_normalize_optional_path() {
    local path="$1"
    local option_name="$2"
    local reason

    [ -n "$path" ] || {
        printf '%s\n' ""
        return 0
    }

    if reason=$(config_path_safety_reason "$path"); then
        while [ "${path%/}" != "$path" ]; do
            path=${path%/}
        done
        printf '%s\n' "$path"
        return 0
    fi

    config_notice "$option_name $reason; keeping unvalidated value as-is"
    printf '%s\n' "$path"
    return 0
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

# UCI itself -- independent of any LuCI form attribute such as rmempty --
# does not persist a genuinely empty option value: `option led_green ''`
# is dropped at parse/load time and is indistinguishable from the option
# never having been set at all (confirmed against the pinned OpenWrt UCI
# CLI: `uci get`/`show`/`export` all treat it as absent). A single-space
# value round-trips correctly, so "empty on purpose" cannot be expressed
# with an actual empty string through UCI at any layer above the raw
# config file. To let "no LED wired for this slot" (PR #41 review finding
# 4) actually be set and persisted, the four LED options accept the literal
# sentinel "none" and fold it to a real empty string here in the loader;
# LuCI's config.lua documents "none" as the UI's own no-LED value for the
# same reason.
config_resolve_led_sentinel() {
    if [ "$1" = none ]; then
        printf '%s' ''
    else
        printf '%s' "$1"
    fi
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
            LED_GREEN=$(config_resolve_led_sentinel "$option_value")
            ;;
        led_green2)
            LED_GREEN2=$(config_resolve_led_sentinel "$option_value")
            ;;
        led_green3)
            LED_GREEN3=$(config_resolve_led_sentinel "$option_value")
            ;;
        led_red)
            LED_RED=$(config_resolve_led_sentinel "$option_value")
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
    LED_GREEN="/sys/class/leds/green:wan"
    LED_GREEN2="/sys/class/leds/green:lan-1"
    LED_GREEN3="/sys/class/leds/green:lan-2"
    LED_RED="/sys/class/leds/red:power"

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
            config_apply_uci_option "$uci_dir" led_green2
            config_apply_uci_option "$uci_dir" led_green3
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
    TARGET_MOUNT=$(config_normalize_path "$TARGET_MOUNT" target_mount) || return 1
    # config_normalize_optional_path always returns 0 by design (LED paths
    # must never veto config_load; see its own comment) -- no `|| return 1`
    # here, since one would be dead code pretending to be a safety gate
    # (PR #41 review finding 9).
    LED_GREEN=$(config_normalize_optional_path "$LED_GREEN" led_green)
    LED_GREEN2=$(config_normalize_optional_path "$LED_GREEN2" led_green2)
    LED_GREEN3=$(config_normalize_optional_path "$LED_GREEN3" led_green3)
    LED_RED=$(config_normalize_optional_path "$LED_RED" led_red)
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

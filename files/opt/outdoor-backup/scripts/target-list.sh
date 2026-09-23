#!/bin/sh
#
# Read-only target-storage enumeration for the Outdoor Backup configuration UI.
# It proves each returned mount with the same target anchor and block topology
# checks used by the manager, but it never selects, mounts, or changes storage.
#

TARGET_LIST_DIR=${TARGET_LIST_SCRIPT_DIR:-/opt/outdoor-backup/scripts}
# shellcheck disable=SC1090
. "$TARGET_LIST_DIR/config.sh"
# shellcheck disable=SC1090
. "$TARGET_LIST_DIR/target.sh"
# shellcheck disable=SC1090
. "$TARGET_LIST_DIR/target-device.sh"

# Candidate rejection and configuration validation are expected during UI
# enumeration. Keep these notices local: this read-only discovery path must not
# create syslog noise, while config_load still preserves its success/failure
# contract for the caller.
config_notice() { :; }
target_notice() { :; }
target_device_notice() { :; }

# Decode mountinfo paths and return fields needed for target proof.
# Argument: mountinfo path. Output: major:minor<TAB>mount<TAB>fstype<TAB>source.
target_list_mount_records() {
    [ -r "$1" ] || return 1
    awk '
        function decode(value) {
            gsub(/\\040/, " ", value)
            gsub(/\\011/, "\t", value)
            gsub(/\\012/, "\n", value)
            gsub(/\\134/, "\\", value)
            return value
        }
        /^[[:space:]]*$/ { next }
        {
            for (field = 7; field <= NF; field++) {
                if ($field == "-") {
                    if (field + 2 > NF) {
                        bad = 1
                        next
                    }
                    print $3 "\t" decode($5) "\t" $(field + 1) "\t" $(field + 2)
                    found = 1
                    next
                }
            }
            bad = 1
        }
        END { exit bad ? 1 : 0 }
    ' "$1"
}

# Serialize a completed candidate collection exactly once.
# Arguments: newline-separated device<TAB>uuid<TAB>mount<TAB>fstype records,
# target mount, backup root. Output: one complete JSON object or failure.
target_list_encode() {
    target_list_records=$1
    target_list_current_mount=$2
    target_list_current_root=$3
    printf '%s\n' "$target_list_records" | jq -Rsc \
        --arg target_mount "$target_list_current_mount" \
        --arg backup_root "$target_list_current_root" '
        split("\n") | map(select(length > 0) | split("\t")) |
        if any(length != 4) then error("invalid candidate record") else . end |
        {targets: map({device: .[0], uuid: .[1], mount: .[2], fstype: .[3]}),
         current: {target_mount: $target_mount, backup_root: $backup_root}}
    '
}

# Enumerate fully proven target storage candidates without producing side effects.
# No arguments. Output: one JSON object; failure produces no stdout.
target_list_main() {
    [ "$#" -eq 0 ] || return 1
    config_load || return 1

    target_list_mountinfo=${TARGET_MOUNTINFO_FILE:-/proc/$$/mountinfo}
    target_list_records=$(target_list_mount_records "$target_list_mountinfo") || return 1
    target_list_candidates=
    while IFS='	' read -r target_list_mm target_list_mount target_list_fs target_list_source; do
        [ -n "$target_list_mm" ] || continue
        target_close
        if target_open "$target_list_mount" 2>/dev/null && \
            target_device_target_only "$TARGET_DEVICE"; then
            target_list_candidates="${target_list_candidates}${target_list_candidates:+
}$TARGET_BLOCK_NODE	$TARGET_BLOCK_UUID	$TARGET_MOUNT_PATH	$TARGET_FS_TYPE"
        fi
        target_close
    done <<EOF
$target_list_records
EOF

    target_list_json=$(target_list_encode "$target_list_candidates" "$TARGET_MOUNT" "$BACKUP_ROOT") || return 1
    printf '%s\n' "$target_list_json"
}

if [ "${TARGET_LIST_LIBRARY_ONLY:-0}" != 1 ]; then
    target_list_main "$@"
fi

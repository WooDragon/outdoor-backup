#!/bin/sh
#
# Block-device identity guard for outdoor-backup targets.
# Source this library after target_open: its first argument is TARGET_DEVICE
# (the live target mount's major:minor). This library writes no files.
#

# Emit a validation failure to stderr and syslog. Argument: failure reason.
target_device_notice() {
    printf 'outdoor-backup: target device error: %s\n' "$1" >&2
    logger -t outdoor-backup -p err "$1" 2>/dev/null || :
}

# Clear only state exported by target_device_validate. No arguments.
target_device_clear_state() {
    unset TARGET_BLOCK_NODE TARGET_PHYSICAL_DISK
}

# Return the configurable sysfs root. Output: canonical directory, or failure.
target_device_sysfs_root() {
    target_device_root=${TARGET_SYSFS_ROOT:-/sys}
    target_device_root=$(readlink -f "$target_device_root" 2>/dev/null) || return 1
    [ -d "$target_device_root" ] || return 1
    printf '%s\n' "$target_device_root"
}

# Accept only kernel major:minor notation. Argument: candidate notation.
target_device_valid_major_minor() {
    case "$1" in
        ''|*[^0-9:]*|:*|*:) return 1 ;;
    esac
    target_device_major=${1%%:*}
    target_device_minor=${1#*:}
    [ -n "$target_device_major" ] && [ -n "$target_device_minor" ] && \
        [ "$target_device_minor" = "${target_device_minor%%:*}" ]
}

# Accept only a safe /sys/class/block basename. Argument: DEVNAME.
target_device_valid_devname() {
    case "$1" in
        ''|.|..|*/*|*[[:cntrl:]]*|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

# Read a single sysfs value without accepting a missing or multiline value.
# Argument: file path. Output: value, or nonzero.
target_device_read_value() {
    [ -r "$1" ] || return 1
    target_device_value=$(sed -n '1p' "$1" 2>/dev/null) || return 1
    [ -n "$target_device_value" ] || return 1
    [ "$(sed -n '2p' "$1" 2>/dev/null)" = "" ] || return 1
    printf '%s\n' "$target_device_value"
}

# Resolve one major:minor to its canonical sysfs node and verify its dev file.
# Arguments: sysfs root, major:minor. Output: canonical sysfs node.
target_device_node_for_major_minor() {
    target_device_root=$1
    target_device_mm=$2
    target_device_valid_major_minor "$target_device_mm" || return 1
    target_device_link="$target_device_root/dev/block/$target_device_mm"
    [ -e "$target_device_link" ] || [ -L "$target_device_link" ] || return 1
    target_device_node=$(readlink -f "$target_device_link" 2>/dev/null) || return 1
    case "$target_device_node" in
        "$target_device_root"/*) ;;
        *) return 1 ;;
    esac
    [ -d "$target_device_node" ] || return 1
    target_device_node_mm=$(target_device_read_value "$target_device_node/dev") || return 1
    [ "$target_device_node_mm" = "$target_device_mm" ] || return 1
    printf '%s\n' "$target_device_node"
}

# Get and validate the DEVNAME represented by a canonical sysfs block node.
# Argument: sysfs node. Output: DEVNAME, or nonzero.
target_device_devname_for_node() {
    [ -r "$1/uevent" ] || return 1
    target_device_name=$(sed -n 's/^DEVNAME=//p' "$1/uevent" 2>/dev/null)
    [ "$(sed -n '/^DEVNAME=/p' "$1/uevent" 2>/dev/null | wc -l)" -eq 1 ] || return 1
    target_device_valid_devname "$target_device_name" || return 1
    printf '%s\n' "$target_device_name"
}

# Convert a safe source DEVNAME to the kernel major:minor through sysfs.
# Arguments: sysfs root, DEVNAME. Output: major:minor, or nonzero.
target_device_major_minor_for_name() {
    target_device_root=$1
    target_device_name=$2
    target_device_valid_devname "$target_device_name" || return 1
    target_device_link="$target_device_root/class/block/$target_device_name"
    [ -e "$target_device_link" ] || [ -L "$target_device_link" ] || return 1
    target_device_node=$(readlink -f "$target_device_link" 2>/dev/null) || return 1
    case "$target_device_node" in
        "$target_device_root"/*) ;;
        *) return 1 ;;
    esac
    target_device_actual_name=$(target_device_devname_for_node "$target_device_node") || return 1
    [ "$target_device_actual_name" = "$target_device_name" ] || return 1
    target_device_mm=$(target_device_read_value "$target_device_node/dev") || return 1
    target_device_valid_major_minor "$target_device_mm" || return 1
    printf '%s\n' "$target_device_mm"
}

# Identify a supported physical disk name; virtual maps and unknown devices fail.
# Argument: DEVNAME. Output: nothing; status expresses whether it is physical.
target_device_is_physical_name() {
    printf '%s\n' "$1" | grep -Eq \
        '^sd[a-z]+$|^mmcblk[0-9]+$|^nvme[0-9]+n[0-9]+$'
}

# Resolve loop backing only when it explicitly names one block partition.
# Arguments: sysfs root, loop sysfs node. Output: backing major:minor, or failure.
target_device_loop_backing_major_minor() {
    target_device_root=$1
    target_device_node=$2
    target_device_backing=$(target_device_read_value \
        "$target_device_node/loop/backing_file") || return 1
    case "$target_device_backing" in
        /dev/*) target_device_backing_name=${target_device_backing#/dev/} ;;
        *) return 1 ;;
    esac
    target_device_valid_devname "$target_device_backing_name" || return 1
    target_device_major_minor_for_name "$target_device_root" \
        "$target_device_backing_name"
}

# Resolve a device to its physical whole disk without suffix manipulation.
# Arguments: sysfs root, major:minor, recursion stack. Output: /dev/<disk>.
target_device_physical_disk_for_major_minor() {
    target_device_root=$1
    target_device_mm=$2
    target_device_seen=$3
    case "|$target_device_seen|" in
        *"|$target_device_mm|"*) return 1 ;;
    esac
    target_device_node=$(target_device_node_for_major_minor \
        "$target_device_root" "$target_device_mm") || return 1
    target_device_name=$(target_device_devname_for_node "$target_device_node") || return 1

    case "$target_device_name" in
        loop[0-9]*)
            target_device_backing_mm=$(target_device_loop_backing_major_minor \
                "$target_device_root" "$target_device_node") || return 1
            target_device_physical_disk_for_major_minor "$target_device_root" \
                "$target_device_backing_mm" "$target_device_seen|$target_device_mm"
            return
            ;;
        dm-*|md[0-9]*)
            # slaves can fan out; choosing one backing device would be a lie.
            return 1
            ;;
    esac

    if [ -f "$target_device_node/partition" ]; then
        target_device_node=$(dirname "$target_device_node")
        target_device_name=$(target_device_devname_for_node "$target_device_node") || return 1
    fi
    target_device_is_physical_name "$target_device_name" || return 1
    printf '/dev/%s\n' "$target_device_name"
}

# Read the only UUID from one exact `block info <device>` output record.
# Argument: expected device node. Output: raw UUID field value with newline, or nonzero with no output.
target_device_read_block_uuid() {
    target_device_node=$1
    command -v block >/dev/null 2>&1 || return 1
    target_device_block_output=$(block info "$target_device_node" 2>/dev/null) || return 1
    target_device_parsed_uuid=$(printf '%s\n' "$target_device_block_output" | \
        awk -v expected="$target_device_node" '
            function parse_record(line, prefix, rest, key, value) {
                prefix = expected ":"
                if (substr(line, 1, length(prefix)) != prefix)
                    return 1
                rest = substr(line, length(prefix) + 1)
                while (rest != "") {
                    if (!match(rest, /^[[:space:]]+/))
                        return 1
                    rest = substr(rest, RSTART + RLENGTH)
                    if (rest == "")
                        break
                    if (!match(rest, /^[A-Za-z_][A-Za-z0-9_]*/))
                        return 1
                    key = substr(rest, RSTART, RLENGTH)
                    rest = substr(rest, RSTART + RLENGTH)
                    if (substr(rest, 1, 1) != "=")
                        return 1
                    rest = substr(rest, 2)
                    if (!match(rest, /^"[^"]*"/))
                        return 1
                    value = substr(rest, 2, RLENGTH - 2)
                    rest = substr(rest, RLENGTH + 1)
                    if (key == "UUID") {
                        uuid_count++
                        uuid = value
                    }
                }
                return 0
            }
            {
                lines++
                if ($0 !~ /^[[:space:]]*$/) {
                    records++
                    if (parse_record($0))
                        bad = 1
                }
            }
            END {
                if (lines != 1 || records != 1 || bad || uuid_count != 1)
                    exit 1
                print uuid
            }') || return 1
    printf '%s\n' "$target_device_parsed_uuid"
}

# Compare one exact block record UUID with the configured UUID.
# Arguments: expected device node, expected UUID. Output: nothing, or failure.
target_device_uuid_matches_block() {
    target_device_node=$1
    target_device_expected_uuid=$2
    target_device_parsed_uuid=$(target_device_read_block_uuid "$target_device_node") || return 1
    [ "$target_device_parsed_uuid" = "$target_device_expected_uuid" ]
}

# Print major:minor and filesystem type for /, /rom, and /overlay mount records.
# Argument: mountinfo path. Output: major:minor<TAB>fstype records.
target_device_system_mount_records() {
    [ -r "$1" ] || return 1
    awk '
        ($5 == "/" || $5 == "/rom" || $5 == "/overlay") {
            for (field = 7; field <= NF; field++) {
                if ($field == "-") {
                    print $3 "\t" $(field + 1)
                    next
                }
            }
            bad = 1
        }
        END { exit bad ? 1 : 0 }
    ' "$1"
}

# Return success for pseudo filesystems that do not prove a physical backing.
# Argument: filesystem type.
target_device_is_pseudo_filesystem() {
    case "$1" in
        overlay|rootfs|tmpfs) return 0 ;;
        *) return 1 ;;
    esac
}

# Resolve target/source physical disks from temporary state initialized by validate.
# No arguments; returns 0 after resolving both disks, or 1 on failure.
target_device_resolve_pair() {
    target_device_node=$(target_device_node_for_major_minor \
        "$target_device_root" "$target_device_target_mm") || {
        target_device_notice 'target major:minor has no trustworthy sysfs node'
        return 1
    }
    target_device_target_name=$(target_device_devname_for_node "$target_device_node") || {
        target_device_notice 'target sysfs node has no trustworthy DEVNAME'
        return 1
    }
    case "$target_device_target_name" in
        loop*|dm-*|md*)
            target_device_notice 'target must not be a virtual block device'
            return 1
            ;;
    esac
    target_device_target_disk=$(target_device_physical_disk_for_major_minor \
        "$target_device_root" "$target_device_target_mm" '') || {
        target_device_notice 'target has no supported physical parent disk'
        return 1
    }
    target_device_source_mm=$(target_device_major_minor_for_name \
        "$target_device_root" "$target_device_source_name") || {
        target_device_notice 'source device has no trustworthy sysfs identity'
        return 1
    }
    target_device_source_disk=$(target_device_physical_disk_for_major_minor \
        "$target_device_root" "$target_device_source_mm" '') || {
        target_device_notice 'source device has no supported physical parent disk'
        return 1
    }
    if [ "$target_device_target_disk" = "$target_device_source_disk" ]; then
        target_device_notice 'target and source share a physical disk'
        return 1
    fi
    return 0
}

# Exclude physical system backing disks using temporary state initialized by validate.
# No arguments; returns 0 after exclusion, or 1 when no safe exclusion is proven.
target_device_exclude_system_disks() {
    target_device_mountinfo=${TARGET_MOUNTINFO_FILE:-/proc/$$/mountinfo}
    target_device_records=$(target_device_system_mount_records \
        "$target_device_mountinfo") || {
        target_device_notice 'system mountinfo cannot be parsed'
        return 1
    }
    target_device_proven_system=0
    while IFS='	' read -r target_device_system_mm target_device_system_fs; do
        [ -n "$target_device_system_mm" ] || continue
        target_device_is_pseudo_filesystem "$target_device_system_fs" && continue
        target_device_valid_major_minor "$target_device_system_mm" || {
            target_device_notice 'system mount has invalid block identity'
            return 1
        }
        target_device_system_disk=$(target_device_physical_disk_for_major_minor \
            "$target_device_root" "$target_device_system_mm" '') || {
            target_device_notice 'system backing block cannot be resolved safely'
            return 1
        }
        target_device_proven_system=1
        if [ "$target_device_system_disk" = "$target_device_target_disk" ] || \
            [ "$target_device_system_disk" = "$target_device_source_disk" ]; then
            target_device_notice 'target or source shares a physical system disk'
            return 1
        fi
    done <<EOF
$target_device_records
EOF
    if [ "$target_device_proven_system" -ne 1 ]; then
        target_device_notice 'no physical system backing disk was proven'
        return 1
    fi
    return 0
}

# Validate target block UUID and prove it is distinct from source and system.
# Arguments: target major:minor, expected UUID, source DEVNAME.
# Success exports TARGET_BLOCK_NODE and TARGET_PHYSICAL_DISK; failure exports none.
target_device_validate() {
    target_device_clear_state
    target_device_target_mm=$1
    target_device_expected_uuid=$2
    target_device_source_name=$3

    target_device_valid_major_minor "$target_device_target_mm" || {
        target_device_notice 'target device identity is not major:minor'
        return 1
    }
    case "$target_device_expected_uuid" in
        '' ) target_device_notice 'target UUID is unconfigured'; return 1 ;;
        *[!A-Za-z0-9-]* ) target_device_notice 'target UUID contains unsafe characters'; return 1 ;;
    esac
    target_device_valid_devname "$target_device_source_name" || {
        target_device_notice 'source device name is unsafe'
        return 1
    }
    target_device_root=$(target_device_sysfs_root) || {
        target_device_notice 'sysfs block topology is unavailable'
        return 1
    }
    command -v block >/dev/null 2>&1 || {
        target_device_notice 'official block CLI is unavailable'
        return 1
    }

    target_device_resolve_pair || return 1
    target_device_block_node="/dev/$target_device_target_name"
    target_device_uuid_matches_block "$target_device_block_node" \
        "$target_device_expected_uuid" || {
        target_device_notice 'block UUID does not uniquely match the configured target UUID'
        return 1
    }

    target_device_exclude_system_disks || return 1

    TARGET_BLOCK_NODE=$target_device_block_node
    TARGET_PHYSICAL_DISK=$target_device_target_disk
    return 0
}

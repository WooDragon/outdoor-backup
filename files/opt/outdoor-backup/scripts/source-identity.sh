#!/bin/sh
#
# Source identity snapshot and recheck library for outdoor-backup.
# A snapshot proves only that the observed source topology, filesystem UUID,
# and available gendisk diskseq agree at two observation points. diskseq is
# not a physical-card identifier: old kernels can lack it, and media changes
# not reported by the kernel cannot be detected here. This file is inert when
# sourced and neither mounts, locks, cancels, nor writes persistent state.
#

# Emit one static source-identity failure to stderr and syslog.
# Args: $1 static reason. Returns: always zero.
source_identity_notice() {
    printf 'outdoor-backup: source identity error: %s\n' "$1" >&2
    logger -t outdoor-backup -p err "$1" 2>/dev/null || :
    return 0
}

# Accept a canonical unsigned 64-bit decimal value without shell arithmetic.
# Args: $1 candidate. Returns: 0 for 1..18446744073709551615, otherwise 1.
source_identity_valid_diskseq() {
    source_identity_diskseq_candidate=$1
    case "$source_identity_diskseq_candidate" in
        ''|0|0[0-9]*|*[!0-9]*) return 1 ;;
    esac
    [ "${#source_identity_diskseq_candidate}" -lt 20 ] && return 0
    [ "${#source_identity_diskseq_candidate}" -eq 20 ] || return 1
    # shellcheck disable=SC2071 # String order follows an equal-length decimal bound.
    [ "$source_identity_diskseq_candidate" \< 18446744073709551615 ] || \
        [ "$source_identity_diskseq_candidate" = 18446744073709551615 ]
}

# Read the gendisk diskseq, using null only when its attribute is absent.
# Args: $1 canonical gendisk sysfs node. Output: decimal string or null.
# Returns: 0, or nonzero when an existing attribute cannot be trusted.
source_identity_read_diskseq() {
    source_identity_diskseq_node=$1
    source_identity_diskseq_path=$source_identity_diskseq_node/diskseq
    if [ ! -e "$source_identity_diskseq_path" ] && [ ! -L "$source_identity_diskseq_path" ]; then
        printf '%s\n' null
        return 0
    fi
    [ -f "$source_identity_diskseq_path" ] && [ ! -L "$source_identity_diskseq_path" ] || return 1
    # Count raw records before command substitution removes its final output LF.
    # A sysfs value is exactly one nonempty physical record; EOF without LF is OK.
    source_identity_diskseq_value=$(awk '
        NR == 1 { source_identity_value = $0; next }
        { source_identity_extra_record = 1 }
        END {
            if (NR != 1 || source_identity_value == "" || source_identity_extra_record)
                exit 1
            print source_identity_value
        }
    ' "$source_identity_diskseq_path") || return 1
    source_identity_valid_diskseq "$source_identity_diskseq_value" || return 1
    printf '%s\n' "$source_identity_diskseq_value"
}

# Reject strings that cannot be emitted directly as JSON string values.
# Args: $1 string. Returns: 0 or 1.
source_identity_json_safe_string() {
    case "$1" in
        *'"'*|*\\*|*[[:cntrl:]]*) return 1 ;;
    esac
    return 0
}

# Resolve one DEVNAME to its canonical node, major:minor, and parent gendisk.
# Args: $1 sysfs root, $2 DEVNAME. Output: node<TAB>major:minor<TAB>diskseq.
# Returns: 0 only for a fully revalidated topology sample.
source_identity_read_topology() {
    source_identity_topology_root=$1
    source_identity_topology_name=$2
    source_identity_topology_mm=$(target_device_major_minor_for_name \
        "$source_identity_topology_root" "$source_identity_topology_name") || return 1
    source_identity_topology_node=$(target_device_node_for_major_minor \
        "$source_identity_topology_root" "$source_identity_topology_mm") || return 1
    source_identity_topology_actual_name=$(target_device_devname_for_node \
        "$source_identity_topology_node") || return 1
    [ "$source_identity_topology_actual_name" = "$source_identity_topology_name" ] || return 1
    if [ -e "$source_identity_topology_node/partition" ] || \
        [ -L "$source_identity_topology_node/partition" ]; then
        source_identity_topology_parent=${source_identity_topology_node%/*}
    else
        source_identity_topology_parent=$source_identity_topology_node
    fi
    case "$source_identity_topology_parent" in
        "$source_identity_topology_root"/*) ;;
        *) return 1 ;;
    esac
    [ -d "$source_identity_topology_parent" ] || return 1
    source_identity_topology_parent_name=$(target_device_devname_for_node \
        "$source_identity_topology_parent") || return 1
    source_identity_topology_parent_mm=$(target_device_read_value \
        "$source_identity_topology_parent/dev") || return 1
    target_device_valid_major_minor "$source_identity_topology_parent_mm" || return 1
    source_identity_topology_parent_check=$(target_device_node_for_major_minor \
        "$source_identity_topology_root" "$source_identity_topology_parent_mm") || return 1
    [ "$source_identity_topology_parent_check" = "$source_identity_topology_parent" ] || return 1
    source_identity_topology_diskseq=$(source_identity_read_diskseq \
        "$source_identity_topology_parent") || return 1
    source_identity_json_safe_string "$source_identity_topology_node" || return 1
    printf '%s\t%s\t%s\n' "$source_identity_topology_node" \
        "$source_identity_topology_mm" "$source_identity_topology_diskseq"
}

# Read a normalized filesystem UUID from the exact source node.
# Args: $1 DEVNAME. Output: normalized UUID. Returns: 0 or 1.
source_identity_read_filesystem_uuid() {
    source_identity_uuid_name=$1
    card_identity_read_source_uuid "/dev/$source_identity_uuid_name"
}

# Collect one stable snapshot without writing diagnostics.
# Args: $1 DEVNAME. Output: compact JSON snapshot. Returns: 0 or 1.
source_identity_collect() {
    source_identity_collect_name=$1
    target_device_valid_devname "$source_identity_collect_name" || return 1
    source_identity_collect_root=$(target_device_sysfs_root) || return 1
    source_identity_collect_first=$(source_identity_read_topology \
        "$source_identity_collect_root" "$source_identity_collect_name") || return 1
    IFS='	' read -r source_identity_collect_node source_identity_collect_mm \
        source_identity_collect_diskseq <<EOF
$source_identity_collect_first
EOF
    source_identity_collect_uuid=$(source_identity_read_filesystem_uuid \
        "$source_identity_collect_name") || return 1
    source_identity_collect_second=$(source_identity_read_topology \
        "$source_identity_collect_root" "$source_identity_collect_name") || return 1
    [ "$source_identity_collect_first" = "$source_identity_collect_second" ] || return 1
    source_identity_json_safe_string "$source_identity_collect_uuid" || return 1
    if [ "$source_identity_collect_diskseq" = null ]; then
        source_identity_collect_diskseq_json=null
    else
        source_identity_collect_diskseq_json="\"$source_identity_collect_diskseq\""
    fi
    printf '{"devname":"%s","node":"%s","major_minor":"%s","filesystem_uuid":"%s","diskseq":%s}\n' \
        "$source_identity_collect_name" "$source_identity_collect_node" \
        "$source_identity_collect_mm" "$source_identity_collect_uuid" \
        "$source_identity_collect_diskseq_json"
}

# Capture one source identity snapshot.
# Args: $1 DEVNAME. Output: one compact JSON snapshot only. Returns: 0 or 1.
source_identity_read() {
    [ "$#" -eq 1 ] || {
        source_identity_notice 'source snapshot arguments are invalid'
        return 1
    }
    source_identity_collect "$1" || {
        source_identity_notice 'source snapshot is unavailable or changed during observation'
        return 1
    }
}

# Re-read and compare a full source identity snapshot as opaque data.
# Args: $1 DEVNAME, $2 expected complete snapshot JSON. Output: nothing.
# Returns: 0 only for exact same stable snapshot, otherwise 1.
source_identity_matches() {
    [ "$#" -eq 2 ] || {
        source_identity_notice 'source snapshot recheck arguments are invalid'
        return 1
    }
    source_identity_match_current=$(source_identity_collect "$1") || {
        source_identity_notice 'source snapshot cannot be rechecked'
        return 1
    }
    [ "$source_identity_match_current" = "$2" ] || {
        source_identity_notice 'source snapshot differs from the expected snapshot'
        return 1
    }
    return 0
}

#!/bin/sh
#
# Source filesystem identity binding for outdoor-backup.
# This library is inert when sourced. Its caller must already have a live,
# writable target anchor and the target-device UUID reader available.
#

# Emit an identity-policy failure without changing target or source state.
# Args: $1 human-readable failure reason. Returns: always zero.
card_identity_notice() {
    printf 'outdoor-backup: card identity error: %s\n' "$1" >&2
    logger -t outdoor-backup -p err "$1" 2>/dev/null || :
    return 0
}

# Normalize one source filesystem UUID after accepting only portable characters.
# Args: $1 raw UUID. Output: lowercase UUID. Returns: 0 or 1.
card_identity_normalize_source_uuid() {
    card_identity_raw_uuid=$1
    case "$card_identity_raw_uuid" in
        ''|*[!A-Za-z0-9-]*) return 1 ;;
    esac
    LC_ALL=C printf '%s\n' "$card_identity_raw_uuid" | tr 'A-Z' 'a-z'
}

# Read and normalize one source filesystem UUID through the established getter.
# Args: $1 source block node. Output: lowercase UUID. Returns: 0 or 1.
card_identity_read_source_uuid() {
    card_identity_source_node=$1
    card_identity_raw_uuid=$(target_device_read_block_uuid "$card_identity_source_node") || {
        card_identity_notice 'cannot read source filesystem UUID'
        return 1
    }
    card_identity_normalize_source_uuid "$card_identity_raw_uuid" || {
        card_identity_notice 'source filesystem UUID is empty or unsafe'
        return 1
    }
}

# Validate one card UUID using the existing card configuration rule.
# Args: $1 SD UUID. Returns: 0 or 1.
card_identity_valid_sd_uuid() {
    is_valid_uuid "$1"
}

# Convert the anchored backup root to its safe relative identity directory.
# Args: none. Output: relative path. Returns: 0 or 1.
card_identity_relative_directory() {
    case "${TARGET_BACKUP_ROOT:-}" in
        "${TARGET_FD_ROOT:-/nonexistent}"/*) ;;
        *) return 1 ;;
    esac
    card_identity_relative_root=${TARGET_BACKUP_ROOT#"$TARGET_FD_ROOT"/}
    [ -n "$card_identity_relative_root" ] || return 1
    printf '%s/.card-identities\n' "$card_identity_relative_root"
}

# Check an existing record's exact v1 data contract.
# Args: $1 record path, $2 current SD UUID, $3 normalized source UUID.
# Returns: 0 only for an exact matching regular v1 record.
card_identity_record_matches() {
    card_identity_record=$1
    card_identity_sd_uuid=$2
    card_identity_source_uuid=$3
    [ -f "$card_identity_record" ] && [ ! -L "$card_identity_record" ] || return 1
    jq -se --arg sd_uuid "$card_identity_sd_uuid" \
        --arg fs_uuid "$card_identity_source_uuid" '
        if length != 1 then false else
            .[0] | type == "object" and
            (keys | sort == ["fs_uuid", "sd_uuid", "version"]) and
            (.version == 1 and (.version | type == "number")) and
            (.sd_uuid == $sd_uuid and (.sd_uuid | type == "string")) and
            (.fs_uuid == $fs_uuid and (.fs_uuid | type == "string") and
             (.fs_uuid | length > 0) and
             (.fs_uuid | all(explode[]; (. >= 48 and . <= 57) or
                 (. >= 97 and . <= 122) or . == 45)))
        end
    ' "$card_identity_record" >/dev/null 2>&1
}

# Publish a missing identity record through the anchored target only.
# Args: $1 formal record, $2 SD UUID, $3 normalized source UUID.
# Returns: 0 after publication and final anchor check, otherwise nonzero.
card_identity_publish_record() {
    card_identity_publish_path=$1
    card_identity_publish_sd_uuid=$2
    card_identity_publish_source_uuid=$3
    card_identity_publish_dir=${card_identity_publish_path%/*}
    card_identity_publish_temp=

    if [ -e "$card_identity_publish_path" ] || [ -L "$card_identity_publish_path" ]; then
        card_identity_notice 'card identity record appeared during provisioning'
        return 1
    fi
    target_anchor_healthy || return 1
    card_identity_publish_temp=$(mktemp "$card_identity_publish_dir/.${card_identity_publish_sd_uuid}.json.XXXXXX") || {
        card_identity_notice 'cannot create temporary card identity record'
        return 1
    }
    if [ ! -f "$card_identity_publish_temp" ] || [ -L "$card_identity_publish_temp" ]; then
        rm -f "$card_identity_publish_temp" || :
        card_identity_notice 'temporary card identity record is not a regular file'
        return 1
    fi
    if ! jq -n --arg sd_uuid "$card_identity_publish_sd_uuid" \
        --arg fs_uuid "$card_identity_publish_source_uuid" \
        '{version: 1, sd_uuid: $sd_uuid, fs_uuid: $fs_uuid}' > "$card_identity_publish_temp"; then
        rm -f "$card_identity_publish_temp" || :
        card_identity_notice 'cannot write card identity record'
        return 1
    fi
    if [ ! -f "$card_identity_publish_temp" ] || [ -L "$card_identity_publish_temp" ] || \
        ! card_identity_record_matches "$card_identity_publish_temp" \
            "$card_identity_publish_sd_uuid" "$card_identity_publish_source_uuid"; then
        rm -f "$card_identity_publish_temp" || :
        card_identity_notice 'temporary card identity record failed validation'
        return 1
    fi
    if ! target_anchor_healthy || [ -e "$card_identity_publish_path" ] || \
        [ -L "$card_identity_publish_path" ]; then
        rm -f "$card_identity_publish_temp" || :
        card_identity_notice 'target changed or card identity record appeared before publication'
        return 1
    fi
    if ! mv "$card_identity_publish_temp" "$card_identity_publish_path"; then
        rm -f "$card_identity_publish_temp" || :
        card_identity_notice 'cannot publish card identity record'
        return 1
    fi
    if ! sync; then
        card_identity_notice 'cannot synchronize card identity record'
        return 1
    fi
    if ! target_anchor_healthy || ! card_identity_record_matches \
        "$card_identity_publish_path" "$card_identity_publish_sd_uuid" \
        "$card_identity_publish_source_uuid"; then
        card_identity_notice 'published card identity record cannot be revalidated'
        return 1
    fi
    return 0
}

# Bind a card configuration UUID to its observed source filesystem UUID.
# Args: $1 SD UUID, $2 normalized source filesystem UUID. Returns: 0 or 1.
card_identity_bind() {
    card_identity_sd_uuid=$1
    card_identity_source_uuid=$(card_identity_normalize_source_uuid "$2") || {
        card_identity_notice 'source filesystem UUID is empty or unsafe'
        return 1
    }
    if ! card_identity_valid_sd_uuid "$card_identity_sd_uuid"; then
        card_identity_notice 'SD UUID is invalid for card identity binding'
        return 1
    fi
    target_anchor_healthy || return 1
    card_identity_relative_dir=$(card_identity_relative_directory) || {
        card_identity_notice 'target identity directory is not anchored'
        return 1
    }
    target_prepare_directory "$card_identity_relative_dir" || return 1
    target_anchor_healthy || return 1
    card_identity_record="$TARGET_FD_ROOT/$card_identity_relative_dir/$card_identity_sd_uuid.json"

    if [ -e "$card_identity_record" ] || [ -L "$card_identity_record" ]; then
        if card_identity_record_matches "$card_identity_record" "$card_identity_sd_uuid" \
            "$card_identity_source_uuid"; then
            return 0
        fi
        if [ -f "$card_identity_record" ] && [ ! -L "$card_identity_record" ]; then
            card_identity_notice 'card identity conflict'
        else
            card_identity_notice 'card identity record is not a regular file'
        fi
        return 1
    fi
    card_identity_publish_record "$card_identity_record" "$card_identity_sd_uuid" \
        "$card_identity_source_uuid"
}

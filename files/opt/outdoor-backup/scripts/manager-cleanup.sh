#!/bin/sh
# Source-only mirror cleanup. Manager owns traps, lease and the existing lock.
# Exit contract: 1 badargs/force, 2 badroot, 3 failure, 4 dateunsupported,
# 5 busy (closed admission/lock timeout), 130/143 cancelled. No Perl or media hash.

# Emit a fixed machine-readable code. Argument: actual exit status; returns zero.
manager_cleanup_error() {
    case "$1" in
        1) cleanup_error=badargs ;;
        2) cleanup_error=badroot ;;
        4) cleanup_error=dateunsupported ;;
        5) cleanup_error=busy ;;
        130|143) cleanup_error=cancelled ;;
        *) cleanup_error=failure ;;
    esac
    printf 'outdoor-backup: cleanup error=%s\n' "$cleanup_error" >&2
}

# Check every canonical ancestor without creating or following anything.
# Argument: absolute configured root. Returns 2 unsafe path, 3 read failure, 4 date.
cleanup_data_ancestors() {
    local probe=$1
    case "$probe" in /*) ;; *) return 2 ;; esac
    case "$probe" in /|*/|*//*|*/./*|*/../*|*/.|*/..|*[[:cntrl:]]*) return 2 ;; esac
    while :; do
        [ ! -L "$probe" ] && [ -d "$probe" ] || return 2
        [ -r "$probe" ] && [ -x "$probe" ] || return 3
        cleanup_data_date_state "$probe" && return 4
        [ "$probe" != / ] || break
        probe=${probe%/*}
        [ -n "$probe" ] || probe=/
    done
    return 0
}

# Recognize suspicious date state by presence, never by trusting its JSON.
# Argument: directory. Returns 0 for date state, 1 for clear (including dangling links).
cleanup_data_date_state() {
    local directory=$1 name
    for name in .outdoor-backup library.json routes; do
        if [ -e "$directory/$name" ] || [ -L "$directory/$name" ]; then return 0; fi
    done
    return 1
}

# Preflight the whole tree including hidden/reserved children, without line splitting.
# Argument: existing FD-relative directory. Returns 3 unsupported/read failure, 4 date.
# Local recursion variables prevent a deeper traversal from changing the outer set.
cleanup_data_tree_check() {
    local directory=$1 child
    [ ! -L "$directory" ] && [ -d "$directory" ] || return 3
    [ -r "$directory" ] && [ -x "$directory" ] || return 3
    ls -A "$directory" >/dev/null || return 3
    cleanup_data_date_state "$directory" && return 4
    for child in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
        check_cancel_request || return "$?"
        if [ ! -e "$child" ] && [ ! -L "$child" ]; then
            # Only an unexpanded glob may be absent. A listed entry disappearing
            # or becoming unreadable is not an empty directory.
            case "$child" in
                "$directory/*"|"$directory/.[!.]*"|"$directory/..?*") continue ;;
                *) return 3 ;;
            esac
        fi
        [ ! -L "$child" ] || return 3
        if [ -d "$child" ]; then
            cleanup_data_tree_check "$child" || return "$?"
        elif [ -f "$child" ]; then
            [ -r "$child" ] || return 3
            # BusyBox ls performs the metadata read; stat is not a baseline applet.
            ls -ld "$child" >/dev/null || return 3
        else
            return 3
        fi
    done
    return 0
}

# Check the original lease/owner/FD9/device identity before a reader or writer.
# No arguments. Returns original cancellation code or 3 for failed owner/target proof.
manager_cleanup_gate() {
    check_cancel_request || return "$?"
    lock_is_owned_by_self || return 3
    target_anchor_healthy || return 3
    target_device_target_only "$TARGET_DEVICE" || return 3
    [ "$TARGET_BLOCK_UUID" = "$TARGET_UUID" ] || return 3
    check_cancel_request
}

# Admit an existing exact configured root through FD9, without target_prepare_root.
# No arguments. Returns 2 invalid root, 3 target failure, 4 date; never mkdirs media.
manager_cleanup_admit() {
    [ "$BACKUP_LAYOUT" = mirror ] || return 4
    [ "$CLEANUP_REQUEST_ROOT" = "$BACKUP_ROOT" ] || return 2
    case "$BACKUP_ROOT" in "$TARGET_MOUNT"/*) ;; *) return 2 ;; esac
    cleanup_data_ancestors "$BACKUP_ROOT" || return "$?"
    target_open "$TARGET_MOUNT" || return 3
    TARGET_BACKUP_RELATIVE=${BACKUP_ROOT#"$TARGET_MOUNT"/}
    TARGET_BACKUP_PATH=$BACKUP_ROOT
    TARGET_BACKUP_ROOT=$TARGET_FD_ROOT/$TARGET_BACKUP_RELATIVE
    manager_cleanup_gate || return "$?"
    # Verify all existing components via the anchor, rather than creating a root.
    local rest=$TARGET_BACKUP_RELATIVE path=$TARGET_FD_ROOT component
    while [ -n "$rest" ]; do
        component=${rest%%/*}
        path=$path/$component
        [ ! -L "$path" ] && [ -d "$path" ] || return 2
        case "$rest" in */*) rest=${rest#*/} ;; *) rest= ;; esac
    done
    # Phase two covers all candidates before the first delete; hidden state too.
    cleanup_data_tree_check "$TARGET_BACKUP_ROOT" || return "$?"
    manager_cleanup_gate
}

# Load existing aliases as data, never source or recreate absent configuration.
# No arguments. Returns 0 with CLEANUP_ALIASES JSON, or 3 for unsupported/read failure.
manager_cleanup_aliases() {
    local path=$BASE_DIR/conf/aliases.json probe=$BASE_DIR/conf
    while :; do
        [ ! -L "$probe" ] && [ -d "$probe" ] || return 3
        [ "$probe" != / ] || break
        probe=${probe%/*}
        [ -n "$probe" ] || probe=/
    done
    CLEANUP_ALIASES='{}'
    if [ -e "$path" ] || [ -L "$path" ]; then
        [ ! -L "$path" ] && [ -f "$path" ] && [ -r "$path" ] || return 3
        CLEANUP_ALIASES=$(jq -ce 'select(type == "object" and .version == "1.0") |
            .aliases | select(type == "object") |
            select(all(.[]; type == "object" and (.alias == null or (.alias | type) == "string")))' "$path") || return 3
        if [ "$ACTION" = cleanup ] && [ "$CLEANUP_KEEP_ALIASES" = 0 ]; then
            [ -w "$path" ] || return 3
        fi
    fi
    return 0
}

# Visit precisely the legacy deletion set: visible children of one UUID directory.
# Arguments: preview|delete, FD-relative card directory. Sets CLEANUP_CARD_SIZE for preview.
# Returns original cancellation, or 3 on size/delete failure. Hidden level-one stays.
cleanup_data_children() {
    local operation=$1 directory=$2 child usage kilobytes
    CLEANUP_CARD_SIZE=0
    for child in "$directory"/*; do
        if [ ! -e "$child" ] && [ ! -L "$child" ]; then
            [ "$child" = "$directory/*" ] && continue
            return 3
        fi
        manager_cleanup_gate || return "$?"
        case "$operation" in
            preview)
                usage=$(du -sk "$child") || return 3
                kilobytes=${usage%%[!0-9]*}
                case "$kilobytes" in ''|*[!0-9]*) return 3 ;; esac
                CLEANUP_CARD_SIZE=$(jq -en --argjson total "$CLEANUP_CARD_SIZE" --argjson kb "$kilobytes" \
                    '$total + ($kb * 1024) | select(. >= 0 and . <= 9007199254740991)') || return 3
                ;;
            delete) rm -rf -- "$child" || return 3 ;;
            *) return 3 ;;
        esac
        # A current rm may finish after TERM. The next gate forbids a new writer.
        manager_cleanup_gate || return "$?"
    done
    return 0
}

# Generate the v1 fixed schema using jq's exact text escaping, never HTML or ls parsing.
# No arguments. Returns 0 and stdout JSON, or nonzero; owner is released before browser use.
manager_cleanup_preview() {
    local directory uuid cards='[]'
    for directory in "$TARGET_BACKUP_ROOT"/*; do
        [ -d "$directory" ] || continue
        uuid=${directory##*/}
        is_valid_uuid "$uuid" || continue
        cleanup_data_children preview "$directory" || return "$?"
        cards=$(printf '%s\n' "$cards" | jq -c --arg uuid "$uuid" --argjson aliases "$CLEANUP_ALIASES" \
            --arg path "$BACKUP_ROOT/$uuid" --argjson bytes "$CLEANUP_CARD_SIZE" \
            '($aliases[$uuid].alias // "") as $name |
             . + [{uuid:$uuid, display_name:(if ($name | length) > 0 then $name else "SD_" + $uuid[0:8] end),
                   size_bytes:$bytes, path:$path}]') || return 3
    done
    manager_cleanup_gate || return "$?"
    printf '%s\n' "$cards" | jq -ce --arg root "$BACKUP_ROOT" --arg uuid "$TARGET_UUID" \
        '{version:1,layout:"mirror",backup_root:$root,target_uuid:$uuid,cards:.,
          total_size_bytes:(map(.size_bytes)|add // 0),total_cards:length}' || return 3
}

# Delete only the set preflighted above; aliases are optional, identity history never is.
# No arguments. Returns 0 only after every deletion, sync and final gate succeeds.
manager_cleanup_execute() {
    local directory uuid
    for directory in "$TARGET_BACKUP_ROOT"/*; do
        [ -d "$directory" ] || continue
        uuid=${directory##*/}
        is_valid_uuid "$uuid" || continue
        cleanup_data_children delete "$directory" || return "$?"
    done
    manager_cleanup_gate || return "$?"
    if [ "$CLEANUP_KEEP_ALIASES" = 0 ] && [ -f "$BASE_DIR/conf/aliases.json" ]; then
        printf '{"version":"1.0","aliases":{}}\n' > "$BASE_DIR/conf/aliases.json" || return 3
    fi
    manager_cleanup_gate || return "$?"
    sync || return 3
    manager_cleanup_gate
}

# Finalize cleanup in the original owner order: close anchor, release lock, release lease.
# No arguments; preserves the original status and sticky cancel, never writes backup status/LED.
manager_cleanup_finish() {
    local result=$?
    trap - EXIT
    set +e
    trap '' INT TERM
    [ "$BACKUP_CANCEL_CODE" -eq 0 ] || result=$BACKUP_CANCEL_CODE
    target_close
    release_lock
    if [ "$(readlink "$LOCK_LINK" 2>/dev/null)" = "/proc/$$" ]; then
        [ "$result" -ne 0 ] || result=3
    fi
    service_lease_release || { [ "$result" -ne 0 ] || result=3; }
    [ "$result" -eq 0 ] || manager_cleanup_error "$result"
    exit "$result"
}

# Run one admitted administrator action with existing manager locking/cancel machinery.
# No arguments. Returns operation's code; EXIT trap always drains synchronous work first.
manager_cleanup_main() {
    trap manager_cleanup_finish EXIT
    trap 'record_cancel 130' INT
    trap 'record_cancel 143' TERM
    # No application log or LED writes on this branch, including lock contention.
    log_info() { printf 'outdoor-backup: cleanup: %s\n' "$1" >&2; }
    log_error() { log_info "$1"; }
    log_warn() { log_info "$1"; }
    check_cancel_request || return "$?"
    if ! acquire_lock; then
        [ "$BACKUP_CANCEL_CODE" -eq 0 ] || return "$BACKUP_CANCEL_CODE"
        return 5
    fi
    manager_cleanup_admit || return "$?"
    manager_cleanup_aliases || return "$?"
    manager_cleanup_gate || return "$?"
    if [ "$ACTION" = cleanup-preview ]; then manager_cleanup_preview; else manager_cleanup_execute; fi
}

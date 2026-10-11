#!/bin/sh
# Lazy manager-owned date orchestration. No traps, PID manager or status writer.
# All functions take no arguments unless noted and return 0/nonzero.
MANAGER_DATE_ARCHIVE='{"files_total":null,"routes_total":null,"excluded_total":null,"undated_total":null}'
MANAGER_DATE_WARNINGS='[]'

# Freeze validated result counters/warning aggregates before private work removal.
# Reads file paths, not --argjson strings; never exposes source paths in warnings.
manager_date_snapshot() {
    MANAGER_DATE_ARCHIVE=$(jq -ce '{files_total,routes_total,excluded_total,undated_total}' "$MEDIA_DATE_RESULT_JSON") || return 1
    MANAGER_DATE_WARNINGS=$(jq -ce '.warnings | sort_by(.code) | group_by(.code) | map({code:.[0].code,count:length})' "$MEDIA_DATE_RESULT_JSON") || return 1
    MANAGER_DATE_SOURCE_BYTES=$MEDIA_DATE_SOURCE_BYTES_TOTAL
    MANAGER_DATE_PENDING_BYTES=$MEDIA_DATE_PENDING_BYTES_BOUND
    MANAGER_DATE_REPLACEMENT_BYTES=$MEDIA_DATE_REPLACEMENT_BYTES_BOUND
    MANAGER_DATE_REPLACED_PATH="$TARGET_BACKUP_PATH/.outdoor-backup/replaced/${MEDIA_DATE_REPLACED_DIR##*/}"
}

# Construct the exact status.sh seventeenth argument from task-owned snapshots.
# Unknown planning counts remain null. Result/paths survive module cleanup.
manager_date_task() {
    jq -cn --arg phase "$MANAGER_DATE_PHASE" --arg comparison "$BACKUP_COMPARISON_MODE" \
        --argjson archive "$MANAGER_DATE_ARCHIVE" \
        --argjson warnings "${MANAGER_DATE_WARNINGS:-[]}" \
        --argjson count "${MANAGER_DATE_REPLACED_COUNT:-null}" \
        --arg path "${MANAGER_DATE_REPLACED_PATH:-}" '
        {version:1,layout:"date",phase:$phase,comparison_mode:$comparison,
         archive:$archive,warnings:$warnings,
         replaced:{files_count:$count,path:(if $path == "" then null else $path end)}}'
}

# Date-only status using the same sole writer, display root and public root path.
# Args: running|failed|completed, error, optional live progress JSON.
manager_date_status() {
    md_status_task=$(manager_date_task) || return 1
    md_status_percent=$BACKUP_STATUS_PERCENT
    md_status_files=${BACKUP_STATUS_FILES_DONE:-0}
    md_status_bytes=${BACKUP_STATUS_BYTES_DONE:-0}
    if [ "$1" = completed ]; then
        md_status_percent=100
        md_status_files=$BACKUP_TRANSFER_FILES
        md_status_bytes=$BACKUP_TRANSFER_BYTES
    fi
    write_status "$1" "$SD_UUID" "$BACKUP_DISPLAY_NAME" "$DEVNAME" \
        "$BACKUP_STARTED_AT" "$md_status_percent" 0 "$md_status_files" \
        "$md_status_bytes" "$md_status_bytes" "${BACKUP_STATUS_SPEED:-0}" "$TARGET_FD_ROOT" \
        "$MANAGER_DATE_DISPLAY_ROOT" "$2" "$MANAGER_DATE_DISPLAY_ROOT" "${3:-null}" "$md_status_task"
}

# Plan then perform exactly one actual transfer. Module owns route-first claim;
# this manager owns aliases, status transitions and the final success decision.
perform_date_backup() {
    MANAGER_DATE_PHASE=planning
    MANAGER_DATE_DISPLAY_ROOT=$LIBRARY_ROOT
    BACKUP_DISPLAY_NAME=$(get_display_name "$SD_UUID") || return 1
    BACKUP_STARTED_AT=$(date +%s) || return 1
    backup_status_begin || { ERROR_TYPE=status; return 1; }
    STATUS_STARTED=1
    media_date_prepare || { ERROR_TYPE=${MEDIA_DATE_ERROR:-planning}; return 1; }
    BACKUP_ROOT=$TARGET_BACKUP_ROOT
    # Route/identity have both passed admission; only now may aliases change.
    update_alias_last_seen "$SD_UUID" || log_warn 'Failed to update alias timestamp'
    media_date_plan || { ERROR_TYPE=${MEDIA_DATE_ERROR:-planning}; return 1; }
    manager_date_snapshot || { ERROR_TYPE=planning; return 1; }
    manager_date_space || return 1
    target_anchor_healthy || { ERROR_TYPE=verify_failed; return 1; }
    check_cancel_request || return "$?"
    media_date_directory .logs || { ERROR_TYPE=${MEDIA_DATE_ERROR:-planning}; return 1; }
    BACKUP_LOG_FILE="$TARGET_BACKUP_ROOT/.logs/backup_${SD_UUID}_$(date +%Y%m%d_%H%M%S).log"
    MANAGER_DATE_PHASE=transferring
    manager_date_status running '' || { ERROR_TYPE=status; return 1; }
    check_cancel_request || return "$?"
    if backup_transfer_date "$MEDIA_DATE_WORK/view" "$TARGET_BACKUP_ROOT" \
        "$BACKUP_LOG_FILE" "$BACKUP_COMPARISON_MODE" "$MEDIA_DATE_REPLACED_DIR"; then
        check_cancel_request || return "$?"
        [ "$BACKUP_STATUS_WRITE_FAILED" -eq 0 ] || { ERROR_TYPE=status; return 1; }
        BACKUP_TRANSFER_FINISHED_AT=$(date +%s) || return 1
        BACKUP_TRANSFER_FINISHED_TEXT=$(date '+%Y-%m-%d %H:%M:%S') || return 1
        BACKUP_TRANSFER_SUCCEEDED=1
        return 0
    else
        md_transfer_exit=$?
    fi
    ERROR_TYPE=${BACKUP_TRANSFER_ERROR:-rsync}
    return "$md_transfer_exit"
}

# Existing minimum MB gate through FD9; bounds are diagnostics, not admission
# arithmetic on large byte counts or a promise that this target cannot fill.
manager_date_space() {
    minimum_free=${MIN_FREE_SPACE:-1024}
    is_safe_mb_value "$minimum_free" || { ERROR_TYPE=no_space; return 1; }
    target_free=$(get_available_space_mb "$TARGET_FD_ROOT") || return 1
    is_safe_mb_value "$target_free" || { ERROR_TYPE=no_space; return 1; }
    [ "$target_free" -ge "$minimum_free" ] || { ERROR_TYPE=no_space; return 1; }
    return 0
}

# After the synchronous runner has drained, count then remove only private work.
# Never launch a count reader after cancellation/lease loss. Preserve first error.
manager_date_cleanup() {
    MANAGER_DATE_PHASE=finalizing
    md_cleanup_rc=0
    if [ -n "${MEDIA_DATE_REPLACED_DIR:-}" ] && check_cancel_request; then
        if media_date_finish_counts; then
            MANAGER_DATE_REPLACED_COUNT=$MEDIA_DATE_REPLACED_COUNT
        else
            md_cleanup_rc=$?
        fi
        if [ "$STATUS_STARTED" -eq 1 ] && ! manager_date_status running ''; then
            md_cleanup_rc=1
        fi
    fi
    media_date_cleanup || md_cleanup_rc=1
    [ "$md_cleanup_rc" -eq 0 ] || { ERROR_TYPE=${MEDIA_DATE_ERROR:-date_cleanup}; return "$md_cleanup_rc"; }
}

# Append frozen comparisons/risk/counts after work deletion, then reuse final gates.
manager_date_summary() {
    cat >> "$BACKUP_LOG_FILE" <<EOF
Layout: date
Comparison Mode: $BACKUP_COMPARISON_MODE
Quick check uses size/mtime; same-size/mtime content changes may be missed.
Checksum compares current source and corresponding targets, not historical whole-library media.
Source bytes: $MANAGER_DATE_SOURCE_BYTES
Pending partial bytes bound: $MANAGER_DATE_PENDING_BYTES
Replacement bytes bound: $MANAGER_DATE_REPLACEMENT_BYTES
Space bounds are conservative risk estimates, not a capacity guarantee.
Archive: $MANAGER_DATE_ARCHIVE
Warnings: $MANAGER_DATE_WARNINGS
Retained old files: ${MANAGER_DATE_REPLACED_COUNT:-unknown}
Retained old files path: $MANAGER_DATE_REPLACED_PATH
EOF
}

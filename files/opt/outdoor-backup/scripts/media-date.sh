#!/bin/sh
# Inert date-library lifecycle, sourced ONLY by an existing manager owner.
# Caller preconditions: live owner/lease + FD9, source mounted RO, parsed PRIMARY
# card, consumed filesystem UUID checked against the immutable source snapshot.
# No trap, mounts, owner acquisition, status writer, media transfer or second PID.
# Public functions take no arguments and return 0, 1, or sticky cancel status.

# Record a bounded machine-readable reason; arbitrary helper stderr stays private.
# Args: error token. Returns 1, never writes public status/logs.
media_date_fail() {
    MEDIA_DATE_ERROR=$1
    return 1
}

# Enforce cancellation (includes lease), ownership and live target at boundaries.
# Args: none. Returns 0/nonzero. Caller functions propagate sticky cancellation.
media_date_guard() {
    check_cancel_request
    md_guard_rc=$?
    if [ "$md_guard_rc" -ne 0 ]; then
        MEDIA_DATE_ERROR=cancelled
        return "$md_guard_rc"
    fi
    lock_is_owned_by_self || { media_date_fail owner_lost; return 1; }
    target_anchor_healthy || { media_date_fail target_unhealthy; return 1; }
}

# One synchronous runner invocation, always guarded BEFORE and AFTER return.
# Args: private stdout destination, command + fixed argv. Returns command/cancel.
media_date_run() {
    md_run_output=$1
    shift
    media_date_guard || return "$?"
    transfer_process_run "$@" > "$md_run_output" 2>> "$MEDIA_DATE_WORK/stderr.log"
    md_run_rc=$?
    media_date_guard || return "$?"
    if [ "$md_run_rc" -ne 0 ]; then
        MEDIA_DATE_ERROR=tool_failed
        # Only the fixed planner may return a business refusal. Other tools'
        # stdout/stderr cannot authorize a public reason or a later transfer.
        if [ "${1:-}" = perl ] && [ "${2:-}" = "$SCRIPT_DIR/media-date-plan.pl" ]; then
            media_date_read_error "$md_run_output" || :
        fi
        return "$md_run_rc"
    fi
    return 0
}

# Accept only exact canonical error schema + enum, never a diagnostic prefix.
# Args: private planner stdout file. Returns 0/1; preserves tool_failed on reject.
media_date_read_error() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    md_error_size=$(wc -c < "$1") || return 1
    [ "$md_error_size" -le 256 ] || return 1
    md_error_code=$(jq -er '.error | select(type == "string")' "$1" 2>/dev/null) || return 1
    case "$md_error_code" in
        source_slot_reused|reclassification_required|target_leaf_collision|\
        target_prefix_collision|target_component_conflict|target_leaf_type_conflict|\
        foreign_target|namespace_occupied|namespace_component_conflict|\
        invalid_relative_path|invalid_path_component|reserved_partial_component|\
        invalid_absolute_path|invalid_uuid|unknown_request_version|\
        unknown_library_version|unknown_library_profile|invalid_archive_offset|\
        unknown_routes_version|routes_identity_mismatch|invalid_routes_entries|\
        missing_group_anchor|invalid_date_bucket|invalid_date_reason|\
        invalid_route_target|invalid_group_anchor|invalid_identity_version|\
        invalid_identity_signatures|invalid_identity_type|invalid_identity_digest|\
        invalid_metadata_schema|invalid_metadata_field|unknown_metadata_field|\
        invalid_metadata_warning|invalid_metadata_date|invalid_umid|\
        invalid_object|unknown_or_missing_key|json_duplicate_key|json_trailing_data|\
        json_invalid_string|json_invalid_unicode|json_invalid_value|json_depth_limit|\
        json_missing_colon|json_missing_comma|json_not_regular|routes_size_limit|\
        source_submount|source_changed|source_device_changed|source_count_limit|tool_failed) ;;
        *) return 1 ;;
    esac
    # Byte equality also rejects duplicate keys, extra fields, trailing JSON and
    # noncanonical whitespace/types. jq alone would accept duplicate members.
    printf '{"error":"%s","version":1}\n' "$md_error_code" > "$MEDIA_DATE_WORK/error-canonical.json" || return 1
    cmp -s "$1" "$MEDIA_DATE_WORK/error-canonical.json" || return 1
    MEDIA_DATE_ERROR=$md_error_code
}

# Actual helper interface, fixed interpreter/script paths and caller-owned data.
# Args: one documented command + its data args. Returns runner status.
media_date_helper() {
    media_date_run "$MEDIA_DATE_WORK/helper.json" perl "$SCRIPT_DIR/media-date-plan.pl" "$@"
}

# Guard directory preparation, using the FD9-relative creator's symlink checks.
# Args: fixed relative child of library. Returns 0/nonzero.
media_date_directory() {
    media_date_guard || return "$?"
    target_prepare_directory "${TARGET_BACKUP_ROOT#"$TARGET_FD_ROOT"/}/$1" || {
        media_date_fail directory_failed; return 1;
    }
    media_date_guard
}

# Create one 0700 work dir under the caller's pre-existing owner runtime parent.
# Args: none. Returns 0/1, records dev/inode/uid to prevent cleanup path adoption.
media_date_work_create() {
    [ -z "${MEDIA_DATE_OWNED_WORK:-}" ] || { media_date_fail work_already_active; return 1; }
    [ -d "$BASE_DIR/var" ] && [ ! -L "$BASE_DIR/var" ] || return 1
    MEDIA_DATE_WORK=$(umask 077; mktemp -d "$BASE_DIR/var/media-date.XXXXXX") || return 1
    MEDIA_DATE_OWNED_WORK=$MEDIA_DATE_WORK
    # Local ownership stat only; no source/metadata reader or managed PID.
    MEDIA_DATE_WORK_TOKEN=$(perl -e 'my @s=lstat($ARGV[0]); die unless @s && -d _ && !-l _ && ($s[2]&07777)==0700 && $s[4]==$>; print join(":",@s[0,1,4])' "$MEDIA_DATE_WORK") || return 1
    media_date_guard
}

# Validate caller source identifiers without any on-card writes or re-baselining.
# Args: none. Returns 0/1. RO/snapshot consumption remain explicit caller duties.
media_date_source_check() {
    [ "${BACKUP_MODE:-}" = PRIMARY ] || { media_date_fail source_not_primary; return 1; }
    card_identity_valid_sd_uuid "${SD_UUID:-}" || { media_date_fail invalid_source_id; return 1; }
    md_normalized_uuid=$(card_identity_normalize_source_uuid "${SOURCE_FS_UUID:-}") || {
        media_date_fail invalid_source_uuid; return 1;
    }
    [ "$md_normalized_uuid" = "$SOURCE_FS_UUID" ] || { media_date_fail invalid_source_uuid; return 1; }
    [ -d "$MOUNT_POINT" ] && [ ! -L "$MOUNT_POINT" ] || { media_date_fail source_unavailable; return 1; }
}

# Read the strict immutable policy; never silently adopt a changed UCI offset.
# Args: none. Returns 0/nonzero, sets policy paths/id only after strict validation.
media_date_library_check() {
    if [ -e "$MEDIA_DATE_LIBRARY_JSON" ] || [ -L "$MEDIA_DATE_LIBRARY_JSON" ]; then
        media_date_validate library "$MEDIA_DATE_LIBRARY_JSON" || { media_date_fail invalid_library; return 1; }
    else
        library_layout_empty_root "$TARGET_BACKUP_ROOT" || { media_date_fail unknown_nonempty_library; return 1; }
        # Default only at new-library admission, after owner/FD9 checks. An
        # existing marker must keep the empty-offset policy-inheritance branch.
        [ -n "${ARCHIVE_OFFSET_MINUTES:-}" ] || ARCHIVE_OFFSET_MINUTES=480
        config_valid_archive_offset "$ARCHIVE_OFFSET_MINUTES" || { media_date_fail invalid_archive_offset; return 1; }
        return 0
    fi
    MEDIA_DATE_LIBRARY_ID=$(jq -r '.library_id' "$MEDIA_DATE_WORK/helper.json") || return 1
    md_offset=$(jq -r '.archive_offset_minutes' "$MEDIA_DATE_WORK/helper.json") || return 1
    if [ -n "${ARCHIVE_OFFSET_MINUTES:-}" ] && [ "$ARCHIVE_OFFSET_MINUTES" != "$md_offset" ]; then
        media_date_fail library_policy_changed; return 1
    fi
    cp "$MEDIA_DATE_WORK/helper.json" "$MEDIA_DATE_WORK/library-policy.json" || return 1
}

# Admit the date library/source, prepare a private view workspace and unique job.
# Args: none. Returns 0/nonzero; no planning/transfer started by this function.
# Public outputs are module-owned and usable only after a successful return.
media_date_prepare_impl() {
    MEDIA_DATE_ERROR='' MEDIA_DATE_PHASE=planning MEDIA_DATE_SOURCE_BYTES_TOTAL=0 MEDIA_DATE_REPLACED_COUNT=0
    media_date_guard || return "$?"
    media_date_source_check || return "$?"
    media_date_work_create || return "$?"
    . "$SCRIPT_DIR/media-date-tools.sh"
    . "$SCRIPT_DIR/media-date-publication.sh"
    media_date_write_tools || { media_date_fail tools_write_failed; return 1; }
    target_prepare_date_root "$LIBRARY_ROOT" || { media_date_fail invalid_library_root; return 1; }
    MEDIA_DATE_LIBRARY_JSON="$TARGET_BACKUP_ROOT/.outdoor-backup/library.json"
    MEDIA_DATE_ROUTES_FILE="$TARGET_BACKUP_ROOT/.outdoor-backup/routes/$SD_UUID.json"
    MEDIA_DATE_RESULT_JSON="$MEDIA_DATE_WORK/result.json"
    MEDIA_DATE_LIBRARY_ID=
    media_date_helper probe || return "$?"
    media_date_tool probe "$MEDIA_DATE_WORK/helper.json" || { media_date_fail invalid_probe; return 1; }
    media_date_metadata_paths || return "$?"
    media_date_library_check || return "$?"
    media_date_probe_filesystem || return "$?"
    if [ ! -e "$MEDIA_DATE_LIBRARY_JSON" ]; then
        media_date_initialize || return "$?"
        media_date_library_check || return "$?"
    fi
    media_date_source_admit || return "$?"
    media_date_directory .outdoor-backup/replaced || return "$?"
    media_date_guard || return "$?"
    MEDIA_DATE_REPLACED_DIR=$(umask 077; mktemp -d "$TARGET_BACKUP_ROOT/.outdoor-backup/replaced/job.XXXXXX") || {
        media_date_fail replaced_job_failed; return 1;
    }
    media_date_guard
}

# Reject non-directory/symbolic managed ancestors before opening metadata leaves.
# Args: none. Returns 0/1. Does not claim partial initialization state.
media_date_metadata_paths() {
    for md_component in .outdoor-backup .outdoor-backup/routes .outdoor-backup/replaced; do
        md_path="$TARGET_BACKUP_ROOT/$md_component"
        [ ! -L "$md_path" ] || { media_date_fail invalid_metadata_directory; return 1; }
        if [ -e "$md_path" ] && [ ! -d "$md_path" ]; then
            media_date_fail invalid_metadata_directory; return 1
        fi
    done
}

# Build fixed versioned request with jq, run planner, strictly validate result and
# history-preserving candidate, then publish route. Never invoke actual rsync.
# Args: none. Returns 0/nonzero. Phase becomes ready only after all sync/guards.
media_date_plan_impl() {
    media_date_guard || return "$?"
    [ -n "${MEDIA_DATE_REPLACED_DIR:-}" ] && [ "$MEDIA_DATE_WORK" = "${MEDIA_DATE_OWNED_WORK:-}" ] || {
        media_date_fail not_prepared; return 1;
    }
    MEDIA_DATE_PHASE=planning
    media_date_validate routes "$MEDIA_DATE_ROUTES_FILE" || return "$?"
    cp "$MEDIA_DATE_ROUTES_FILE" "$MEDIA_DATE_WORK/history.json" || return 1
    jq -n --arg source "$MOUNT_POINT" --arg root "$TARGET_BACKUP_ROOT" --arg id "$SD_UUID" \
        --arg route "$MEDIA_DATE_ROUTES_FILE" --arg work "$MEDIA_DATE_WORK" \
        --slurpfile library "$MEDIA_DATE_WORK/library-policy.json" \
        '{version:1,source_root:$source,library_root:$root,source_id:$id,library:$library[0],route_file:$route,work_dir:$work}' \
        > "$MEDIA_DATE_WORK/request.json" || { media_date_fail request_write_failed; return 1; }
    media_date_helper plan "$MEDIA_DATE_WORK/request.json" || return "$?"
    media_date_tool result "$MEDIA_DATE_WORK/helper.json" "$MEDIA_DATE_WORK" "$MEDIA_DATE_LIBRARY_ID" \
        "$SD_UUID" "$MEDIA_DATE_WORK/history.json" "$MOUNT_POINT" || { media_date_fail invalid_result; return 1; }
    media_date_validate routes "$MEDIA_DATE_WORK/routes.json" || return "$?"
    media_date_tool risk "$MEDIA_DATE_WORK/routes.json" "$TARGET_BACKUP_ROOT" || return "$?"
    MEDIA_DATE_PENDING_BYTES_BOUND=$(jq -r '.pending_bytes_bound' "$MEDIA_DATE_WORK/tools.json") || return 1
    MEDIA_DATE_REPLACEMENT_BYTES_BOUND=$(jq -r '.replacement_bytes_bound' "$MEDIA_DATE_WORK/tools.json") || return 1
    MEDIA_DATE_SOURCE_BYTES_TOTAL=$(jq -r '.source_bytes_total' "$MEDIA_DATE_RESULT_JSON") || return 1
    media_date_publish routes "$MEDIA_DATE_WORK/routes.json" "$MEDIA_DATE_ROUTES_FILE" replace || return "$?"
    MEDIA_DATE_PHASE=ready
    return 0
}

# Count ordinary files retained in this job, without line splitting/hash reads.
# Args: none. Caller invokes after runner drain. Returns 0/nonzero.
media_date_finish_counts_impl() {
    MEDIA_DATE_PHASE=finalizing
    media_date_tool counts "$MEDIA_DATE_REPLACED_DIR" || return "$?"
    MEDIA_DATE_REPLACED_COUNT=$(jq -r '.replaced_count' "$MEDIA_DATE_WORK/tools.json") || return 1
    media_date_guard
}

# Preserve the manager's first cancellation even if a validator maps its error.
# Args: implementation exit status. Returns that status or sticky cancel code.
media_date_return() {
    if [ "${BACKUP_CANCEL_CODE:-0}" -ne 0 ]; then
        MEDIA_DATE_ERROR=cancelled
        return "$BACKUP_CANCEL_CODE"
    fi
    return "$1"
}

# Public owner-only admission. Args: none. Returns 0/error/sticky cancel.
media_date_prepare() {
    media_date_prepare_impl
    media_date_return "$?"
}

# Public candidate planning/publication. Args: none. Returns 0/error/cancel.
media_date_plan() {
    media_date_plan_impl
    media_date_return "$?"
}

# Public post-drain count. Args: none. Returns 0/error/sticky cancel.
media_date_finish_counts() {
    media_date_finish_counts_impl
    media_date_return "$?"
}

# Remove ONLY registered work after caller-drained runner and verified owner.
# Args: none. Returns 0/1. Does not delete library/job/media, unmount or unlock.
# Does not consult cancel/lease: cancelled owner still must release private work.
media_date_cleanup() {
    [ -n "${MEDIA_DATE_OWNED_WORK:-}" ] || return 0
    lock_is_owned_by_self || { media_date_fail cleanup_owner_lost; return 1; }
    [ -z "${TRANSFER_PROCESS_PID:-}" ] || { media_date_fail cleanup_runner_active; return 1; }
    md_work_token=$(perl -e 'my @s=lstat($ARGV[0]); die unless @s && -d _ && !-l _ && ($s[2]&07777)==0700 && $s[4]==$>; print join(":",@s[0,1,4])' "$MEDIA_DATE_OWNED_WORK") || return 1
    [ "$md_work_token" = "$MEDIA_DATE_WORK_TOKEN" ] || { media_date_fail cleanup_work_changed; return 1; }
    rm -rf "$MEDIA_DATE_OWNED_WORK" || { media_date_fail cleanup_failed; return 1; }
    unset MEDIA_DATE_WORK MEDIA_DATE_OWNED_WORK MEDIA_DATE_WORK_TOKEN MEDIA_DATE_REPLACED_DIR
    unset MEDIA_DATE_LIBRARY_JSON MEDIA_DATE_RESULT_JSON MEDIA_DATE_PHASE MEDIA_DATE_ROUTES_FILE
    unset MEDIA_DATE_LIBRARY_ID MEDIA_DATE_SOURCE_BYTES_TOTAL MEDIA_DATE_REPLACED_COUNT
    unset MEDIA_DATE_PENDING_BYTES_BOUND MEDIA_DATE_REPLACEMENT_BYTES_BOUND
    # MEDIA_DATE_ERROR deliberately survives cleanup for caller terminal reporting.
    return 0
}

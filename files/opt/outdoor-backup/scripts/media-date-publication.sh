#!/bin/sh
# Source-only same-filesystem metadata publication; no media/identity inference.

# Strictly validate helper output against the exact canonical validated input.
# Args: library|routes, regular file. Returns 0/nonzero; stderr remains private.
media_date_validate() {
    md_validate_kind=$1 md_validate_file=$2
    case "$md_validate_kind" in
        library) media_date_helper validate-library "$md_validate_file" || return "$?" ;;
        routes) media_date_helper validate-routes "$md_validate_file" "$MEDIA_DATE_LIBRARY_ID" "$SD_UUID" || return "$?" ;;
        *) return 1 ;;
    esac
    media_date_tool "$md_validate_kind" "$md_validate_file" "$MEDIA_DATE_LIBRARY_ID" "$SD_UUID" || return "$?"
    cmp -s "$MEDIA_DATE_WORK/helper.json" "$MEDIA_DATE_WORK/tools.json" || {
        media_date_fail invalid_validation_output; return 1;
    }
}

# Stage a new/candidate metadata snapshot in its FINAL directory, validate,
# sync, guard, rename, sync, guard. Existing routes require prior strict admission.
# Args: kind, private candidate, final file, new|replace. Returns 0/nonzero.
# Post-rename failure is deliberately not rolled back.
media_date_publish() {
    md_publish_kind=$1 md_publish_input=$2 md_publish_final=$3 md_publish_policy=$4
    media_date_guard || return "$?"
    if [ "$md_publish_policy" = new ]; then
        [ ! -e "$md_publish_final" ] && [ ! -L "$md_publish_final" ] || {
            media_date_fail metadata_appeared; return 1;
        }
    else
        media_date_validate "$md_publish_kind" "$md_publish_final" || return "$?"
        cmp -s "$md_publish_final" "$MEDIA_DATE_WORK/history.json" || {
            media_date_fail routes_changed; return 1;
        }
    fi
    MEDIA_DATE_TEMP=$(umask 077; mktemp "${md_publish_final%/*}/.media-date.XXXXXX") || {
        media_date_fail candidate_temp_failed; return 1;
    }
    if ! cp "$md_publish_input" "$MEDIA_DATE_TEMP"; then
        media_date_discard_temp; media_date_fail candidate_write_failed; return 1
    fi
    media_date_validate "$md_publish_kind" "$MEDIA_DATE_TEMP"
    md_publish_rc=$?
    if [ "$md_publish_rc" -eq 0 ]; then
        sync || { media_date_fail pre_sync_failed; md_publish_rc=1; }
    fi
    if [ "$md_publish_rc" -eq 0 ]; then
        media_date_guard || md_publish_rc=$?
    fi
    if [ "$md_publish_rc" -ne 0 ]; then
        media_date_discard_temp; return "$md_publish_rc"
    fi
    if [ "$md_publish_policy" = new ] && { [ -e "$md_publish_final" ] || [ -L "$md_publish_final" ]; }; then
        media_date_discard_temp; media_date_fail metadata_appeared; return 1
    fi
    if ! mv "$MEDIA_DATE_TEMP" "$md_publish_final"; then
        media_date_discard_temp; media_date_fail rename_failed; return 1
    fi
    MEDIA_DATE_TEMP=
    sync || { media_date_fail post_sync_failed; return 1; }
    media_date_guard
}

# Remove only this invocation's mktemp file while owner/anchor are intact.
# Args: none. Returns 0/1; failure leaves the tracked private candidate in place.
media_date_discard_temp() {
    [ -n "${MEDIA_DATE_TEMP:-}" ] || return 0
    lock_is_owned_by_self && target_anchor_healthy || return 1
    rm -f "$MEDIA_DATE_TEMP" || return 1
    MEDIA_DATE_TEMP=
}

# Initialize only a truly empty new date root, after tool/source/capability checks.
# Args: none. Returns 0/1. UUID identifies the library, never media contents.
media_date_initialize() {
    library_layout_empty_root "$TARGET_BACKUP_ROOT" || { media_date_fail unknown_nonempty_library; return 1; }
    config_valid_archive_offset "${ARCHIVE_OFFSET_MINUTES:-}" || { media_date_fail invalid_archive_offset; return 1; }
    md_library_uuid=$(generate_uuid) || { media_date_fail library_uuid_failed; return 1; }
    MEDIA_DATE_LIBRARY_ID=$(printf '%s' "$md_library_uuid" | LC_ALL=C tr 'ABCDEF' 'abcdef') || return 1
    card_identity_valid_sd_uuid "$MEDIA_DATE_LIBRARY_ID" || { media_date_fail library_uuid_failed; return 1; }
    jq -n --arg id "$MEDIA_DATE_LIBRARY_ID" --argjson offset "$ARCHIVE_OFFSET_MINUTES" \
        '{version:1,library_id:$id,layout:"date",parser_profile:"media-date-v1",archive_offset_minutes:$offset}' \
        > "$MEDIA_DATE_WORK/library-new.json" || return 1
    media_date_validate library "$MEDIA_DATE_WORK/library-new.json" || return "$?"
    media_date_directory .outdoor-backup || return "$?"
    media_date_publish library "$MEDIA_DATE_WORK/library-new.json" "$MEDIA_DATE_LIBRARY_JSON" new
}

# Check the per-source 8.2 state table before creating any source namespace/job.
# Args: none. Returns 0/nonzero; identity is published only AFTER empty route sync.
media_date_source_admit() {
    md_identity="$TARGET_BACKUP_ROOT/.card-identities/$SD_UUID.json"
    md_has_identity=0 md_has_route=0 md_route_count=0
    [ ! -L "$TARGET_BACKUP_ROOT/.card-identities" ] || { media_date_fail invalid_identity_directory; return 1; }
    if [ -e "$TARGET_BACKUP_ROOT/.card-identities" ] && [ ! -d "$TARGET_BACKUP_ROOT/.card-identities" ]; then
        media_date_fail invalid_identity_directory; return 1
    fi
    if [ -e "$md_identity" ] || [ -L "$md_identity" ]; then
        media_date_tool identity "$md_identity" "$SD_UUID" "$SOURCE_FS_UUID" || { media_date_fail invalid_identity; return 1; }
        md_has_identity=1
    fi
    if [ -e "$MEDIA_DATE_ROUTES_FILE" ] || [ -L "$MEDIA_DATE_ROUTES_FILE" ]; then
        media_date_validate routes "$MEDIA_DATE_ROUTES_FILE" || { media_date_fail invalid_routes; return 1; }
        md_has_route=1
        md_route_count=$(jq -r '.entries | length' "$MEDIA_DATE_WORK/helper.json") || return 1
    fi
    if [ "$md_has_identity" = 1 ] && [ "$md_has_route" = 0 ]; then
        media_date_fail routes_missing; return 1
    fi
    if [ "$md_has_identity" = 0 ] && [ "$md_route_count" -gt 0 ]; then
        media_date_fail identity_missing; return 1
    fi
    if [ "$md_route_count" -eq 0 ]; then
        media_date_namespace_empty || return "$?"
    fi
    if [ "$md_has_route" = 0 ]; then
        media_date_directory .outdoor-backup/routes || return "$?"
        jq -n --arg lib "$MEDIA_DATE_LIBRARY_ID" --arg src "$SD_UUID" \
            '{version:1,library_id:$lib,source_id:$src,entries:{}}' > "$MEDIA_DATE_WORK/empty.json" || return 1
        media_date_publish routes "$MEDIA_DATE_WORK/empty.json" "$MEDIA_DATE_ROUTES_FILE" new || return "$?"
    fi
    media_date_guard || return "$?"
    card_identity_bind "$SD_UUID" "$SOURCE_FS_UUID" || { media_date_fail identity_claim_failed; return 1; }
    media_date_guard
}

# Check namespace-empty success schema too; all nonzero/error results reject.
# Args: none. Returns 0/nonzero, without creating source namespace directories.
media_date_namespace_empty() {
    media_date_helper namespace-empty "$TARGET_BACKUP_ROOT" "$SD_UUID" || { media_date_fail namespace_not_empty; return 1; }
    media_date_tool namespace "$MEDIA_DATE_WORK/helper.json" "$SD_UUID" || { media_date_fail invalid_namespace_output; return 1; }
}

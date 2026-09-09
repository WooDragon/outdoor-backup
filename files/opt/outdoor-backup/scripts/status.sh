#!/bin/sh
#
# Atomic status.json snapshot support for Outdoor Backup.
# This file is intentionally inert when sourced: callers explicitly invoke
# write_status after their target and lifecycle state are established.
#

# Command seams default to production tools and let the BDD fixture force errors.
STATUS_FILE="${STATUS_FILE:-${BASE_DIR:-/opt/outdoor-backup}/var/status.json}"
STATUS_JQ="${STATUS_JQ:-jq}"
STATUS_DF="${STATUS_DF:-df}"
STATUS_MV="${STATUS_MV:-mv}"

# Return success only for a non-negative decimal integer.
# Args: $1=value. Output: none. Return: 0 for safe JSON number, 1 otherwise.
status_is_nonnegative_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Normalize an optional numeric argument without allowing shell/JSON injection.
# Args: $1=value, $2=default. Output: normalized integer. Return: 0 or 1.
status_number_or_default() {
    local value default
    value=$1
    default=$2
    [ -n "$value" ] || value=$default
    status_is_nonnegative_integer "$value" || return 1
    printf '%s\n' "$value"
}

# Read and validate the sole persisted snapshot before carrying its history.
# Args: none. Output: compact JSON history array. Return: 0 or 1.
status_read_history() {
    [ -e "$STATUS_FILE" ] || {
        printf '%s\n' '[]'
        return 0
    }
    "$STATUS_JQ" -ce '
        if type == "object" and
           .version == "1.0" and
           (.last_update | type == "number") and
           (.storage | type == "object") and
           (.storage.root | type == "string") and
           ([.storage.total_bytes, .storage.used_bytes, .storage.free_bytes] | all(type == "number")) and
           ((.current_backup == null) or
            (.current_backup | type == "object" and
             .active == true and
             ([.uuid, .name, .device] | all(type == "string")) and
             ([.started_at, .progress_percent, .files_total, .files_done,
               .bytes_total, .bytes_done, .speed_bytes_per_sec]
              | all(type == "number" and . >= 0)))) and
           (.history | type == "array") and
           all(.history[];
               type == "object" and
               ([.uuid, .name, .status, .backup_path] | all(type == "string")) and
               (.status == "completed" or .status == "error") and
               ([.last_backup_at, .files_count, .bytes_total] | all(type == "number")) and
               (.error_message == null or (.error_message | type == "string"))
           )
        then .history
        else error("invalid status snapshot")
        end
    ' "$STATUS_FILE"
}

# Collect df counters in KiB for a path, falling back to zero if df is unknown.
# Args: $1=path to probe, including an active /proc/self/fd path. Output: 3 ints.
status_storage_kib() {
    local df_line total used free
    df_line=$("$STATUS_DF" -k "$1" 2>/dev/null | awk 'NR == 2 { print $2, $3, $4 }')
    set -- $df_line
    total=${1:-0}
    used=${2:-0}
    free=${3:-0}
    status_is_nonnegative_integer "$total" || total=0
    status_is_nonnegative_integer "$used" || used=0
    status_is_nonnegative_integer "$free" || free=0
    printf '%s %s %s\n' "$total" "$used" "$free"
}

# Produce a current_backup object only for a running backup.
# Args: normalized status values passed by write_status. Output: compact JSON.
status_current_backup() {
    local phase
    phase=$1
    shift
    [ "$phase" = running ] || {
        printf '%s\n' null
        return 0
    }
    "$STATUS_JQ" -cn --arg uuid "$1" --arg name "$2" --arg device "$3" \
        --argjson started_at "$4" --argjson progress "$5" \
        --argjson files_total "$6" --argjson files_done "$7" \
        --argjson bytes_total "$8" --argjson bytes_done "$9" --argjson speed "${10}" \
        '{active: true, uuid: $uuid, name: $name, device: $device,
          started_at: $started_at, progress_percent: $progress,
          files_total: $files_total, files_done: $files_done,
          bytes_total: $bytes_total, bytes_done: $bytes_done,
          speed_bytes_per_sec: $speed}'
}

# Merge one terminal event into a history array, newest first and UUID-unique.
# Args: phase, values for a terminal event, prior compact history. Output: JSON.
status_merge_history() {
    local phase uuid name files_count bytes_total backup_path error_message now prior_history
    local event_status error_json
    phase=$1
    uuid=$2
    name=$3
    files_count=$4
    bytes_total=$5
    backup_path=$6
    error_message=$7
    now=$8
    prior_history=$9
    case "$phase" in
        running|idle)
            printf '%s\n' "$prior_history"
            return 0
            ;;
        completed) event_status=completed; error_json=null ;;
        failed) event_status=error; error_json=string ;;
        *) return 1 ;;
    esac
    "$STATUS_JQ" -ce --arg uuid "$uuid" --arg name "$name" --arg status "$event_status" \
        --arg backup_path "$backup_path" --arg error "$error_message" \
        --argjson last_backup_at "$now" --argjson files_count "$files_count" \
        --argjson bytes_total "$bytes_total" --arg error_type "$error_json" '
        [{uuid: $uuid, name: $name, last_backup_at: $last_backup_at,
          status: $status, files_count: $files_count, bytes_total: $bytes_total,
          backup_path: $backup_path,
          error_message: (if $error_type == "null" then null else $error end)}]
        + map(select(.uuid != $uuid)) | .[:20]
    ' <<EOF
$prior_history
EOF
}

# Write the one-file status snapshot atomically.
# Args: phase, uuid, name, device, started_at, progress, files_total, files_done,
# bytes_total, bytes_done, speed, storage probe path, backup path, error message,
# optional display root. Return: 0 only after same-directory rename succeeds.
write_status() {
    local phase uuid name device now started_at progress files_total files_done
    local bytes_total bytes_done speed storage_probe backup_path error_message display_root
    local prior_history history current_backup storage_kib storage_total storage_used storage_free
    local status_dir temp_file
    phase=$1
    uuid=$2
    name=$3
    device=$4
    now=$(date +%s) || return 1
    started_at=$(status_number_or_default "$5" "$now") || return 1
    progress=$(status_number_or_default "$6" 0) || return 1
    files_total=$(status_number_or_default "$7" 0) || return 1
    files_done=$(status_number_or_default "$8" 0) || return 1
    bytes_total=$(status_number_or_default "$9" 0) || return 1
    bytes_done=$(status_number_or_default "${10}" 0) || return 1
    speed=$(status_number_or_default "${11}" 0) || return 1
    storage_probe=${12:-/}
    backup_path=${13:-}
    error_message=${14:-}
    display_root=${15:-$storage_probe}
    case "$phase" in running|completed|failed|idle) ;; *) return 1 ;; esac

    prior_history=$(status_read_history) || return 1
    history=$(status_merge_history "$phase" "$uuid" "$name" "$files_done" \
        "$bytes_total" "$backup_path" "$error_message" "$now" "$prior_history") || return 1
    current_backup=$(status_current_backup "$phase" "$uuid" "$name" "$device" \
        "$started_at" "$progress" "$files_total" "$files_done" "$bytes_total" \
        "$bytes_done" "$speed") || return 1
    storage_kib=$(status_storage_kib "$storage_probe")
    set -- $storage_kib
    storage_total=$(( $1 * 1024 ))
    storage_used=$(( $2 * 1024 ))
    storage_free=$(( $3 * 1024 ))

    status_dir=$(dirname "$STATUS_FILE")
    mkdir -p "$status_dir" 2>/dev/null || return 1
    temp_file=$(mktemp "$status_dir/.status.json.tmp.XXXXXX") || return 1
    if ! "$STATUS_JQ" -n --arg root "$display_root" --argjson updated "$now" \
        --argjson total "$storage_total" --argjson used "$storage_used" \
        --argjson free "$storage_free" --argjson current "$current_backup" \
        --argjson history "$history" '
            {version: "1.0", last_update: $updated,
             storage: {root: $root, total_bytes: $total, used_bytes: $used, free_bytes: $free},
             current_backup: $current, history: $history}
        ' > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    if ! "$STATUS_MV" "$temp_file" "$STATUS_FILE"; then
        rm -f "$temp_file"
        return 1
    fi
}

#!/bin/sh
#
# BDD tests for the standalone status.json snapshot module. Source is read-only
# inside a pinned OpenWrt container; every fixture and command double is under
# /tmp, never on the host or a device node.
#
set -eu

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 --network bridge \
        --tmpfs /tmp:exec -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-status.sh --inside
fi

[ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || {
    printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
    exit 1
}

mkdir -p /var/lock
opkg update >/dev/null
opkg install jq >/dev/null

STATUS_SCRIPT=/src/files/opt/outdoor-backup/scripts/status.sh
TEST_ROOT="/tmp/outdoor-backup-status.$$"
STATUS_FILE="$TEST_ROOT/var/status.json"
BIN="$TEST_ROOT/bin"
CASES=0
ASSERTIONS=0
FAILED=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILED=$((FAILED + 1))
}

begin_case() {
    CASES=$((CASES + 1))
    printf 'CASE %s: %s\n' "$1" "$2"
}

assert_success() {
    message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    "$@" || fail "$message"
}

assert_failure() {
    message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    if "$@"; then
        fail "$message"
    fi
}

assert_equal() {
    actual=$1
    expected=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    [ "$actual" = "$expected" ] || fail "$message (expected=[$expected], actual=[$actual])"
}

assert_jq() {
    filter=$1
    message=$2
    ASSERTIONS=$((ASSERTIONS + 1))
    jq -e "$filter" "$STATUS_FILE" >/dev/null 2>&1 || fail "$message"
}

no_temp_files() {
    status_dir=$(dirname "$STATUS_FILE")
    set -- "$status_dir"/.status.json.tmp.*
    [ "$1" = "$status_dir/.status.json.tmp.*" ]
}

snapshot_hash() {
    sha256sum "$STATUS_FILE" | awk '{print $1}'
}

write_status_call() {
    write_status "$@"
}

setup_fixture() {
    rm -rf "$TEST_ROOT"
    mkdir -p "$TEST_ROOT/var" "$BIN" "$TEST_ROOT/storage" "$TEST_ROOT/display"
    cat > "$BIN/jq" <<'EOF'
#!/bin/sh
[ "${STATUS_TEST_FAIL_JQ:-0}" = 1 ] && [ "${1:-}" = '-n' ] && exit 1
exec /usr/bin/jq "$@"
EOF
    cat > "$BIN/mv" <<'EOF'
#!/bin/sh
[ "${STATUS_TEST_FAIL_MV:-0}" = 1 ] && exit 1
exec /bin/mv "$@"
EOF
    cat > "$BIN/df" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$STATUS_TEST_DF_ARGS"
printf '%s\n' 'Filesystem 1K-blocks Used Available Use% Mounted on'
printf '%s\n' '/dev/fixture 100 25 75 25% /fixture'
EOF
    chmod 700 "$BIN/jq" "$BIN/mv" "$BIN/df"
    export PATH="$BIN:/usr/sbin:/usr/bin:/sbin:/bin"
    hash -r 2>/dev/null || :
    export STATUS_FILE STATUS_TEST_DF_ARGS="$TEST_ROOT/df.args"
    export STATUS_JQ="$BIN/jq" STATUS_DF="$BIN/df" STATUS_MV="$BIN/mv"
    unset STATUS_TEST_FAIL_JQ STATUS_TEST_FAIL_MV
    # shellcheck disable=SC1090
    . "$STATUS_SCRIPT"
}

write_running() {
    write_status running '11111111-1111-1111-1111-111111111111' 'Camera card' sda1 \
        100 25 40 10 4096 1024 512 "$TEST_ROOT/storage" /backup ''
}

write_completed() {
    write_status completed '11111111-1111-1111-1111-111111111111' 'Camera card' sda1 \
        100 100 40 40 4096 4096 0 "$TEST_ROOT/storage" /backup ''
}

case_running_schema() {
    begin_case S01 'running publishes the complete LuCI current_backup and storage schema'
    setup_fixture
    assert_success 'running snapshot writes' write_running
    assert_jq '(.version == "1.0") and (.last_update | type == "number") and
        (.storage.root | type == "string") and (.storage.total_bytes == 102400) and
        (.storage.used_bytes == 25600) and (.storage.free_bytes == 76800) and
        (.current_backup.active == true) and
        ([.current_backup.uuid, .current_backup.name, .current_backup.device] | all(type == "string")) and
        ([.current_backup.started_at, .current_backup.progress_percent, .current_backup.files_total,
          .current_backup.files_done, .current_backup.bytes_total, .current_backup.bytes_done,
          .current_backup.speed_bytes_per_sec] | all(type == "number")) and (.history == [])' \
        'running snapshot has correct types and values'
}

case_terminal_and_idle_schema() {
    begin_case S02 'completed, failed, and idle retain the required terminal semantics'
    setup_fixture
    assert_success 'completed snapshot writes' write_completed
    assert_jq '.current_backup == null and (.history | length == 1) and
        .history[0] == {uuid: "11111111-1111-1111-1111-111111111111", name: "Camera card",
        last_backup_at: .history[0].last_backup_at, status: "completed", files_count: 40,
        bytes_total: 4096, backup_path: "/backup", error_message: null} and
        (.history[0].last_backup_at | type == "number")' \
        'completed creates the LuCI history entry'
    assert_success 'failed snapshot writes' write_status_call failed \
        '22222222-2222-2222-2222-222222222222' '' sdb1 200 0 0 0 0 0 0 \
        "$TEST_ROOT/storage" /failed 'disk write failed'
    assert_jq '.current_backup == null and (.history | length == 2) and
        .history[0].status == "error" and .history[0].name == "" and
        .history[0].error_message == "disk write failed" and
        ([.history[0].files_count, .history[0].bytes_total] | all(type == "number"))' \
        'failed records error history with empty name and string error'
    assert_success 'idle snapshot writes' write_status_call idle '' '' '' '' '' '' '' '' '' '' \
        "$TEST_ROOT/storage" '' ''
    assert_jq '.current_backup == null and (.history | length == 2)' \
        'idle preserves history without adding an entry'
}

case_dedup_and_limit() {
    begin_case S03 'terminal histories replace matching UUIDs and retain only newest twenty'
    setup_fixture
    assert_success 'first UUID writes' write_completed
    assert_success 'same UUID replaces old history' write_status_call completed \
        '11111111-1111-1111-1111-111111111111' 'Replacement' sda1 101 100 41 41 8192 8192 0 \
        "$TEST_ROOT/storage" /replacement ''
    assert_jq '(.history | length == 1) and .history[0].name == "Replacement" and
        .history[0].files_count == 41 and .history[0].backup_path == "/replacement"' \
        'same UUID is replaced rather than duplicated'
    index=1
    while [ "$index" -le 21 ]; do
        uuid=$(printf 'aaaaaaaa-aaaa-aaaa-aaaa-%012d' "$index")
        write_status completed "$uuid" "Card $index" sda1 "$index" 100 "$index" "$index" \
            "$index" "$index" 0 "$TEST_ROOT/storage" "/backup/$index" '' || fail "history write $index"
        index=$((index + 1))
    done
    assert_jq '(.history | length == 20) and .history[0].uuid == "aaaaaaaa-aaaa-aaaa-aaaa-000000000021" and
        ([.history[].uuid] | index("11111111-1111-1111-1111-111111111111") == null)' \
        'history is newest-first and capped at twenty'
}

case_string_serialization() {
    begin_case S04 'jq preserves quotes, backslashes, newlines, controls, empty name, and error string'
    setup_fixture
    name=$(printf 'quote" slash\\ newline\ncontrol\001')
    error=$(printf 'problem "path\\"\ncontrol\002')
    assert_success 'special-string failed snapshot writes' write_status_call failed \
        '33333333-3333-3333-3333-333333333333' "$name" sdc1 1 0 0 0 0 0 0 \
        "$TEST_ROOT/storage" '/path/with "quote"' "$error"
    ASSERTIONS=$((ASSERTIONS + 1))
    jq -e --arg name "$name" --arg error "$error" \
        '(.history[0].name == $name) and (.history[0].error_message == $error)' \
        "$STATUS_FILE" >/dev/null 2>&1 || fail 'valid JSON round-trips every special string'
}

case_invalid_input_preserves_snapshot() {
    begin_case S05 'invalid phase and numeric input fail without replacing the last good snapshot'
    setup_fixture
    assert_success 'baseline snapshot writes' write_running
    before=$(snapshot_hash)
    assert_failure 'invalid phase is rejected' write_status_call bogus x n d 1 1 1 1 1 1 1 "$TEST_ROOT/storage" /b ''
    assert_equal "$(snapshot_hash)" "$before" 'invalid phase preserves snapshot'
    assert_failure 'negative value is rejected' write_status_call running x n d 1 -1 1 1 1 1 1 "$TEST_ROOT/storage" /b ''
    assert_equal "$(snapshot_hash)" "$before" 'negative number preserves snapshot'
    assert_failure 'non-numeric value is rejected' write_status_call running x n d 1 '1;touch /tmp/no' 1 1 1 1 1 "$TEST_ROOT/storage" /b ''
    assert_equal "$(snapshot_hash)" "$before" 'non-numeric injection preserves snapshot'
}

case_bad_existing_snapshot_preserves_file() {
    begin_case S06 'invalid or wrong-shaped existing status snapshots are rejected, never reset as empty'
    setup_fixture
    printf '%s\n' '{bad json' > "$STATUS_FILE"
    before=$(snapshot_hash)
    assert_failure 'invalid JSON is rejected' write_completed
    assert_equal "$(snapshot_hash)" "$before" 'invalid JSON remains untouched'
    printf '%s\n' '{"version":"1.0","history":{}}' > "$STATUS_FILE"
    before=$(snapshot_hash)
    assert_failure 'non-array history shape is rejected' write_completed
    assert_equal "$(snapshot_hash)" "$before" 'wrong-shaped JSON remains untouched'
    printf '%s\n' '{"version":"1.0","last_update":1,"storage":{"root":"/fixture","total_bytes":100,"used_bytes":25,"free_bytes":75},"current_backup":{},"history":[]}' > "$STATUS_FILE"
    before=$(snapshot_hash)
    assert_failure 'empty current_backup object is rejected' write_status_call idle '' '' '' '' '' '' '' '' '' '' "$TEST_ROOT/storage" '' ''
    assert_equal "$(snapshot_hash)" "$before" 'empty current_backup remains untouched'
    printf '%s\n' '{"version":"1.0","last_update":1,"storage":{"root":"/fixture","total_bytes":100,"used_bytes":25,"free_bytes":75},"current_backup":{"active":true,"uuid":"u","name":"n","device":"d","started_at":"bad","progress_percent":0,"files_total":0,"files_done":0,"bytes_total":0,"bytes_done":0,"speed_bytes_per_sec":0},"history":[]}' > "$STATUS_FILE"
    before=$(snapshot_hash)
    assert_failure 'current_backup field type is rejected' write_status_call idle '' '' '' '' '' '' '' '' '' '' "$TEST_ROOT/storage" '' ''
    assert_equal "$(snapshot_hash)" "$before" 'wrong current_backup type remains untouched'
    printf '%s\n' '{"version":"1.0","last_update":1,"storage":{"root":"/fixture","total_bytes":100,"used_bytes":25,"free_bytes":75},"current_backup":null,"history":[{"uuid":"u","name":"n","last_backup_at":1,"status":"running","files_count":0,"bytes_total":0,"backup_path":"/backup","error_message":null}]}' > "$STATUS_FILE"
    before=$(snapshot_hash)
    assert_failure 'running history status is rejected' write_status_call idle '' '' '' '' '' '' '' '' '' '' "$TEST_ROOT/storage" '' ''
    assert_equal "$(snapshot_hash)" "$before" 'invalid history status remains untouched'
}

case_atomic_failures_preserve_snapshot() {
    begin_case S07 'temporary-write and rename failures keep the old snapshot and clean temporary files'
    setup_fixture
    : > "$TEST_ROOT/.status.json.tmp.other-dir"
    assert_success 'temporary file in another directory is ignored' no_temp_files
    : > "$(dirname "$STATUS_FILE")/.status.json.tmp.sentinel"
    assert_failure 'fixture temp sentinel is detected' no_temp_files
    rm -f "$(dirname "$STATUS_FILE")/.status.json.tmp.sentinel"
    assert_success 'fixture temp sentinel cleanup leaves no temp files' no_temp_files
    rm -f "$TEST_ROOT/.status.json.tmp.other-dir"
    assert_success 'baseline snapshot writes' write_running
    before=$(snapshot_hash)
    STATUS_TEST_FAIL_JQ=1
    export STATUS_TEST_FAIL_JQ
    assert_failure 'temporary JSON write failure is returned' write_completed
    unset STATUS_TEST_FAIL_JQ
    assert_equal "$(snapshot_hash)" "$before" 'temporary JSON write failure preserves old snapshot'
    assert_success 'temporary JSON write failure cleans temp' no_temp_files
    STATUS_TEST_FAIL_MV=1
    export STATUS_TEST_FAIL_MV
    assert_failure 'rename failure is returned' write_completed
    unset STATUS_TEST_FAIL_MV
    assert_equal "$(snapshot_hash)" "$before" 'rename failure preserves old snapshot'
    assert_success 'rename failure cleans temp' no_temp_files
}

case_fd_probe_and_display_root() {
    begin_case S08 'df probes the live descriptor path while JSON exposes the stable display root'
    setup_fixture
    : > "$TEST_ROOT/storage/live-anchor"
    exec 9< "$TEST_ROOT/storage/live-anchor"
    probe=/proc/self/fd/9
    assert_success 'FD-backed storage snapshot writes' write_status_call idle '' '' '' '' '' '' '' '' '' '' \
        "$probe" '' '' "$TEST_ROOT/display"
    exec 9<&-
    assert_equal "$(cat "$STATUS_TEST_DF_ARGS")" "-k $probe" 'df receives live FD probe path'
    ASSERTIONS=$((ASSERTIONS + 1))
    jq -e --arg root "$TEST_ROOT/display" '.storage.root == $root' \
        "$STATUS_FILE" >/dev/null 2>&1 || fail 'JSON keeps display root separate from FD probe path'
}

case_module_is_inert_when_sourced() {
    begin_case S09 'sourcing defines write_status without creating files or installing a trap'
    setup_fixture
    ASSERTIONS=$((ASSERTIONS + 1))
    command -v write_status >/dev/null 2>&1 || fail 'write_status function is defined'
    assert_success 'source has no status-file side effect' test ! -e "$STATUS_FILE"
    assert_equal "$(trap)" '' 'source installs no global trap'
}

if [ ! -r "$STATUS_SCRIPT" ]; then
    printf 'FAIL: status module is missing: %s\n' "$STATUS_SCRIPT" >&2
    exit 1
fi

case_running_schema
case_terminal_and_idle_schema
case_dedup_and_limit
case_string_serialization
case_invalid_input_preserves_snapshot
case_bad_existing_snapshot_preserves_file
case_atomic_failures_preserve_snapshot
case_fd_probe_and_display_root
case_module_is_inert_when_sourced

printf 'RESULT cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
[ "$CASES" -eq 9 ] || { printf 'FAIL: expected 9 cases, ran %s\n' "$CASES" >&2; exit 1; }
[ "$ASSERTIONS" -eq 47 ] || { printf 'FAIL: expected 47 assertions, ran %s\n' "$ASSERTIONS" >&2; exit 1; }
[ "$FAILED" -eq 0 ]

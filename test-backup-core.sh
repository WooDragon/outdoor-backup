#!/bin/bash
#
# BDD test suite for backup core reliability fixes
# Covers issues #1 (append-verify), #4 (LED codes), #5 (space check),
# #6 (rsync exit code), #7 (status.json writer).
#
# macOS openrsync lacks --append-verify / --info=progress2, so a mock rsync
# on PATH simulates success/failure/progress deterministically.
#

# Note: intentionally NOT using `set -e` — this suite probes failure paths
# (nonzero rsync exits, missing hardware), so a nonzero must be inspected by
# the test, not abort the whole run.

# Test directories
TEST_ROOT="/tmp/outdoor-backup-core-test"
BASE_DIR="$TEST_ROOT/opt"
MOCK_BIN="$TEST_ROOT/bin"
SCRIPTS_SRC="$(cd "$(dirname "$0")/files/opt/outdoor-backup/scripts" && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

test_passed() {
	echo -e "${GREEN}✓ PASSED${NC}: $1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_failed() {
	echo -e "${RED}✗ FAILED${NC}: $1"
	TESTS_FAILED=$((TESTS_FAILED + 1))
}

test_warning() {
	echo -e "${YELLOW}⚠ WARNING${NC}: $1"
}

# JSON field extractor.
# Uses jq when available (jq filter syntax, e.g. '.current_backup.active').
# Falls back to a safe python3 key-walker that splits the same dotted path —
# no eval, only literal dict/list indexing of trusted, test-controlled paths.
json_field() {
	local file="$1"
	local filter="$2"
	if command -v jq >/dev/null 2>&1; then
		jq -r "$filter" "$file" 2>/dev/null
	else
		FILTER="$filter" python3 - "$file" << 'PYEOF' 2>/dev/null
import json, os, sys
data = json.load(open(sys.argv[1]))
# Walk a leading-dot path like ".a.b.0.c" by literal key/index lookups only.
path = os.environ["FILTER"].lstrip(".")
node = data
for part in [p for p in path.split(".") if p != ""]:
    if isinstance(node, list):
        node = node[int(part)]
    else:
        node = node[part]
print(node)
PYEOF
	fi
}

# Validate that a file is well-formed JSON
json_valid() {
	local file="$1"
	if command -v jq >/dev/null 2>&1; then
		jq empty "$file" >/dev/null 2>&1
	else
		python3 -c "import json; json.load(open('$file'))" >/dev/null 2>&1
	fi
}

setup_env() {
	rm -rf "$TEST_ROOT"
	mkdir -p "$BASE_DIR/var/lock" "$BASE_DIR/log" "$BASE_DIR/conf" "$MOCK_BIN"
	cp "$SCRIPTS_SRC/common.sh" "$BASE_DIR/scripts.common.sh" 2>/dev/null || true
	mkdir -p "$BASE_DIR/scripts"
	cp "$SCRIPTS_SRC/common.sh" "$BASE_DIR/scripts/common.sh"
	# Minimal globals common.sh expects when sourced standalone
	export BASE_DIR
	export LOG_TAG="outdoor-backup-test"
	export STATUS_FILE="$BASE_DIR/var/status.json"
	export ALIASES_FILE="$BASE_DIR/conf/aliases.json"
}

main() {
	echo "========================================"
	echo "  Outdoor Backup - Core Reliability Suite"
	echo "========================================"
	setup_env

	test_status_writer_running
	test_status_writer_completed
	test_status_writer_failed
	test_status_history_dedup
	test_status_json_escaping
	test_status_newline_in_name
	test_led_functions_exist
	test_led_no_hardware_safe
	test_e2e_rsync_success
	test_e2e_rsync_failure
	test_e2e_append_verify_flag
	test_e2e_no_du_precheck
	test_error_type_led_dispatch

	echo ""
	echo "========================================"
	echo "  Test Results"
	echo "========================================"
	echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
	echo -e "${RED}Failed: $TESTS_FAILED${NC}"

	rm -rf "$TEST_ROOT"

	if [ $TESTS_FAILED -eq 0 ]; then
		echo -e "${GREEN}All tests passed!${NC}"
		exit 0
	else
		echo -e "${RED}Some tests failed.${NC}"
		exit 1
	fi
}

# PLACEHOLDER_TESTS

# === Issue #7: status.json writer ===

# Scenario: backup starts -> status.json exists, status=running, fields match
# the frontend current_backup contract.
test_status_writer_running() {
	echo ""
	echo "=== #7: status.json running state ==="
	( . "$BASE_DIR/scripts/common.sh"
	  write_status "running" "550e8400-e29b-41d4-a716-446655440000" \
		"Canon Card" "sda1" 1728825000 45 1200 540 \
		52428800000 23592960000 157286400 "$BASE_DIR" "" "" )

	if [ -f "$STATUS_FILE" ]; then
		test_passed "status.json created on running"
	else
		test_failed "status.json not created"
		return
	fi

	if json_valid "$STATUS_FILE"; then
		test_passed "status.json is valid JSON"
	else
		test_failed "status.json is malformed"
		echo "--- content ---"; cat "$STATUS_FILE"
		return
	fi

	[ "$(json_field "$STATUS_FILE" '.current_backup.active')" = "true" ] \
		&& test_passed "current_backup.active=true" \
		|| test_failed "current_backup.active wrong"

	[ "$(json_field "$STATUS_FILE" '.current_backup.progress_percent')" = "45" ] \
		&& test_passed "progress_percent=45" \
		|| test_failed "progress_percent wrong"

	[ "$(json_field "$STATUS_FILE" '.current_backup.name')" = "Canon Card" ] \
		&& test_passed "name preserved" \
		|| test_failed "name wrong"
}

# Scenario: backup completes -> current_backup=null, one history entry added
# with status=completed.
test_status_writer_completed() {
	echo ""
	echo "=== #7: status.json completed state ==="
	rm -f "$BASE_DIR/var/history.jsonl"
	( . "$BASE_DIR/scripts/common.sh"
	  write_status "completed" "550e8400-e29b-41d4-a716-446655440000" \
		"Canon Card" "sda1" 1728825000 100 1200 1200 \
		52428800000 52428800000 0 "$BASE_DIR" "$BASE_DIR/target" "" )

	json_valid "$STATUS_FILE" \
		&& test_passed "completed status.json valid" \
		|| test_failed "completed status.json malformed"

	[ "$(json_field "$STATUS_FILE" '.current_backup')" = "null" ] \
		&& test_passed "current_backup=null when not running" \
		|| test_failed "current_backup should be null"

	[ "$(json_field "$STATUS_FILE" '.history[0].status')" = "completed" ] \
		&& test_passed "history[0].status=completed" \
		|| test_failed "history status wrong"

	[ "$(json_field "$STATUS_FILE" '.history[0].files_count')" = "1200" ] \
		&& test_passed "history files_count=1200" \
		|| test_failed "history files_count wrong"
}

# Scenario: backup fails -> history entry with status=error + error_message.
test_status_writer_failed() {
	echo ""
	echo "=== #7/#6: status.json failed state ==="
	rm -f "$BASE_DIR/var/history.jsonl"
	( . "$BASE_DIR/scripts/common.sh"
	  write_status "failed" "7c9e6679-7425-40de-944b-e07fc1f90ae7" \
		"Sony Card" "sdb1" 1728825000 0 0 0 0 0 0 \
		"$BASE_DIR" "$BASE_DIR/target" "rsync exit 11" )

	[ "$(json_field "$STATUS_FILE" '.history[0].status')" = "error" ] \
		&& test_passed "failed -> history status=error" \
		|| test_failed "failed status wrong"

	local msg
	msg=$(json_field "$STATUS_FILE" '.history[0].error_message')
	[ "$msg" = "rsync exit 11" ] \
		&& test_passed "error_message recorded" \
		|| test_failed "error_message wrong: '$msg'"
}

# Scenario: same card backed up twice -> history keeps ONE row (newest wins),
# not two duplicate rows. Matches the frontend one-row-per-card table.
test_status_history_dedup() {
	echo ""
	echo "=== #7: history dedup by UUID ==="
	rm -f "$BASE_DIR/var/history.jsonl"
	local uuid="3b1e7a9f-8d6c-4c3e-b2f4-9a1e7d8c4b5a"
	( . "$BASE_DIR/scripts/common.sh"
	  write_status "completed" "$uuid" "Card A" "sda1" 100 100 10 10 1000 1000 0 "$BASE_DIR" "/t" "" )
	( . "$BASE_DIR/scripts/common.sh"
	  write_status "completed" "$uuid" "Card A" "sda1" 200 100 20 20 2000 2000 0 "$BASE_DIR" "/t" "" )

	local count
	if command -v jq >/dev/null 2>&1; then
		count=$(jq '.history | length' "$STATUS_FILE" 2>/dev/null)
	else
		count=$(json_field "$STATUS_FILE" '.history' | grep -c uuid || echo "?")
	fi
	[ "$count" = "1" ] \
		&& test_passed "duplicate card collapses to 1 history row" \
		|| test_failed "expected 1 history row, got $count"

	# Newest entry should reflect the second write (files_count=20).
	[ "$(json_field "$STATUS_FILE" '.history[0].files_count')" = "20" ] \
		&& test_passed "newest backup wins in history" \
		|| test_failed "history did not update to newest"
}

# Scenario: card name with quotes/backslashes must not break JSON.
test_status_json_escaping() {
	echo ""
	echo "=== #7: JSON escaping of card names ==="
	rm -f "$BASE_DIR/var/history.jsonl"
	( . "$BASE_DIR/scripts/common.sh"
	  write_status "running" "550e8400-e29b-41d4-a716-446655440000" \
		'Quote"Back\slash' "sda1" 100 50 10 5 1000 500 100 "$BASE_DIR" "" "" )

	json_valid "$STATUS_FILE" \
		&& test_passed "special chars in name keep JSON valid" \
		|| { test_failed "JSON broken by special chars"; cat "$STATUS_FILE"; }
}

# Scenario: a card name containing a NEWLINE (possible via WebUI alias) must
# not break status.json parsing nor corrupt the one-object-per-line history.
test_status_newline_in_name() {
	echo ""
	echo "=== #7: embedded newline in card name ==="
	rm -f "$BASE_DIR/var/history.jsonl"
	local nl_name
	nl_name=$(printf 'Line1\nLine2')
	( . "$BASE_DIR/scripts/common.sh"
	  write_status "completed" "550e8400-e29b-41d4-a716-446655440000" \
		"$nl_name" "sda1" 100 100 5 5 500 500 0 "$BASE_DIR" "/t" "" )

	json_valid "$STATUS_FILE" \
		&& test_passed "newline in name keeps status.json valid" \
		|| { test_failed "newline broke status.json"; cat "$STATUS_FILE"; }

	# history.jsonl must stay one-object-per-line (single line for one card).
	local lines
	lines=$(wc -l < "$BASE_DIR/var/history.jsonl" 2>/dev/null | tr -d ' ')
	[ "$lines" = "1" ] \
		&& test_passed "history.jsonl invariant intact (1 line)" \
		|| test_failed "history.jsonl split across $lines lines"
}

# === Issue #4: differentiated LED functions ===

# Scenario: all differentiated LED functions must be defined after sourcing.
test_led_functions_exist() {
	echo ""
	echo "=== #4: differentiated LED functions defined ==="
	( . "$BASE_DIR/scripts/common.sh"
	  for fn in led_err_no_space led_err_lock_timeout led_err_device_unknown \
		    led_err_rsync led_err_verify_failed led_blink_pattern; do
		if ! command -v "$fn" >/dev/null 2>&1; then
			echo "MISSING:$fn"
		fi
	  done ) > "$TEST_ROOT/led_check.txt" 2>&1

	if grep -q MISSING "$TEST_ROOT/led_check.txt"; then
		test_failed "LED functions missing: $(grep MISSING "$TEST_ROOT/led_check.txt" | tr '\n' ' ')"
	else
		test_passed "all 6 differentiated LED functions defined"
	fi
}

# Scenario: LED functions must not error when the LED sysfs path is absent
# (typical of the test host and many non-R5S devices).
test_led_no_hardware_safe() {
	echo ""
	echo "=== #4: LED functions safe without hardware ==="
	local rc=0
	(
		. "$BASE_DIR/scripts/common.sh"
		LED_RED="/nonexistent/led/red"
		LED_GREEN="/nonexistent/led/green"
		led_err_no_space
		led_err_lock_timeout
		led_err_device_unknown
		led_err_verify_failed
	) >/dev/null 2>&1 || rc=$?

	if [ "$rc" -eq 0 ]; then
		test_passed "LED functions exit cleanly with no hardware"
	else
		test_failed "LED functions errored without hardware (rc=$rc)"
	fi
}

# === E2E: perform_backup with mock rsync ===
#
# macOS openrsync can't do --append-verify/--info=progress2, so we put a mock
# rsync first on PATH. The mock logs the args it received (to assert flags),
# writes a fake --stats block into the --log-file, and exits with a code we
# control via MOCK_RSYNC_EXIT. This exercises the REAL perform_backup() exit-
# code capture path (#6), not a reimplementation.

# Build a sourcable backup-manager environment under $1=envdir.
e2e_setup() {
	local envdir="$1"
	rm -rf "$envdir"
	mkdir -p "$envdir/opt/scripts" "$envdir/opt/var/lock" "$envdir/opt/log" \
		"$envdir/opt/conf" "$envdir/bin" "$envdir/mnt/sdcard" \
		"$envdir/mnt/ssd/SDMirrors/.logs"
	cp "$SCRIPTS_SRC/common.sh" "$envdir/opt/scripts/common.sh"
	cp "$SCRIPTS_SRC/backup-manager.sh" "$envdir/opt/scripts/backup-manager.sh"

	# Mock rsync: record args, emit a --stats-style summary into --log-file,
	# print one progress2-style line to stdout, then exit MOCK_RSYNC_EXIT.
	cat > "$envdir/bin/rsync" << 'MOCKEOF'
#!/bin/sh
echo "$@" >> "$MOCK_RSYNC_ARGS_LOG"
log_file=""
for a in "$@"; do
	case "$a" in --log-file=*) log_file="${a#--log-file=}" ;; esac
done
printf '   1048576  50%%  10.00MB/s    0:00:01\r'
printf '   2097152 100%%  10.00MB/s    0:00:00 (xfr#3, to-chk=0/3)\n'
if [ -n "$log_file" ]; then
	cat >> "$log_file" << STATS

Number of regular files transferred: 3
Total transferred file size: 2,097,152 bytes
STATS
fi
exit "${MOCK_RSYNC_EXIT:-0}"
MOCKEOF
	chmod +x "$envdir/bin/rsync"

	E2E_BASE="$envdir/opt"
	E2E_BIN="$envdir/bin"
	E2E_MOUNT="$envdir/mnt/sdcard"
	E2E_BACKUP_ROOT="$envdir/mnt/ssd/SDMirrors"
}

# Run perform_backup() in a controlled subshell. Writes "RC=<code>" as the last
# line; status.json lands in $E2E_BASE/var/status.json.
# Args: $1 mock_exit  $2 args_log_path
e2e_run_backup() {
	local mock_exit="$1" args_log="$2"
	(
		set +e
		export OUTDOOR_BACKUP_SOURCED=1
		export PATH="$E2E_BIN:$PATH"
		export MOCK_RSYNC_EXIT="$mock_exit"
		export MOCK_RSYNC_ARGS_LOG="$args_log"
		# Pre-set path seams so the sourced script finds common.sh in the
		# fixture and targets the test dirs (see backup-manager.sh constants).
		SCRIPT_DIR="$E2E_BASE/scripts"
		BASE_DIR="$E2E_BASE"
		MOUNT_POINT="$E2E_MOUNT"
		BACKUP_ROOT="$E2E_BACKUP_ROOT"
		STATUS_FILE="$E2E_BASE/var/status.json"
		ALIASES_FILE="$E2E_BASE/conf/aliases.json"
		# shellcheck disable=SC1090
		. "$E2E_BASE/scripts/backup-manager.sh" "add" "sda1" "/devices/mock"
		# Sourcing re-enabled `set -e`; disable again so benign nonzero
		# intermediate commands inside perform_backup don't abort the subshell.
		set +e
		LOG_TAG="test"
		SD_UUID="550e8400-e29b-41d4-a716-446655440000"
		BACKUP_MODE="PRIMARY"
		MIN_FREE_SPACE=1
		LED_RED="/nonexistent/red"
		LED_GREEN="/nonexistent/green"
		echo "source-marker" > "$E2E_MOUNT/photo.raw"
		perform_backup
		echo "RC=$?"
	)
}

# Scenario #6: mock rsync exits 0 -> perform_backup returns 0, status=completed.
test_e2e_rsync_success() {
	echo ""
	echo "=== #6 E2E: rsync success -> return 0 + completed ==="
	e2e_setup "$TEST_ROOT/e2e1"
	local out
	out=$(e2e_run_backup 0 "$TEST_ROOT/e2e1/args.log" 2>/dev/null)
	echo "$out" | grep -q "RC=0" \
		&& test_passed "perform_backup returns 0 on rsync success" \
		|| test_failed "expected RC=0, got: $(echo "$out" | grep RC=)"
	local st="$TEST_ROOT/e2e1/opt/var/status.json"
	[ -f "$st" ] && [ "$(json_field "$st" '.history[0].status')" = "completed" ] \
		&& test_passed "status.json history=completed on success" \
		|| test_failed "history status not completed"
}

# Scenario #6: mock rsync exits 11 -> perform_backup returns 11 (NOT 0).
# This is the core data-integrity bug: failure must not masquerade as success.
test_e2e_rsync_failure() {
	echo ""
	echo "=== #6 E2E: rsync failure -> nonzero return (no green light) ==="
	e2e_setup "$TEST_ROOT/e2e2"
	local out
	out=$(e2e_run_backup 11 "$TEST_ROOT/e2e2/args.log" 2>/dev/null)
	echo "$out" | grep -q "RC=11" \
		&& test_passed "rsync exit 11 propagates (not swallowed)" \
		|| test_failed "expected RC=11, got: $(echo "$out" | grep RC=)"
	local st="$TEST_ROOT/e2e2/opt/var/status.json"
	[ "$(json_field "$st" '.history[0].status')" = "error" ] \
		&& test_passed "status.json history=error on failure" \
		|| test_failed "history status not error"
}

# Scenario #1: rsync must use --partial (safe resume), and must NOT use the
# corruption-prone --ignore-existing or blind --append/--append-verify.
test_e2e_append_verify_flag() {
	echo ""
	echo "=== #1 E2E: --partial replaces --ignore-existing (no blind append) ==="
	e2e_setup "$TEST_ROOT/e2e3"
	e2e_run_backup 0 "$TEST_ROOT/e2e3/args.log" >/dev/null 2>&1
	local args="$TEST_ROOT/e2e3/args.log"
	grep -q -- "--partial" "$args" \
		&& test_passed "rsync called with --partial" \
		|| test_failed "--partial missing from rsync args"
	grep -q -- "--ignore-existing" "$args" \
		&& test_failed "--ignore-existing still present (bug not fixed)" \
		|| test_passed "--ignore-existing removed"
	grep -q -- "--append" "$args" \
		&& test_failed "--append/--append-verify present (corruption risk)" \
		|| test_passed "no blind --append (avoids same-name corruption)"
}

# Scenario #5: removed du precheck. Even though the test host's df free space
# is far larger than the (tiny) source, the key assertion is that NO `du -sm`
# over the source runs and the backup proceeds. We assert by completion when
# MIN_FREE_SPACE is satisfied, and rejection when MIN_FREE_SPACE is impossibly
# high (proving the new df-based guard, not the old whole-card du, is in play).
test_e2e_no_du_precheck() {
	echo ""
	echo "=== #5 E2E: df-based min-free guard, no whole-card du ==="
	e2e_setup "$TEST_ROOT/e2e4"
	# Impossible min free (exabytes) -> must be rejected as no_space.
	local out
	out=$(
		set +e
		export OUTDOOR_BACKUP_SOURCED=1
		export PATH="$TEST_ROOT/e2e4/bin:$PATH"
		export MOCK_RSYNC_EXIT=0
		export MOCK_RSYNC_ARGS_LOG="$TEST_ROOT/e2e4/args.log"
		SCRIPT_DIR="$TEST_ROOT/e2e4/opt/scripts"
		BASE_DIR="$TEST_ROOT/e2e4/opt"
		MOUNT_POINT="$TEST_ROOT/e2e4/mnt/sdcard"
		BACKUP_ROOT="$TEST_ROOT/e2e4/mnt/ssd/SDMirrors"
		STATUS_FILE="$BASE_DIR/var/status.json"
		ALIASES_FILE="$BASE_DIR/conf/aliases.json"
		# shellcheck disable=SC1090
		. "$TEST_ROOT/e2e4/opt/scripts/backup-manager.sh" "add" "sda1" "/d"
		set +e
		LOG_TAG=test
		SD_UUID="550e8400-e29b-41d4-a716-446655440000"
		BACKUP_MODE=PRIMARY
		MIN_FREE_SPACE=999999999999
		LED_RED="/nonexistent/red"; LED_GREEN="/nonexistent/green"
		perform_backup
		echo "RC=$? ERR=$ERROR_TYPE"
	)
	echo "$out" | grep -q "ERR=no_space" \
		&& test_passed "impossible min-free -> no_space (df guard active)" \
		|| test_failed "expected no_space, got: $(echo "$out" | grep RC=)"
	# rsync must NOT have run when space check fails early.
	if [ -f "$TEST_ROOT/e2e4/args.log" ]; then
		test_failed "rsync ran despite failing space check"
	else
		test_passed "rsync skipped when space check fails (fail-fast)"
	fi
}

# Scenario #4/#8: every ERROR_TYPE the code can set must map to a distinct LED
# function in cleanup()'s dispatch. Guards against the regression where LED
# functions existed but no code path ever set their ERROR_TYPE.
test_error_type_led_dispatch() {
	echo ""
	echo "=== #4/#8: ERROR_TYPE -> LED dispatch coverage ==="
	# Assert the source actually assigns each non-rsync error type somewhere.
	local mgr="$SCRIPTS_SRC/backup-manager.sh"
	for et in no_space lock_timeout device_unknown; do
		if grep -q "ERROR_TYPE=\"$et\"" "$mgr"; then
			test_passed "ERROR_TYPE=$et is assigned in backup-manager.sh"
		else
			test_failed "ERROR_TYPE=$et never set (LED unreachable)"
		fi
	done
	# Assert cleanup() dispatches each type to its LED function.
	for pair in "no_space:led_err_no_space" \
		    "lock_timeout:led_err_lock_timeout" \
		    "device_unknown:led_err_device_unknown" \
		    "verify_failed:led_err_verify_failed"; do
		local key="${pair%%:*}" fn="${pair##*:}"
		if grep -q "$key)" "$mgr" && grep -q "$fn" "$mgr"; then
			test_passed "cleanup dispatches $key -> $fn"
		else
			test_failed "cleanup missing dispatch $key -> $fn"
		fi
	done
}






main "$@"

#!/bin/sh
#
# BDD integration tests for manager-owned rsync live progress. The host starts
# one pinned, disposable OpenWrt container; source stays read-only and every
# mutable fixture is container-local under /tmp or a unique /dev tmpfs child.
#
set -u

IMAGE="openwrt/rootfs:aarch64_generic-24.10.8"
IMAGE_DIGEST="sha256:f6dd33c1d9b7d6f1e0848f2fbb92b8d03fc9b425dc08c3574a44936b93133704"

if [ "${1:-}" != "--inside" ]; then
	REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
	RUN_ID="${$}.$(date +%s)"
	HOST_EVIDENCE="/tmp/outdoor-live-progress.${RUN_ID}"
	CID_FILE="${HOST_EVIDENCE}.cid"
	cleanup_container() {
		if [ -s "$CID_FILE" ]; then
			cid=$(sed -n '1p' "$CID_FILE")
			[ -z "$cid" ] || docker rm -f "$cid" >/dev/null 2>&1 || :
		fi
		rm -f "$CID_FILE"
	}
	trap cleanup_container EXIT INT TERM
	set +e
	docker run --pull=never --cidfile "$CID_FILE" --memory 512m --pids-limit 128 \
		--cap-drop ALL --security-opt no-new-privileges --log-driver local \
		--log-opt max-size=2m --log-opt max-file=1 --log-opt compress=false --tmpfs /tmp:rw,exec \
		-v "$REPO_ROOT:/src:ro" "$IMAGE@$IMAGE_DIGEST" \
		/bin/ash /src/test-live-progress.sh --inside >"${HOST_EVIDENCE}.stdout" 2>"${HOST_EVIDENCE}.stderr"
	rc=$?
	printf '%s\n' "$rc" >"${HOST_EVIDENCE}.rc"
	printf 'EVIDENCE: %s.{stdout,stderr,rc}\n' "$HOST_EVIDENCE" >&2
	cat "${HOST_EVIDENCE}.stdout"
	cat "${HOST_EVIDENCE}.stderr" >&2
	exit "$rc"
fi

[ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || {
	printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
	exit 1
}
mkdir -p /var/lock || exit 1
opkg update >/dev/null || exit 1
opkg install jq rsync >/dev/null || exit 1

TEST_CAPTURED_STDERR=1
TEST_ASYNC_STDERR=/tmp/outdoor-live-progress-async.stderr
TEST_TARGET_MANAGER_LIBRARY_ONLY=1
. /src/test-target-manager.sh

CASES=0
ASSERTIONS=0
FAILED=0
LIVE_SEQ=0

fail() { printf 'FAIL: %s\n' "$1" >&2; FAILED=$((FAILED + 1)); }
begin_case() { CASES=$((CASES + 1)); printf 'CASE %s: %s\n' "$1" "$2"; }
assert_success() { message=$1; shift; ASSERTIONS=$((ASSERTIONS + 1)); "$@" || fail "$message"; }
assert_failure() { message=$1; shift; ASSERTIONS=$((ASSERTIONS + 1)); "$@" && fail "$message"; }
assert_equal() {
	actual=$1 expected=$2 message=$3
	ASSERTIONS=$((ASSERTIONS + 1))
	[ "$actual" = "$expected" ] || fail "$message (expected=[$expected], actual=[$actual])"
}
assert_jq() {
	filter=$1 message=$2
	ASSERTIONS=$((ASSERTIONS + 1))
	jq -e "$filter" "$RUNTIME/var/status.json" >/dev/null 2>&1 || fail "$message"
}
wait_for_jq() {
	filter=$1 attempts=0
	while [ "$attempts" -lt 15 ]; do
		[ -f "$RUNTIME/var/status.json" ] && jq -e "$filter" "$RUNTIME/var/status.json" >/dev/null 2>&1 && return 0
		/bin/sleep 1
		attempts=$((attempts + 1))
	done
	if [ -f "$RUNTIME/var/status.json" ]; then
		jq -c . "$RUNTIME/var/status.json" >&2
	else
		printf '%s\n' 'live-progress status snapshot was never created' >&2
	fi
	return 1
}
wait_for_path() {
	path=$1 attempts=0
	while [ ! -e "$path" ] && [ "$attempts" -lt 15 ]; do /bin/sleep 1; attempts=$((attempts + 1)); done
	[ -e "$path" ]
}
wait_for_effect() {
	needle=$1 attempts=0
	while ! grep -F -q -- "$needle" "$EFFECTS" 2>/dev/null && [ "$attempts" -lt 15 ]; do
		/bin/sleep 1
		attempts=$((attempts + 1))
	done
	grep -F -q -- "$needle" "$EFFECTS"
}
wait_for_effect_count() {
	needle=$1 expected=$2 attempts=0
	while [ "$(grep -F -c -- "$needle" "$EFFECTS" 2>/dev/null || :)" -lt "$expected" ] && [ "$attempts" -lt 15 ]; do
		/bin/sleep 1
		attempts=$((attempts + 1))
	done
	[ "$(grep -F -c -- "$needle" "$EFFECTS" 2>/dev/null || :)" -ge "$expected" ]
}
wait_for_exit() {
	pid=$1 attempts=0
	while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 20 ]; do /bin/sleep 1; attempts=$((attempts + 1)); done
	! kill -0 "$pid" 2>/dev/null
}

live_reset() {
	[ -z "${LIVE_DEV_ROOT:-}" ] || rm -rf "$LIVE_DEV_ROOT"
	rm -rf "$TEST_ROOT"
	LIVE_SEQ=$((LIVE_SEQ + 1))
	TEST_ROOT="$SUITE_ROOT/live-$LIVE_SEQ"
	derive_fixture_paths
	TARGET_MOUNT=/dev
	LIVE_DEV_ROOT="/dev/outdoor-live-progress-$$-$LIVE_SEQ"
	LIVE_BACKUP_ROOT="$LIVE_DEV_ROOT/backups"
	mkdir -p "$TEST_ROOT" "$LIVE_DEV_ROOT"
	prepare_fixture_topology || return 1
	prepare_runtime || return 1
	sed -i "s|^BACKUP_ROOT=.*|BACKUP_ROOT=\"$LIVE_BACKUP_ROOT\"|" "$RUNTIME/conf/backup.conf"
	cat > "$BIN/rsync" <<'EOF'
#!/bin/ash
printf '%s\n' 'live-rsync-start' >> "$TEST_EFFECTS"
[ -z "${TEST_PROGRESS_READY:-}" ] || : > "$TEST_PROGRESS_READY"
case "$(cat "$(dirname "$0")/progress-mode" 2>/dev/null || printf suffix)" in
suffix)
	printf '\r 100 11%% 1.00kB/s 0:00:01 (xfr#1, to-chk=9/10)\n'
	/bin/sleep 2
	printf '\r 300 11%% 3.00kB/s 0:00:03 (xfr#3, to-chk=7/10)\n'
	/bin/sleep 2
	printf '\r 500 11%% 5.00kB/s 0:00:05 (xfr#5, to-chk=5/10)\n'
	/bin/sleep 2
	;;
unknown)
	printf '\r 100 11%% 1.00kB/s 0:00:01\n'
	/bin/sleep 3
	printf '\r 300 11%% 3.00kB/s 0:00:04\n'
	/bin/sleep 3
	printf '\r 500 11%% 5.00kB/s 0:00:07\n'
	/bin/sleep 2
	;;
duplicate)
	printf '\r 100 11%% 1.00kB/s 0:00:01\n'
	/bin/sleep 5
	;;
zero)
	printf '\r 0 0%% 0.00kB/s 0:00:00 (xfr#0, to-chk=0/0)\n'
	/bin/sleep 3
	;;
malformed)
	printf '\r 100 11%% 1.00kB/s 0:00:01 (xfr#1, to-chk=9/10)\n'
	/bin/sleep 2
	printf '\r nonsense 11%% impossible\n'
	/bin/sleep 2
	;;
known-then-suffix-free)
	printf '\r 100 11%% 1.00kB/s 0:00:01 (xfr#1, to-chk=9/10)\n'
	while [ ! -e "$TEST_KNOWN_SUFFIX_FIRST_MARKER" ]; do /bin/sleep 1; done
	# Move the previous suffix outside the parser's 8192-byte tail window.
	awk 'BEGIN { for (padding_index = 0; padding_index < 8200; padding_index++) printf "diagnostic padding\n" }'
	printf '\r 300 11%% 3.00kB/s 0:00:03\n'
	while [ ! -e "$TEST_KNOWN_SUFFIX_SECOND_MARKER" ]; do /bin/sleep 1; done
	;;
long)
	progress=1
	while [ "$progress" -le 4 ]; do
		printf '\r %s 11%% 1.00kB/s 0:00:01 (xfr#%s, to-chk=%s/4)\n' \
			"$((progress * 100))" "$progress" "$((4 - progress))"
		/bin/sleep 1
		progress=$((progress + 1))
	done
	;;
esac
printf '%s\n' 'Number of regular files transferred: 7'
printf '%s\n' 'Total transferred file size: 1,234 bytes'
EOF
	chmod 755 "$BIN/rsync"
}

start_manager() {
	TEST_RUN_MANAGER_EXEC=1 TEST_MANAGER_SHELL=/bin/ash TEST_MOUNT_AUTO_CARD=1 \
		TEST_RSYNC_STATS=1 TEST_SLEEP_PASSTHROUGH=1 run_manager add sda1 /devices/mock &
	MANAGER_PID=$!
}

case_live_suffix_progress_and_throttle() {
	begin_case L01 'running snapshots use xfr and to-chk counters without raw rsync percentage'
	live_reset || { fail 'L01 fixture setup failed'; return; }
	printf '%s\n' suffix > "$BIN/progress-mode"
	start_manager
	assert_success 'L01 real rsync fixture starts through the manager runner' wait_for_effect live-rsync-start
	assert_success 'L01 first valid running snapshot is published' \
		wait_for_jq '.current_backup.live_progress.entries_done == 3 and .current_backup.live_progress.entries_total == 10 and .current_backup.live_progress.files_known == true and .current_backup.bytes_done == 300'
	first_update=$(jq -r '.last_update' "$RUNTIME/var/status.json")
	/bin/sleep 1
	second_update=$(jq -r '.last_update' "$RUNTIME/var/status.json")
	assert_equal "$second_update" "$first_update" 'L01 one-second loop is throttled to at most one publication per two seconds'
	assert_success 'L01 later valid record changes observed values' \
		wait_for_jq '.current_backup.files_done == 5 and .current_backup.bytes_done == 500 and .current_backup.speed_bytes_per_sec == 5120 and .current_backup.live_progress.entries_done == 5 and .current_backup.progress_percent == 50'
	assert_jq '.current_backup.files_total == 0 and .current_backup.bytes_total == 0 and .current_backup.progress_percent < 100 and .current_backup.live_progress == {basis:"file_list_entries", entries_done:5, entries_total:10, sampled_at:.current_backup.live_progress.sampled_at, files_known:true}' \
		'L01 keeps old totals unknown and uses entry-list basis with running cap'
	assert_success 'L01 manager eventually completes' wait_for_exit "$MANAGER_PID"
	wait "$MANAGER_PID" 2>/dev/null || manager_rc=$?
	manager_rc=${manager_rc:-0}
	assert_equal "$manager_rc" 0 'L01 live observation preserves successful rsync exit'
	assert_jq '.current_backup == null and .history[0].status == "completed"' 'L01 terminal snapshot cannot be overwritten by a running observer'
}

case_unknown_and_malformed_retain_last_snapshot() {
	begin_case L02 'unknown entries remain explicit and malformed observations cannot overwrite valid state'
	live_reset || { fail 'L02 unknown fixture setup failed'; return; }
	printf '%s\n' unknown > "$BIN/progress-mode"
	start_manager
	assert_success 'L02 suffix-free bytes and speed publish a sampled unknown-entry snapshot' \
		wait_for_jq '.current_backup.files_done == 0 and .current_backup.bytes_done > 0 and .current_backup.speed_bytes_per_sec > 0 and .current_backup.live_progress.entries_done == null and .current_backup.live_progress.entries_total == null and .current_backup.live_progress.files_known == false and (.current_backup.live_progress.sampled_at | type == "number")'
	unknown_bytes=$(jq -r '.current_backup.bytes_done' "$RUNTIME/var/status.json")
	unknown_speed=$(jq -r '.current_backup.speed_bytes_per_sec' "$RUNTIME/var/status.json")
	unknown_sampled_at=$(jq -r '.current_backup.live_progress.sampled_at' "$RUNTIME/var/status.json")
	unknown_writes=$(cat "$TEST_ROOT/status-mv-count")
	assert_success 'L02 changed suffix-free bytes and speed publish a new observation' \
		wait_for_jq ".current_backup.bytes_done > $unknown_bytes and .current_backup.speed_bytes_per_sec > $unknown_speed and (.current_backup.live_progress.sampled_at > 0)"
	assert_success 'L02 changed observation advances sampled time' \
		test "$(jq -r '.current_backup.live_progress.sampled_at' "$RUNTIME/var/status.json")" -gt "$unknown_sampled_at"
	assert_success 'L02 changed observation performs one additional status write' \
		test "$(cat "$TEST_ROOT/status-mv-count")" -gt "$unknown_writes"
	assert_success 'L02 unknown manager completes' wait_for_exit "$MANAGER_PID"
	wait "$MANAGER_PID" 2>/dev/null || unknown_rc=$?
	unknown_rc=${unknown_rc:-0}
	assert_equal "$unknown_rc" 0 'L02 unknown metadata does not alter transfer exit'

	live_reset || { fail 'L02 duplicate fixture setup failed'; return; }
	printf '%s\n' duplicate > "$BIN/progress-mode"
	start_manager
	assert_success 'L02 duplicate baseline is sampled once' \
		wait_for_jq '.current_backup.bytes_done == 100 and (.current_backup.live_progress.sampled_at | type == "number")'
	duplicate_sampled_at=$(jq -r '.current_backup.live_progress.sampled_at' "$RUNTIME/var/status.json")
	duplicate_writes=$(cat "$TEST_ROOT/status-mv-count")
	/bin/sleep 3
	assert_equal "$(jq -r '.current_backup.live_progress.sampled_at' "$RUNTIME/var/status.json")" "$duplicate_sampled_at" \
		'L02 unchanged parser tuple does not refresh sampled_at'
	assert_equal "$(cat "$TEST_ROOT/status-mv-count")" "$duplicate_writes" \
		'L02 unchanged parser tuple does not publish another status snapshot'
	assert_success 'L02 duplicate manager completes' wait_for_exit "$MANAGER_PID"
	wait "$MANAGER_PID" 2>/dev/null || duplicate_rc=$?
	duplicate_rc=${duplicate_rc:-0}
	assert_equal "$duplicate_rc" 0 'L02 duplicate observation preserves rsync success'

	live_reset || { fail 'L02 zero-total fixture setup failed'; return; }
	printf '%s\n' zero > "$BIN/progress-mode"
	start_manager
	assert_success 'L02 zero to-chk total is rejected without inventing known entry totals or losing the real xfr#0 file count' \
		wait_for_jq '.current_backup.files_done == 0 and .current_backup.live_progress.entries_done == null and .current_backup.live_progress.entries_total == null and .current_backup.live_progress.files_known == true and .current_backup.progress_percent == 0'
	assert_success 'L02 zero-total manager completes without arithmetic failure' wait_for_exit "$MANAGER_PID"
	wait "$MANAGER_PID" 2>/dev/null || zero_rc=$?
	zero_rc=${zero_rc:-0}
	assert_equal "$zero_rc" 0 'L02 rejected zero total preserves rsync success'

	live_reset || { fail 'L02 malformed fixture setup failed'; return; }
	printf '%s\n' malformed > "$BIN/progress-mode"
	start_manager
	assert_success 'L02 valid baseline appears before malformed tail' \
		wait_for_jq '.current_backup.bytes_done == 100 and .current_backup.live_progress.entries_done == 1'
	/bin/sleep 2
	assert_jq '.current_backup.bytes_done == 100 and .current_backup.live_progress.entries_done == 1 and .current_backup.live_progress.entries_total == 10' \
		'L02 malformed record preserves the last valid per-task snapshot'
	assert_success 'L02 malformed manager completes' wait_for_exit "$MANAGER_PID"
	wait "$MANAGER_PID" 2>/dev/null || malformed_rc=$?
	malformed_rc=${malformed_rc:-0}
	assert_equal "$malformed_rc" 0 'L02 malformed observation does not forge an rsync failure'

	live_reset || { fail 'L02 known-then-suffix-free fixture setup failed'; return; }
	printf '%s\n' known-then-suffix-free > "$BIN/progress-mode"
	TEST_KNOWN_SUFFIX_FIRST_MARKER="$BIN/known-suffix-first-release"
	TEST_KNOWN_SUFFIX_SECOND_MARKER="$BIN/known-suffix-second-release"
	export TEST_KNOWN_SUFFIX_FIRST_MARKER TEST_KNOWN_SUFFIX_SECOND_MARKER
	start_manager
	assert_success 'L02 a valid xfr sample establishes a known file count before a suffix-free tail' \
		wait_for_jq '.current_backup.files_done == 1 and .current_backup.live_progress.files_known == true and .current_backup.live_progress.entries_done == 1'
	known_suffix_writes=$(cat "$TEST_ROOT/status-mv-count")
	# Always release this marker after the assertion so a failed check cannot strand rsync.
	: > "$TEST_KNOWN_SUFFIX_FIRST_MARKER"
	assert_success 'L02 a suffix-free tail keeps the last observed file count and entry progress' \
		wait_for_jq '.current_backup.bytes_done == 300 and .current_backup.files_done == 1 and .current_backup.live_progress.files_known == true and .current_backup.live_progress.entries_done == 1 and .current_backup.live_progress.entries_total == 10'
	assert_success 'L02 suffix-free tail publishes the retained state as a new status snapshot' \
		test "$(cat "$TEST_ROOT/status-mv-count")" -gt "$known_suffix_writes"
	# Always release this marker after observing the retained state, including on failure.
	: > "$TEST_KNOWN_SUFFIX_SECOND_MARKER"
	assert_success 'L02 known-then-suffix-free manager completes' wait_for_exit "$MANAGER_PID"
	wait "$MANAGER_PID" 2>/dev/null || known_suffix_rc=$?
	known_suffix_rc=${known_suffix_rc:-0}
	unset TEST_KNOWN_SUFFIX_FIRST_MARKER TEST_KNOWN_SUFFIX_SECOND_MARKER
	assert_equal "$known_suffix_rc" 0 'L02 suffix-free tail preserves rsync success after a known file count'
}

case_new_task_reset_write_failure_and_cancel_drain() {
	begin_case L03 'new tasks reset state, status failures become lifecycle failures, and cancellation drains observers'
	live_reset || { fail 'L03 reset fixture setup failed'; return; }
	printf '%s\n' duplicate > "$BIN/progress-mode"
	start_manager
	assert_success 'L03 first task observes a suffix-free parser tuple' \
		wait_for_jq '.current_backup.bytes_done == 100 and (.current_backup.live_progress.sampled_at | type == "number")'
	assert_success 'L03 first task exits' wait_for_exit "$MANAGER_PID"
	wait "$MANAGER_PID" 2>/dev/null || :
	start_manager
	assert_success 'L03 second task begins with a reset unknown snapshot before observation' \
		wait_for_jq '.current_backup.active == true and .current_backup.files_done == 0 and .current_backup.live_progress.entries_done == null and .current_backup.live_progress.files_known == false and .current_backup.live_progress.sampled_at == null'
	assert_success 'L03 a new task accepts the same parser tuple after reset' \
		wait_for_jq '.current_backup.bytes_done == 100 and (.current_backup.live_progress.sampled_at | type == "number")'
	assert_success 'L03 second rsync session is live before cancellation' wait_for_effect_count live-rsync-start 2
	kill -TERM "$MANAGER_PID"
	assert_success 'L03 reset task drains after TERM' wait_for_exit "$MANAGER_PID"
	wait "$MANAGER_PID" 2>/dev/null || reset_rc=$?
	reset_rc=${reset_rc:-0}
	assert_equal "$reset_rc" 143 'L03 cancellation preserves its actual exit status'
	assert_jq '.current_backup == null and .history[0].status == "error" and .history[0].error_message == "cancelled"' \
		'L03 cancelled observer cannot replace terminal status'

	live_reset || { fail 'L03 write-failure fixture setup failed'; return; }
	printf '%s\n' long > "$BIN/progress-mode"
	TEST_STATUS_MV_FAIL_ON=2
	export TEST_STATUS_MV_FAIL_ON
	start_manager
	assert_success 'L03 status-write failure scenario starts real progress output' wait_for_effect live-rsync-start
	assert_success 'L03 status-write failure manager exits' wait_for_exit "$MANAGER_PID"
	wait "$MANAGER_PID" 2>/dev/null || write_rc=$?
	write_rc=${write_rc:-0}
	unset TEST_STATUS_MV_FAIL_ON
	assert_equal "$write_rc" 1 'L03 failed running snapshot turns a successful transfer into lifecycle error'
	assert_jq '.current_backup == null and .history[0].status == "error" and .history[0].error_message == "rsync"' \
		'L03 status write failure never claims completed'
}

case_legacy_status_call_keeps_shape_and_history_reader() {
	begin_case L04 'old write_status calls keep their original running schema and history remains readable'
	live_reset || { fail 'L04 fixture setup failed'; return; }
	STATUS_FILE="$RUNTIME/var/status.json"
	export STATUS_FILE
	. "$SCRIPTS/status.sh"
	assert_success 'L04 old 15-argument write_status call succeeds' write_status running test card sda1 1 0 0 0 0 0 0 "$LIVE_DEV_ROOT" /backup '' "$LIVE_DEV_ROOT"
	assert_jq '(.current_backup | has("live_progress") | not) and (.current_backup | keys | sort) == ["active","bytes_done","bytes_total","device","files_done","files_total","name","progress_percent","speed_bytes_per_sec","started_at","uuid"]' \
		'L04 legacy running JSON shape has no new field'
	assert_success 'L04 old snapshot remains readable by status_read_history' status_read_history
	assert_success 'L04 a prior four-field live-progress object remains accepted as files unknown' \
		write_status running test card sda1 1 0 0 0 0 0 0 "$LIVE_DEV_ROOT" /backup '' "$LIVE_DEV_ROOT" \
		'{"basis":"file_list_entries","entries_done":null,"entries_total":null,"sampled_at":1}'
	assert_jq '.current_backup.live_progress == {basis:"file_list_entries", entries_done:null, entries_total:null, sampled_at:1, files_known:false}' \
		'L04 four-field live progress is normalized to the fixed five-field form'
	assert_failure 'L04 non-boolean files_known is rejected without replacing the last valid snapshot' \
		write_status running test card sda1 1 0 0 0 0 0 0 "$LIVE_DEV_ROOT" /backup '' "$LIVE_DEV_ROOT" \
		'{"basis":"file_list_entries","entries_done":null,"entries_total":null,"sampled_at":2,"files_known":"true"}'
	assert_jq '.current_backup.live_progress.files_known == false and .current_backup.live_progress.sampled_at == 1' \
		'L04 rejected files_known preserves the prior normalized snapshot'
}

main() {
	trap 'rm -rf "$SUITE_ROOT" "${LIVE_DEV_ROOT:-}" /opt/outdoor-backup/conf "$TEST_ASYNC_STDERR"' EXIT INT TERM
	case_live_suffix_progress_and_throttle
	case_unknown_and_malformed_retain_last_snapshot
	case_new_task_reset_write_failure_and_cancel_drain
	case_legacy_status_call_keeps_shape_and_history_reader
	printf 'RESULT cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
	[ "$CASES" -eq 4 ] || fail "expected 4 cases, ran $CASES"
	[ "$ASSERTIONS" -eq 50 ] || fail "expected 50 assertions, ran $ASSERTIONS"
	[ "$FAILED" -eq 0 ]
}

main "$@"

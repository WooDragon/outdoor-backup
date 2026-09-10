#!/bin/sh
#
# BDD tests for the shipped private-session transfer runner. Every process is
# created inside the pinned OpenWrt container; signals target only fixture PIDs.
#
set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
	REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
	exec docker run --rm --platform linux/amd64 --network bridge --tmpfs /tmp:rw,exec \
		-v "$REPO_ROOT:/src:ro" "$IMAGE@$IMAGE_DIGEST" \
		/bin/ash /src/test-transfer-process.sh --inside
fi

[ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || {
	printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
	exit 1
}

PROCESS_SCRIPT=/src/files/opt/outdoor-backup/scripts/transfer-process.sh
TEST_ROOT="/tmp/outdoor-backup-transfer-process.$$"
BIN="$TEST_ROOT/bin"
CASES=0
ASSERTIONS=0
FAILED=0

fail() { printf 'FAIL: %s\n' "$1" >&2; FAILED=$((FAILED + 1)); }
begin_case() { CASES=$((CASES + 1)); printf 'CASE %s: %s\n' "$1" "$2"; }
assert_equal() {
	actual=$1 expected=$2 message=$3
	ASSERTIONS=$((ASSERTIONS + 1))
	[ "$actual" = "$expected" ] || fail "$message (expected=[$expected], actual=[$actual])"
}
assert_success() {
	message=$1; shift; ASSERTIONS=$((ASSERTIONS + 1)); "$@" || fail "$message"
}
assert_absent() {
	path=$1 message=$2; ASSERTIONS=$((ASSERTIONS + 1))
	[ ! -e "$path" ] || fail "$message (path=[$path])"
}
wait_for_path() {
	path=$1 attempts=0
	while [ ! -e "$path" ] && [ "$attempts" -lt 10 ]; do
		/bin/sleep 1
		attempts=$((attempts + 1))
	done
	[ -e "$path" ]
}
wait_for_exit() {
	pid=$1 attempts=0
	while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 12 ]; do
		/bin/sleep 1
		attempts=$((attempts + 1))
	done
	! kill -0 "$pid" 2>/dev/null
}
setup_fixture() {
	rm -rf "$TEST_ROOT"
	mkdir -p "$BIN"
	cat > "$BIN/runner" <<'EOF'
#!/bin/ash
. "$TEST_PROCESS_SCRIPT"
BACKUP_CANCEL_CODE=0
trap '[ "$BACKUP_CANCEL_CODE" -ne 0 ] || BACKUP_CANCEL_CODE=143' TERM
transfer_process_run "$@"
rc=$?
printf '%s\n' "$rc" > "$TEST_RESULT"
exit "$rc"
EOF
	cat > "$BIN/pre-cancel-runner" <<'EOF'
#!/bin/ash
. "$TEST_PROCESS_SCRIPT"
BACKUP_CANCEL_CODE=143
transfer_process_run "$@"
rc=$?
printf '%s\n' "$rc" > "$TEST_RESULT"
exit "$rc"
EOF
	sed -n '/^transfer_process_read_stat() {/,/^# Return whether the expected private session/p' \
		"$PROCESS_SCRIPT" | sed '1s/^transfer_process_read_stat()/transfer_process_read_stat_original()/' \
		> "$TEST_ROOT/read-stat-original.sh"
	cat > "$BIN/gated-runner" <<'EOF'
#!/bin/ash
. "$TEST_PROCESS_SCRIPT"
. "$TEST_READ_STAT_LIBRARY"
TEST_FIRST_READ_USED=0
transfer_process_read_stat() {
	if [ "$TEST_FIRST_READ_USED" -eq 0 ]; then
		TEST_FIRST_READ_USED=1
		while [ ! -e "$TEST_FIRST_READ_RELEASE" ]; do /bin/sleep 1; done
	fi
	transfer_process_read_stat_original "$@"
}
BACKUP_CANCEL_CODE=0
trap '[ "$BACKUP_CANCEL_CODE" -ne 0 ] || BACKUP_CANCEL_CODE=143' TERM
transfer_process_run "$@"
rc=$?
printf '%s\n' "$rc" > "$TEST_RESULT"
exit "$rc"
EOF
	cat > "$BIN/snapshot-runner" <<'EOF'
#!/bin/ash
. "$TEST_PROCESS_SCRIPT"
. "$TEST_READ_STAT_LIBRARY"
transfer_process_read_stat() {
	if [ "${TEST_SNAPSHOT_TRIGGERED:-0}" = 0 ] && [ -r "$TEST_SNAPSHOT_OLD_PID" ] && \
		[ "$1" = "$(cat "$TEST_SNAPSHOT_OLD_PID")" ]; then
		TEST_SNAPSHOT_TRIGGERED=1
		: > "$TEST_SNAPSHOT_TRIGGER"
		while [ ! -e "$TEST_SNAPSHOT_REPLACEMENT_READY" ]; do /bin/sleep 1; done
	fi
	transfer_process_read_stat_original "$@"
}
BACKUP_CANCEL_CODE=0
transfer_process_run "$@"
rc=$?
printf '%s\n' "$rc" > "$TEST_RESULT"
exit "$rc"
EOF
	cat > "$BIN/leader-replacement" <<'EOF'
#!/bin/ash
old_pid_file=$1
trigger=$2
replacement_ready=$3
replacement_release=$4
trace=$5
(
	while [ ! -e "$trigger" ]; do /bin/sleep 1; done
	(
		trap 'exit 0' TERM
		: > "$replacement_ready"
		while [ ! -e "$replacement_release" ]; do printf 'replacement-write\n' >> "$trace"; /bin/sleep 1; done
	) &
	exit 0
) &
printf '%s\n' "$!" > "$old_pid_file"
exit 0
EOF
	cat > "$BIN/writer" <<'EOF'
#!/bin/ash
ready=$1
trace=$2
child_ready=$3
: > "$ready"
(
	trap 'exit 0' TERM
	: > "$child_ready"
	while :; do printf 'child\n' >> "$trace"; /bin/sleep 1; done
) &
child=$!
printf '%s\n' "$child" > "$ready.child"
trap 'wait "$child" 2>/dev/null; exit 0' TERM
while :; do printf 'leader\n' >> "$trace"; /bin/sleep 1; done
EOF
	cat > "$BIN/leader-exits" <<'EOF'
#!/bin/ash
ready=$1
trace=$2
: > "$ready"
(
	trap 'exit 0' TERM
	while :; do printf 'child\n' >> "$trace"; /bin/sleep 1; done
) &
printf '%s\n' "$!" > "$ready.child"
exit 0
EOF
	chmod 700 "$BIN"/*
}
start_runner() {
	result=$1; shift
	TEST_PROCESS_SCRIPT="$PROCESS_SCRIPT" TEST_RESULT="$result" "$BIN/runner" "$@" &
	RUNNER_PID=$!
}
start_pre_cancel_runner() {
	result=$1; shift
	TEST_PROCESS_SCRIPT="$PROCESS_SCRIPT" TEST_RESULT="$result" "$BIN/pre-cancel-runner" "$@" &
	RUNNER_PID=$!
}
start_gated_runner() {
	result=$1 gate=$2; shift 2
	TEST_PROCESS_SCRIPT="$PROCESS_SCRIPT" TEST_READ_STAT_LIBRARY="$TEST_ROOT/read-stat-original.sh" \
		TEST_RESULT="$result" TEST_FIRST_READ_RELEASE="$gate" "$BIN/gated-runner" "$@" &
	RUNNER_PID=$!
}
start_snapshot_runner() {
	result=$1; shift
	TEST_PROCESS_SCRIPT="$PROCESS_SCRIPT" TEST_READ_STAT_LIBRARY="$TEST_ROOT/read-stat-original.sh" \
		TEST_RESULT="$result" TEST_SNAPSHOT_OLD_PID="$TEST_ROOT/snapshot-old.pid" \
		TEST_SNAPSHOT_TRIGGER="$TEST_ROOT/snapshot-trigger" \
		TEST_SNAPSHOT_REPLACEMENT_READY="$TEST_ROOT/snapshot-replacement-ready" \
		"$BIN/snapshot-runner" "$@" &
	RUNNER_PID=$!
}

case_source_is_inert() {
	begin_case P01 'sourcing runner installs no trap and creates no runtime output'
	setup_fixture
	before=$(trap)
	. "$PROCESS_SCRIPT"
	assert_equal "$(trap)" "$before" 'P01 source leaves caller traps unchanged'
	assert_success 'P01 source defines run API' command -v transfer_process_run
	assert_absent "$TEST_ROOT/unexpected" 'P01 source does not write fixture state'
}

case_missing_setsid_fails_without_child() {
	begin_case P02 'missing setsid fails loud and never launches a command'
	setup_fixture
	marker="$TEST_ROOT/marker"
	cat > "$BIN/command" <<EOF
#!/bin/ash
: > "$marker"
EOF
	chmod 700 "$BIN/command"
	if PATH="$BIN" TEST_PROCESS_SCRIPT="$PROCESS_SCRIPT" TEST_RESULT="$TEST_ROOT/result" \
		"$BIN/runner" command; then rc=0; else rc=$?; fi
	assert_equal "$rc" 127 'P02 missing setsid returns fail-loud command-not-found status'
	assert_absent "$marker" 'P02 command was not launched without setsid'
	assert_equal "$(cat "$TEST_ROOT/result")" 127 'P02 runner records the fail-loud result without launching a command'
}

case_cancel_isolated_private_group() {
	begin_case P03 'TERM cancels only the owned session and waits for its child writer'
	setup_fixture
	a_ready="$TEST_ROOT/a.ready" a_trace="$TEST_ROOT/a.trace" a_child="$TEST_ROOT/a.child-ready"
	b_ready="$TEST_ROOT/b.ready" b_trace="$TEST_ROOT/b.trace" b_child="$TEST_ROOT/b.child-ready"
	start_runner "$TEST_ROOT/a.result" "$BIN/writer" "$a_ready" "$a_trace" "$a_child"
	a_runner=$RUNNER_PID
	start_runner "$TEST_ROOT/b.result" "$BIN/writer" "$b_ready" "$b_trace" "$b_child"
	b_runner=$RUNNER_PID
	assert_success 'P03 A leader becomes observable' wait_for_path "$a_ready"
	assert_success 'P03 A child becomes observable' wait_for_path "$a_child"
	assert_success 'P03 B leader becomes observable' wait_for_path "$b_ready"
	kill -TERM "$a_runner"
	kill -TERM "$a_runner"
	assert_success 'P03 repeated TERM remains idempotent until its session exits' wait_for_exit "$a_runner"
	wait "$a_runner" 2>/dev/null || a_rc=$?
	a_rc=${a_rc:-0}
	assert_equal "$a_rc" 143 'P03 TERM keeps its first cancellation exit status'
	assert_equal "$(cat "$TEST_ROOT/a.result")" 143 'P03 runner reports cancellation rather than child signal status'
	ASSERTIONS=$((ASSERTIONS + 1))
	kill -0 "$b_runner" 2>/dev/null || fail 'P03 B private session remains alive after A cancellation'
	before=$(wc -l < "$a_trace")
	/bin/sleep 2
	after=$(wc -l < "$a_trace")
	assert_equal "$after" "$before" 'P03 no A writer remains after cancellation returns'
	kill -TERM "$b_runner"
	wait "$b_runner" 2>/dev/null || :
}

case_prelaunch_cancel_waits_for_private_session() {
	begin_case P04 'a pre-launch sticky TERM waits for the new session and leaves no writer'
	setup_fixture
	ready="$TEST_ROOT/pre.ready" trace="$TEST_ROOT/pre.trace" child_ready="$TEST_ROOT/pre.child-ready"
	start_pre_cancel_runner "$TEST_ROOT/pre.result" "$BIN/writer" "$ready" "$trace" "$child_ready"
	pre_runner=$RUNNER_PID
	assert_success 'P04 pre-cancelled runner exits in bounded time' wait_for_exit "$pre_runner"
	wait "$pre_runner" 2>/dev/null || pre_rc=$?
	pre_rc=${pre_rc:-0}
	assert_equal "$pre_rc" 143 'P04 pre-launch cancellation remains TERM rather than launch failure'
	assert_equal "$(cat "$TEST_ROOT/pre.result")" 143 'P04 runner reports the sticky cancellation code'
	if [ -e "$trace" ]; then
		before=$(wc -l < "$trace")
		/bin/sleep 2
		after=$(wc -l < "$trace")
		assert_equal "$after" "$before" 'P04 no writer survives a cancellation during session creation'
	else
		assert_absent "$child_ready" 'P04 no child was created before the session received TERM'
	fi
}

case_fast_natural_and_leader_exit_child() {
	begin_case P05 'natural status survives and leader exit does not release before its child stops'
	setup_fixture
	start_runner "$TEST_ROOT/fast.result" /bin/sh -c 'exit 23'
	fast_runner=$RUNNER_PID
	wait "$fast_runner" 2>/dev/null || fast_rc=$?
	fast_rc=${fast_rc:-0}
	assert_equal "$fast_rc" 23 'P05 fast natural exit preserves real command status'
	assert_equal "$(cat "$TEST_ROOT/fast.result")" 23 'P05 fast result is not converted to launch failure'
	ready="$TEST_ROOT/leader.ready" trace="$TEST_ROOT/leader.trace"
	start_runner "$TEST_ROOT/leader.result" "$BIN/leader-exits" "$ready" "$trace"
	leader_runner=$RUNNER_PID
	assert_success 'P05 detached child is observable' wait_for_path "$ready.child"
	/bin/sleep 2
	ASSERTIONS=$((ASSERTIONS + 1))
	kill -0 "$leader_runner" 2>/dev/null || fail 'P05 runner did not return while session child still writes'
	child_pid=$(cat "$ready.child")
	kill -TERM "$child_pid"
	assert_success 'P05 runner returns after the last child exits' wait_for_exit "$leader_runner"
	wait "$leader_runner" 2>/dev/null || leader_rc=$?
	leader_rc=${leader_rc:-0}
	assert_equal "$leader_rc" 0 'P05 leader-exit session preserves natural zero once child ends'
}

case_leader_gone_before_first_proc_read_drains_child() {
	begin_case P06 'leader gone before first proc read retains the session until its child exits'
	setup_fixture
	ready="$TEST_ROOT/early.ready" trace="$TEST_ROOT/early.trace" gate="$TEST_ROOT/first-read-release"
	start_gated_runner "$TEST_ROOT/early.result" "$gate" "$BIN/leader-exits" "$ready" "$trace"
	early_runner=$RUNNER_PID
	assert_success 'P06 leader created the child before the gated first proc read' wait_for_path "$trace"
	: > "$gate"
	/bin/sleep 2
	ASSERTIONS=$((ASSERTIONS + 1))
	kill -0 "$early_runner" 2>/dev/null || fail 'P06 runner did not return before the early child stopped'
	child_pid=$(cat "$ready.child")
	kill -TERM "$child_pid"
	assert_success 'P06 runner returns after the early child exits' wait_for_exit "$early_runner"
	wait "$early_runner" 2>/dev/null || early_rc=$?
	early_rc=${early_rc:-0}
	assert_equal "$early_rc" 0 'P06 exact natural zero survives the early-leader drain'
	assert_equal "$(cat "$TEST_ROOT/early.result")" 0 'P06 runner records natural success only after child drain'
}

case_cancel_during_gone_leader_drain_returns_sticky() {
	begin_case P07 'TERM during a gone-leader drain preserves sticky status without unknown group kill'
	setup_fixture
	ready="$TEST_ROOT/drain.ready" trace="$TEST_ROOT/drain.trace" gate="$TEST_ROOT/drain-first-read-release"
	start_gated_runner "$TEST_ROOT/drain.result" "$gate" "$BIN/leader-exits" "$ready" "$trace"
	drain_runner=$RUNNER_PID
	assert_success 'P07 child is writing before the gated first read' wait_for_path "$trace"
	: > "$gate"
	/bin/sleep 2
	kill -TERM "$drain_runner"
	/bin/sleep 2
	ASSERTIONS=$((ASSERTIONS + 1))
	kill -0 "$drain_runner" 2>/dev/null || fail 'P07 runner returned while gone-leader child still wrote'
	child_pid=$(cat "$ready.child")
	kill -TERM "$child_pid"
	assert_success 'P07 drain runner exits after the known child stops' wait_for_exit "$drain_runner"
	wait "$drain_runner" 2>/dev/null || drain_rc=$?
	drain_rc=${drain_rc:-0}
	assert_equal "$drain_rc" 143 'P07 drain-stage TERM returns sticky cancellation status'
	assert_equal "$(cat "$TEST_ROOT/drain.result")" 143 'P07 result is not natural zero after drain-stage TERM'
}

case_snapshot_gap_requires_second_empty_scan() {
	begin_case P08 'replacement child after a proc snapshot prevents a one-scan false empty'
	setup_fixture
	old_pid="$TEST_ROOT/snapshot-old.pid"
	trigger="$TEST_ROOT/snapshot-trigger"
	replacement_ready="$TEST_ROOT/snapshot-replacement-ready"
	replacement_release="$TEST_ROOT/snapshot-replacement-release"
	trace="$TEST_ROOT/snapshot-trace"
	start_snapshot_runner "$TEST_ROOT/snapshot.result" "$BIN/leader-replacement" \
		"$old_pid" "$trigger" "$replacement_ready" "$replacement_release" "$trace"
	snapshot_runner=$RUNNER_PID
	assert_success 'P08 old group member is registered before the group scan' wait_for_path "$old_pid"
	assert_success 'P08 real read-stat wrapper triggers replacement after snapshot enumeration' wait_for_path "$replacement_ready"
	/bin/sleep 2
	ASSERTIONS=$((ASSERTIONS + 1))
	kill -0 "$snapshot_runner" 2>/dev/null || fail 'P08 runner returned after one empty snapshot despite replacement writer'
	assert_success 'P08 replacement writer is active while runner retains resources' test -s "$trace"
	: > "$replacement_release"
	assert_success 'P08 runner returns only after the replacement exits and a second scan is empty' wait_for_exit "$snapshot_runner"
	wait "$snapshot_runner" 2>/dev/null || snapshot_rc=$?
	snapshot_rc=${snapshot_rc:-0}
	assert_equal "$snapshot_rc" 0 'P08 natural result survives the two-empty confirmation'
}

main() {
	trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
	case_source_is_inert
	case_missing_setsid_fails_without_child
	case_cancel_isolated_private_group
	case_prelaunch_cancel_waits_for_private_session
	case_fast_natural_and_leader_exit_child
	case_leader_gone_before_first_proc_read_drains_child
	case_cancel_during_gone_leader_drain_returns_sticky
	case_snapshot_gap_requires_second_empty_scan
	printf 'RESULT cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
	[ "$CASES" -eq 8 ] || fail "expected 8 cases, ran $CASES"
	[ "$ASSERTIONS" -eq 40 ] || fail "expected 40 assertions, ran $ASSERTIONS"
	[ "$FAILED" -eq 0 ]
}

main "$@"

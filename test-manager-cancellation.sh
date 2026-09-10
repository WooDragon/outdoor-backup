#!/bin/sh
#
# BDD integration tests for manager-owned cancellation. Reuses the real target
# manager fixture as a source-only library, then runs the shipped manager under
# an exec wrapper so delivered TERM/INT dispositions are genuine ash behavior.
#
set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
	REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
	exec docker run --rm --platform linux/amd64 --network bridge \
		--cap-add SYS_ADMIN --security-opt seccomp=unconfined --tmpfs /tmp:rw,exec --tmpfs /opt:rw,exec \
		-v "$REPO_ROOT:/src:ro" "$IMAGE@$IMAGE_DIGEST" \
		/bin/ash /src/test-manager-cancellation.sh --inside
fi

[ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || {
	printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
	exit 1
}

# Loading the existing fixture gives this narrow suite its real target guard,
# source-mount, status, lock, LED, and cleanup doubles without copying them.
TEST_CAPTURED_STDERR=1
TEST_ASYNC_STDERR=/tmp/outdoor-backup-manager-cancellation.stderr
TEST_TARGET_MANAGER_LIBRARY_ONLY=1
. /src/test-target-manager.sh

MC_CASES=0
MC_ASSERTIONS=0
MC_FAILED=0

mc_fail() { printf 'FAIL: %s\n' "$1" >&2; MC_FAILED=$((MC_FAILED + 1)); }
mc_case() { MC_CASES=$((MC_CASES + 1)); printf 'CASE %s: %s\n' "$1" "$2"; }
mc_equal() {
	actual=$1 expected=$2 message=$3
	MC_ASSERTIONS=$((MC_ASSERTIONS + 1))
	[ "$actual" = "$expected" ] || mc_fail "$message (expected=[$expected], actual=[$actual])"
}
mc_success() {
	message=$1; shift; MC_ASSERTIONS=$((MC_ASSERTIONS + 1)); "$@" || mc_fail "$message"
}
mc_absent() {
	path=$1 message=$2; MC_ASSERTIONS=$((MC_ASSERTIONS + 1))
	[ ! -e "$path" ] && [ ! -L "$path" ] || mc_fail "$message (path=[$path])"
}
mc_wait_path() {
	path=$1 attempts=0
	while [ ! -e "$path" ] && [ "$attempts" -lt 10 ]; do
		/bin/sleep 1
		attempts=$((attempts + 1))
	done
	[ -e "$path" ]
}
mc_wait_exit() {
	pid=$1 attempts=0
	while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 15 ]; do
		/bin/sleep 1
		attempts=$((attempts + 1))
	done
	! kill -0 "$pid" 2>/dev/null
}
write_normal_signal_shell() {
	cat > "$BIN/normal-signal-ash" <<'EOF'
#!/bin/ash
[ -z "${TEST_MANAGER_PID_FILE:-}" ] || printf '%s\n' "$$" > "$TEST_MANAGER_PID_FILE"
exec /bin/ash "$@"
EOF
	chmod 700 "$BIN/normal-signal-ash"
}
write_active_rsync() {
	cat > "$BIN/rsync" <<'EOF'
#!/bin/ash
printf 'rsync-active\n' >> "$TEST_EFFECTS"
: > "$TEST_CANCEL_READY"
(
	trap 'exit 0' TERM
	: > "$TEST_CANCEL_CHILD_READY"
	while :; do printf 'child-write\n' >> "$TEST_CANCEL_TRACE"; /bin/sleep 1; done
) &
child=$!
printf '%s\n' "$child" > "$TEST_CANCEL_CHILD_PID"
trap 'wait "$child" 2>/dev/null; exit 0' TERM
while :; do printf 'leader-write\n' >> "$TEST_CANCEL_TRACE"; /bin/sleep 1; done
EOF
	chmod 700 "$BIN/rsync"
}
start_manager() {
	TEST_RUN_MANAGER_EXEC=1 TEST_MANAGER_SHELL="$BIN/normal-signal-ash" \
		TEST_CANCEL_READY="$TEST_ROOT/cancel-ready" \
		TEST_CANCEL_CHILD_READY="$TEST_ROOT/cancel-child-ready" \
		TEST_CANCEL_CHILD_PID="$TEST_ROOT/cancel-child-pid" \
		TEST_CANCEL_TRACE="$TEST_ROOT/cancel-trace" \
		TEST_MOUNT_AUTO_CARD=1 TEST_RSYNC_STATS=1 \
		run_manager add sda1 /devices/mock &
	MANAGER_PID=$!
}

start_success_manager_with_cleanup_signal() {
	pid_file="$TEST_ROOT/cleanup-manager.pid"
	TEST_RUN_MANAGER_EXEC=1 TEST_MANAGER_SHELL="$BIN/normal-signal-ash" \
		TEST_MANAGER_PID_FILE="$pid_file" TEST_MOUNT_AUTO_CARD=1 TEST_RSYNC_STATS=1 \
		TEST_SYNC_SIGNAL_ON="${TEST_SYNC_SIGNAL_ON:-0}" \
		TEST_SYNC_SIGNAL_PID_FILE="${TEST_SYNC_SIGNAL_PID_FILE:-}" \
		run_manager add sda1 /devices/mock &
	MANAGER_PID=$!
	mc_wait_path "$pid_file" || return 1
}

case_active_term_stops_writers_before_cleanup() {
	mc_case C01 'active TERM waits for owned rsync writers before unmount and failed terminal status'
	reset_case || { mc_fail 'C01 fixture setup failed'; return; }
	write_normal_signal_shell
	write_active_rsync
	start_manager
	manager_pid=$MANAGER_PID
	mc_success 'C01 actual rsync leader becomes observable' mc_wait_path "$TEST_ROOT/cancel-ready"
	mc_success 'C01 actual rsync child becomes observable' mc_wait_path "$TEST_ROOT/cancel-child-ready"
	kill -TERM "$manager_pid"
	mc_success 'C01 manager exits only after cancellation lifecycle completes' mc_wait_exit "$manager_pid"
	wait "$manager_pid" 2>/dev/null || manager_rc=$?
	manager_rc=${manager_rc:-0}
	mc_equal "$manager_rc" 143 'C01 TERM preserves manager cancellation code'
	mc_success 'C01 terminal history is failed with cancelled error' \
		/bin/sh -c 'jq -e "$1" "$2" >/dev/null' sh \
		'.history[0].status == "error" and .history[0].error_message == "cancelled" and .current_backup == null' \
		"$RUNTIME/var/status.json"
	mc_success 'C01 successful completed history was not published' \
		/bin/sh -c 'jq -e "$1" "$2" >/dev/null' sh \
		'([.history[].status] | index("completed") == null)' "$RUNTIME/var/status.json"
	trace_before=$(wc -l < "$TEST_ROOT/cancel-trace")
	/bin/sleep 2
	trace_after=$(wc -l < "$TEST_ROOT/cancel-trace")
	mc_equal "$trace_after" "$trace_before" 'C01 no transfer writer remains after manager returned'
	mc_success 'C01 source cleanup precedes lock unlink in the real manager effects' \
		/bin/sh -c 'source_line=$(grep -n "source-umount" "$1" | cut -d: -f1); lock_line=$(grep -n "lock-unlink" "$1" | cut -d: -f1); [ -n "$source_line" ] && [ -n "$lock_line" ] && [ "$source_line" -lt "$lock_line" ]' sh "$EFFECTS"
	mc_absent "$RUNTIME/var/lock/backup.lock" 'C01 lock releases after safe cleanup'
	mc_success 'C01 transfer temporary outputs are removed after writers are gone' \
		/bin/sh -c 'runtime=$1; set -- "$runtime"/var/.backup-transfer.*; [ "$1" = "$runtime/var/.backup-transfer.*" ]' sh "$RUNTIME"
}

case_waiting_lock_term_touches_no_owner_state() {
	mc_case C02 'TERM while waiting for another owner lock leaves its resource state untouched'
	reset_case || { mc_fail 'C02 fixture setup failed'; return; }
	write_normal_signal_shell
	cat > "$BIN/backup-manager.sh" <<'EOF'
#!/bin/ash
ln -s "/proc/$$" "$TEST_LOCK_LINK"
: > "$TEST_HOLDER_READY"
while [ ! -e "$TEST_HOLDER_RELEASE" ]; do /bin/sleep 1; done
EOF
	chmod 700 "$BIN/backup-manager.sh"
	TEST_LOCK_LINK="$RUNTIME/var/lock/backup.lock" TEST_HOLDER_READY="$TEST_ROOT/holder-ready" \
		TEST_HOLDER_RELEASE="$TEST_ROOT/holder-release" "$BIN/backup-manager.sh" &
	holder_pid=$!
	mc_success 'C02 competing owner published its lock' mc_wait_path "$TEST_ROOT/holder-ready"
	TEST_RUN_MANAGER_EXEC=1 TEST_MANAGER_SHELL="$BIN/normal-signal-ash" TEST_SLEEP_PASSTHROUGH=1 \
		LOCK_TIMEOUT=10 LOCK_INTERVAL=1 run_manager add sda1 /devices/mock &
	manager_pid=$!
	/bin/sleep 1
	kill -TERM "$manager_pid"
	mc_success 'C02 waiting manager exits on sticky TERM' mc_wait_exit "$manager_pid"
	wait "$manager_pid" 2>/dev/null || manager_rc=$?
	manager_rc=${manager_rc:-0}
	mc_equal "$manager_rc" 143 'C02 waiting cancellation preserves TERM status'
	mc_equal "$(readlink "$RUNTIME/var/lock/backup.lock")" "/proc/$holder_pid" 'C02 manager did not alter A owner lock'
	mc_absent "$SOURCE_MOUNT_STATE" 'C02 waiting manager never mounted source media'
	mc_absent "$RUNTIME/var/status.json" 'C02 waiting manager never published status'
	mc_absent "$TEST_ROOT/green/trigger" 'C02 waiting manager never starts success LED'
	# A background shell often inherits ignored INT. The exec launcher resets it,
	# so this is a real INT delivery test rather than a host-job-control fake.
	# Keep this manager foreground so it inherits normal INT. A separate bounded
	# fixture child waits for its recorded PID before delivering the signal.
	int_pid_file="$TEST_ROOT/normal-int-manager.pid"
	(
		mc_wait_path "$int_pid_file" || exit 1
		/bin/sleep 1
		kill -INT "$(cat "$int_pid_file")"
	) &
	int_trigger_pid=$!
	if TEST_MANAGER_SHELL="$BIN/normal-signal-ash" TEST_MANAGER_PID_FILE="$int_pid_file" \
		TEST_SLEEP_PASSTHROUGH=1 LOCK_TIMEOUT=10 LOCK_INTERVAL=1 run_manager add sda1 /devices/mock; then
		int_manager_rc=0
	else
		int_manager_rc=$?
	fi
	wait "$int_trigger_pid" 2>/dev/null || mc_fail 'C02 INT trigger could not reach the foreground manager'
	mc_equal "$int_manager_rc" 130 'C02 first INT maps to its sticky cancellation status'
	mc_equal "$(readlink "$RUNTIME/var/lock/backup.lock")" "/proc/$holder_pid" 'C02 INT waiter also leaves A owner lock intact'
	: > "$TEST_ROOT/holder-release"
	wait "$holder_pid" 2>/dev/null || mc_fail 'C02 fixture holder did not exit cleanly'
}

case_cleanup_terminal_boundary() {
	mc_case C03 'TERM from cleanup sync becomes cancelled before the terminal boundary'
	reset_case || { mc_fail 'C03 fixture setup failed'; return; }
	write_normal_signal_shell
	TEST_SYNC_SIGNAL_ON=2
	TEST_SYNC_SIGNAL_PID_FILE="$TEST_ROOT/cleanup-manager.pid"
	start_success_manager_with_cleanup_signal || { mc_fail 'C03 manager did not publish PID'; return; }
	manager_pid=$MANAGER_PID
	mc_success 'C03 manager exits after sync-triggered TERM' mc_wait_exit "$manager_pid"
	wait "$manager_pid" 2>/dev/null || manager_rc=$?
	manager_rc=${manager_rc:-0}
	mc_equal "$manager_rc" 143 'C03 sync-boundary TERM wins over natural success'
	mc_success 'C03 final status is cancelled error without completed history' \
		/bin/sh -c 'jq -e "$1" "$2" >/dev/null' sh \
		'.history[0].status == "error" and .history[0].error_message == "cancelled" and ([.history[].status] | index("completed") == null)' \
		"$RUNTIME/var/status.json"
	unset TEST_SYNC_SIGNAL_ON TEST_SYNC_SIGNAL_PID_FILE TEST_SYNC_SIGNAL_PID
}

status_signal_fields() {
	while IFS= read -r status_line; do
		case "$status_line" in
			PPid:*|SigIgn:*|SigCgt:*) printf '%s;' "$status_line" ;;
		esac
	done < "/proc/$1/status"
	printf '\n'
}

write_completed_status_term_mv() {
	cat > "$BIN/status-mv" <<'EOF'
#!/bin/ash
status_signal_fields() {
    while IFS= read -r status_line; do
        case "$status_line" in
            PPid:*|SigIgn:*|SigCgt:*) printf '%s;' "$status_line" ;;
        esac
    done < "/proc/$1/status"
    printf '\n'
}
count=0
[ -r "$TEST_STATUS_MV_COUNT" ] && count=$(cat "$TEST_STATUS_MV_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$TEST_STATUS_MV_COUNT"
source=$1
target=''
for value in "$@"; do target=$value; done
phase=$(jq -r 'if .current_backup == null then .history[0].status else "running" end' "$source")
manager_pid=$(cat "$TEST_LATE_TERM_PID_FILE")
printf 'event=before-mv count=%s phase=%s sender=%s manager=%s target=%s manager-status=%s\n' \
    "$count" "$phase" "$$" "$manager_pid" "$target" "$(status_signal_fields "$manager_pid")" >> "$TEST_LATE_TERM_TRACE"
if [ "$phase" = completed ]; then
    kill -TERM "$manager_pid"
    signal_rc=$?
    printf 'event=sent-term count=%s phase=%s sender=%s manager=%s signal-rc=%s manager-status=%s\n' \
        "$count" "$phase" "$$" "$manager_pid" "$signal_rc" \
        "$(status_signal_fields "$manager_pid")" >> "$TEST_LATE_TERM_TRACE"
fi
/bin/mv "$@"
mv_rc=$?
printf 'event=mv-exit count=%s phase=%s sender=%s mv-rc=%s stub-exit=%s\n' \
    "$count" "$phase" "$$" "$mv_rc" "$mv_rc" >> "$TEST_LATE_TERM_TRACE"
exit "$mv_rc"
EOF
	chmod 700 "$BIN/status-mv"
}

start_manager_with_pid_file() {
	pid_file=$1
	shift
	(
		for manager_env in "$@"; do
			export "$manager_env"
		done
		TEST_RUN_MANAGER_EXEC=1 TEST_MANAGER_SHELL="$BIN/normal-signal-ash" \
			TEST_MANAGER_PID_FILE="$pid_file" run_manager add sda1 /devices/mock
	) &
	MANAGER_PID=$!
	mc_wait_path "$pid_file"
}

make_phase_gate_mutation() {
	phase_gate=$1
	MUTATED_MANAGER="$SCRIPTS/${phase_gate}-manager.sh"
	cp "$SCRIPTS/backup-manager.sh" "$MUTATED_MANAGER"
	case "$phase_gate" in
		source-identity)
			sed -i '/if ! read_source_identity; then/,/if ! setup_sdcard_config; then/ { /check_cancel_request/d; }' "$MUTATED_MANAGER"
			;;
		card-config)
			sed -i '/if ! setup_sdcard_config; then/,/if ! bind_card_identity; then/ { /check_cancel_request/d; }' "$MUTATED_MANAGER"
			;;
		preflight-df)
			sed -i '/check_minimum_free_space || return 1/,/BACKUP_STARTED_AT=$(date +%s)/ { /check_cancel_request/d; }' "$MUTATED_MANAGER"
			;;
		*) return 1 ;;
	esac
	chmod 700 "$MUTATED_MANAGER"
}

phase_gate_removed() {
	case "$1" in
		source-identity)
			sed -n '/if ! read_source_identity; then/,/if ! setup_sdcard_config; then/p' "$MUTATED_MANAGER" | grep -F -q check_cancel_request && return 1
			;;
		card-config)
			sed -n '/if ! setup_sdcard_config; then/,/if ! bind_card_identity; then/p' "$MUTATED_MANAGER" | grep -F -q check_cancel_request && return 1
			;;
		preflight-df)
			sed -n '/check_minimum_free_space || return 1/,/BACKUP_STARTED_AT=$(date +%s)/p' "$MUTATED_MANAGER" | grep -F -q check_cancel_request && return 1
			;;
		*) return 1 ;;
	esac
	return 0
}

case_terminal_completed_term_is_ignored() {
	mc_case C04 'TERM during completed status rename is ignored after terminal boundary'
	reset_case || { mc_fail 'C04 fixture setup failed'; return; }
	write_normal_signal_shell
	write_completed_status_term_mv
	pid_file="$TEST_ROOT/c04-manager.pid"
	trace="$TEST_ROOT/c04-trace"
	: > "$trace"
	TEST_LATE_TERM_PID_FILE="$pid_file" TEST_LATE_TERM_TRACE="$trace"
	export TEST_LATE_TERM_PID_FILE TEST_LATE_TERM_TRACE
	start_manager_with_pid_file "$pid_file" TEST_MOUNT_AUTO_CARD=1 TEST_RSYNC_STATS=1 || {
		mc_fail 'C04 manager did not publish PID'; return;
	}
	manager_pid=$MANAGER_PID
	mc_success 'C04 manager exits after terminal rename' mc_wait_exit "$manager_pid"
	manager_rc=0
	wait "$manager_pid" 2>/dev/null || manager_rc=$?
	mc_success 'C04 completed rename trigger fired' grep -F 'event=sent-term count=2 phase=completed' "$trace"
	mc_success 'C04 TERM was ignored by the recorded manager' \
		/bin/sh -c 'grep -F "manager=$1" "$2" | grep -E "SigIgn:.*000000000000400" >/dev/null' sh "$manager_pid" "$trace"
	mc_success 'C04 status-mv delivered TERM successfully' grep -F 'signal-rc=0' "$trace"
	mc_success 'C04 completed status-mv exits naturally' grep -F 'event=mv-exit count=2 phase=completed' "$trace"
	mc_equal "$manager_rc" 0 'C04 late TERM cannot convert completed manager to 143'
	mc_success 'C04 history has exactly one completed terminal event' \
		/bin/sh -c 'jq -e "(.history | length == 1) and .history[0].status == \"completed\" and .history[0].error_message == null and .current_backup == null" "$1" >/dev/null' sh "$RUNTIME/var/status.json"
	unset TEST_LATE_TERM_PID_FILE TEST_LATE_TERM_TRACE
}

case_source_identity_term_stops_before_card_write() {
	mc_case C05 'TERM from source identity lookup stops before card write or target binding'
	reset_case || { mc_fail 'C05 fixture setup failed'; return; }
	write_normal_signal_shell
	pid_file="$TEST_ROOT/c05-manager.pid"
	trace="$TEST_ROOT/c05-trace"
	: > "$trace"
	TEST_SOURCE_BLOCK_SIGNAL_PID_FILE="$pid_file" TEST_SOURCE_BLOCK_SIGNAL_TRACE="$trace"
	export TEST_SOURCE_BLOCK_SIGNAL_PID_FILE TEST_SOURCE_BLOCK_SIGNAL_TRACE
	start_manager_with_pid_file "$pid_file" || { mc_fail 'C05 manager did not publish PID'; return; }
	manager_pid=$MANAGER_PID
	mc_success 'C05 manager exits after source identity cancellation' mc_wait_exit "$manager_pid"
	manager_rc=0
	wait "$manager_pid" 2>/dev/null || manager_rc=$?
	mc_success 'C05 source block trigger fired on /dev/sda1' grep -F 'phase=source-block args=[info /dev/sda1]' "$trace"
	mc_success 'C05 source block TERM reached recorded manager' grep -F 'signal-rc=0' "$trace"
	mc_equal "$manager_rc" 143 'C05 source identity TERM preserves cancellation exit'
	mc_absent "$SOURCE_MOUNT/FieldBackup.conf" 'C05 cancelled source lookup does not publish card configuration'
	mc_success 'C05 never opens source card read-write' \
		/bin/sh -c '! grep -F -q "mount mode=rw" "$1"' sh "$EFFECTS"
	mc_absent "$TARGET_MOUNT/backups/.card-identities" 'C05 does not publish a card identity record'
	mc_absent /opt/outdoor-backup/conf/aliases.json 'C05 does not publish an alias'
	mc_success 'C05 never starts rsync' /bin/sh -c '! grep -F -q rsync "$1"' sh "$EFFECTS"
	mc_success 'C05 owner cleanup may unmount its completed read-only mount' \
		grep -F "umount target=[$SOURCE_MOUNT]" "$EFFECTS"
	reset_case || { mc_fail 'C05 Red fixture setup failed'; return; }
	write_normal_signal_shell
	make_phase_gate_mutation source-identity || { mc_fail 'C05 Red mutation failed'; return; }
	mc_success 'C05 Red mutation removes only the source identity gate' phase_gate_removed source-identity
	red_pid_file="$TEST_ROOT/c05-red-manager.pid"
	red_trace="$TEST_ROOT/c05-red-trace"
	: > "$red_trace"
	MANAGER_SCRIPT="$MUTATED_MANAGER" TEST_SOURCE_BLOCK_SIGNAL_PID_FILE="$red_pid_file" \
		TEST_SOURCE_BLOCK_SIGNAL_TRACE="$red_trace"
	export MANAGER_SCRIPT TEST_SOURCE_BLOCK_SIGNAL_PID_FILE TEST_SOURCE_BLOCK_SIGNAL_TRACE
	start_manager_with_pid_file "$red_pid_file" || { mc_fail 'C05 Red manager did not publish PID'; return; }
	wait "$MANAGER_PID" 2>/dev/null || :
	mc_success 'C05 Red mutation reaches card configuration publication' \
		test -f "$SOURCE_MOUNT/FieldBackup.conf"
	unset MANAGER_SCRIPT TEST_SOURCE_BLOCK_SIGNAL_PID_FILE TEST_SOURCE_BLOCK_SIGNAL_TRACE
}

case_card_config_sync_term_stops_before_binding() {
	mc_case C06 'TERM after card config publication stops before identity binding and transfer'
	reset_case || { mc_fail 'C06 fixture setup failed'; return; }
	write_normal_signal_shell
	pid_file="$TEST_ROOT/c06-manager.pid"
	trace="$TEST_ROOT/c06-trace"
	: > "$trace"
	TEST_CONFIG_SYNC_SIGNAL_ON=1 TEST_CONFIG_SYNC_SIGNAL_PID_FILE="$pid_file" \
		TEST_CONFIG_SYNC_SIGNAL_TRACE="$trace"
	export TEST_CONFIG_SYNC_SIGNAL_ON TEST_CONFIG_SYNC_SIGNAL_PID_FILE TEST_CONFIG_SYNC_SIGNAL_TRACE
	start_manager_with_pid_file "$pid_file" || { mc_fail 'C06 manager did not publish PID'; return; }
	manager_pid=$MANAGER_PID
	mc_success 'C06 manager exits after config-sync cancellation' mc_wait_exit "$manager_pid"
	manager_rc=0
	wait "$manager_pid" 2>/dev/null || manager_rc=$?
	mc_success 'C06 config sync trigger fired' grep -F 'phase=config-sync count=1' "$trace"
	mc_success 'C06 config sync TERM reached recorded manager' grep -F 'signal-rc=0' "$trace"
	mc_equal "$manager_rc" 143 'C06 config sync TERM preserves cancellation exit'
	mc_success 'C06 already-published config remains observable' test -f "$SOURCE_MOUNT/FieldBackup.conf"
	mc_success 'C06 source returns to read-only before the cancellation boundary' \
		grep -F "mount mode=ro target=[$SOURCE_MOUNT]" "$EFFECTS"
	mc_absent "$TARGET_MOUNT/backups/.card-identities" 'C06 does not bind an identity after cancellation'
	mc_absent /opt/outdoor-backup/conf/aliases.json 'C06 does not publish an alias after cancellation'
	mc_success 'C06 backup root has no card data entries' \
		/bin/sh -c '[ -d "$1" ] && ! find "$1" -mindepth 1 -print | grep -q .' sh "$TARGET_MOUNT/backups"
	mc_success 'C06 never starts rsync' /bin/sh -c '! grep -F -q rsync "$1"' sh "$EFFECTS"
	reset_case || { mc_fail 'C06 Red fixture setup failed'; return; }
	write_normal_signal_shell
	make_phase_gate_mutation card-config || { mc_fail 'C06 Red mutation failed'; return; }
	mc_success 'C06 Red mutation removes only the card config gate' phase_gate_removed card-config
	red_pid_file="$TEST_ROOT/c06-red-manager.pid"
	red_trace="$TEST_ROOT/c06-red-trace"
	: > "$red_trace"
	MANAGER_SCRIPT="$MUTATED_MANAGER" TEST_CONFIG_SYNC_SIGNAL_ON=1 \
		TEST_CONFIG_SYNC_SIGNAL_PID_FILE="$red_pid_file" TEST_CONFIG_SYNC_SIGNAL_TRACE="$red_trace"
	export MANAGER_SCRIPT TEST_CONFIG_SYNC_SIGNAL_ON TEST_CONFIG_SYNC_SIGNAL_PID_FILE TEST_CONFIG_SYNC_SIGNAL_TRACE
	start_manager_with_pid_file "$red_pid_file" || { mc_fail 'C06 Red manager did not publish PID'; return; }
	wait "$MANAGER_PID" 2>/dev/null || :
	mc_success 'C06 Red mutation reaches identity publication' \
		/bin/sh -c 'find "$1" -path "*/.card-identities/*.json" -type f | grep -q .' sh "$TARGET_MOUNT/backups"
	unset MANAGER_SCRIPT TEST_CONFIG_SYNC_SIGNAL_ON TEST_CONFIG_SYNC_SIGNAL_PID_FILE TEST_CONFIG_SYNC_SIGNAL_TRACE
}

case_preflight_df_term_stops_before_running_status() {
	mc_case C07 'TERM from trustworthy preflight df stops before running status and rsync'
	reset_case || { mc_fail 'C07 fixture setup failed'; return; }
	write_normal_signal_shell
	printf 'SD_UUID="%s"\nBACKUP_MODE="PRIMARY"\n' "$CARD_UUID" > "$SOURCE_MOUNT/FieldBackup.conf"
	pid_file="$TEST_ROOT/c07-manager.pid"
	trace="$TEST_ROOT/c07-trace"
	: > "$trace"
	TEST_PREFLIGHT_DF_SIGNAL_PID_FILE="$pid_file" TEST_PREFLIGHT_DF_SIGNAL_TRACE="$trace"
	export TEST_PREFLIGHT_DF_SIGNAL_PID_FILE TEST_PREFLIGHT_DF_SIGNAL_TRACE
	start_manager_with_pid_file "$pid_file" || { mc_fail 'C07 manager did not publish PID'; return; }
	manager_pid=$MANAGER_PID
	mc_success 'C07 manager exits after preflight cancellation' mc_wait_exit "$manager_pid"
	manager_rc=0
	wait "$manager_pid" 2>/dev/null || manager_rc=$?
	mc_success 'C07 preflight df trigger fired only for -m query' grep -F 'phase=preflight-df args=[-m ' "$trace"
	mc_success 'C07 preflight df TERM reached recorded manager' grep -F 'signal-rc=0' "$trace"
	mc_equal "$manager_rc" 143 'C07 preflight df TERM preserves cancellation exit'
	mc_absent "$RUNTIME/var/status.json" 'C07 does not publish a running or terminal status'
	mc_success 'C07 never starts rsync' /bin/sh -c '! grep -F -q rsync "$1"' sh "$EFFECTS"
	reset_case || { mc_fail 'C07 Red fixture setup failed'; return; }
	write_normal_signal_shell
	printf 'SD_UUID="%s"\nBACKUP_MODE="PRIMARY"\n' "$CARD_UUID" > "$SOURCE_MOUNT/FieldBackup.conf"
	make_phase_gate_mutation preflight-df || { mc_fail 'C07 Red mutation failed'; return; }
	mc_success 'C07 Red mutation removes only the preflight gate' phase_gate_removed preflight-df
	red_pid_file="$TEST_ROOT/c07-red-manager.pid"
	red_trace="$TEST_ROOT/c07-red-trace"
	: > "$red_trace"
	MANAGER_SCRIPT="$MUTATED_MANAGER" TEST_PREFLIGHT_DF_SIGNAL_PID_FILE="$red_pid_file" \
		TEST_PREFLIGHT_DF_SIGNAL_TRACE="$red_trace"
	export MANAGER_SCRIPT TEST_PREFLIGHT_DF_SIGNAL_PID_FILE TEST_PREFLIGHT_DF_SIGNAL_TRACE
	start_manager_with_pid_file "$red_pid_file" || { mc_fail 'C07 Red manager did not publish PID'; return; }
	wait "$MANAGER_PID" 2>/dev/null || :
	mc_success 'C07 Red mutation publishes status after cancelled preflight' \
		test -f "$RUNTIME/var/status.json"
	unset MANAGER_SCRIPT TEST_PREFLIGHT_DF_SIGNAL_PID_FILE TEST_PREFLIGHT_DF_SIGNAL_TRACE
}

main() {
	trap 'settle_led_fixture; unmount_target; rm -rf "$SUITE_ROOT" /opt/outdoor-backup/conf "$TEST_ASYNC_STDERR"' EXIT INT TERM
	case_active_term_stops_writers_before_cleanup
	case_waiting_lock_term_touches_no_owner_state
	case_cleanup_terminal_boundary
	case_terminal_completed_term_is_ignored
	case_source_identity_term_stops_before_card_write
	case_card_config_sync_term_stops_before_binding
	case_preflight_df_term_stops_before_running_status
	printf 'RESULT cases=%s assertions=%s failed=%s\n' "$MC_CASES" "$MC_ASSERTIONS" "$MC_FAILED"
	[ "$MC_CASES" -eq 7 ] || mc_fail "expected 7 cases, ran $MC_CASES"
	[ "$MC_ASSERTIONS" -eq 61 ] || mc_fail "expected 61 assertions, ran $MC_ASSERTIONS"
	[ "$MC_FAILED" -eq 0 ]
}

main "$@"

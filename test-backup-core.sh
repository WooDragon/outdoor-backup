#!/bin/sh
#
# BDD integration tests for the source-only rsync transfer helper. The host
# starts one disposable, pinned OpenWrt container; source code is mounted
# read-only and every fixture lives in container-local /tmp.
#

set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
	REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
	exec docker run --rm --platform linux/amd64 --network bridge \
		--cap-add SYS_ADMIN --security-opt seccomp=unconfined --tmpfs /tmp:rw,exec \
		-v "$REPO_ROOT:/src:ro" \
		"$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-backup-core.sh --inside
fi

[ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || {
	printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
	exit 1
}

mkdir -p /var/lock
opkg update >/dev/null
opkg install rsync >/dev/null

REPO_ROOT=/src
TRANSFER_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/backup-transfer.sh"
PROCESS_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/transfer-process.sh"
TEST_ROOT="/tmp/outdoor-backup-transfer.$$"
BASE_DIR="$TEST_ROOT/runtime/opt/outdoor-backup"
SOURCE_DIR="$TEST_ROOT/source"
TARGET_ROOT="$TEST_ROOT/target"
LOG_DIR="$TEST_ROOT/logs"
BIN_DIR="$TEST_ROOT/bin"
NO_RSYNC_BIN="$TEST_ROOT/no-rsync-bin"
FULL_TARGET="$TEST_ROOT/full-target"
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

assert_equal() {
	actual=$1
	expected=$2
	message=$3
	ASSERTIONS=$((ASSERTIONS + 1))
	[ "$actual" = "$expected" ] || fail "$message (expected=[$expected], actual=[$actual])"
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

assert_file_hash_equal() {
	left=$1
	right=$2
	message=$3
	ASSERTIONS=$((ASSERTIONS + 1))
	left_hash=$(sha256sum "$left" | awk '{print $1}')
	right_hash=$(sha256sum "$right" | awk '{print $1}')
	[ "$left_hash" = "$right_hash" ] || fail "$message (left=$left_hash, right=$right_hash)"
}

assert_file_absent() {
	path=$1
	message=$2
	ASSERTIONS=$((ASSERTIONS + 1))
	[ ! -e "$path" ] || fail "$message (path=[$path])"
}

assert_tree_hashes_equal() {
	source_root=$1
	target_root=$2
	message=$3
	ASSERTIONS=$((ASSERTIONS + 1))
	source_hashes=$(cd "$source_root" && find . -type f -exec sha256sum {} \; | LC_ALL=C sort)
	target_hashes=$(cd "$target_root" && find . -type f -exec sha256sum {} \; | LC_ALL=C sort)
	[ "$source_hashes" = "$target_hashes" ] || fail "$message"
}

assert_contains() {
	needle=$1
	file=$2
	message=$3
	ASSERTIONS=$((ASSERTIONS + 1))
	grep -F -q -- "$needle" "$file" || fail "$message (missing=[$needle])"
}

assert_not_contains() {
	needle=$1
	file=$2
	message=$3
	ASSERTIONS=$((ASSERTIONS + 1))
	if grep -F -q -- "$needle" "$file"; then
		fail "$message (unexpected=[$needle])"
	fi
}

assert_no_runtime_temp_files() {
	set -- "$BASE_DIR/var/.backup-transfer."*
	ASSERTIONS=$((ASSERTIONS + 1))
	[ "$1" = "$BASE_DIR/var/.backup-transfer.*" ] || fail 'transfer runtime output files were not cleaned'
}

wait_for_path() {
	path=$1
	attempts=0
	while [ ! -e "$path" ] && [ "$attempts" -lt 10 ]; do
		/bin/sleep 1
		attempts=$((attempts + 1))
	done
	[ -e "$path" ]
}

cleanup_test_data() {
	if mountpoint -q "$FULL_TARGET" 2>/dev/null; then
		umount "$FULL_TARGET" || :
	fi
	rm -rf "$TEST_ROOT"
}

setup_fixture() {
	cleanup_test_data
	mkdir -p "$BASE_DIR/var" "$SOURCE_DIR" "$TARGET_ROOT" "$LOG_DIR" "$BIN_DIR" "$NO_RSYNC_BIN"
	CONFIG_FILE=FieldBackup.conf
	# shellcheck disable=SC1090
	. "$PROCESS_SCRIPT"
	# shellcheck disable=SC1090
	. "$TRANSFER_SCRIPT"
}

run_transfer() {
	backup_transfer "$1" "$2" "$3"
}

snapshot_source() {
	find "$SOURCE_DIR" -type f -exec sha256sum {} \; | LC_ALL=C sort
}

create_rsync_double() {
	cat > "$BIN_DIR/rsync" << 'DOUBLE'
#!/bin/sh
printf '%s\n' "$@" > "$RSYNC_ARGS_FILE"
if [ "${RSYNC_DOUBLE_DIAGNOSTIC:-}" != "" ]; then
	printf '%s\n' "$RSYNC_DOUBLE_DIAGNOSTIC" >&2
fi
if [ "${RSYNC_DOUBLE_STATS:-}" != "" ]; then
	printf '%s\n' 'Number of regular files transferred: 7'
	printf '%s\n' 'Total transferred file size: 1,234 bytes'
fi
exit "${RSYNC_DOUBLE_EXIT:-0}"
DOUBLE
	chmod 755 "$BIN_DIR/rsync"
}

create_rsync_mutation() {
	mutation_flag=$1
	cat > "$BIN_DIR/rsync" << DOUBLE
#!/bin/sh
exec /usr/bin/rsync "$mutation_flag" "\$@"
DOUBLE
	chmod 755 "$BIN_DIR/rsync"
}

create_early_exit_rsync() {
	cat > "$BIN_DIR/rsync" <<'EOF'
#!/bin/ash
: > "$TEST_EARLY_READY"
(
	trap 'exit 0' TERM
	while :; do printf 'child-write\n' >> "$TEST_EARLY_TRACE"; /bin/sleep 1; done
) &
printf '%s\n' "$!" > "$TEST_EARLY_CHILD_PID"
exit 0
EOF
	chmod 755 "$BIN_DIR/rsync"
}

create_term_ignoring_rsync() {
	cat > "$BIN_DIR/rsync" <<'EOF'
#!/bin/ash
: > "$TEST_CANCEL_READY"
trap ':' TERM
while [ ! -e "$TEST_CANCEL_RELEASE" ]; do
	printf 'writer-still-active\n' >> "$TEST_CANCEL_TRACE"
	/bin/sleep 1
done
exit 0
EOF
	chmod 755 "$BIN_DIR/rsync"
}

create_logger_double() {
	cat > "$BIN_DIR/logger" <<'EOF'
#!/bin/ash
printf '%s\n' "$*" >> "$TEST_LOGGER_OUTPUT"
if [ "${TEST_LOGGER_FAIL:-0}" = 1 ]; then
	exit 1
fi
exit 0
EOF
	chmod 755 "$BIN_DIR/logger"
}

create_cancel_transfer_runner() {
	cat > "$BIN_DIR/cancel-transfer-runner" <<'EOF'
#!/bin/ash
. "$TEST_PROCESS_SCRIPT"
. "$TEST_TRANSFER_SCRIPT"
BACKUP_CANCEL_CODE=0
trap '[ "$BACKUP_CANCEL_CODE" -ne 0 ] || BACKUP_CANCEL_CODE=143' TERM
backup_transfer "$@"
rc=$?
printf '%s\n' "$rc" > "$TEST_CANCEL_RESULT"
exit "$rc"
EOF
	chmod 755 "$BIN_DIR/cancel-transfer-runner"
}

create_mktemp_double() {
	cat > "$BIN_DIR/mktemp" << 'DOUBLE'
#!/bin/sh
case "${MK_TEMP_DOUBLE_MODE:-}" in
	fail-second)
		case "$1" in
		"$MK_TEMP_DOUBLE_BASE"/var/.backup-transfer.*.XXXXXX) ;;
		*) exit 97 ;;
		esac
		calls=0
		[ -f "$MK_TEMP_DOUBLE_STATE" ] && IFS= read -r calls < "$MK_TEMP_DOUBLE_STATE"
		calls=$((calls + 1))
		printf '%s\n' "$calls" > "$MK_TEMP_DOUBLE_STATE"
		[ "$calls" -ne 2 ] || exit 1
		exec /bin/mktemp "$@"
		;;
	fail-stdout-redirect)
		[ "$1" = "$MK_TEMP_DOUBLE_BASE/var/.backup-transfer.stdout.XXXXXX" ] || exit 97
		printf '%s\n' "$MK_TEMP_DOUBLE_BASE/missing/stdout"
		;;
	fail-stderr-redirect)
		case "$1" in
		"$MK_TEMP_DOUBLE_BASE/var/.backup-transfer.stdout.XXXXXX")
			exec /bin/mktemp "$@"
			;;
		"$MK_TEMP_DOUBLE_BASE/var/.backup-transfer.stderr.XXXXXX")
			printf '%s\n' "$MK_TEMP_DOUBLE_BASE/missing/stderr"
			;;
		*) exit 97 ;;
		esac
		;;
	*) exit 97 ;;
	esac
DOUBLE
	chmod 755 "$BIN_DIR/mktemp"
}

prepare_no_rsync_path() {
	for command_name in mktemp rm grep tr; do
		ln -sf /bin/busybox "$NO_RSYNC_BIN/$command_name"
	done
}

case_source_is_inert() {
	begin_case T01 'sourcing only defines the transfer API without runtime output'
	setup_fixture
	ASSERTIONS=$((ASSERTIONS + 1))
	command -v backup_transfer >/dev/null 2>&1 || fail 'T01 backup_transfer is defined after source'
	ASSERTIONS=$((ASSERTIONS + 1))
	command -v backup_transfer_cleanup >/dev/null 2>&1 || fail 'T01 cleanup API is defined after source'
	assert_no_runtime_temp_files
}

case_real_transfer_and_fd_target() {
	begin_case T02 'real rsync preserves spaced source, FD target, and log arguments'
	setup_fixture
	SOURCE_DIR="$TEST_ROOT/source with space"
	fd_target_dir="$TARGET_ROOT/fd target with space"
	transfer_log="$LOG_DIR/logs with space/first transfer.log"
	mkdir -p "$SOURCE_DIR" "$fd_target_dir" "$(dirname "$transfer_log")"
	printf '%s\n' 'first version' > "$SOURCE_DIR/alpha.txt"
	printf '%s\n' 'unchanged' > "$SOURCE_DIR/unchanged.txt"
	before=$(snapshot_source)
	exec 9<"$TARGET_ROOT"
	fd_target="/proc/$$/fd/9/fd target with space/"
	if run_transfer "$SOURCE_DIR/" "$fd_target" "$transfer_log"; then
		assert_equal "$BACKUP_TRANSFER_EXIT" 0 'T02 reports real rsync success'
	else
		fail 'T02 real rsync unexpectedly failed'
	fi
	assert_file_hash_equal "$SOURCE_DIR/alpha.txt" "$fd_target_dir/alpha.txt" 'T02 first file hash matches'
	assert_file_hash_equal "$SOURCE_DIR/unchanged.txt" "$fd_target_dir/unchanged.txt" 'T02 unchanged file hash matches'
	assert_equal "$(snapshot_source)" "$before" 'T02 source snapshot remains unchanged'
	assert_no_runtime_temp_files
	exec 9<&-
}

case_incremental_update_and_preservation() {
	begin_case T03 'real rsync transfers only new, size-changed, and newer same-size files'
	setup_fixture
	printf '%s\n' 'old content' > "$SOURCE_DIR/change.txt"
	printf '%s\n' 'same-size-old' > "$SOURCE_DIR/same-size.txt"
	printf '%s\n' 'unchanged content' > "$SOURCE_DIR/unchanged.txt"
	printf '%s\n' 'remove source only' > "$SOURCE_DIR/remove-me.txt"
	touch -t 202609090101 "$SOURCE_DIR/same-size.txt"
	assert_success 'T03 initial copy succeeds' run_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/initial.log"
	printf '%s\n' 'new content with a different size' > "$SOURCE_DIR/change.txt"
	printf '%s\n' 'same-size-new' > "$SOURCE_DIR/same-size.txt"
	touch -t 202609090102 "$SOURCE_DIR/same-size.txt"
	printf '%s\n' 'new file' > "$SOURCE_DIR/new.txt"
	printf '%s\n' 'preserve me' > "$TARGET_ROOT/target-only.txt"
	rm "$SOURCE_DIR/remove-me.txt"
	before=$(snapshot_source)
	expected_bytes=$(($(wc -c < "$SOURCE_DIR/change.txt") + $(wc -c < "$SOURCE_DIR/same-size.txt") + $(wc -c < "$SOURCE_DIR/new.txt")))
	if run_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/incremental.log"; then
		assert_equal "$BACKUP_TRANSFER_FILES" 3 'T03 stats count only expected incremental files'
		assert_equal "$BACKUP_TRANSFER_BYTES" "$expected_bytes" 'T03 stats bytes include only expected incremental files'
	else
		fail 'T03 incremental real rsync unexpectedly failed'
	fi
	assert_file_hash_equal "$SOURCE_DIR/change.txt" "$TARGET_ROOT/change.txt" 'T03 size-changed file is updated'
	assert_file_hash_equal "$SOURCE_DIR/same-size.txt" "$TARGET_ROOT/same-size.txt" 'T03 newer same-size file is updated'
	assert_file_hash_equal "$SOURCE_DIR/new.txt" "$TARGET_ROOT/new.txt" 'T03 new file is copied'
	assert_file_hash_equal "$SOURCE_DIR/unchanged.txt" "$TARGET_ROOT/unchanged.txt" 'T03 unchanged source file remains identical'
	assert_equal "$(cat "$TARGET_ROOT/remove-me.txt")" 'remove source only' 'T03 source deletion does not delete target file'
	assert_equal "$(cat "$TARGET_ROOT/target-only.txt")" 'preserve me' 'T03 target-only file is retained'
	assert_equal "$(snapshot_source)" "$before" 'T03 source snapshot remains unchanged'
	assert_no_runtime_temp_files
}

case_incremental_mutation_probes() {
	begin_case T04 'temporary rsync mutations prove same-size incremental assertions detect drift'
	for mutation_flag in --ignore-times --size-only; do
		setup_fixture
		printf '%s\n' 'same-size-old' > "$SOURCE_DIR/same-size.txt"
		printf '%s\n' 'unchanged content' > "$SOURCE_DIR/unchanged.txt"
		touch -t 202609090101 "$SOURCE_DIR/same-size.txt"
		assert_success "T04 $mutation_flag initial copy succeeds" run_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/initial.log"
		printf '%s\n' 'same-size-new' > "$SOURCE_DIR/same-size.txt"
		touch -t 202609090102 "$SOURCE_DIR/same-size.txt"
		create_rsync_mutation "$mutation_flag"
		old_path=$PATH
		PATH="$BIN_DIR:$PATH"
		assert_success "T04 $mutation_flag transfer completes" run_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/mutation.log"
		PATH=$old_path
		if [ "$mutation_flag" = --ignore-times ]; then
			assert_failure 'T04 --ignore-times makes expected file-count assertion red' test "$BACKUP_TRANSFER_FILES" -eq 1
		else
			assert_failure 'T04 --size-only makes same-size hash assertion red' cmp -s "$SOURCE_DIR/same-size.txt" "$TARGET_ROOT/same-size.txt"
		fi
		assert_no_runtime_temp_files
	done
}

case_partial_target_recovery() {
	begin_case T10 'real rsync restores a partial target file to the source hash'
	setup_fixture
	dd if=/dev/zero of="$SOURCE_DIR/payload.bin" bs=1024 count=256 >/dev/null 2>&1
	dd if="$SOURCE_DIR/payload.bin" of="$TARGET_ROOT/payload.bin" bs=1024 count=8 >/dev/null 2>&1
	before=$(snapshot_source)
	assert_success 'T10 partial target transfer succeeds' run_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/partial.log"
	assert_file_hash_equal "$SOURCE_DIR/payload.bin" "$TARGET_ROOT/payload.bin" 'T10 partial file recovers fully'
	assert_equal "$(snapshot_source)" "$before" 'T10 source snapshot remains unchanged'
	assert_no_runtime_temp_files
}

case_failure_exit_and_classification() {
	begin_case T05 'controlled rsync failures preserve exit codes and classify only diagnostics'
	setup_fixture
	create_rsync_double
	printf '%s\n' fixture > "$SOURCE_DIR/input.txt"
	RSYNC_ARGS_FILE="$TEST_ROOT/args.log"
	export RSYNC_ARGS_FILE
	old_path=$PATH
	PATH="$BIN_DIR:$PATH"

	for spec in '0::' '11::rsync' '12::rsync' '23::rsync' '23:ENOSPC:no_space' '23:No space left on device:no_space'; do
		exit_code=${spec%%:*}
		rest=${spec#*:}
		diagnostic=${rest%%:*}
		expected_error=${rest#*:}
		RSYNC_DOUBLE_EXIT=$exit_code
		RSYNC_DOUBLE_DIAGNOSTIC=$diagnostic
		RSYNC_DOUBLE_STATS=1
		export RSYNC_DOUBLE_EXIT RSYNC_DOUBLE_DIAGNOSTIC RSYNC_DOUBLE_STATS
		if run_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/double-$exit_code.log"; then
			actual_return=0
		else
			actual_return=$?
		fi
		assert_equal "$actual_return" "$exit_code" "T04 rsync exit $exit_code propagates"
		assert_equal "$BACKUP_TRANSFER_EXIT" "$exit_code" "T04 global exit records $exit_code"
		assert_equal "$BACKUP_TRANSFER_ERROR" "$expected_error" "T04 error classification for $exit_code"
	done
	PATH=$old_path
	assert_no_runtime_temp_files
}

case_argv_contract() {
	begin_case T06 'transfer argv preserves spaced source, target, and log arguments'
	setup_fixture
	SOURCE_DIR="$TEST_ROOT/source with space"
	TARGET_ROOT="$TEST_ROOT/target with space"
	transfer_log="$LOG_DIR/logs with space/argv transfer.log"
	mkdir -p "$SOURCE_DIR" "$TARGET_ROOT" "$(dirname "$transfer_log")"
	create_rsync_double
	printf '%s\n' fixture > "$SOURCE_DIR/input.txt"
	RSYNC_ARGS_FILE="$TEST_ROOT/args.log"
	RSYNC_DOUBLE_EXIT=0
	RSYNC_DOUBLE_DIAGNOSTIC=''
	RSYNC_DOUBLE_STATS=1
	export RSYNC_ARGS_FILE RSYNC_DOUBLE_EXIT RSYNC_DOUBLE_DIAGNOSTIC RSYNC_DOUBLE_STATS
	old_path=$PATH
	PATH="$BIN_DIR:$PATH"
	assert_success 'T06 controlled success returns zero' run_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$transfer_log"
	PATH=$old_path
	assert_contains --archive "$RSYNC_ARGS_FILE" 'T05 archive flag retained'
	assert_contains --recursive "$RSYNC_ARGS_FILE" 'T05 recursive flag retained'
	assert_contains --times "$RSYNC_ARGS_FILE" 'T05 times flag retained'
	assert_contains --prune-empty-dirs "$RSYNC_ARGS_FILE" 'T05 prune-empty-dirs retained'
	assert_contains --partial "$RSYNC_ARGS_FILE" 'T05 partial retained'
	assert_contains --stats "$RSYNC_ARGS_FILE" 'T05 stats retained'
	assert_contains "--log-file=$transfer_log" "$RSYNC_ARGS_FILE" 'T06 actual spaced log-file argument retained'
	assert_contains '--exclude=FieldBackup.conf' "$RSYNC_ARGS_FILE" 'T05 config exclude retained'
	assert_contains '--exclude=.Trash*' "$RSYNC_ARGS_FILE" 'T05 Trash exclude retained'
	assert_contains '--exclude=.Spotlight*' "$RSYNC_ARGS_FILE" 'T05 Spotlight exclude retained'
	assert_contains '--exclude=.fseventsd' "$RSYNC_ARGS_FILE" 'T05 fseventsd exclude retained'
	assert_contains '--exclude=System Volume Information' "$RSYNC_ARGS_FILE" 'T05 Windows metadata exclude retained'
	assert_contains '--exclude=$RECYCLE.BIN' "$RSYNC_ARGS_FILE" 'T05 recycle exclude retained'
	for forbidden_flag in --ignore-existing --append --append-verify --human-readable --progress --info=progress2 --delete; do
		assert_not_contains "$forbidden_flag" "$RSYNC_ARGS_FILE" "T05 forbidden $forbidden_flag is absent"
	done
	last_two=$(awk '{ previous=current; current=$0 } END { printf "%s|%s|", previous, current }' "$RSYNC_ARGS_FILE")
	assert_equal "$last_two" "$SOURCE_DIR/|$TARGET_ROOT/|" 'T06 source and target remain complete final argv entries'
	assert_equal "$BACKUP_TRANSFER_FILES" 7 'T06 stats files parsed from actual helper output'
	assert_equal "$BACKUP_TRANSFER_BYTES" 1234 'T06 stats bytes parsed without invented units'
	assert_no_runtime_temp_files
}

case_missing_rsync_and_runtime_failure_reset_state() {
	begin_case T07 'missing rsync and runtime-output preparation failures cannot retain success state'
	setup_fixture
	printf '%s\n' fixture > "$SOURCE_DIR/input.txt"
	assert_success 'T06 establishes a prior success state' run_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/success.log"
	prepare_no_rsync_path
	old_path=$PATH
	PATH=$NO_RSYNC_BIN
	if run_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/missing.log"; then
		missing_return=0
	else
		missing_return=$?
	fi
	PATH=$old_path
	assert_equal "$missing_return" 127 'T06 missing rsync returns shell command-not-found code'
	assert_equal "$BACKUP_TRANSFER_EXIT" 127 'T06 missing rsync updates exit global'
	assert_equal "$BACKUP_TRANSFER_FILES" 0 'T06 missing rsync resets transferred files'
	assert_equal "$BACKUP_TRANSFER_BYTES" 0 'T06 missing rsync resets transferred bytes'
	assert_equal "$BACKUP_TRANSFER_ERROR" rsync 'T06 missing rsync is an rsync error'
	assert_no_runtime_temp_files

	old_base_dir=$BASE_DIR
	BASE_DIR="$TEST_ROOT/no-runtime"
	if run_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/preparation.log"; then
		preparation_return=0
	else
		preparation_return=$?
	fi
	BASE_DIR=$old_base_dir
	assert_equal "$preparation_return" 1 'T06 temporary output creation failure returns nonzero'
	assert_equal "$BACKUP_TRANSFER_EXIT" 1 'T06 preparation failure records its exit code'
	assert_equal "$BACKUP_TRANSFER_FILES" 0 'T06 preparation failure does not retain files'
	assert_equal "$BACKUP_TRANSFER_BYTES" 0 'T06 preparation failure does not retain bytes'
	assert_equal "$BACKUP_TRANSFER_ERROR" rsync 'T06 preparation failure has a defined failure class'
	assert_no_runtime_temp_files
}

case_runtime_output_failure_injections() {
	begin_case T08 'strict mktemp and redirection doubles reset state and clean registered files'
	setup_fixture
	printf '%s\n' fixture > "$SOURCE_DIR/input.txt"
	assert_success 'T08 establishes a real prior success state' run_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/success.log"
	create_mktemp_double
	old_path=$PATH
	PATH="$BIN_DIR:$PATH"
	MK_TEMP_DOUBLE_MODE=fail-second
	MK_TEMP_DOUBLE_BASE=$BASE_DIR
	MK_TEMP_DOUBLE_STATE="$TEST_ROOT/mktemp-calls"
	export MK_TEMP_DOUBLE_MODE MK_TEMP_DOUBLE_BASE MK_TEMP_DOUBLE_STATE
	if run_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/mktemp.log"; then
		mktemp_return=0
	else
		mktemp_return=$?
	fi
	PATH=$old_path
	assert_failure 'T08 second mktemp must fail' test "$mktemp_return" -eq 0
	assert_equal "$BACKUP_TRANSFER_EXIT" "$mktemp_return" 'T08 second mktemp exit global matches return'
	assert_equal "$BACKUP_TRANSFER_FILES" 0 'T08 second mktemp resets files'
	assert_equal "$BACKUP_TRANSFER_BYTES" 0 'T08 second mktemp resets bytes'
	assert_failure 'T08 second mktemp records a nonempty error' test -z "$BACKUP_TRANSFER_ERROR"
	assert_no_runtime_temp_files

	for redirect_mode in fail-stdout-redirect fail-stderr-redirect; do
		setup_fixture
		printf '%s\n' fixture > "$SOURCE_DIR/input.txt"
		assert_success "T08 $redirect_mode establishes a real prior success state" run_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/success.log"
		create_mktemp_double
		old_path=$PATH
		PATH="$BIN_DIR:$PATH"
		MK_TEMP_DOUBLE_MODE=$redirect_mode
		MK_TEMP_DOUBLE_BASE=$BASE_DIR
		export MK_TEMP_DOUBLE_MODE MK_TEMP_DOUBLE_BASE
		if run_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/$redirect_mode.log"; then
			redirect_return=0
		else
			redirect_return=$?
		fi
		PATH=$old_path
		assert_failure "T08 $redirect_mode must fail" test "$redirect_return" -eq 0
		assert_equal "$BACKUP_TRANSFER_EXIT" "$redirect_return" "T08 $redirect_mode exit global matches return"
		assert_equal "$BACKUP_TRANSFER_FILES" 0 "T08 $redirect_mode resets files"
		assert_equal "$BACKUP_TRANSFER_BYTES" 0 "T08 $redirect_mode resets bytes"
		assert_failure "T08 $redirect_mode records a nonempty error" test -z "$BACKUP_TRANSFER_ERROR"
		assert_no_runtime_temp_files
	done
}

case_real_enospc_and_cleanup() {
	begin_case T09 'real tmpfs ENOSPC is detected without touching host storage'
	setup_fixture
	mkdir -p "$FULL_TARGET"
	mount -t tmpfs -o size=2m tmpfs "$FULL_TARGET" || {
		fail 'T07 cannot create test-owned tmpfs'
		return
	}
	dd if=/dev/zero of="$FULL_TARGET/filler.bin" bs=1024 count=1900 >/dev/null 2>&1 || {
		fail 'T07 cannot fill test-owned tmpfs'
		return
	}
	dd if=/dev/zero of="$SOURCE_DIR/too-large.bin" bs=1024 count=512 >/dev/null 2>&1
	before=$(snapshot_source)
	if run_transfer "$SOURCE_DIR/" "$FULL_TARGET/" "$LOG_DIR/full.log"; then
		full_return=0
	else
		full_return=$?
	fi
	assert_failure 'T09 real full tmpfs must not report success' test "$full_return" -eq 0
	assert_equal "$BACKUP_TRANSFER_EXIT" "$full_return" 'T09 actual ENOSPC exit global matches return'
	assert_equal "$BACKUP_TRANSFER_ERROR" no_space 'T09 actual ENOSPC diagnostic maps to no_space'
	assert_equal "$(snapshot_source)" "$before" 'T09 actual ENOSPC leaves source snapshot unchanged'
	assert_no_runtime_temp_files
	umount "$FULL_TARGET" || fail 'T09 unmounts test-owned tmpfs'
}

case_early_leader_exit_keeps_temp_until_child_drain() {
	begin_case T11 'leader exit before first proc read retains transfer temps until its child drains'
	setup_fixture
	create_early_exit_rsync
	TEST_EARLY_READY="$TEST_ROOT/early-ready"
	TEST_EARLY_TRACE="$TEST_ROOT/early-trace"
	TEST_EARLY_CHILD_PID="$TEST_ROOT/early-child-pid"
	TEST_FIRST_READ_RELEASE="$TEST_ROOT/early-first-read-release"
	READ_STAT_LIBRARY="$TEST_ROOT/read-stat-original.sh"
	sed -n '/^transfer_process_read_stat() {/,/^# Return whether the expected private session/p' \
		"$PROCESS_SCRIPT" | sed '1s/^transfer_process_read_stat()/transfer_process_read_stat_original()/' \
		> "$READ_STAT_LIBRARY"
	# shellcheck disable=SC1090
	. "$READ_STAT_LIBRARY"
	TEST_FIRST_READ_USED=0
	transfer_process_read_stat() {
		if [ "$TEST_FIRST_READ_USED" -eq 0 ]; then
			TEST_FIRST_READ_USED=1
			while [ ! -e "$TEST_FIRST_READ_RELEASE" ]; do /bin/sleep 1; done
		fi
		transfer_process_read_stat_original "$@"
	}
	export TEST_EARLY_READY TEST_EARLY_TRACE TEST_EARLY_CHILD_PID TEST_FIRST_READ_RELEASE
	old_path=$PATH
	PATH="$BIN_DIR:$PATH"
	( backup_transfer "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/early.log"; printf '%s\n' "$?" > "$TEST_ROOT/early-result" ) &
	transfer_pid=$!
	assert_success 'T11 early child writes before the first proc read is released' wait_for_path "$TEST_EARLY_TRACE"
	set -- "$BASE_DIR/var/.backup-transfer."*
	ASSERTIONS=$((ASSERTIONS + 1))
	[ "$1" != "$BASE_DIR/var/.backup-transfer.*" ] || fail 'T11 transfer temps exist while first proc read is gated'
	: > "$TEST_FIRST_READ_RELEASE"
	/bin/sleep 2
	ASSERTIONS=$((ASSERTIONS + 1))
	kill -0 "$transfer_pid" 2>/dev/null || fail 'T11 transfer returned before leader-gone child stopped'
	set -- "$BASE_DIR/var/.backup-transfer."*
	ASSERTIONS=$((ASSERTIONS + 1))
	[ "$1" != "$BASE_DIR/var/.backup-transfer.*" ] || fail 'T11 transfer temps were removed while child still wrote'
	kill -TERM "$(cat "$TEST_EARLY_CHILD_PID")"
	wait "$transfer_pid" 2>/dev/null || early_rc=$?
	early_rc=${early_rc:-0}
	PATH=$old_path
	assert_equal "$early_rc" 0 'T11 natural transfer status survives early leader drain'
	assert_equal "$(cat "$TEST_ROOT/early-result")" 0 'T11 helper returns only after child drain'
	assert_no_runtime_temp_files
}

case_cancellation_notice_bypasses_transfer_output_redirect() {
	begin_case T12 'accepted cancellation remains observable while an ignoring writer retains transfer output files'
	setup_fixture
	create_term_ignoring_rsync
	create_logger_double
	create_cancel_transfer_runner
	TEST_CANCEL_READY="$TEST_ROOT/cancel-ready"
	TEST_CANCEL_RELEASE="$TEST_ROOT/cancel-release"
	TEST_CANCEL_TRACE="$TEST_ROOT/cancel-trace"
	TEST_CANCEL_RESULT="$TEST_ROOT/cancel-result"
	TEST_LOGGER_OUTPUT="$TEST_ROOT/cancel-syslog"
	export TEST_CANCEL_READY TEST_CANCEL_RELEASE TEST_CANCEL_TRACE TEST_CANCEL_RESULT TEST_LOGGER_OUTPUT
	old_path=$PATH
	PATH="$BIN_DIR:$PATH"
	BASE_DIR="$BASE_DIR" TEST_PROCESS_SCRIPT="$PROCESS_SCRIPT" TEST_TRANSFER_SCRIPT="$TRANSFER_SCRIPT" \
		"$BIN_DIR/cancel-transfer-runner" "$SOURCE_DIR/" "$TARGET_ROOT/" "$LOG_DIR/cancel.log" \
		> "$TEST_ROOT/cancel-outer.stdout" 2> "$TEST_ROOT/cancel-outer.stderr" &
	transfer_pid=$!
	assert_success 'T12 rsync writer becomes active before cancellation' wait_for_path "$TEST_CANCEL_READY"
	kill -TERM "$transfer_pid"
	/bin/sleep 2
	ASSERTIONS=$((ASSERTIONS + 1))
	kill -0 "$transfer_pid" 2>/dev/null || fail 'T12 runner remains alive while writer ignores TERM'
	assert_contains 'waiting for transfer writers' "$TEST_LOGGER_OUTPUT" 'T12 retained-writer wait is observable outside redirected runner stderr'
	assert_equal "$(cat "$TEST_ROOT/cancel-outer.stderr")" '' \
		'T12 outer stderr remains empty because backup_transfer owns the runner redirect'
	set -- "$BASE_DIR/var/.backup-transfer.stderr."*
	ASSERTIONS=$((ASSERTIONS + 1))
	[ "$1" != "$BASE_DIR/var/.backup-transfer.stderr.*" ] || fail 'T12 runner stderr temp remains while writer is active'
	assert_contains 'waiting for transfer writers' "$1" \
		'T12 runner diagnostic remains in the private stderr temp while syslog stays observable'
	: > "$TEST_CANCEL_RELEASE"
	wait "$transfer_pid" 2>/dev/null || cancel_rc=$?
	cancel_rc=${cancel_rc:-0}
	PATH=$old_path
	assert_equal "$cancel_rc" 143 'T12 cancellation preserves TERM status after writer release'
	assert_equal "$(cat "$TEST_CANCEL_RESULT")" 143 'T12 runner returns sticky TERM status after writer release'
	assert_no_runtime_temp_files
}

main() {
	[ -f "$TRANSFER_SCRIPT" ] || {
		printf 'FAIL: missing transfer helper: %s\n' "$TRANSFER_SCRIPT" >&2
		exit 1
	}
	trap cleanup_test_data EXIT INT TERM
	case_source_is_inert
	case_real_transfer_and_fd_target
	case_incremental_update_and_preservation
	case_incremental_mutation_probes
	case_partial_target_recovery
	case_failure_exit_and_classification
	case_argv_contract
	case_missing_rsync_and_runtime_failure_reset_state
	case_runtime_output_failure_injections
	case_real_enospc_and_cleanup
	case_early_leader_exit_keeps_temp_until_child_drain
	case_cancellation_notice_bypasses_transfer_output_redirect
	printf 'RESULT: cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
	[ "$CASES" -eq 12 ] || fail "expected 12 cases, ran $CASES"
	[ "$ASSERTIONS" -eq 130 ] || fail "expected 130 assertions, ran $ASSERTIONS"
	[ "$FAILED" -eq 0 ]
}

main "$@"

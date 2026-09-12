#!/bin/sh
#
# BDD integration tests for backup-manager service admission and quiescent stop.
# The production manager, FD locks, owner argv checks, and controller are real
# OpenWrt ash processes. target and source mounts remain the existing isolated
# target-manager fixture stubs.
#

set -u

# Run the native aarch64 rootfs. The production owner parser deliberately
# accepts only ash's canonical argv; Rosetta's wrapper argv is not production.
IMAGE='openwrt/rootfs:aarch64_generic-24.10.8'
IMAGE_DIGEST='sha256:f6dd33c1d9b7d6f1e0848f2fbb92b8d03fc9b425dc08c3574a44936b93133704'

if [ "${1:-}" != '--inside' ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 1
    EVIDENCE_ROOT=$(mktemp -d /tmp/outdoor-backup-manager-service.XXXXXX) || exit 1
    python3 "$REPO_ROOT/tests/run-local-container.py" --evidence "$EVIDENCE_ROOT" -- \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-manager-service.sh --inside
    suite_rc=$?
    [ -f "$EVIDENCE_ROOT/suite.rc" ] || printf '%s\n' "$suite_rc" > "$EVIDENCE_ROOT/suite.rc"
    [ -f "$EVIDENCE_ROOT/suite.stdout" ] && cat "$EVIDENCE_ROOT/suite.stdout"
    [ -f "$EVIDENCE_ROOT/suite.stderr" ] && cat "$EVIDENCE_ROOT/suite.stderr" >&2
    printf 'evidence=%s\n' "$EVIDENCE_ROOT"
    exit "$suite_rc"
fi

[ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || {
    printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
    exit 1
}

# Reuse only the target-manager fixture library. Its target tmpfs, fixture
# sysfs, source mount stub, and assertion helpers remain a single tested base.
REPO_ROOT=/src
set -- --inside
# The sourced fixture normally redirects asynchronous stderr for its own runner.
# This suite owns the top-level runner, so retain its real diagnostics directly.
TEST_CAPTURED_STDERR=1
TEST_ASYNC_STDERR=/evidence/target-fixture.stderr
TEST_TARGET_MANAGER_LIBRARY_ONLY=1
# shellcheck disable=SC1090
. "$REPO_ROOT/test-target-manager.sh"

MANAGER_SERVICE_ROOT=/evidence/runtime
CASES=0
ASSERTIONS=0
FAILED=0
ACTIVE_PIDS=''
EXPECTED_CASES=8
# MS02 F8 adds 11 lifecycle assertions; MS05 adds 17; MS07 adds 16.
EXPECTED_ASSERTIONS=206 # 195 baseline + 11

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILED=$((FAILED + 1))
}

begin_case() {
    CASES=$((CASES + 1))
    printf 'CASE %s: %s\n' "$1" "$2"
}

assert_equal() {
    actual=$1 expected=$2 message=$3
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
        fail "$message (unexpected success)"
    fi
}

assert_file_absent() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "$2 (exists=[$1])"
}

assert_not_contains() {
    needle=$1 file=$2 message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    grep -F -q -- "$needle" "$file" && fail "$message (unexpected=[$needle])"
}

assert_contains() {
    needle=$1 file=$2 message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    grep -F -q -- "$needle" "$file" || fail "$message (missing=[$needle])"
}

track_pid() { ACTIVE_PIDS="$ACTIVE_PIDS $1"; }

cleanup_pids() {
    for service_pid in $ACTIVE_PIDS; do
        kill -TERM "$service_pid" 2>/dev/null || :
        wait "$service_pid" 2>/dev/null || :
    done
    ACTIVE_PIDS=''
}

wait_path() {
    watched_path=$1 watched_pid=$2 label=$3 elapsed=0
    while [ "$elapsed" -lt 20 ]; do
        [ -e "$watched_path" ] && return 0
        kill -0 "$watched_pid" 2>/dev/null || {
            fail "$label exited before readiness"
            return 1
        }
        /bin/sleep 1
        elapsed=$((elapsed + 1))
    done
    fail "$label did not become ready"
    return 1
}

wait_pid() {
    watched_pid=$1 timeout_seconds=$2 label=$3 elapsed=0
    while kill -0 "$watched_pid" 2>/dev/null; do
        process_state=$(awk '{print $3}' "/proc/$watched_pid/stat" 2>/dev/null || :)
        [ "$process_state" = Z ] && break
        if [ "$elapsed" -ge "$timeout_seconds" ]; then
            fail "$label exceeded ${timeout_seconds}s watchdog"
            kill -TERM "$watched_pid" 2>/dev/null || :
            /bin/sleep 1
            kill -KILL "$watched_pid" 2>/dev/null || :
            wait "$watched_pid" 2>/dev/null || :
            return 124
        fi
        /bin/sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$watched_pid"
}

# Poll an already-created state file without using a fixed delay as sequencing.
# Arguments: path, exact expected bytes, watched producer PID, diagnostic label.
wait_file_value() {
    watched_path=$1 expected_value=$2 watched_pid=$3 label=$4 elapsed=0
    while [ "$elapsed" -lt 20 ]; do
        if [ -r "$watched_path" ] && [ "$(cat "$watched_path")" = "$expected_value" ]; then
            return 0
        fi
        kill -0 "$watched_pid" 2>/dev/null || {
            fail "$label exited before publishing [$expected_value]"
            return 1
        }
        /bin/sleep 1
        elapsed=$((elapsed + 1))
    done
    fail "$label did not publish [$expected_value]"
    return 1
}

# Like wait_pid, but a timeout is an expected observable for mutation controls.
# It still terminates the fixture process and returns 124, never a fake 143.
wait_pid_bounded() {
    watched_pid=$1 timeout_seconds=$2 elapsed=0
    while kill -0 "$watched_pid" 2>/dev/null; do
        process_state=$(awk '{print $3}' "/proc/$watched_pid/stat" 2>/dev/null || :)
        [ "$process_state" = Z ] && break
        if [ "$elapsed" -ge "$timeout_seconds" ]; then
            kill -TERM "$watched_pid" 2>/dev/null || :
            /bin/sleep 1
            kill -KILL "$watched_pid" 2>/dev/null || :
            wait "$watched_pid" 2>/dev/null || :
            return 124
        fi
        /bin/sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$watched_pid"
}

persist_ms03_waiter_evidence() {
    evidence_prefix=$1
    persist_evidence_value "$evidence_prefix/b.rc" "$2" || fail "$evidence_prefix cannot persist B exit oracle"
    persist_evidence_file "$evidence_prefix/b.out" "$3" || fail "$evidence_prefix cannot persist B diagnostic oracle"
    persist_evidence_file "$evidence_prefix/b.ready" "$4" || fail "$evidence_prefix cannot persist B readiness marker"
    persist_evidence_file "$evidence_prefix/b.lock-attempt" "$4" || fail "$evidence_prefix cannot persist B lock-attempt marker"
    persist_evidence_value "$evidence_prefix/service-state" "$(cat "$SERVICE_RUNTIME/state")" || \
        fail "$evidence_prefix cannot persist stopped state"
    persist_evidence_value "$evidence_prefix/business-lock" "$(readlink "$RUNTIME/var/lock/backup.lock" 2>/dev/null || :)" || \
        fail "$evidence_prefix cannot persist business-lock identity"
    persist_evidence_value "$evidence_prefix/controller-wait" "$5" || \
        fail "$evidence_prefix cannot persist controller wait result"
}

service_state_write_fixture() {
    printf '%s' "$1" > "$SERVICE_RUNTIME/state"
}

service_control_env() {
    OUTDOOR_BACKUP_SERVICE_DIR="$SERVICE_RUNTIME" \
    OUTDOOR_BACKUP_RC_DIR="$SERVICE_RC_DIR" \
    OUTDOOR_BACKUP_INIT_SCRIPT="$SERVICE_INIT_SCRIPT" \
    "$@"
}

# Persist only explicit small-oracle values. Never retain the isolated target
# tmpfs, mounted fixture data, or an entire runtime tree after a passing case.
persist_evidence_value() {
    evidence_name=$1
    shift
    mkdir -p "$(dirname "$MANAGER_SERVICE_ROOT/$evidence_name")" || return 1
    printf '%s\n' "$*" > "$MANAGER_SERVICE_ROOT/$evidence_name"
}

persist_evidence_file() {
    evidence_name=$1
    evidence_source=$2
    mkdir -p "$(dirname "$MANAGER_SERVICE_ROOT/$evidence_name")" || return 1
    cp "$evidence_source" "$MANAGER_SERVICE_ROOT/$evidence_name"
}

# Build an old-behavior control only in the ephemeral fixture. Keep the source
# library (cleanup still has its real function), remove admission/trap semantics,
# and restore the old sticky-signal-only cancellation gate. It introduces no new
# I/O or side effect; it exposes the deleted service boundary.
# Derive a case-private manager which invokes the delivered target_open first,
# records that completed invocation, and returns its exact real result. This is
# an execution seam, not a textual ordering claim: an admission rejection must
# leave the event absent because target_open was never called.
make_target_open_observable_manager() {
    target_event=$1
    observed_target=$SCRIPTS/target-open-observable.sh
    observed_manager=$SCRIPTS/manager-target-open-observable.sh
    target_anchor='target_open() {'
    manager_anchor='. "$SCRIPT_DIR/target.sh"'
    [ "$(grep -F -c -- "$target_anchor" "$SCRIPTS/target.sh")" -eq 1 ] || return 1
    [ "$(grep -F -c -- "$manager_anchor" "$SCRIPTS/backup-manager.sh")" -eq 1 ] || return 1
    awk '
        $0 == "target_open() {" { print "target_open_actual() {"; renamed++; next }
        { print }
        END { exit !(renamed == 1) }
    ' "$SCRIPTS/target.sh" > "$observed_target" || return 1
    cat >> "$observed_target" <<EOF

target_open() {
    target_open_actual "\$@"
    target_open_rc=\$?
    printf '%s\\n' 'target-open completed' >> '$target_event'
    return "\$target_open_rc"
}
EOF
    /bin/ash -n "$observed_target" || return 1
    awk '
        $0 == ". \"$SCRIPT_DIR/target.sh\"" {
            print ". \"$SCRIPT_DIR/target-open-observable.sh\""
            replaced++
            next
        }
        { print }
        END { exit !(replaced == 1) }
    ' "$SCRIPTS/backup-manager.sh" > "$observed_manager" || return 1
    chmod 700 "$observed_manager" || return 1
    /bin/ash -n "$observed_manager"
}

# Build an old-behavior control only in the ephemeral fixture. Keep the source
# library (cleanup still has its real function), remove admission/trap semantics,
# and restore the old sticky-signal-only cancellation gate. It introduces no new
# I/O or side effect; it exposes the deleted service boundary.
make_no_service_admission_mutant() {
    source_manager=${1:-$SCRIPTS/backup-manager.sh}
    mutant=${2:-$SCRIPTS/manager-no-service-admission.sh}
    source_marker='. "$SCRIPT_DIR/service-state.sh"'
    [ "$(grep -F -c -- "$source_marker" "$source_manager")" -eq 1 ] || return 1
    [ "$(grep -F -c -- 'trap temporary_lease_cleanup EXIT' "$source_manager")" -eq 1 ] || return 1
    [ "$(grep -F -c -- 'check_cancel_request() {' "$source_manager")" -eq 1 ] || return 1
    awk '
        $0 == ". \"$SCRIPT_DIR/service-state.sh\"" { print; drop_admission = 1; next }
        drop_admission {
            if ($0 == "trap temporary_lease_cleanup EXIT") { drop_admission = 0; removed_admission++; }
            next
        }
        $0 == "check_cancel_request() {" {
            print "check_cancel_request() {"
            print "\tcancel_code=${BACKUP_CANCEL_CODE:-0}"
            print "\t[ \"$cancel_code\" -eq 0 ] && return 0"
            print "\tERROR_TYPE=cancelled"
            print "\treturn \"$cancel_code\""
            print "}"
            while ((getline next_line) > 0) {
                if (next_line == "}") break
            }
            replaced_current++
            next
        }
        { print }
        END { exit !(removed_admission == 1 && replaced_current == 1) }
    ' "$source_manager" > "$mutant" || return 1
    chmod 700 "$mutant" || return 1
    /bin/ash -n "$mutant"
}

# Remove only expected-generation comparison in a private service-state copy.
# The running-mode rejection remains production-identical, so the control cannot
# manufacture a restart by changing the state record.
make_no_expected_generation_mutant() {
    mutant_state=$SCRIPTS/service-state-no-expected-generation.sh
    mutant_manager=$SCRIPTS/manager-no-expected-generation.sh
    state_anchor='{ [ -n "$SERVICE_LEASE_EXPECTED" ] && [ "$SERVICE_LEASE_EXPECTED" != "$SERVICE_STATE_GENERATION" ]; }; then'
    manager_anchor='. "$SCRIPT_DIR/service-state.sh"'
    [ "$(grep -F -c -- "$state_anchor" "$SCRIPTS/service-state.sh")" -eq 1 ] || return 1
    [ "$(grep -F -c -- "$manager_anchor" "$SCRIPTS/manager-target-open-observable.sh")" -eq 1 ] || return 1
    awk '
        $0 == "    if [ \"$SERVICE_STATE_MODE\" != running ] || \\" {
            if ((getline expected_line) < 1 || expected_line != "        { [ -n \"$SERVICE_LEASE_EXPECTED\" ] && [ \"$SERVICE_LEASE_EXPECTED\" != \"$SERVICE_STATE_GENERATION\" ]; }; then") exit 1
            print "    if [ \"$SERVICE_STATE_MODE\" != running ]; then"
            removed++
            next
        }
        { print }
        END { exit !(removed == 1) }
    ' "$SCRIPTS/service-state.sh" > "$mutant_state" || return 1
    /bin/ash -n "$mutant_state" || return 1
    awk '
        $0 == ". \"$SCRIPT_DIR/service-state.sh\"" {
            print ". \"$SCRIPT_DIR/service-state-no-expected-generation.sh\""
            replaced++
            next
        }
        { print }
        END { exit !(replaced == 1) }
    ' "$SCRIPTS/manager-target-open-observable.sh" > "$mutant_manager" || return 1
    chmod 700 "$mutant_manager" || return 1
    /bin/ash -n "$mutant_manager"
}

# Move the one owner-cleanup lease release to the TERM/INT cancellation record in
# a private copy. That runs while transfer_process_run is still draining the same
# writer session, making the normal FD8-busy predicate fail for this control.
make_early_release_mutant() {
    mutant=$SCRIPTS/manager-early-lease-release.sh
    [ "$(grep -F -c -- 'BACKUP_CANCEL_CODE=$1' "$SCRIPTS/backup-manager.sh")" -eq 1 ] || return 1
    [ "$(grep -F -c -- 'release_lock' "$SCRIPTS/backup-manager.sh")" -eq 2 ] || return 1
    awk '
        BEGIN { quote = sprintf("%c", 39) }
        $0 == "\tBACKUP_CANCEL_CODE=$1" {
            print
            print "\tservice_lease_release || exit 1"
            inserted++
            next
        }
        $0 == "\trelease_lock" {
            print
            if ((getline line_one) < 1 || (getline line_two) < 1 ||
                (getline line_three) < 1 || (getline line_four) < 1 ||
                (getline line_five) < 1) exit 1
            if (line_one != "\tif ! service_lease_release; then" ||
                line_two != "\t\tprintf " quote "%s\\n" quote " " quote "outdoor-backup: explicit service lease release failed" quote " >&2" ||
                line_three != "\t\t[ \"$cleanup_exit_code\" -ne 0 ] || cleanup_exit_code=1" ||
                line_four != "\tfi" || line_five != "\texit \"$cleanup_exit_code\"") exit 1
            print line_five
            removed++
            next
        }
        { print }
        END { exit !(inserted == 1 && removed == 1) }
    ' "$SCRIPTS/backup-manager.sh" > "$mutant" || return 1
    chmod 700 "$mutant" || return 1
    /bin/ash -n "$mutant"
}

# Delete exactly the acquire_lock loop's service-current gate in a disposable
# runtime copy. The BDD oracle below must reject this manager while A stays owner.
make_no_waiter_current_gate_mutant() {
    mutant=$SCRIPTS/manager-no-waiter-current-gate.sh
    awk '
        $0 == "acquire_lock() {" { in_acquire = 1 }
        in_acquire && $0 == "\t\tcheck_cancel_request || return \"$?\"" {
            removed++
            next
        }
        { print }
        in_acquire && $0 == "}" { in_acquire = 0 }
        END { exit !(removed == 1 && in_acquire == 0) }
    ' "$SCRIPTS/backup-manager.sh" > "$mutant" || return 1
    chmod 700 "$mutant" || return 1
    /bin/ash -n "$mutant"
}

# Keep all normal sleeps intact except the final acquire_lock sleep in this
# disposable copy. The marker is therefore an exact last-iteration boundary,
# not a timing guess or a global fixture sleep override.
make_last_lock_sleep_barrier_manager() {
    barrier_manager=$SCRIPTS/manager-last-lock-sleep-barrier.sh
    awk '
        $0 == "acquire_lock() {" { in_acquire = 1 }
        in_acquire && $0 == "\t\tsleep \"$interval\"" {
            print "\t\tif [ $((elapsed + interval)) -ge \"$timeout\" ]; then"
            print "\t\t\tprintf \047manager=%s elapsed=%s timeout=%s\\n\047 \"$$\" \"$elapsed\" \"$timeout\" > \"${TEST_LOCK_LAST_SLEEP_READY:?}\""
            print "\t\t\twhile [ ! -e \"${TEST_LOCK_LAST_SLEEP_RELEASE:?}\" ]; do /bin/sleep 1; done"
            print "\t\tfi"
            print
            inserted++
        }
        { print }
        in_acquire && $0 == "}" { in_acquire = 0 }
        END { exit !(inserted == 1 && in_acquire == 0) }
    ' "$SCRIPTS/backup-manager.sh" > "$barrier_manager" || return 1
    chmod 700 "$barrier_manager" || return 1
    /bin/ash -n "$barrier_manager"
}

install_controller() {
    cp "$REPO_ROOT/files/opt/outdoor-backup/scripts/service-control.sh" \
        "$SCRIPTS/service-control.sh" || return 1
    chmod 700 "$SCRIPTS/service-control.sh"
}

run_controller_background() {
    controller_output=$1
    service_control_env /bin/ash "$SCRIPTS/service-control.sh" stop >"$controller_output" 2>&1 &
    CONTROLLER_PID=$!
    track_pid "$CONTROLLER_PID"
}

start_manager_background() {
    manager_output=$1
    shift
    TEST_RUN_MANAGER_EXEC=1 run_manager "$@" >"$manager_output" 2>&1 &
    MANAGER_PID=$!
    track_pid "$MANAGER_PID"
}

prepare_service_case() {
    cleanup_pids
    reset_case || return 1
    install_controller || return 1
    service_state_write_fixture 'running:0'
    rm -f "$TEST_ROOT"/manager.ready "$TEST_ROOT"/manager.release \
        "$TEST_ROOT"/controller.out "$TEST_ROOT"/manager.out
}

# Replace only the local rsync test executable. It is a service test barrier,
# not a production double: the manager, its FD8 lease, lock, and cleanup stay
# the actual delivered code.
install_transfer_barrier() {
    cat > "$BIN/rsync" <<'EOF'
#!/bin/sh
printf 'rsync-start pid=%s\n' "$$" >> "$TEST_EFFECTS"
printf '%s\n' "$$" > "$TEST_MANAGER_SERVICE_RSYNC_PID"
: > "$TEST_MANAGER_SERVICE_READY"
while [ ! -e "$TEST_MANAGER_SERVICE_RELEASE" ]; do /bin/sleep 1; done
printf 'rsync-release\n' >> "$TEST_EFFECTS"
exit 0
EOF
    chmod 755 "$BIN/rsync"
}

# MS03 alone needs A to remain the genuine manager, lock owner, and S-lease
# holder after controller TERM. The writer records TERM but waits for the test's
# explicit release, so B's waiter-local cancellation is observable before A can
# clean up. Other cases deliberately retain their ordinary barrier semantics.
install_ms03_owner_transfer_barrier() {
    cat > "$BIN/rsync" <<'EOF'
#!/bin/sh
record_cancel() {
    printf 'owner-writer-cancel pid=%s signal=%s\n' "$$" "$1" >> "$TEST_MS03_OWNER_EVENTS"
    printf 'pid=%s signal=%s\n' "$$" "$1" > "$TEST_MS03_OWNER_CANCEL"
}

printf 'owner-writer-start pid=%s\n' "$$" >> "$TEST_MS03_OWNER_EVENTS"
printf '%s\n' "$$" > "$TEST_MANAGER_SERVICE_RSYNC_PID"
: > "$TEST_MANAGER_SERVICE_READY"
trap 'record_cancel TERM' TERM
while [ ! -e "$TEST_MS03_OWNER_RELEASE" ]; do
    /bin/sleep 1 || :
done
printf 'owner-writer-release pid=%s\n' "$$" >> "$TEST_MS03_OWNER_EVENTS"
exit 0
EOF
    chmod 755 "$BIN/rsync"
}

run_manager_service() {
    TEST_MANAGER_SERVICE_READY="$TEST_ROOT/manager.ready" \
    TEST_MANAGER_SERVICE_RELEASE="$TEST_ROOT/manager.release" \
    TEST_MANAGER_SERVICE_RSYNC_PID="$TEST_ROOT/rsync.pid" \
    TEST_MOUNT_AUTO_CARD=1 TEST_RUN_MANAGER_EXEC=1 \
    run_manager "$@"
}

start_manager_service() {
    manager_output=$1
    manager_program=${2:-$SCRIPTS/backup-manager.sh}
    (
        # A background shell otherwise inherits ignored INT. Reset the disposition
        # before exec so this is a real manager signal test, not job-control noise.
        trap - INT
        TEST_MANAGER_SERVICE_READY="$TEST_ROOT/manager.ready" \
        TEST_MANAGER_SERVICE_RELEASE="$TEST_ROOT/manager.release" \
        TEST_MANAGER_SERVICE_RSYNC_PID="$TEST_ROOT/rsync.pid" \
        MANAGER_SCRIPT="$manager_program" TEST_MOUNT_AUTO_CARD=1 TEST_RUN_MANAGER_EXEC=1 \
        run_manager add sda1 /devices/mock >"$manager_output" 2>&1
    ) &
    MANAGER_PID=$!
    track_pid "$MANAGER_PID"
}

# MS08 needs a writer which survives the transfer group's cancellation until the
# test deliberately releases it. Other cases keep their existing simple rsync
# barrier, so this fixture cannot alter their signal semantics.
install_ms08_transfer_barrier() {
    cat > "$BIN/rsync" <<'EOF'
#!/bin/sh
record_cancel() {
    printf 'writer-cancel pid=%s signal=%s\n' "$$" "$1" >> "$TEST_MS08_EVENTS"
    printf 'pid=%s signal=%s\n' "$$" "$1" > "$TEST_MS08_CANCEL"
}

printf 'writer-start pid=%s\n' "$$" >> "$TEST_MS08_EVENTS"
printf '%s\n' "$$" > "$TEST_MANAGER_SERVICE_RSYNC_PID"
printf 'pid=%s\n' "$$" > "$TEST_MANAGER_SERVICE_READY"
printf 'writer-ready pid=%s\n' "$$" >> "$TEST_MS08_EVENTS"
trap 'record_cancel TERM' TERM
trap 'record_cancel INT' INT
while [ ! -e "$TEST_MANAGER_SERVICE_RELEASE" ]; do
    # A signal can interrupt sleep. The loop, rather than sleep's status, owns
    # the hold so TERM/INT cannot bypass the explicit test release barrier.
    /bin/sleep 1 || :
done
printf 'pid=%s\n' "$$" > "$TEST_MS08_RELEASED"
printf 'writer-release pid=%s\n' "$$" >> "$TEST_MS08_EVENTS"
printf 'writer-exit pid=%s\n' "$$" >> "$TEST_MS08_EVENTS"
exit 0
EOF
    chmod 755 "$BIN/rsync"
}

# Wrap only this case's existing source-unmount stub. The wrapper first lets the
# shared stub perform the real operation and publish its count, then records the
# same completed operation before returning to production cleanup. It never
# infers an event afterward from the count, so its event order is causal.
install_ms08_source_umount_event_seam() {
    ms08_umount_base="$BIN/umount.ms08-base"
    cp "$BIN/umount" "$ms08_umount_base" || return 1
    cat > "$BIN/umount" <<'EOF'
#!/bin/sh
umount_target=''
for value in "$@"; do
    case $value in
        -*) ;;
        *) umount_target=$value ;;
    esac
done
if [ "$umount_target" = "$TEST_SOURCE_MOUNT" ] && [ -n "${TEST_MS02_WRITER_PID_FILE:-}" ]; then
    writer_pid=$(cat "$TEST_MS02_WRITER_PID_FILE" 2>/dev/null || :)
    case $writer_pid in ''|*[!0-9]*) exit 1 ;; esac
    writer_state=$(awk '{print $3}' "/proc/$writer_pid/stat" 2>/dev/null || :)
    [ -n "$writer_state" ] || writer_state=absent
    case $writer_state in
        Z|X|absent) printf 'writer-drained pid=%s state=%s\n' "$writer_pid" "$writer_state" >> "${TEST_MS08_EVENTS:?}" ;;
        *) printf 'writer-live pid=%s state=%s\n' "$writer_pid" "$writer_state" >> "${TEST_MS08_EVENTS:?}"; exit 1 ;;
    esac
fi
"${TEST_MS08_UMOUNT_BASE:?}" "$@"
umount_rc=$?
if [ "$umount_rc" -eq 0 ]; then
    umount_target=''
    for value in "$@"; do
        case $value in
            -*) ;;
            *) umount_target=$value ;;
        esac
    done
    if [ "$umount_target" = "$TEST_SOURCE_MOUNT" ]; then
        umount_count=$(cat "${TEST_SOURCE_UMOUNT_COUNT:?}")
        printf 'source-umount count=%s lock=[%s]\n' "$umount_count" \
            "$(readlink "${TEST_LOCK_LINK:?}" 2>/dev/null || :)" >> "${TEST_MS08_EVENTS:?}"
    fi
fi
exit "$umount_rc"
EOF
    chmod 755 "$BIN/umount"
}

# Record and validate the actual writer rather than treating kill -0 as liveness:
# the transfer runner promises an alive non-zombie private session leader. Always
# leave both raw identity artifacts, including when the predicate is false.
ms08_capture_live_writer_stat() {
    writer_pid=$1
    writer_stat_file=$2
    writer_argv_file=${writer_stat_file%.stat}.argv
    : > "$writer_stat_file" || return 1
    : > "$writer_argv_file" || return 1
    awk '{printf "pid=%s state=%s pgrp=%s session=%s\n", $1, $3, $5, $6}' \
        "/proc/$writer_pid/stat" > "$writer_stat_file" 2>/dev/null || return 1
    tr '\000' ' ' < "/proc/$writer_pid/cmdline" > "$writer_argv_file" 2>/dev/null || return 1
    grep -E -q -x "pid=$writer_pid state=[^ZX] pgrp=$writer_pid session=$writer_pid" \
        "$writer_stat_file"
}

persist_ms08_writer_identity() {
    control_label=$1
    state_label=$2
    stat_file=$3
    persist_evidence_file "ms08/$control_label.writer.$state_label.stat" "$stat_file" || \
        fail "MS08 $control_label cannot persist writer $state_label stat"
    persist_evidence_file "ms08/$control_label.writer.$state_label.argv" "${stat_file%.stat}.argv" || \
        fail "MS08 $control_label cannot persist writer $state_label argv"
}

# Create a private manager copy which records only the result of its own real
# release_lock call. The unique indented call-site anchor deliberately survives
# the early-release mutation, so both controls have the same observation seam.
make_ms08_observable_manager() {
    observable_source=$1
    observable_manager=$2
    observable_anchor=$(printf '\trelease_lock')
    [ "$(grep -F -c -- "$observable_anchor" "$observable_source")" -eq 1 ] || return 1
    awk '
        BEGIN { quote = sprintf("%c", 34) }
        $0 == "\trelease_lock" {
            print
            print "\tms08_release_lock_rc=$?"
            print "\tif [ " quote "$ms08_release_lock_rc" quote " -ne 0 ]; then"
            print "\t\tprintf " quote "business-unlock-failed manager=%s rc=%s\\n" quote " " quote "$$" quote " " quote "$ms08_release_lock_rc" quote " >> " quote "${TEST_MS08_EVENTS:?}" quote
            print "\telif [ ! -e " quote "$LOCK_LINK" quote " ] && [ ! -L " quote "$LOCK_LINK" quote " ]; then"
            print "\t\tprintf " quote "business-unlock manager=%s\\n" quote " " quote "$$" quote " >> " quote "${TEST_MS08_EVENTS:?}" quote
            print "\telse"
            print "\t\tprintf " quote "business-unlock-failed manager=%s rc=0 lock-present\\n" quote " " quote "$$" quote " >> " quote "${TEST_MS08_EVENTS:?}" quote
            print "\tfi"
            inserted++
            next
        }
        { print }
        END { exit !(inserted == 1) }
    ' "$observable_source" > "$observable_manager" || return 1
    chmod 700 "$observable_manager" || return 1
    /bin/ash -n "$observable_manager"
}

# MS02 must retain the canonical argv that controller owner validation accepts.
# First add MS08's real release_lock observation, then wrap only the cleanup
# lease-release branch and atomically install that private production copy at
# the canonical path. The event is emitted only after the real release returns.
make_ms02_observable_manager() {
    ms02_lock_observed=$SCRIPTS/manager-ms02-lock-observed.sh
    ms02_observed=$SCRIPTS/manager-ms02-observed.sh
    make_ms08_observable_manager "$SCRIPTS/backup-manager.sh" "$ms02_lock_observed" || return 1
    [ "$(grep -F -c -- 'if ! service_lease_release; then' "$ms02_lock_observed")" -eq 3 ] || return 1
    awk '
        $0 == "\trelease_lock" { after_release_lock = 1 }
        after_release_lock && $0 == "\tif ! service_lease_release; then" {
            print "\tif service_lease_release; then"
            print "\t\tprintf \"service-lease-release manager=%s\\n\" \"$$\" >> \"${TEST_MS08_EVENTS:?}\""
            print "\telse"
            wrapped++
            next
        }
        { print }
        END { exit !(wrapped == 1) }
    ' "$ms02_lock_observed" > "$ms02_observed" || return 1
    chmod 700 "$ms02_observed" || return 1
    /bin/ash -n "$ms02_observed" || return 1
    mv "$ms02_observed" "$SCRIPTS/backup-manager.sh"
}

# The manager writes the authoritative release event synchronously. It may exit
# immediately afterward, so either a recorded event or completed manager is a
# valid wakeup; the caller separately verifies the exact event and final lock.
wait_ms08_business_unlock() {
    watched_pid=$1
    watched_lock=$2
    event_file=$3
    elapsed=0
    while [ "$elapsed" -lt 20 ]; do
        grep -F -x -q "business-unlock manager=$watched_pid" "$event_file" && return 0
        process_state=$(awk '{print $3}' "/proc/$watched_pid/stat" 2>/dev/null || :)
        [ -z "$process_state" ] || [ "$process_state" = Z ] || [ "$process_state" = X ] && break
        /bin/sleep 1
        elapsed=$((elapsed + 1))
    done
    [ ! -e "$watched_lock" ] && [ ! -L "$watched_lock" ]
}

# The MS08 source event is written by its private umount wrapper after the shared
# stub performed the operation. Waiting only accommodates process scheduling; it
# never manufactures an event from the observed counter.
wait_ms08_event() {
    expected_event=$1
    event_file=$2
    watched_pid=$3
    label=$4
    elapsed=0
    while [ "$elapsed" -lt 20 ]; do
        grep -F -x -q "$expected_event" "$event_file" && return 0
        kill -0 "$watched_pid" 2>/dev/null || {
            fail "$label exited before recording [$expected_event]"
            return 1
        }
        /bin/sleep 1
        elapsed=$((elapsed + 1))
    done
    fail "$label did not record [$expected_event]"
    return 1
}

start_ms08_manager_service() {
    manager_output=$1
    manager_program=$2
    (
        trap - INT
        TEST_MANAGER_SERVICE_READY="$TEST_ROOT/manager.ready" \
        TEST_MANAGER_SERVICE_RELEASE="$TEST_ROOT/manager.release" \
        TEST_MANAGER_SERVICE_RSYNC_PID="$TEST_ROOT/rsync.pid" \
        TEST_MS08_EVENTS="$TEST_ROOT/ms08.events" \
        TEST_MS08_CANCEL="$TEST_ROOT/ms08.cancel" \
        TEST_MS08_RELEASED="$TEST_ROOT/ms08.released" \
        TEST_MS08_UMOUNT_BASE="$BIN/umount.ms08-base" \
        MANAGER_SCRIPT="$manager_program" TEST_MOUNT_AUTO_CARD=1 TEST_RUN_MANAGER_EXEC=1 \
        run_manager add sda1 /devices/mock >"$manager_output" 2>&1
    ) &
    MANAGER_PID=$!
    track_pid "$MANAGER_PID"
}

# On an MS08 setup failure, release only its own writer and wait for only its
# own manager. This prevents the suite EXIT trap from inheriting a held writer.
abort_ms08_transfer_control() {
    control_label=$1
    : > "$TEST_ROOT/manager.release" 2>/dev/null || :
    if [ -n "${MANAGER_PID:-}" ]; then
        if wait_pid_bounded "$MANAGER_PID" 20; then
            abort_manager_rc=0
        else
            abort_manager_rc=$?
        fi
        persist_evidence_value "ms08/$control_label.abort-manager.rc" "$abort_manager_rc" || \
            fail "MS08 $control_label cannot persist bounded cleanup rc"
    fi
}

case_ms01_admission_partitions_and_fast_paths() {
    begin_case MS01 'running admission accepts legacy and matching epochs while rejected modes have no manager effects'
    prepare_service_case || { fail 'MS01 fixture setup failed'; return; }
    assert_success 'MS01 private target-open observer is syntactically valid' \
        make_target_open_observable_manager "$TEST_ROOT/target-open.events"
    MANAGER_SCRIPT="$SCRIPTS/manager-target-open-observable.sh" TEST_MOUNT_AUTO_CARD=1 \
        assert_success 'MS01 legacy running add succeeds' run_manager add sda1 /devices/mock
    assert_contains 'rsync' "$EFFECTS" 'MS01 legacy add reached the real transfer path'
    assert_contains 'target-open completed' "$TEST_ROOT/target-open.events" \
        'MS01 legacy add executes the real target-open guard observer'

    prepare_service_case || { fail 'MS01 matching fixture setup failed'; return; }
    assert_success 'MS01 matching target-open observer is syntactically valid' \
        make_target_open_observable_manager "$TEST_ROOT/target-open.events"
    OUTDOOR_BACKUP_SERVICE_GENERATION=0 MANAGER_SCRIPT="$SCRIPTS/manager-target-open-observable.sh" \
        TEST_MOUNT_AUTO_CARD=1 assert_success 'MS01 matching epoch add succeeds' run_manager add sda1 /devices/mock

    # Invalid explicit values are library errors (1); a legal stale value is a
    # normal non-admission (2). Neither is allowed to reach target or source.
    for invalid_generation in '' invalid 01 2147483648; do
        prepare_service_case || { fail 'MS01 invalid fixture setup failed'; return; }
        assert_success "MS01 invalid generation [$invalid_generation] target-open observer is syntactically valid" \
            make_target_open_observable_manager "$TEST_ROOT/target-open.events"
        OUTDOOR_BACKUP_SERVICE_GENERATION=$invalid_generation \
            MANAGER_SCRIPT="$SCRIPTS/manager-target-open-observable.sh" run_manager add sda1 /devices/mock \
            >"$TEST_ROOT/reject.out" 2>&1
        assert_equal "$?" 1 "MS01 invalid generation [$invalid_generation] returns state-error rc one"
        assert_contains 'service state error' "$TEST_ROOT/reject.out" \
            "MS01 invalid generation [$invalid_generation] emits state-error marker"
        assert_file_absent "$TEST_ROOT/target-open.events" \
            "MS01 invalid generation [$invalid_generation] does not enter target guard"
        assert_not_contains 'mount mode=' "$EFFECTS" "MS01 invalid generation [$invalid_generation] has no source mount"
        assert_file_absent "$RUNTIME/var/status.json" "MS01 invalid generation [$invalid_generation] has no status"
    done

    prepare_service_case || { fail 'MS01 mismatch fixture setup failed'; return; }
    assert_success 'MS01 mismatch target-open observer is syntactically valid' \
        make_target_open_observable_manager "$TEST_ROOT/target-open.events"
    OUTDOOR_BACKUP_SERVICE_GENERATION=1 MANAGER_SCRIPT="$SCRIPTS/manager-target-open-observable.sh" \
        run_manager add sda1 /devices/mock >"$TEST_ROOT/reject.out" 2>&1
    assert_equal "$?" 2 'MS01 legal mismatched generation returns admission rc two'
    assert_contains 'service admission not admitted' "$TEST_ROOT/reject.out" 'MS01 mismatch emits admission marker'
    assert_file_absent "$TEST_ROOT/target-open.events" 'MS01 mismatch does not enter target guard'
    assert_not_contains 'mount mode=' "$EFFECTS" 'MS01 mismatch has no source mount'
    assert_file_absent "$RUNTIME/var/status.json" 'MS01 mismatch has no status'

    prepare_service_case || { fail 'MS01 stopped fixture setup failed'; return; }
    service_state_write_fixture 'stopped:0'
    assert_success 'MS01 stopped target-open observer is syntactically valid' \
        make_target_open_observable_manager "$TEST_ROOT/target-open.events"
    MANAGER_SCRIPT="$SCRIPTS/manager-target-open-observable.sh" run_manager add sda1 /devices/mock \
        >"$TEST_ROOT/stopped.out" 2>&1
    assert_equal "$?" 2 'MS01 stopped state returns admission rc two'
    assert_file_absent "$TEST_ROOT/target-open.events" 'MS01 stopped state does not enter target guard'
    assert_not_contains 'mount mode=' "$EFFECTS" 'MS01 stopped state has no source side effect'
    assert_file_absent "$RUNTIME/var/lock/backup.lock" 'MS01 stopped state has no business lock'

    # Red control: deleting only service admission/current semantics allows a
    # stopped service to reach the real target-open guard and a real source mount.
    prepare_service_case || { fail 'MS01 Red fixture setup failed'; return; }
    service_state_write_fixture 'stopped:0'
    assert_success 'MS01 Red private target-open observer is syntactically valid' \
        make_target_open_observable_manager "$TEST_ROOT/target-open.events"
    assert_success 'MS01 Red private no-admission mutant is syntactically valid' \
        make_no_service_admission_mutant "$SCRIPTS/manager-target-open-observable.sh" \
        "$SCRIPTS/manager-no-service-admission.sh"
    MANAGER_SCRIPT="$SCRIPTS/manager-no-service-admission.sh" TEST_MOUNT_AUTO_CARD=1 \
        run_manager add sda1 /devices/mock >"$TEST_ROOT/red.out" 2>&1
    red_rc=$?
    red_mount_count=$(grep -c '^mount mode=' "$EFFECTS")
    red_service_error_count=$(grep -c 'service \(admission\|state\) error' "$TEST_ROOT/red.out" || :)
    assert_contains 'target-open completed' "$TEST_ROOT/target-open.events" \
        'MS01 Red stopped mutant reaches the real target-open guard'
    assert_equal "$red_mount_count" 1 'MS01 Red stopped mutant incorrectly reaches source mount'
    persist_evidence_value red/no-service-admission.rc "$red_rc" || fail 'MS01 Red cannot persist final rc'
    persist_evidence_value red/source-mount-count "$red_mount_count" || fail 'MS01 Red cannot persist source mount oracle'
    persist_evidence_value red/service-error-count "$red_service_error_count" || fail 'MS01 Red cannot persist service diagnostic count'
    persist_evidence_file red/no-service-admission.out "$TEST_ROOT/red.out" || fail 'MS01 Red cannot persist diagnostic'

    # The existing fast paths must not require the service library at all.
    prepare_service_case || { fail 'MS01 fast-path fixture setup failed'; return; }
    rm -f "$SCRIPTS/service-state.sh"
    assert_success 'MS01 legacy remove remains a no-op without service library' run_manager remove sda1 /devices/mock
    printf 'ENABLED=0\n' >> "$RUNTIME/conf/backup.conf"
    assert_success 'MS01 disabled add remains a no-op without service library' run_manager add sda1 /devices/mock
}

case_ms02_stop_real_manager_and_writer() {
    begin_case MS02 'controller closes state but remains pending until the real writer drains and cleanup releases FD8'
    prepare_service_case || { fail 'MS02 fixture setup failed'; return; }
    TEST_MS08_EVENTS="$TEST_ROOT/ms02.events"
    TEST_MS08_CANCEL="$TEST_ROOT/ms02.cancel"
    TEST_MS08_RELEASED="$TEST_ROOT/ms02.released"
    TEST_MS08_UMOUNT_BASE="$BIN/umount.ms08-base"
    TEST_MS02_WRITER_PID_FILE="$TEST_ROOT/rsync.pid"
    export TEST_MS08_EVENTS TEST_MS08_CANCEL TEST_MS08_RELEASED TEST_MS08_UMOUNT_BASE TEST_MS02_WRITER_PID_FILE
    : > "$TEST_MS08_EVENTS" || { fail 'MS02 event evidence setup failed'; return; }
    assert_success 'MS02 canonical manager has one real cleanup lease-release observer' make_ms02_observable_manager
    assert_success 'MS02 source cleanup installs the existing real umount event seam' \
        install_ms08_source_umount_event_seam
    install_ms08_transfer_barrier || { fail 'MS02 writer hold setup failed'; return; }
    start_manager_service "$TEST_ROOT/manager.out"
    wait_path "$TEST_ROOT/manager.ready" "$MANAGER_PID" 'MS02 real manager' || return
    assert_success 'MS02 real rsync child is ready' test -s "$TEST_ROOT/rsync.pid"
    ms02_writer_pid=$(cat "$TEST_ROOT/rsync.pid")
    tr '\000' '\n' < "/proc/$MANAGER_PID/cmdline" > "$TEST_ROOT/manager.argv"
    assert_equal "$(tr '\n' ' ' < "$TEST_ROOT/manager.argv")" \
        "/bin/ash $SCRIPTS/backup-manager.sh add sda1 /devices/mock " \
        'MS02 manager uses the controller canonical five-slot add argv'
    ms02_source_umount_before=$(cat "$TEST_ROOT/source-umount-count" 2>/dev/null || printf 0)
    run_controller_background "$TEST_ROOT/controller.out"
    wait_file_value "$SERVICE_RUNTIME/state" stopped:0 "$CONTROLLER_PID" 'MS02 controller closes state' || return
    assert_equal "$(cat "$SERVICE_RUNTIME/state")" stopped:0 'MS02 real controller closes the service before stop completion'
    wait_path "$TEST_MS08_CANCEL" "$MANAGER_PID" 'MS02 writer cancellation' || return
    assert_success 'MS02 controller cancellation targets the real writer session' \
        grep -F -x "pid=$ms02_writer_pid signal=TERM" "$TEST_MS08_CANCEL"
    assert_success 'MS02 writer remains live in explicit hold after controller closes state' \
        ms08_capture_live_writer_stat "$ms02_writer_pid" "$TEST_ROOT/ms02.writer.hold.stat"
    assert_success 'MS02 controller remains pending while the real writer holds its S lease' kill -0 "$CONTROLLER_PID"
    if admission_x_probe; then
        ms02_before_x_rc=0
    else
        ms02_before_x_rc=$?
    fi
    assert_equal "$ms02_before_x_rc" 2 'MS02 held S lease blocks X after controller has closed state'
    : > "$TEST_ROOT/manager.release"
    wait_path "$TEST_MS08_RELEASED" "$MANAGER_PID" 'MS02 writer release' || return
    assert_success 'MS02 writer release marker identifies the held writer' \
        grep -F -x "pid=$ms02_writer_pid" "$TEST_MS08_RELEASED"
    ms02_source_umount_after=$((ms02_source_umount_before + 1))
    wait_file_value "$TEST_ROOT/source-umount-count" "$ms02_source_umount_after" "$MANAGER_PID" \
        'MS02 source cleanup' || return
    ms02_source_event="source-umount count=$ms02_source_umount_after lock=[/proc/$MANAGER_PID]"
    assert_success 'MS02 source unmount records the still-held business lock' \
        grep -F -x "$ms02_source_event" "$TEST_MS08_EVENTS"
    wait_ms08_business_unlock "$MANAGER_PID" "$RUNTIME/var/lock/backup.lock" "$TEST_MS08_EVENTS" || {
        fail 'MS02 manager did not finish real business-lock cleanup'
        return
    }
    assert_success 'MS02 business lock releases only after source cleanup' \
        test ! -e "$RUNTIME/var/lock/backup.lock" -a ! -L "$RUNTIME/var/lock/backup.lock"
    assert_success 'MS02 manager records successful explicit lease release after data cleanup' \
        grep -F -x "service-lease-release manager=$MANAGER_PID" "$TEST_MS08_EVENTS"
    if wait_pid "$MANAGER_PID" 20 'MS02 manager'; then
        ms02_manager_rc=0
    else
        ms02_manager_rc=$?
    fi
    if wait_pid "$CONTROLLER_PID" 20 'MS02 controller'; then
        ms02_controller_rc=0
    else
        ms02_controller_rc=$?
    fi
    assert_equal "$ms02_manager_rc" 143 'MS02 real manager exits with cancellation code 143'
    assert_equal "$ms02_controller_rc" 0 'MS02 controller succeeds only after quiescence'
    assert_contains 'stop completed after quiescence' "$TEST_ROOT/controller.out" \
        'MS02 real controller emits completion only after quiescence'
    assert_not_contains 'Backup completed successfully' "$RUNTIME/log/backup.log" 'MS02 cancellation never writes completed'
    assert_success 'MS02 records writer drain, source cleanup, unlock, and lease release in order' \
        ms02_cleanup_order_is_exact "$ms02_writer_pid" "$MANAGER_PID" "$ms02_source_event" "$TEST_MS08_EVENTS"
    persist_evidence_value ms02/manager.rc "$ms02_manager_rc" || fail 'MS02 cannot persist manager rc'
    persist_evidence_value ms02/controller.rc "$ms02_controller_rc" || fail 'MS02 cannot persist controller rc'
    persist_evidence_file ms02/events "$TEST_MS08_EVENTS" || fail 'MS02 cannot persist lifecycle events'
    persist_evidence_file ms02/controller.out "$TEST_ROOT/controller.out" || fail 'MS02 cannot persist controller diagnostic'
}

start_ms03_waiter() {
    waiter_output=$1
    waiter_program=$2
    waiter_attempt=$3
    waiter_acquired=$4
    TEST_LOCK_ATTEMPT_MARKER="$waiter_attempt" \
        TEST_LOCK_ACQUIRED_MARKER="$waiter_acquired" \
        LOCK_TIMEOUT=30 LOCK_INTERVAL=1 TEST_SLEEP_PASSTHROUGH=1 \
        TEST_MOUNT_AUTO_CARD=1 MANAGER_SCRIPT="$waiter_program" TEST_RUN_MANAGER_EXEC=1 \
        run_manager add sda1 /devices/mock >"$waiter_output" 2>&1 &
    B_PID=$!
    track_pid "$B_PID"
}

prepare_ms03_owner_and_waiter() {
    prepare_service_case || return 1
    install_ms03_owner_transfer_barrier || return 1
    TEST_MS03_OWNER_EVENTS="$TEST_ROOT/ms03-owner.events"
    TEST_MS03_OWNER_CANCEL="$TEST_ROOT/ms03-owner.cancel"
    TEST_MS03_OWNER_RELEASE="$TEST_ROOT/ms03-owner.release"
    export TEST_MS03_OWNER_EVENTS TEST_MS03_OWNER_CANCEL TEST_MS03_OWNER_RELEASE
    : > "$TEST_MS03_OWNER_EVENTS" || return 1
    start_manager_service "$TEST_ROOT/a.out"
    wait_path "$TEST_ROOT/manager.ready" "$MANAGER_PID" 'MS03 owner A' || return 1
    A_PID=$MANAGER_PID
    assert_equal "$(readlink "$RUNTIME/var/lock/backup.lock")" "/proc/$A_PID" \
        'MS03 A owns the real business lock before B starts'
}

verify_ms03_owner_holding_after_stop() {
    wait_path "$TEST_MS03_OWNER_CANCEL" "$A_PID" 'MS03 owner writer cancellation' || return 1
    assert_equal "$(cat "$TEST_MS03_OWNER_CANCEL")" "pid=$(cat "$TEST_ROOT/rsync.pid") signal=TERM" \
        'MS03 controller cancellation reaches the real A writer before B result'
    assert_equal "$(readlink "$RUNTIME/var/lock/backup.lock")" "/proc/$A_PID" \
        'MS03 A retains the business lock after writer cancellation'
}

close_ms03_and_wait_for_b() {
    run_controller_background "$TEST_ROOT/controller.out"
    wait_file_value "$SERVICE_RUNTIME/state" stopped:0 "$CONTROLLER_PID" 'MS03 controller' || return 1
    assert_success 'MS03 controller remains waiting while A owns the business lock' kill -0 "$CONTROLLER_PID"
    verify_ms03_owner_holding_after_stop || return 1
    if wait_pid "$B_PID" 10 'MS03 queued B'; then
        b_rc=0
    else
        b_rc=$?
    fi
}

finish_ms03_owner_and_controller() {
    : > "$TEST_MS03_OWNER_RELEASE"
    if wait_pid "$A_PID" 20 'MS03 owner A'; then
        a_rc=0
    else
        a_rc=$?
    fi
    if wait_pid "$CONTROLLER_PID" 20 'MS03 controller'; then
        controller_rc=0
    else
        controller_rc=$?
    fi
    persist_evidence_file "ms03/controller-$A_PID.out" "$TEST_ROOT/controller.out" || \
        fail 'MS03 cannot persist controller diagnostic'
    persist_evidence_value "ms03/controller-$A_PID.a.rc" "$a_rc" || \
        fail 'MS03 cannot persist owner exit code'
    persist_evidence_value "ms03/controller-$A_PID.controller.rc" "$controller_rc" || \
        fail 'MS03 cannot persist controller exit code'
    persist_evidence_file "ms03/controller-$A_PID.state" "$SERVICE_RUNTIME/state" || \
        fail 'MS03 cannot persist stopped state'
    unset TEST_MS03_OWNER_EVENTS TEST_MS03_OWNER_CANCEL TEST_MS03_OWNER_RELEASE
}

case_ms03_waiter_current_gate() {
    begin_case MS03 'a queued real manager notices stopped state before it acquires the business lock'

    # Baseline: B has reached a failed real ln(1) lock attempt while A remains the
    # active transfer owner. Closing service must stop B before A is released.
    prepare_ms03_owner_and_waiter || { fail 'MS03 baseline fixture setup failed'; return; }
    start_ms03_waiter "$TEST_ROOT/b.out" "$SCRIPTS/backup-manager.sh" \
        "$TEST_ROOT/b.lock-attempt" "$TEST_ROOT/b.lock-acquired"
    wait_path "$TEST_ROOT/b.lock-attempt" "$B_PID" 'MS03 queued B lock attempt' || return
    assert_equal "$(cat "$TEST_ROOT/b.lock-attempt")" \
        "manager=$B_PID lock=[$RUNTIME/var/lock/backup.lock]" \
        'MS03 B marker identifies its failed business-lock attempt'
    assert_success 'MS03 B remains queued after its failed lock attempt' kill -0 "$B_PID"
    assert_equal "$(readlink "$RUNTIME/var/lock/backup.lock")" "/proc/$A_PID" \
        'MS03 A remains the business-lock owner while B waits'
    close_ms03_and_wait_for_b || return
    assert_equal "$b_rc" 143 'MS03 B observes service closure while waiting'
    assert_contains 'service no longer current' "$TEST_ROOT/b.out" \
        'MS03 B fails at the shared lease-current gate, not at lock timeout'
    assert_file_absent "$TEST_ROOT/b.lock-acquired" 'MS03 B never acquired A business lock'
    ms03_mount_count=$(grep -c '^mount mode=' "$EFFECTS")
    assert_equal "$ms03_mount_count" 1 'MS03 waiter B never mounts source media'
    assert_success 'MS03 controller still waits for A after B has exited' kill -0 "$CONTROLLER_PID"
    persist_ms03_waiter_evidence ms03 "$b_rc" "$TEST_ROOT/b.out" "$TEST_ROOT/b.lock-attempt" \
        'alive-before-a-release'
    finish_ms03_owner_and_controller
    assert_equal "$a_rc" 143 'MS03 A receives controller cancellation after B result is known'
    assert_equal "$controller_rc" 0 'MS03 controller succeeds only after A releases lease and lock'

    # Mutation control: deleting only acquire_lock's cancellation gate leaves B
    # alive until the watchdog, proving the preceding B-specific oracle is real.
    prepare_ms03_owner_and_waiter || { fail 'MS03 mutant fixture setup failed'; return; }
    assert_success 'MS03 private waiter-gate mutant is syntactically valid' \
        make_no_waiter_current_gate_mutant
    start_ms03_waiter "$TEST_ROOT/mutant-b.out" "$SCRIPTS/manager-no-waiter-current-gate.sh" \
        "$TEST_ROOT/mutant-b.lock-attempt" "$TEST_ROOT/mutant-b.lock-acquired"
    wait_path "$TEST_ROOT/mutant-b.lock-attempt" "$B_PID" 'MS03 mutant B lock attempt' || return
    assert_equal "$(readlink "$RUNTIME/var/lock/backup.lock")" "/proc/$A_PID" \
        'MS03 mutant B remains behind the real A business lock'
    run_controller_background "$TEST_ROOT/controller.out"
    wait_file_value "$SERVICE_RUNTIME/state" stopped:0 "$CONTROLLER_PID" 'MS03 mutant controller' || return
    assert_success 'MS03 mutant controller remains waiting while A owns the business lock' kill -0 "$CONTROLLER_PID"
    verify_ms03_owner_holding_after_stop || return
    if wait_pid_bounded "$B_PID" 10; then
        b_rc=0
    else
        b_rc=$?
    fi
    assert_failure 'MS03 B cancellation oracle rejects waiter-gate mutant' test "$b_rc" -eq 143
    assert_equal "$b_rc" 124 'MS03 waiter-gate mutant exceeds bounded B watchdog'
    assert_file_absent "$TEST_ROOT/mutant-b.lock-acquired" 'MS03 mutant B never obtains A business lock'
    assert_success 'MS03 mutant controller still waits for A' kill -0 "$CONTROLLER_PID"
    persist_ms03_waiter_evidence ms03/mutant "$b_rc" "$TEST_ROOT/mutant-b.out" \
        "$TEST_ROOT/mutant-b.lock-attempt" 'alive-before-a-release'
    finish_ms03_owner_and_controller
    assert_equal "$a_rc" 143 'MS03 mutant control still cancels A'
    assert_equal "$controller_rc" 0 'MS03 mutant controller exits after A cleanup'

    # Boundary regression: force B into the final acquire_lock sleep while A
    # still owns the lock. Current production is expected to fail this assertion
    # with rc=1; the future single-point production fix must make it 143.
    prepare_ms03_owner_and_waiter || { fail 'MS03 last-sleep fixture setup failed'; return; }
    assert_success 'MS03 private last-sleep barrier manager is syntactically valid' \
        make_last_lock_sleep_barrier_manager
    TEST_LOCK_LAST_SLEEP_READY="$TEST_ROOT/last-sleep.ready"
    TEST_LOCK_LAST_SLEEP_RELEASE="$TEST_ROOT/last-sleep.release"
    export TEST_LOCK_LAST_SLEEP_READY TEST_LOCK_LAST_SLEEP_RELEASE
    TEST_LOCK_ATTEMPT_MARKER="$TEST_ROOT/last-sleep.lock-attempt" \
        TEST_LOCK_ACQUIRED_MARKER="$TEST_ROOT/last-sleep.lock-acquired" \
        LOCK_TIMEOUT=2 LOCK_INTERVAL=1 TEST_SLEEP_PASSTHROUGH=1 \
        TEST_MOUNT_AUTO_CARD=1 MANAGER_SCRIPT="$SCRIPTS/manager-last-lock-sleep-barrier.sh" \
        TEST_RUN_MANAGER_EXEC=1 run_manager add sda1 /devices/mock >"$TEST_ROOT/last-sleep-b.out" 2>&1 &
    B_PID=$!
    track_pid "$B_PID"
    wait_path "$TEST_ROOT/last-sleep.lock-attempt" "$B_PID" 'MS03 last-sleep B lock attempt' || return
    wait_path "$TEST_ROOT/last-sleep.ready" "$B_PID" 'MS03 last-sleep B barrier' || return
    assert_contains "manager=$B_PID elapsed=1 timeout=2" "$TEST_ROOT/last-sleep.ready" \
        'MS03 last-sleep marker is the final acquire_lock iteration'
    assert_equal "$(readlink "$RUNTIME/var/lock/backup.lock")" "/proc/$A_PID" \
        'MS03 A retains the business lock through B final sleep'
    run_controller_background "$TEST_ROOT/controller.out"
    wait_file_value "$SERVICE_RUNTIME/state" stopped:0 "$CONTROLLER_PID" 'MS03 last-sleep controller' || return
    assert_success 'MS03 last-sleep controller remains waiting for A' kill -0 "$CONTROLLER_PID"
    verify_ms03_owner_holding_after_stop || return
    : > "$TEST_ROOT/last-sleep.release"
    if wait_pid "$B_PID" 10 'MS03 last-sleep B'; then
        b_rc=0
    else
        b_rc=$?
    fi
    assert_equal "$b_rc" 143 'MS03 final acquire_lock sleep observes stopped service before timeout'
    assert_contains 'service no longer current' "$TEST_ROOT/last-sleep-b.out" \
        'MS03 final-sleep B reports closure instead of lock timeout'
    assert_file_absent "$TEST_ROOT/last-sleep.lock-acquired" 'MS03 final-sleep B never acquires A business lock'
    assert_equal "$(grep -c '^mount mode=' "$EFFECTS")" 1 \
        'MS03 final-sleep B has no source side effect'
    assert_success 'MS03 final-sleep controller still waits for A' kill -0 "$CONTROLLER_PID"
    persist_ms03_waiter_evidence ms03/last-sleep "$b_rc" "$TEST_ROOT/last-sleep-b.out" \
        "$TEST_ROOT/last-sleep.lock-attempt" 'alive-before-a-release'
    persist_evidence_file ms03/last-sleep/final-sleep-ready "$TEST_ROOT/last-sleep.ready" || \
        fail 'MS03 cannot persist final-sleep readiness marker'
    finish_ms03_owner_and_controller
    assert_equal "$a_rc" 143 'MS03 final-sleep control cancels A after B result'
    assert_equal "$controller_rc" 0 'MS03 final-sleep controller exits after A cleanup'
    unset TEST_LOCK_LAST_SLEEP_READY TEST_LOCK_LAST_SLEEP_RELEASE
}

make_prelock_lease_barrier_manager() {
    prelock_manager=$SCRIPTS/manager-prelock-lease-barrier.sh
    awk '
        $0 == "\tif ! SOURCE_IDENTITY_SNAPSHOT=$(source_identity_read \"$DEVNAME\"); then" {
            print "\tprintf \047manager=%s\\n\047 \"$$\" > \"${TEST_PRELOCK_READY:?}\""
            print "\twhile [ ! -e \"${TEST_PRELOCK_RELEASE:?}\" ]; do /bin/sleep 1; done"
            inserted++
        }
        { print }
        END { exit !(inserted == 1) }
    ' "$SCRIPTS/backup-manager.sh" > "$prelock_manager" || return 1
    chmod 700 "$prelock_manager" || return 1
    /bin/ash -n "$prelock_manager"
}

case_ms04_prelock_lease_blocks_stop() {
    begin_case MS04 'a pre-business-lock admission lease blocks successful stop until the manager exits'
    prepare_service_case || { fail 'MS04 fixture setup failed'; return; }
    assert_success 'MS04 private prelock barrier manager is syntactically valid' \
        make_prelock_lease_barrier_manager
    TEST_PRELOCK_READY="$TEST_ROOT/prelock.ready"
    TEST_PRELOCK_RELEASE="$TEST_ROOT/prelock.release"
    export TEST_PRELOCK_READY TEST_PRELOCK_RELEASE
    MANAGER_SCRIPT="$SCRIPTS/manager-prelock-lease-barrier.sh" TEST_RUN_MANAGER_EXEC=1 \
        run_manager add sda1 /devices/mock >"$TEST_ROOT/prelock.out" 2>&1 &
    MANAGER_PID=$!
    track_pid "$MANAGER_PID"
    wait_path "$TEST_ROOT/prelock.ready" "$MANAGER_PID" 'MS04 prelock manager readiness' || return
    assert_equal "$(cat "$TEST_ROOT/prelock.ready")" "manager=$MANAGER_PID" \
        'MS04 prelock marker identifies the live manager owning its S lease'
    assert_success 'MS04 prelock manager remains alive at its barrier' kill -0 "$MANAGER_PID"
    if admission_x_probe; then
        prelock_x_rc=0
    else
        prelock_x_rc=$?
    fi
    assert_equal "$prelock_x_rc" 2 'MS04 prelock manager holds real admission S lease before stop'
    run_controller_background "$TEST_ROOT/controller.out"
    wait_file_value "$SERVICE_RUNTIME/state" stopped:0 "$CONTROLLER_PID" 'MS04 controller' || return
    assert_success 'MS04 controller remains blocked on prelock S lease' kill -0 "$CONTROLLER_PID"
    : > "$TEST_ROOT/prelock.release"
    if wait_pid "$MANAGER_PID" 20 'MS04 prelock manager'; then
        manager_rc=0
    else
        manager_rc=$?
    fi
    if wait_pid "$CONTROLLER_PID" 20 'MS04 controller'; then
        controller_rc=0
    else
        controller_rc=$?
    fi
    assert_equal "$manager_rc" 143 'MS04 prelock manager fails closed after released barrier'
    assert_equal "$controller_rc" 0 'MS04 controller succeeds only after S lease release'
    persist_evidence_value ms04/manager.rc "$manager_rc" || fail 'MS04 cannot persist manager exit oracle'
    persist_evidence_file ms04/manager.out "$TEST_ROOT/prelock.out" || fail 'MS04 cannot persist manager diagnostic'
    persist_evidence_file ms04/ready "$TEST_ROOT/prelock.ready" || fail 'MS04 cannot persist ready marker'
    persist_evidence_value ms04/service-state "$(cat "$SERVICE_RUNTIME/state")" || fail 'MS04 cannot persist closed state'
    persist_evidence_value ms04/business-lock "$(readlink "$RUNTIME/var/lock/backup.lock" 2>/dev/null || :)" || \
        fail 'MS04 cannot persist lock identity'
    persist_evidence_value ms04/controller-wait 'alive-before-prelock-release' || \
        fail 'MS04 cannot persist controller wait oracle'
    unset TEST_PRELOCK_READY TEST_PRELOCK_RELEASE
}

# Capture a real timer process identity. A PID alone is not liveness evidence:
# it may be a zombie or have been reused. The starttime makes the before/after
# comparison an identity check, while the state excludes both zombie and dead.
ms05_capture_live_timer_stat() {
    timer_pid=$1
    timer_stat_file=$2
    : > "$timer_stat_file" || return 1
    awk '{printf "pid=%s state=%s starttime=%s\n", $1, $3, $22}' \
        "/proc/$timer_pid/stat" > "$timer_stat_file" 2>/dev/null || return 1
    grep -E -q -x "pid=$timer_pid state=[^ZX] starttime=[0-9]+" "$timer_stat_file"
}

ms05_timer_starttime() {
    awk -F '[ =]' '{print $6}' "$1"
}

# This mutation is deliberately limited to the original FD8 owner branch:
# closing the parent's descriptor preserves the inherited OFD lock if a child
# still owns it, unlike production's flock -u. The manager otherwise remains
# the delivered manager with only its source-only state library redirected.
make_ms05_parent_close_only_lease_manager() {
    mutant_state=$SCRIPTS/service-state-parent-close-only.sh
    mutant_manager=$SCRIPTS/manager-ms05-parent-close-only.sh
    state_anchor='    flock -u 8 || return 1'
    [ "$(grep -F -c -- "$state_anchor" "$SCRIPTS/service-state.sh")" -eq 1 ] || return 1
    [ "$(awk '$0 == ". \"$SCRIPT_DIR/service-state.sh\"" { matches++ } END { print matches + 0 }' \
        "$SCRIPTS/backup-manager.sh")" -eq 1 ] || return 1
    awk '
        $0 == "    flock -u 8 || return 1" { removed++; next }
        { print }
        END { exit !(removed == 1) }
    ' "$SCRIPTS/service-state.sh" > "$mutant_state" || return 1
    /bin/ash -n "$mutant_state" || return 1
    awk '
        $0 == ". \"$SCRIPT_DIR/service-state.sh\"" {
            print ". \"$SCRIPT_DIR/service-state-parent-close-only.sh\""
            replaced++
            next
        }
        { print }
        END { exit !(replaced == 1) }
    ' "$SCRIPTS/backup-manager.sh" > "$mutant_manager" || return 1
    chmod 700 "$mutant_manager" || return 1
    /bin/ash -n "$mutant_manager"
}

case_ms05_guard_failure_releases_inherited_lease() {
    begin_case MS05 'guard failure unlocks FD8 while the same live LED timer remains held'
    prepare_service_case || { fail 'MS05 fixture setup failed'; return; }
    set_config_target_uuid WRONG-UUID
    TEST_TIMER_CONTROLLED=1
    export TEST_TIMER_CONTROLLED
    if run_manager add sda1 /devices/mock >"$TEST_ROOT/guard.out" 2>&1; then
        guard_rc=0
    else
        guard_rc=$?
    fi
    assert_equal "$guard_rc" 1 'MS05 normal guard failure preserves failure status'
    assert_success 'MS05 normal inherited LED timer reached controlled wait' \
        wait_path "$TEST_ROOT/timer-ready" $$ 'MS05 normal timer'
    timer_pid=$(cat "$TEST_ROOT/timer-pid")
    assert_success 'MS05 normal timer is live before X' \
        ms05_capture_live_timer_stat "$timer_pid" "$TEST_ROOT/normal.timer.before.stat"
    assert_file_absent "$TEST_ROOT/timer-release" 'MS05 normal timer remains unreleased before X'
    if admission_x_probe; then
        normal_before_x_rc=0
    else
        normal_before_x_rc=$?
    fi
    assert_equal "$normal_before_x_rc" 0 'MS05 normal explicit release permits X while timer is live'
    assert_success 'MS05 normal timer remains live after first X' \
        ms05_capture_live_timer_stat "$timer_pid" "$TEST_ROOT/normal.timer.after.stat"
    assert_equal "$(ms05_timer_starttime "$TEST_ROOT/normal.timer.before.stat")" \
        "$(ms05_timer_starttime "$TEST_ROOT/normal.timer.after.stat")" \
        'MS05 normal X sees the same timer instance before and after admission'
    assert_file_absent "$TEST_ROOT/timer-release" 'MS05 normal timer remains unreleased after first X'
    if admission_x_probe; then
        normal_after_x_rc=0
    else
        normal_after_x_rc=$?
    fi
    assert_equal "$normal_after_x_rc" 0 'MS05 normal independent second X remains available'
    persist_evidence_value ms05/normal.guard.rc "$guard_rc" || fail 'MS05 cannot persist normal guard rc'
    persist_evidence_value ms05/normal.x-before.rc "$normal_before_x_rc" || fail 'MS05 cannot persist normal pre-X rc'
    persist_evidence_value ms05/normal.x-after.rc "$normal_after_x_rc" || fail 'MS05 cannot persist normal post-X rc'
    persist_evidence_file ms05/normal.timer.before.stat "$TEST_ROOT/normal.timer.before.stat" || \
        fail 'MS05 cannot persist normal pre-X timer stat'
    persist_evidence_file ms05/normal.timer.after.stat "$TEST_ROOT/normal.timer.after.stat" || \
        fail 'MS05 cannot persist normal post-X timer stat'
    : > "$TEST_ROOT/timer-release"
    assert_success 'MS05 normal explicit release settles its timer' settle_led_fixture

    # Negative control: retain a live timer after the parent closes FD8 but does
    # not unlock its OFD. If the actual timer inherited FD8, X must see ordinary
    # contention (2); if it did not, the persisted evidence records that fact.
    prepare_service_case || { fail 'MS05 mutant fixture setup failed'; return; }
    assert_success 'MS05 private parent-close-only lease state is syntactically valid' \
        make_ms05_parent_close_only_lease_manager
    set_config_target_uuid WRONG-UUID
    MANAGER_SCRIPT="$SCRIPTS/manager-ms05-parent-close-only.sh" TEST_TIMER_CONTROLLED=1 \
        run_manager add sda1 /devices/mock >"$TEST_ROOT/mutant-guard.out" 2>&1
    mutant_guard_rc=$?
    assert_equal "$mutant_guard_rc" 1 'MS05 parent-close-only mutant preserves guard failure status'
    assert_success 'MS05 mutant inherited LED timer reached controlled wait' \
        wait_path "$TEST_ROOT/timer-ready" $$ 'MS05 mutant timer'
    mutant_timer_pid=$(cat "$TEST_ROOT/timer-pid")
    assert_success 'MS05 mutant timer is live before X' \
        ms05_capture_live_timer_stat "$mutant_timer_pid" "$TEST_ROOT/mutant.timer.before.stat"
    assert_file_absent "$TEST_ROOT/timer-release" 'MS05 mutant timer remains unreleased before X'
    if admission_x_probe; then
        mutant_x_rc=0
    else
        mutant_x_rc=$?
    fi
    assert_failure 'MS05 normal X=0 predicate rejects close-only OFD mutant' test "$mutant_x_rc" -eq 0
    assert_equal "$mutant_x_rc" 2 'MS05 live timer inherits FD8 and keeps the close-only OFD lease busy'
    assert_success 'MS05 mutant timer remains live through rejected X' \
        ms05_capture_live_timer_stat "$mutant_timer_pid" "$TEST_ROOT/mutant.timer.after.stat"
    assert_equal "$(ms05_timer_starttime "$TEST_ROOT/mutant.timer.before.stat")" \
        "$(ms05_timer_starttime "$TEST_ROOT/mutant.timer.after.stat")" \
        'MS05 mutant X sees the same timer instance before and after contention'
    persist_evidence_value ms05/mutant.guard.rc "$mutant_guard_rc" || fail 'MS05 cannot persist mutant guard rc'
    persist_evidence_value ms05/mutant.x.rc "$mutant_x_rc" || fail 'MS05 cannot persist mutant X rc'
    persist_evidence_file ms05/mutant.timer.before.stat "$TEST_ROOT/mutant.timer.before.stat" || \
        fail 'MS05 cannot persist mutant pre-X timer stat'
    persist_evidence_file ms05/mutant.timer.after.stat "$TEST_ROOT/mutant.timer.after.stat" || \
        fail 'MS05 cannot persist mutant post-X timer stat'
    : > "$TEST_ROOT/timer-release"
    assert_success 'MS05 mutant explicit release settles its timer' settle_led_fixture
    unset TEST_TIMER_CONTROLLED
}

case_ms06_epoch_restart_rejects_old_manager() {
    begin_case MS06 'old expected generation cannot proceed after real stop/start while a new expected generation can'
    prepare_service_case || { fail 'MS06 fixture setup failed'; return; }
    captured_expected_generation=${SERVICE_RUNTIME:+$(cat "$SERVICE_RUNTIME/state")}
    captured_expected_generation=${captured_expected_generation#running:}
    assert_equal "$captured_expected_generation" 0 'MS06 captures the pre-stop expected generation from the live runtime'

    service_control_env /bin/ash "$SCRIPTS/service-control.sh" stop >"$TEST_ROOT/stop.out" 2>&1
    assert_equal "$?" 0 'MS06 real controller stops generation zero'
    assert_equal "$(cat "$SERVICE_RUNTIME/state")" 'stopped:0' 'MS06 real stop closes generation zero'
    service_control_env /bin/ash "$SCRIPTS/service-control.sh" start >"$TEST_ROOT/start.out" 2>&1
    assert_equal "$?" 0 'MS06 real controller starts the next generation'
    assert_equal "$(cat "$SERVICE_RUNTIME/state")" 'running:1' 'MS06 real stop/start advances epoch without fixture rewrite'

    assert_success 'MS06 private target-open observer is syntactically valid' \
        make_target_open_observable_manager "$TEST_ROOT/old-target-open.events"
    OUTDOOR_BACKUP_SERVICE_GENERATION=$captured_expected_generation \
        MANAGER_SCRIPT="$SCRIPTS/manager-target-open-observable.sh" \
        run_manager add sda1 /devices/mock >"$TEST_ROOT/old.out" 2>&1
    old_rc=$?
    assert_equal "$old_rc" 2 'MS06 old expected generation is rejected after the real restart'
    assert_contains 'service admission not admitted' "$TEST_ROOT/old.out" \
        'MS06 old request reports the admission rejection'
    assert_file_absent "$TEST_ROOT/old-target-open.events" \
        'MS06 old request cannot enter the target guard'
    assert_not_contains 'mount mode=' "$EFFECTS" 'MS06 old request has no source mount'
    assert_file_absent "$RUNTIME/var/status.json" 'MS06 old request writes no status'
    assert_file_absent "$TARGET_MOUNT/backups" 'MS06 old request creates no target root'

    OUTDOOR_BACKUP_SERVICE_GENERATION=1 TEST_MOUNT_AUTO_CARD=1 \
        MANAGER_SCRIPT="$SCRIPTS/manager-target-open-observable.sh" \
        run_manager add sda1 /devices/mock >"$TEST_ROOT/new.out" 2>&1
    assert_equal "$?" 0 'MS06 new expected generation is admitted in the same runtime'

    # Red control: retain the actual running state and all target/source code, but
    # bypass only expected-epoch equality. The normal rc=2 oracle above therefore
    # distinguishes the deleted generation predicate from a fabricated restart.
    assert_success 'MS06 private expected-generation mutant is syntactically valid' \
        make_no_expected_generation_mutant
    mutant_mount_count_before=$(grep -c '^mount mode=' "$EFFECTS")
    OUTDOOR_BACKUP_SERVICE_GENERATION=$captured_expected_generation \
        MANAGER_SCRIPT="$SCRIPTS/manager-no-expected-generation.sh" TEST_MOUNT_AUTO_CARD=1 \
        run_manager add sda1 /devices/mock >"$TEST_ROOT/mutant-old.out" 2>&1
    mutant_old_rc=$?
    mutant_mount_count_after=$(grep -c '^mount mode=' "$EFFECTS")
    assert_failure 'MS06 old-generation rejection oracle rejects expected-generation mutant' \
        test "$mutant_old_rc" -eq 2
    assert_equal "$mutant_old_rc" 0 'MS06 expected-generation mutant wrongly admits old request'
    assert_contains 'target-open completed' "$TEST_ROOT/old-target-open.events" \
        'MS06 expected-generation mutant enters the real target guard'
    assert_equal "$mutant_mount_count_after" "$((mutant_mount_count_before + 1))" \
        'MS06 expected-generation mutant reaches the real source mount'
}

# Copy the existing logger behind a case-local wrapper. At precisely the primary
# backup log call it uses the real state API to write stopped:<same-generation>
# under FD7 control, then execs the unchanged fixture logger so its existing INT
# seam signals the actual foreground manager PID.
install_ms07_closing_signal_logger() {
    ms07_base_logger=$BIN/logger.ms07-base
    cp "$BIN/logger" "$ms07_base_logger" || return 1
    cat > "$BIN/logger" <<'EOF'
#!/bin/sh
case "$*" in
    *"${TEST_MS07_LOGGER_MATCH:?}"*)
        . "${TEST_MS07_STATE_LIBRARY:?}" || exit 1
        service_control_acquire || exit 1
        service_state_read || { service_control_release || :; exit 1; }
        ms07_generation=$SERVICE_STATE_GENERATION
        service_state_write stopped "$ms07_generation" || { service_control_release || :; exit 1; }
        service_control_release || exit 1
        printf 'manager=%s state=stopped:%s\n' "$PPID" "$ms07_generation" > \
            "${TEST_MS07_STATE_CLOSED:?}"
        ;;
esac
exec "${TEST_MS07_LOGGER_BASE:?}" "$@"
EOF
    chmod 755 "$BIN/logger" || return 1
    /bin/ash -n "$BIN/logger"
}

# The observation wrapper calls the real function unchanged and records only the
# selected safe boundary after the logger has closed service state. Its lease
# probe is read-only; it must not acquire, release, or replace the held lease.
make_ms07_observable_safe_boundary_manager() {
    observable_manager=$SCRIPTS/manager-ms07-observable.sh
    boundary_anchor=$(printf '\tlog_info "Starting PRIMARY backup: SD → SSD ($BACKUP_DISPLAY_NAME)"')
    check_anchor='check_cancel_request() {'
    [ "$(grep -F -c -- "$boundary_anchor" "$SCRIPTS/backup-manager.sh")" -eq 1 ] || return 1
    [ "$(grep -F -c -- "$check_anchor" "$SCRIPTS/backup-manager.sh")" -eq 1 ] || return 1
    awk '
        $0 == "check_cancel_request() {" {
            print "check_cancel_request_actual() {"
            while ((getline check_line) > 0) {
                print check_line
                if (check_line == "}") break
            }
            print ""
            print "check_cancel_request() {"
            print "\tms07_before_cancel=${BACKUP_CANCEL_CODE:-0}"
            print "\tservice_lease_current"
            print "\tms07_lease_rc=$?"
            print "\tcheck_cancel_request_actual"
            print "\tms07_check_rc=$?"
            print "\tif [ -e \"${TEST_MS07_STATE_CLOSED:?}\" ]; then"
            print "\t\tprintf \"before-cancel=%s lease-current=%s returned=%s\\n\" \"$ms07_before_cancel\" \"$ms07_lease_rc\" \"$ms07_check_rc\" > \"${TEST_MS07_CHECK_EVIDENCE:?}\""
            print "\tfi"
            print "\treturn \"$ms07_check_rc\""
            print "}"
            wrapped++
            next
        }
        $0 == "\tlog_info \"Starting PRIMARY backup: SD → SSD ($BACKUP_DISPLAY_NAME)\"" {
            print
            print "\tcheck_cancel_request || exit \"$?\""
            inserted++
            next
        }
        { print }
        END { exit !(wrapped == 1 && inserted == 1) }
    ' "$SCRIPTS/backup-manager.sh" > "$observable_manager" || return 1
    chmod 700 "$observable_manager" || return 1
    /bin/ash -n "$observable_manager"
}

# Delete only check_cancel_request's sticky early return in the private wrapper.
# Its real service-current fallback remains, so it exposes 143 at the same safe
# boundary without changing the state, lease, logger, or cleanup implementation.
make_ms07_no_sticky_cancel_mutant() {
    mutant_manager=$SCRIPTS/manager-ms07-no-sticky-cancel.sh
    [ "$(grep -F -c -- 'check_cancel_request_actual() {' "$SCRIPTS/manager-ms07-observable.sh")" -eq 1 ] || return 1
    awk '
        $0 == "\tif [ \"$cancel_code\" -ne 0 ]; then" {
            if ((getline line_one) < 1 || line_one != "\t\tERROR_TYPE=cancelled") exit 1
            if ((getline line_two) < 1 || line_two != "\t\treturn \"$cancel_code\"") exit 1
            if ((getline line_three) < 1 || line_three != "\tfi") exit 1
            removed++
            next
        }
        { print }
        END { exit !(removed == 1) }
    ' "$SCRIPTS/manager-ms07-observable.sh" > "$mutant_manager" || return 1
    chmod 700 "$mutant_manager" || return 1
    /bin/ash -n "$mutant_manager"
}

run_ms07_signal_precedence_control() {
    control_label=$1
    prepare_service_case || { fail "MS07 $control_label fixture setup failed"; return 1; }
    case "$control_label" in
        normal)
            assert_success 'MS07 normal private observable manager is syntactically valid' \
                make_ms07_observable_safe_boundary_manager
            manager_program=$SCRIPTS/manager-ms07-observable.sh
            ;;
        mutant)
            assert_success 'MS07 mutant private observable manager is syntactically valid' \
                make_ms07_observable_safe_boundary_manager
            assert_success 'MS07 private no-sticky mutant is syntactically valid' \
                make_ms07_no_sticky_cancel_mutant
            manager_program=$SCRIPTS/manager-ms07-no-sticky-cancel.sh
            ;;
        *) fail "MS07 unknown signal-precedence control [$control_label]"; return 1 ;;
    esac
    install_ms07_closing_signal_logger || { fail "MS07 $control_label logger wrapper setup failed"; return 1; }
    TEST_MS07_LOGGER_MATCH='Starting PRIMARY backup'
    TEST_MS07_LOGGER_SIGNAL=INT
    TEST_MS07_STATE_LIBRARY="$SCRIPTS/service-state.sh"
    TEST_MS07_LOGGER_BASE="$BIN/logger.ms07-base"
    TEST_MS07_STATE_CLOSED="$TEST_ROOT/ms07.state-closed"
    TEST_MS07_CHECK_EVIDENCE="$TEST_ROOT/ms07.check"
    export TEST_MS07_LOGGER_MATCH TEST_MS07_LOGGER_SIGNAL TEST_MS07_STATE_LIBRARY \
        TEST_MS07_LOGGER_BASE TEST_MS07_STATE_CLOSED TEST_MS07_CHECK_EVIDENCE
    if TEST_LOGGER_SIGNAL_MATCH="$TEST_MS07_LOGGER_MATCH" TEST_LOGGER_SIGNAL="$TEST_MS07_LOGGER_SIGNAL" \
        TEST_MOUNT_AUTO_CARD=1 MANAGER_SCRIPT="$manager_program" \
        run_manager add sda1 /devices/mock >"$TEST_ROOT/$control_label.int.out" 2>&1; then
        ms07_manager_rc=0
    else
        ms07_manager_rc=$?
    fi
    assert_equal "$(cat "$SERVICE_RUNTIME/state")" stopped:0 \
        "MS07 $control_label real state API closes the same generation"
    assert_contains "manager=" "$TEST_ROOT/ms07.state-closed" \
        "MS07 $control_label state-closure evidence identifies manager"
    assert_contains 'state=stopped:0' "$TEST_ROOT/ms07.state-closed" \
        "MS07 $control_label records stopped generation zero"
    assert_contains 'before-cancel=130 lease-current=2' "$TEST_ROOT/ms07.check" \
        "MS07 $control_label records native sticky INT after closed state"
    persist_evidence_value "ms07/$control_label.manager.rc" "$ms07_manager_rc" || \
        fail "MS07 $control_label cannot persist manager rc"
    persist_evidence_file "ms07/$control_label.state-closed" "$TEST_ROOT/ms07.state-closed" || \
        fail "MS07 $control_label cannot persist state closure"
    persist_evidence_file "ms07/$control_label.check" "$TEST_ROOT/ms07.check" || \
        fail "MS07 $control_label cannot persist safe-boundary record"
    persist_evidence_file "ms07/$control_label.notices" "$NOTICES" || \
        fail "MS07 $control_label cannot persist sticky INT notice"
    persist_evidence_file "ms07/$control_label.out" "$TEST_ROOT/$control_label.int.out" || \
        fail "MS07 $control_label cannot persist manager diagnostic"
    unset TEST_MS07_LOGGER_MATCH TEST_MS07_LOGGER_SIGNAL TEST_MS07_STATE_LIBRARY \
        TEST_MS07_LOGGER_BASE TEST_MS07_STATE_CLOSED TEST_MS07_CHECK_EVIDENCE
}

case_ms07_signal_precedence_and_release() {
    begin_case MS07 'state closure plus native INT preserves 130 at the next safe boundary'

    # The normal manager's added private boundary must return the recorded INT,
    # not the closed-service fallback 143. This foreground run avoids ignored
    # background INT disposition; the existing logger seam targets its real PPID.
    run_ms07_signal_precedence_control normal || return
    assert_equal "$ms07_manager_rc" 130 'MS07 normal manager returns real sticky INT 130'
    assert_contains 'Cancellation requested (exit code 130)' "$MANAGER_SERVICE_ROOT/ms07/normal.notices" \
        'MS07 normal logger records the actual INT cancellation'
    assert_contains 'returned=130' "$MANAGER_SERVICE_ROOT/ms07/normal.check" \
        'MS07 normal next safe boundary returns sticky INT rather than lease 143'

    # Negative control: only the sticky branch is removed. The exact same closed
    # state and real INT make the observable boundary return the fallback 143;
    # final cleanup may still preserve 130 and is deliberately not this oracle.
    run_ms07_signal_precedence_control mutant || return
    assert_failure 'MS07 normal safe-boundary 130 predicate rejects no-sticky mutant' \
        grep -F -x -q 'before-cancel=130 lease-current=2 returned=130' "$MANAGER_SERVICE_ROOT/ms07/mutant.check"
    assert_contains 'returned=143' "$MANAGER_SERVICE_ROOT/ms07/mutant.check" \
        'MS07 no-sticky mutant falls back to closed-service 143 at the same boundary'
    assert_equal "$ms07_manager_rc" 130 'MS07 mutant final cleanup retains original sticky INT 130'

    prepare_service_case || { fail 'MS07 TERM fixture setup failed'; return; }
    install_transfer_barrier || { fail 'MS07 barrier setup failed'; return; }
    start_manager_service "$TEST_ROOT/term.out"
    wait_path "$TEST_ROOT/manager.ready" "$MANAGER_PID" 'MS07 TERM manager' || return
    kill -TERM "$MANAGER_PID"
    : > "$TEST_ROOT/manager.release"
    if wait_pid "$MANAGER_PID" 20 'MS07 TERM manager'; then
        term_rc=0
    else
        term_rc=$?
    fi
    assert_equal "$term_rc" 143 'MS07 sticky TERM stays 143 after service closure'

    prepare_service_case || { fail 'MS07 release fixture setup failed'; return; }
    TEST_MOUNT_AUTO_CARD=1 assert_success 'MS07 normal manager succeeds' run_manager add sda1 /devices/mock
    if admission_x_probe; then
        normal_x_rc=0
    else
        normal_x_rc=$?
    fi
    assert_equal "$normal_x_rc" 0 'MS07 normal cleanup explicitly releases lease'
}

admission_x_probe() {
    service_control_env /bin/ash -c '
        . "$1"
        service_admission_exclusive
        probe_rc=$?
        [ "$probe_rc" -ne 0 ] || service_lease_release
        exit "$probe_rc"
    ' ash "$SCRIPTS/service-state.sh"
}

# A required MS08 observation is both an assertion and a hard case boundary:
# continuing after a failed setup would turn absent files into stale-or-unset rc.
require_ms08() {
    required_message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    "$@" && return 0
    fail "$required_message"
    return 1
}

ms08_event_precedes() {
    earlier_event=$1
    later_event=$2
    event_file=$3
    earlier_line=$(grep -n -F -x -- "$earlier_event" "$event_file" | sed -n '1s/:.*//p')
    later_line=$(grep -n -F -x -- "$later_event" "$event_file" | sed -n '1s/:.*//p')
    [ -n "$earlier_line" ] && [ -n "$later_line" ] && [ "$earlier_line" -lt "$later_line" ]
}

ms08_cleanup_order_is_exact() {
    writer_pid=$1
    manager_pid=$2
    manager_rc=$3
    source_event=$4
    event_file=$5
    ms08_event_precedes "writer-release pid=$writer_pid" "$source_event" "$event_file" && \
        ms08_event_precedes "$source_event" "business-unlock manager=$manager_pid" "$event_file" && \
        ms08_event_precedes "business-unlock manager=$manager_pid" \
            "manager-exit manager=$manager_pid rc=$manager_rc" "$event_file"
}

# MS02's drain proof is emitted by the source-unmount wrapper before it delegates
# to the shared stub, so this ordering binds actual dead-writer observation to the
# source cleanup boundary rather than treating the writer's own exit marker as it.
ms02_cleanup_order_is_exact() {
    writer_pid=$1
    manager_pid=$2
    source_event=$3
    event_file=$4
    ms02_drain_line=$(grep -n -E "^writer-drained pid=$writer_pid state=(Z|X|absent)$" "$event_file" | sed -n '1s/:.*//p')
    ms02_source_line=$(grep -n -F -x -- "$source_event" "$event_file" | sed -n '1s/:.*//p')
    ms02_unlock_line=$(grep -n -F -x -- "business-unlock manager=$manager_pid" "$event_file" | sed -n '1s/:.*//p')
    ms02_release_line=$(grep -n -F -x -- "service-lease-release manager=$manager_pid" "$event_file" | sed -n '1s/:.*//p')
    [ -n "$ms02_drain_line" ] && [ -n "$ms02_source_line" ] && \
        [ -n "$ms02_unlock_line" ] && [ -n "$ms02_release_line" ] && \
        [ "$ms02_drain_line" -lt "$ms02_source_line" ] && \
        [ "$ms02_source_line" -lt "$ms02_unlock_line" ] && \
        [ "$ms02_unlock_line" -lt "$ms02_release_line" ]
}

persist_ms08_events() {
    control_label=$1
    control_events=$2
    persist_evidence_file "ms08/$control_label.events" "$control_events" || \
        fail "MS08 $control_label cannot persist exact event order"
}

run_ms08_transfer_control() {
    control_label=$1
    control_manager_rc=1
    control_before_x_rc=1
    control_after_x_rc=1
    control_source_umount_before=0
    mkdir -p "$MANAGER_SERVICE_ROOT/ms08" || { fail "MS08 $control_label cannot create evidence"; return 1; }

    prepare_service_case || { fail "MS08 $control_label fixture setup failed"; return 1; }
    control_events="$TEST_ROOT/ms08.events"
    TEST_MS08_EVENTS="$control_events"
    TEST_MS08_CANCEL="$TEST_ROOT/ms08.cancel"
    TEST_MS08_RELEASED="$TEST_ROOT/ms08.released"
    export TEST_MS08_EVENTS TEST_MS08_CANCEL TEST_MS08_RELEASED
    install_ms08_transfer_barrier || { fail "MS08 $control_label writer fixture setup failed"; return 1; }
    install_ms08_source_umount_event_seam || {
        fail "MS08 $control_label source-cleanup event seam setup failed"
        return 1
    }
    case "$control_label" in
        normal)
            if ! require_ms08 'MS08 private normal manager has exactly one valid release observation seam' \
                make_ms08_observable_manager "$SCRIPTS/backup-manager.sh" \
                "$SCRIPTS/manager-ms08-normal.sh"; then
                return 1
            fi
            control_manager=$SCRIPTS/manager-ms08-normal.sh
            ;;
        mutant)
            # Generate the existing semantic mutation first. Its release_lock
            # call site remains the sole anchor for the common observation seam.
            if ! require_ms08 'MS08 private early-release mutant has exactly one valid mutation' \
                make_early_release_mutant; then
                return 1
            fi
            if ! require_ms08 'MS08 private mutant manager has exactly one valid release observation seam' \
                make_ms08_observable_manager "$SCRIPTS/manager-early-lease-release.sh" \
                "$SCRIPTS/manager-ms08-early-lease-release.sh"; then
                return 1
            fi
            control_manager=$SCRIPTS/manager-ms08-early-lease-release.sh
            ;;
        *) fail "MS08 unknown transfer control [$control_label]"; return 1 ;;
    esac
    : > "$control_events" || { fail "MS08 $control_label cannot initialize event evidence"; return 1; }
    persist_ms08_events "$control_label" "$control_events"
    start_ms08_manager_service "$TEST_ROOT/$control_label.manager.out" "$control_manager"
    if ! wait_path "$TEST_ROOT/manager.ready" "$MANAGER_PID" "MS08 $control_label manager"; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    if ! require_ms08 "MS08 $control_label writer PID is recorded" test -s "$TEST_ROOT/rsync.pid"; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    rsync_pid=$(cat "$TEST_ROOT/rsync.pid")
    persist_evidence_value "ms08/$control_label.writer.pid" "$rsync_pid" || \
        fail "MS08 $control_label cannot persist writer PID"
    if ms08_capture_live_writer_stat "$rsync_pid" "$TEST_ROOT/ms08.writer.ready.stat"; then
        writer_ready_rc=0
    else
        writer_ready_rc=$?
    fi
    persist_ms08_writer_identity "$control_label" ready "$TEST_ROOT/ms08.writer.ready.stat"
    if ! require_ms08 "MS08 $control_label writer is a live private-session leader" \
        test "$writer_ready_rc" -eq 0; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    if ! require_ms08 "MS08 $control_label writer ready marker identifies its live PID" \
        grep -F -x "pid=$rsync_pid" "$TEST_ROOT/manager.ready"; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    persist_evidence_file "ms08/$control_label.writer.ready" "$TEST_ROOT/manager.ready" || \
        fail "MS08 $control_label cannot persist writer ready marker"
    if ! require_ms08 "MS08 $control_label writer has no premature release marker" \
        test ! -e "$TEST_ROOT/ms08.released"; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    control_source_umount_before=$(cat "$TEST_ROOT/source-umount-count" 2>/dev/null || printf 0)
    kill -TERM "$MANAGER_PID" || { fail "MS08 $control_label cannot signal manager TERM"; abort_ms08_transfer_control "$control_label"; return 1; }
    printf 'manager-term-sent manager=%s\n' "$MANAGER_PID" >> "$control_events"
    persist_ms08_events "$control_label" "$control_events"
    if ! wait_path "$TEST_ROOT/ms08.cancel" "$MANAGER_PID" "MS08 $control_label writer cancellation"; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    if ! require_ms08 "MS08 $control_label cancellation marker belongs to writer PID" \
        grep -F -x "pid=$rsync_pid signal=TERM" "$TEST_ROOT/ms08.cancel"; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    persist_evidence_file "ms08/$control_label.writer.cancel" "$TEST_ROOT/ms08.cancel" || \
        fail "MS08 $control_label cannot persist writer cancellation marker"
    if ms08_capture_live_writer_stat "$rsync_pid" "$TEST_ROOT/ms08.writer.hold.stat"; then
        writer_hold_rc=0
    else
        writer_hold_rc=$?
    fi
    persist_ms08_writer_identity "$control_label" hold "$TEST_ROOT/ms08.writer.hold.stat"
    if ! require_ms08 "MS08 $control_label writer remains a live private-session leader in hold" \
        test "$writer_hold_rc" -eq 0; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    if ! require_ms08 "MS08 $control_label writer remains unreleased before X probe" \
        test ! -e "$TEST_ROOT/manager.release"; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    if admission_x_probe; then control_before_x_rc=0; else control_before_x_rc=$?; fi
    printf 'before-x-rc=%s\n' "$control_before_x_rc" >> "$control_events"
    persist_ms08_events "$control_label" "$control_events"
    persist_evidence_value "ms08/$control_label.before-x.rc" "$control_before_x_rc" || \
        fail "MS08 $control_label cannot persist pre-drain X rc"
    : > "$TEST_ROOT/manager.release"
    printf 'barrier-released writer=%s\n' "$rsync_pid" >> "$control_events"
    persist_ms08_events "$control_label" "$control_events"
    if ! wait_path "$TEST_ROOT/ms08.released" "$MANAGER_PID" "MS08 $control_label writer release"; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    if ! require_ms08 "MS08 $control_label release marker identifies writer PID" \
        grep -F -x "pid=$rsync_pid" "$TEST_ROOT/ms08.released"; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    persist_evidence_file "ms08/$control_label.writer.release" "$TEST_ROOT/ms08.released" || \
        fail "MS08 $control_label cannot persist writer release marker"
    control_source_umount_after=$((control_source_umount_before + 1))
    if ! wait_file_value "$TEST_ROOT/source-umount-count" "$control_source_umount_after" "$MANAGER_PID" \
        "MS08 $control_label source cleanup"; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    control_source_event="source-umount count=$control_source_umount_after lock=[/proc/$MANAGER_PID]"
    if ! require_ms08 "MS08 $control_label source cleanup retains the current business lock" \
        grep -F -x "$control_source_event" "$EFFECTS"; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    if ! wait_ms08_event "$control_source_event" "$control_events" "$MANAGER_PID" \
        "MS08 $control_label source cleanup"; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    persist_ms08_events "$control_label" "$control_events"
    if ! wait_ms08_business_unlock "$MANAGER_PID" "$RUNTIME/var/lock/backup.lock" "$control_events"; then
        fail "MS08 $control_label manager neither recorded business unlock nor completed"
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    if ! require_ms08 "MS08 $control_label manager records its own exact business-unlock PID" \
        grep -F -x "business-unlock manager=$MANAGER_PID" "$control_events"; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    if ! require_ms08 "MS08 $control_label business lock is absent after its manager release" \
        test ! -e "$RUNTIME/var/lock/backup.lock" -a ! -L "$RUNTIME/var/lock/backup.lock"; then
        abort_ms08_transfer_control "$control_label"
        return 1
    fi
    persist_ms08_events "$control_label" "$control_events"
    if wait_pid "$MANAGER_PID" 20 "MS08 $control_label manager"; then control_manager_rc=0; else control_manager_rc=$?; fi
    printf 'manager-exit manager=%s rc=%s\n' "$MANAGER_PID" "$control_manager_rc" >> "$control_events"
    persist_ms08_events "$control_label" "$control_events"
    if admission_x_probe; then control_after_x_rc=0; else control_after_x_rc=$?; fi
    printf 'after-x-rc=%s\n' "$control_after_x_rc" >> "$control_events"
    persist_ms08_events "$control_label" "$control_events"
    persist_evidence_value "ms08/$control_label.manager.rc" "$control_manager_rc" || \
        fail "MS08 $control_label cannot persist manager rc"
    persist_evidence_value "ms08/$control_label.after-x.rc" "$control_after_x_rc" || \
        fail "MS08 $control_label cannot persist post-drain X rc"
    persist_evidence_file "ms08/$control_label.manager.out" "$TEST_ROOT/$control_label.manager.out" || \
        fail "MS08 $control_label cannot persist manager diagnostic"
    persist_evidence_file "ms08/$control_label.events" "$control_events" || \
        fail "MS08 $control_label cannot persist exact event order"
    persist_evidence_file "ms08/$control_label.effects" "$EFFECTS" || \
        fail "MS08 $control_label cannot persist source cleanup evidence"
    if ! require_ms08 "MS08 $control_label records exact writer-release cleanup order" \
        ms08_cleanup_order_is_exact "$rsync_pid" "$MANAGER_PID" "$control_manager_rc" \
        "$control_source_event" "$control_events"; then
        return 1
    fi
    case "$control_label" in
        normal)
            MS08_NORMAL_BEFORE_X_RC=$control_before_x_rc
            MS08_NORMAL_MANAGER_RC=$control_manager_rc
            MS08_NORMAL_AFTER_X_RC=$control_after_x_rc
            ;;
        mutant)
            MS08_MUTANT_BEFORE_X_RC=$control_before_x_rc
            MS08_MUTANT_MANAGER_RC=$control_manager_rc
            MS08_MUTANT_AFTER_X_RC=$control_after_x_rc
            ;;
    esac
    return 0
}

case_ms08_release_after_data_cleanup() {
    begin_case MS08 'normal lease blocks X until writer drain; private early-release mutant violates that exact predicate'
    MS08_NORMAL_BEFORE_X_RC=
    MS08_NORMAL_MANAGER_RC=
    MS08_NORMAL_AFTER_X_RC=
    MS08_MUTANT_BEFORE_X_RC=
    MS08_MUTANT_MANAGER_RC=
    MS08_MUTANT_AFTER_X_RC=

    # Baseline: a separate X observer cannot enter while the real writer remains
    # held at the same barrier. This is deliberately not controller stop: its
    # business-lock gate is a distinct contract and remains untouched here.
    run_ms08_transfer_control normal || return
    assert_equal "$MS08_NORMAL_BEFORE_X_RC" 2 'MS08 normal lease remains busy while writer has not drained'
    assert_equal "$MS08_NORMAL_MANAGER_RC" 143 'MS08 normal owner exits with cancellation status'
    assert_equal "$MS08_NORMAL_AFTER_X_RC" 0 'MS08 normal lease becomes available only after cleanup'

    # Private negative control: exactly one production cleanup release is moved
    # into record_cancel, before transfer_process_run drains its writer session.
    run_ms08_transfer_control mutant || return
    assert_failure 'MS08 normal pre-drain busy predicate rejects early-release mutant' \
        test "$MS08_MUTANT_BEFORE_X_RC" -eq 2
    assert_equal "$MS08_MUTANT_BEFORE_X_RC" 0 'MS08 mutant wrongly admits X while writer is still alive'
    assert_equal "$MS08_MUTANT_MANAGER_RC" 143 'MS08 mutant still drains and returns cancellation status'
    assert_equal "$MS08_MUTANT_AFTER_X_RC" 0 'MS08 mutant remains available after drain'
}

preserve_failure_fixture() {
    # The normal evidence is already persisted case-by-case. On failure retain
    # only the aggregate count; never copy fixture mounts, device data, or runtime.
    persist_evidence_value suite/failed-count "$FAILED" 2>/dev/null || :
}

main() {
    trap 'preserve_failure_fixture; cleanup_pids; settle_led_fixture; unmount_target; rm -rf "$SUITE_ROOT" /opt/outdoor-backup/conf' EXIT INT TERM
    mkdir -p "$MANAGER_SERVICE_ROOT" || exit 1
    case_ms01_admission_partitions_and_fast_paths
    case_ms02_stop_real_manager_and_writer
    case_ms03_waiter_current_gate
    case_ms04_prelock_lease_blocks_stop
    case_ms05_guard_failure_releases_inherited_lease
    case_ms06_epoch_restart_rejects_old_manager
    case_ms07_signal_precedence_and_release
    case_ms08_release_after_data_cleanup
    assert_equal "$CASES" "$EXPECTED_CASES" 'all required manager service cases executed'
    assert_equal "$ASSERTIONS" "$((EXPECTED_ASSERTIONS - 1))" \
        'all required manager service assertions executed exactly'
    printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
    [ "$FAILED" -eq 0 ]
}

main "$@"

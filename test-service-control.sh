#!/bin/sh
#
# BDD integration tests for service-control.sh. The host runs this suite only
# in a pinned OpenWrt rootfs; production sources remain read-only under /src.
# Each case makes a private runtime mirror so its manager, lock, and owner
# fixtures cannot affect an installed service or any other test.
#
set -u

SCRIPT_REL='files/opt/outdoor-backup/scripts'
ARM_IMAGE='openwrt/rootfs:aarch64_generic-24.10.8'
ARM_DIGEST='sha256:f6dd33c1d9b7d6f1e0848f2fbb92b8d03fc9b425dc08c3574a44936b93133704'
X86_IMAGE='openwrt/rootfs:x86_64-24.10.8'
X86_DIGEST='sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9'

if [ "${1:-}" != '--inside' ]; then
    REPO_ROOT=$(dirname -- "$0")
    EVIDENCE_ROOT=$(mktemp -d /tmp/outdoor-backup-service-control.XXXXXX) || exit 1
    case "$(uname -m)" in
        arm64|aarch64) image=$ARM_IMAGE; digest=$ARM_DIGEST; platform='linux/aarch64_generic' ;;
        *) image=$X86_IMAGE; digest=$X86_DIGEST; platform='linux/amd64' ;;
    esac
    image_ref="$image@$digest"
    docker run --rm --cidfile "$EVIDENCE_ROOT/container.id" --platform "$platform" --tmpfs /tmp:rw,exec \
        -e TEST_EVIDENCE=/evidence -v "$REPO_ROOT:/src:ro" -v "$EVIDENCE_ROOT:/evidence" \
        "$image_ref" /bin/ash /src/test-service-control.sh --inside \
        >"$EVIDENCE_ROOT/suite.stdout" 2>"$EVIDENCE_ROOT/suite.stderr" &
    docker_client_pid=$!
    docker_elapsed=0
    while kill -0 "$docker_client_pid" 2>/dev/null; do
        docker_state=$(ps -o stat= -p "$docker_client_pid" 2>/dev/null | tr -d ' ')
        [ "$docker_state" = Z ] && break
        if [ "$docker_elapsed" -ge 180 ]; then
            printf '%s\n' 'FAIL: outer Docker BDD watchdog exceeded 180s' >&2
            [ -r "$EVIDENCE_ROOT/container.id" ] && docker stop "$(cat "$EVIDENCE_ROOT/container.id")" >/dev/null 2>&1 || :
            wait "$docker_client_pid" 2>/dev/null || :
            exit 124
        fi
        sleep 1
        docker_elapsed=$((docker_elapsed + 1))
    done
    wait "$docker_client_pid"
    suite_rc=$?
    cat "$EVIDENCE_ROOT/suite.stdout"
    cat "$EVIDENCE_ROOT/suite.stderr" >&2
    printf 'evidence=%s\n' "$EVIDENCE_ROOT"
    exit "$suite_rc"
fi

[ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || {
    printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
    exit 1
}
mkdir -p /var/lock || { printf '%s\n' 'FAIL: cannot create OpenWrt package lock directory' >&2; exit 1; }
opkg update >/dev/null || { printf '%s\n' 'FAIL: cannot refresh OpenWrt package metadata' >&2; exit 1; }
opkg install --force-space jq flock >/dev/null || {
    printf '%s\n' 'FAIL: cannot install jq and flock in pinned OpenWrt rootfs' >&2
    exit 1
}
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || {
    printf '%s\n' 'FAIL: jq or flock missing after installation' >&2
    exit 1
}

REPO_ROOT=/src
SOURCE_DIR="$REPO_ROOT/$SCRIPT_REL"
SOURCE_CONTROL="$SOURCE_DIR/service-control.sh"
SUITE_ROOT="${TEST_EVIDENCE:?}/runtime"
CASES=0
ASSERTIONS=0
FAILED=0
EXPECTED_CASES=16
EXPECTED_ASSERTIONS=119
ACTIVE_PIDS=''

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
    if "$@"; then fail "$message (unexpected success)"; fi
}

assert_absent() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "$2"
}

track_pid() { ACTIVE_PIDS="$ACTIVE_PIDS $1"; }

cleanup_processes() {
    for pid in $ACTIVE_PIDS; do
        kill -TERM "$pid" 2>/dev/null || :
        wait "$pid" 2>/dev/null || :
    done
    ACTIVE_PIDS=''
}

cleanup() {
    cleanup_processes
}

wait_ready() {
    ready_path=$1 pid=$2 label=$3 attempt=0
    while [ "$attempt" -lt 15 ]; do
        [ -e "$ready_path" ] && return 0
        if ! kill -0 "$pid" 2>/dev/null; then
            fail "$label exited before readiness"
            wait "$pid" 2>/dev/null || :
            return 1
        fi
        /bin/sleep 1
        attempt=$((attempt + 1))
    done
    fail "$label did not become ready"
    return 1
}

wait_path() {
    watched_path=$1 pid=$2 label=$3 attempt=0
    while [ "$attempt" -lt 15 ]; do
        [ -e "$watched_path" ] && return 0
        kill -0 "$pid" 2>/dev/null || { fail "$label exited before path appeared"; return 1; }
        /bin/sleep 1
        attempt=$((attempt + 1))
    done
    fail "$label did not create expected path"
    return 1
}

prepare_case() {
    case_name=$1
    cleanup_processes
    CASE_ROOT="$SUITE_ROOT/$case_name"
    RUNTIME_ROOT="$CASE_ROOT/runtime"
    RUNTIME_SCRIPTS="$RUNTIME_ROOT/opt/outdoor-backup/scripts"
    RUNTIME_SERVICE="$RUNTIME_ROOT/var/run/outdoor-backup"
    RUNTIME_RC="$RUNTIME_ROOT/etc/rc.d"
    RUNTIME_INIT="$RUNTIME_ROOT/etc/init.d/outdoor-backup"
    BUSINESS_LOCK="$RUNTIME_ROOT/opt/outdoor-backup/var/lock/backup.lock"
    mkdir -p "$RUNTIME_SCRIPTS" "$RUNTIME_RC" "${RUNTIME_INIT%/*}" "${RUNTIME_SERVICE%/*}" "${BUSINESS_LOCK%/*}"
    cp "$SOURCE_DIR/service-state.sh" "$SOURCE_DIR/target-device.sh" "$SOURCE_DIR/owner-event.sh" "$RUNTIME_SCRIPTS/" || return 1
    cp "$SOURCE_DIR/backup-manager.sh" "$RUNTIME_SCRIPTS/backup-manager.sh" || return 1
    : > "$RUNTIME_INIT"
    chmod 700 "$RUNTIME_SCRIPTS/backup-manager.sh"
}

install_control() {
    cp "$SOURCE_CONTROL" "$RUNTIME_SCRIPTS/service-control.sh" || return 1
    chmod 700 "$RUNTIME_SCRIPTS/service-control.sh"
}

# Rename only the private mirror's approved release functions, then wrap them.
# The wrapper can fail after retaining the real FD lock, proving controller
# cleanup rather than process-exit lock release is responsible for the result.
install_state_write_seam() {
    sed -i 's/^service_state_write()/service_state_write_real()/' "$RUNTIME_SCRIPTS/service-state.sh" || return 1
    cat >> "$RUNTIME_SCRIPTS/service-state.sh" <<'EOF'
service_state_write() {
    write_mode=$1
    [ "${SERVICE_TEST_FAIL_WRITE_MODE:-}" = "$write_mode" ] && return "${SERVICE_TEST_FAIL_WRITE_RC:-1}"
    service_state_write_real "$@"
    write_rc=$?
    if [ "$write_rc" -eq 0 ] && [ "$write_mode" = running ] && \
        [ -n "${SERVICE_TEST_SIGNAL_AFTER_RUNNING:-}" ]; then
        IFS=' ' read -r signal_self_pid _ < /proc/self/stat || return 1
        kill "-${SERVICE_TEST_SIGNAL_AFTER_RUNNING}" "$signal_self_pid" || return 1
    fi
    return "$write_rc"
}
EOF
}

install_control_acquire_seam() {
    sed -i 's/^service_control_acquire()/service_control_acquire_real()/' "$RUNTIME_SCRIPTS/service-state.sh" || return 1
    cat >> "$RUNTIME_SCRIPTS/service-state.sh" <<'EOF'
service_control_acquire() {
    printf 'acquire\n' >> "${SERVICE_TEST_CONTROL_LOG:-/dev/null}"
    service_control_acquire_real "$@"
}
EOF
}

install_release_seam() {
    sed -i 's/^service_lease_release()/service_lease_release_real()/' "$RUNTIME_SCRIPTS/service-state.sh" || return 1
    sed -i 's/^service_control_release()/service_control_release_real()/' "$RUNTIME_SCRIPTS/service-state.sh" || return 1
    cat >> "$RUNTIME_SCRIPTS/service-state.sh" <<'EOF'
service_lease_release() {
    SERVICE_TEST_RELEASE_CALLS=$(( ${SERVICE_TEST_RELEASE_CALLS:-0} + 1 ))
    printf 'fd8\n' >> "${SERVICE_TEST_RELEASE_LOG:-/dev/null}"
    if [ "${SERVICE_TEST_SIGNAL_ON_RELEASE_CALL:-}" = "$SERVICE_TEST_RELEASE_CALLS" ]; then
        IFS=' ' read -r signal_self_pid _ < /proc/self/stat || return 1
        kill "-${SERVICE_TEST_SIGNAL_ON_RELEASE:-TERM}" "$signal_self_pid" || return 1
    fi
    [ "${SERVICE_TEST_FAIL_FD8_RELEASE:-0}" = 1 ] && return 1
    service_lease_release_real
}
service_control_release() {
    printf 'fd7\n' >> "${SERVICE_TEST_RELEASE_LOG:-/dev/null}"
    [ "${SERVICE_TEST_FAIL_FD7_RELEASE:-0}" = 1 ] && return 1
    service_control_release_real
}
EOF
}

write_state() { mkdir -p "$RUNTIME_SERVICE"; printf '%s' "$2" > "$RUNTIME_SERVICE/state"; }
read_state() { cat "$RUNTIME_SERVICE/state"; }

control_env() {
    OUTDOOR_BACKUP_SERVICE_DIR="$RUNTIME_SERVICE" \
    OUTDOOR_BACKUP_RC_DIR="$RUNTIME_RC" \
    OUTDOOR_BACKUP_INIT_SCRIPT="$RUNTIME_INIT" \
    "$@"
}

# Reap one exact child within its generous wall-clock contract. A timeout is a
# test failure even where the caller expected a normal nonzero controller rc.
wait_pid_bounded() {
    watched_pid=$1 timeout_seconds=$2 label=$3 elapsed=0
    while kill -0 "$watched_pid" 2>/dev/null; do
        state=$(awk '{print $3}' "/proc/$watched_pid/stat" 2>/dev/null || :)
        [ "$state" = Z ] && break
        [ "$elapsed" -lt "$timeout_seconds" ] || {
            fail "$label exceeded ${timeout_seconds}s watchdog"
            kill -TERM "$watched_pid" 2>/dev/null || :
            /bin/sleep 1
            kill -KILL "$watched_pid" 2>/dev/null || :
            wait "$watched_pid" 2>/dev/null || :
            return 124
        }
        /bin/sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$watched_pid"
}

# Negative controls are expected to block; this bounded observer proves that the
# suite detects the regression without allowing the mutant to hang the run.
expect_blocked_within() {
    watched_pid=$1 timeout_seconds=$2 elapsed=0
    while kill -0 "$watched_pid" 2>/dev/null; do
        state=$(awk '{print $3}' "/proc/$watched_pid/stat" 2>/dev/null || :)
        [ "$state" = Z ] && return 1
        if [ "$elapsed" -ge "$timeout_seconds" ]; then
            kill -TERM "$watched_pid" 2>/dev/null || :
            /bin/sleep 1
            kill -KILL "$watched_pid" 2>/dev/null || :
            wait "$watched_pid" 2>/dev/null || :
            return 0
        fi
        /bin/sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

run_named_control() {
    controller_path=$1 output=$2
    shift 2
    OUTDOOR_BACKUP_SERVICE_DIR="$RUNTIME_SERVICE" OUTDOOR_BACKUP_RC_DIR="$RUNTIME_RC" \
    OUTDOOR_BACKUP_INIT_SCRIPT="$RUNTIME_INIT" /bin/ash "$controller_path" \
        "$@" >"$output" 2>&1 &
    RUN_CONTROL_PID=$!
    wait_pid_bounded "$RUN_CONTROL_PID" 75 "controller $*"
    RUN_CONTROL_RC=$?
    [ "$RUN_CONTROL_RC" -ne 124 ] || return 124
    return "$RUN_CONTROL_RC"
}

run_control() {
    output=$1
    shift
    run_named_control "$RUNTIME_SCRIPTS/service-control.sh" "$output" "$@"
}

assert_control_rc() {
    expected_rc=$1 output=$2
    shift 2
    run_control "$output" "$@"
    actual_rc=$?
    assert_equal "$actual_rc" "$expected_rc" "controller $* returns exact rc"
}

run_control_background() {
    output=$1
    shift
    OUTDOOR_BACKUP_SERVICE_DIR="$RUNTIME_SERVICE" OUTDOOR_BACKUP_RC_DIR="$RUNTIME_RC" \
    OUTDOOR_BACKUP_INIT_SCRIPT="$RUNTIME_INIT" /bin/ash "$RUNTIME_SCRIPTS/service-control.sh" \
        "$@" >"$output" 2>&1 &
    CONTROLLER_PID=$!
    track_pid "$CONTROLLER_PID"
}

# A daemonized supervisor runs controller as its foreground child and records
# child rc only after wait returns. A test-private controller PID marker lets
# the test signal the real child, not the unrelated supervisor.
run_control_int_supervisor() {
    output=$1
    controller_pid_marker=$2 child_rc_marker=$3 controller_action=$4
    supervisor_script="$CASE_ROOT/int-supervisor.sh"
    supervisor_pidfile="$CASE_ROOT/supervisor.pid"
    cat > "$supervisor_script" <<'EOF'
#!/bin/ash
/bin/ash "$SERVICE_TEST_CONTROLLER_PATH" "$SERVICE_TEST_CONTROLLER_ACTION"
child_rc=$?
printf '%s\n' "$child_rc" > "$SERVICE_TEST_CHILD_RC_FILE"
exit "$child_rc"
EOF
    chmod 700 "$supervisor_script" || return 1
    OUTDOOR_BACKUP_SERVICE_DIR="$RUNTIME_SERVICE" OUTDOOR_BACKUP_RC_DIR="$RUNTIME_RC" \
    OUTDOOR_BACKUP_INIT_SCRIPT="$RUNTIME_INIT" SERVICE_TEST_CONTROLLER_PID_FILE="$controller_pid_marker" \
    SERVICE_TEST_CHILD_RC_FILE="$child_rc_marker" SERVICE_TEST_CONTROLLER_PATH="$RUNTIME_SCRIPTS/service-control.sh" \
    SERVICE_TEST_CONTROLLER_ACTION="$controller_action" start-stop-daemon -S -b -m -p "$supervisor_pidfile" -x "$supervisor_script" >"$output" 2>&1 || return 1
    SUPERVISOR_PID=$(cat "$supervisor_pidfile") || return 1
    track_pid "$SUPERVISOR_PID"
}

wait_nonchild_exit() {
    watched_pid=$1 timeout_seconds=$2 label=$3 elapsed=0
    while kill -0 "$watched_pid" 2>/dev/null; do
        state=$(awk '{print $3}' "/proc/$watched_pid/stat" 2>/dev/null || :)
        [ "$state" = Z ] && return 0
        [ "$elapsed" -lt "$timeout_seconds" ] || { fail "$label did not exit"; return 1; }
        /bin/sleep 1
        elapsed=$((elapsed + 1))
    done
    return 0
}

install_sender_log_seam() {
    cat >> "$RUNTIME_SCRIPTS/owner-event.sh" <<'EOF'
owner_event_send_term() {
    printf '%s\n' "$1" >> "${OWNER_EVENT_SEND_LOG:?}"
    kill -TERM "$1"
}
EOF
}

# Let the existing fixture release itself immediately before the real cmdline
# probe. The probe then fails because the owner is no longer a live process.
install_owner_exit_during_stop_validation_seam() {
    sed -i 's/^owner_event_cmdline_matches_stop()/owner_event_cmdline_matches_stop_real()/' \
        "$RUNTIME_SCRIPTS/owner-event.sh" || return 1
    cat >> "$RUNTIME_SCRIPTS/owner-event.sh" <<'EOF'
owner_event_cmdline_matches_stop() {
    : > "${OWNER_EVENT_TEST_RELEASE_DURING_CMDLINE:?}" || return 1
    owner_event_test_pid=${1#/proc/}
    owner_event_test_pid=${owner_event_test_pid%/cmdline}
    owner_exit_wait=0
    while [ "$owner_exit_wait" -lt 5 ]; do
        owner_event_test_state=$(awk '{print $3}' "/proc/$owner_event_test_pid/stat" 2>/dev/null || :)
        case $owner_event_test_state in Z|X|'') break ;; esac
        /bin/sleep 1
        owner_exit_wait=$((owner_exit_wait + 1))
    done
    owner_event_cmdline_matches_stop_real "$@"
}
EOF
}

write_owner_fixture() {
    cat > "$RUNTIME_SCRIPTS/backup-manager.sh" <<'EOF'
#!/bin/ash
lock=$OUTDOOR_BACKUP_BUSINESS_LOCK
admission=$OUTDOOR_BACKUP_SERVICE_DIR/admission.lock
ready=$OUTDOOR_BACKUP_OWNER_READY
release=$OUTDOOR_BACKUP_OWNER_RELEASE
term=$OUTDOOR_BACKUP_OWNER_TERM
mkdir -p "${lock%/*}" "$OUTDOOR_BACKUP_SERVICE_DIR" || exit 1
exec 8<> "$admission" || exit 1
flock -s -n 8 || exit 1
ln -s "/proc/$$" "$lock" || exit 1
printf '%s\n' "$$" > "$ready" || exit 1
if [ "${OUTDOOR_BACKUP_OWNER_EXIT_ON_RELEASE:-0}" = 1 ]; then
    while [ ! -e "$release" ]; do /bin/sleep 1; done
    rm -f "$lock"; flock -u 8; exec 8>&-; exit 0
fi
trap 'printf TERM > "$term"; while [ ! -e "$release" ]; do /bin/sleep 1; done; rm -f "$lock"; flock -u 8; exec 8>&-; exit 143' TERM
while :; do /bin/sleep 1; done
EOF
    chmod 700 "$RUNTIME_SCRIPTS/backup-manager.sh"
}

start_owner_fixture() {
    owner_exit_on_release=${1:-0}
    OWNER_READY="$CASE_ROOT/owner.ready"
    OWNER_RELEASE="$CASE_ROOT/owner.release"
    OWNER_TERM="$CASE_ROOT/owner.term"
    OWNER_SEND_LOG="$CASE_ROOT/sends.log"
    OUTDOOR_BACKUP_BUSINESS_LOCK="$BUSINESS_LOCK" \
    OUTDOOR_BACKUP_OWNER_READY="$OWNER_READY" OUTDOOR_BACKUP_OWNER_RELEASE="$OWNER_RELEASE" \
    OUTDOOR_BACKUP_OWNER_TERM="$OWNER_TERM" OUTDOOR_BACKUP_SERVICE_DIR="$RUNTIME_SERVICE" \
    OUTDOOR_BACKUP_OWNER_EXIT_ON_RELEASE="$owner_exit_on_release" \
    /bin/ash "$RUNTIME_SCRIPTS/backup-manager.sh" add sda1 /devices/mock/sda1 1 &
    OWNER_PID=$!
    track_pid "$OWNER_PID"
    wait_ready "$OWNER_READY" "$OWNER_PID" 'owner fixture'
}

start_shared_lease_holder() {
    cat > "$CASE_ROOT/lease-holder.sh" <<'EOF'
#!/bin/ash
. "$1"
service_lease_acquire 4 || exit $?
printf '%s\n' "$$" > "$2"
while [ ! -e "$3" ]; do /bin/sleep 1; done
service_lease_release
EOF
    chmod 700 "$CASE_ROOT/lease-holder.sh"
    OUTDOOR_BACKUP_SERVICE_DIR="$RUNTIME_SERVICE" OUTDOOR_BACKUP_RC_DIR="$RUNTIME_RC" \
    OUTDOOR_BACKUP_INIT_SCRIPT="$RUNTIME_INIT" /bin/ash "$CASE_ROOT/lease-holder.sh" \
    "$RUNTIME_SCRIPTS/service-state.sh" "$CASE_ROOT/lease.ready" "$CASE_ROOT/lease.release" &
    LEASE_PID=$!
    track_pid "$LEASE_PID"
    wait_ready "$CASE_ROOT/lease.ready" "$LEASE_PID" 'shared lease holder'
}

start_control_holder() {
    cat > "$CASE_ROOT/control-holder.sh" <<'EOF'
#!/bin/ash
. "$1"
service_control_acquire || exit $?
printf '%s\n' "$$" > "$2"
while [ ! -e "$3" ]; do /bin/sleep 1; done
service_control_release
EOF
    chmod 700 "$CASE_ROOT/control-holder.sh"
    OUTDOOR_BACKUP_SERVICE_DIR="$RUNTIME_SERVICE" /bin/ash "$CASE_ROOT/control-holder.sh" \
    "$RUNTIME_SCRIPTS/service-state.sh" "$CASE_ROOT/control.ready" "$CASE_ROOT/control.release" &
    HOLDER_PID=$!
    track_pid "$HOLDER_PID"
    wait_ready "$CASE_ROOT/control.ready" "$HOLDER_PID" 'control holder'
}

case_red_and_cli_contract() {
    begin_case C01 'Red absence fails, while strict Green CLI rejects extra or unknown actions without state mutation'
    prepare_case c01 || return
    write_state "$RUNTIME_SERVICE" 'stopped:3'
    assert_failure 'C01 absent controller is observable Red failure' \
        run_control "$CASE_ROOT/red.out" stop
    assert_equal "$(read_state)" 'stopped:3' 'C01 Red absence does not mutate state'
    install_control || return
    assert_failure 'C01 missing action fails' run_control "$CASE_ROOT/no-action.out"
    assert_failure 'C01 unknown action fails' run_control "$CASE_ROOT/unknown.out" unknown
    assert_failure 'C01 extra argument fails' run_control "$CASE_ROOT/extra.out" start extra
    assert_equal "$(read_state)" 'stopped:3' 'C01 invalid CLI never mutates state'
}

case_stop_start_and_cold_fallback() {
    begin_case C02 'cold rc fallback, empty stop, start generation increment, and idempotent start are correct'
    prepare_case c02 || return
    install_control || return
    ln -s "$RUNTIME_INIT" "$RUNTIME_RC/S95outdoor-backup"
    assert_success 'C02 stop accepts enabled cold state' run_control "$CASE_ROOT/stop.out" stop
    assert_equal "$(read_state)" 'stopped:0' 'C02 stop publishes stopped generation zero'
    assert_success 'C02 start reopens stopped state' run_control "$CASE_ROOT/start.out" start
    assert_equal "$(read_state)" 'running:1' 'C02 start increments exactly once'
    assert_success 'C02 repeated start is idempotent' run_control "$CASE_ROOT/restart.out" start
    assert_equal "$(read_state)" 'running:1' 'C02 idempotent start preserves generation'
}

case_stopped_admission_and_start_rejections() {
    begin_case C03 'stopped denies S admission and start refuses active lease or any lock path object'
    prepare_case c03 || return
    install_control || return
    write_state "$RUNTIME_SERVICE" 'stopped:4'
    control_env /bin/ash -c '. "$1"; service_lease_acquire; printf "%s" "$?"' ash \
        "$RUNTIME_SCRIPTS/service-state.sh" > "$CASE_ROOT/admission.out" || :
    assert_equal "$(cat "$CASE_ROOT/admission.out")" 2 'C03 stopped state denies shared admission'
    write_state "$RUNTIME_SERVICE" 'running:4'
    start_shared_lease_holder || return
    control_env /bin/ash -c '. "$1"; service_control_acquire; acquire=$?; service_state_write stopped 4; write=$?; service_control_release; printf "%s/%s" "$acquire" "$write"' ash \
        "$RUNTIME_SCRIPTS/service-state.sh" > "$CASE_ROOT/close-with-lease.out"
    assert_equal "$(cat "$CASE_ROOT/close-with-lease.out")" '0/0' 'C03 controller closes state while existing shared lease remains'
    assert_failure 'C03 start cannot publish while shared lease survives' run_control "$CASE_ROOT/lease-start.out" start
    assert_equal "$(read_state)" 'stopped:4' 'C03 lease-busy start leaves stopped state unchanged'
    : > "$CASE_ROOT/lease.release"; wait "$LEASE_PID" || fail 'C03 lease holder exits'
    write_state "$RUNTIME_SERVICE" 'stopped:4'
    : > "$BUSINESS_LOCK"
    assert_failure 'C03 regular business lock rejects start' run_control "$CASE_ROOT/file-lock.out" start
    rm -f "$BUSINESS_LOCK"; ln -s /missing/backup-owner "$BUSINESS_LOCK"
    assert_failure 'C03 dangling business link rejects start' run_control "$CASE_ROOT/link-lock.out" start
    assert_equal "$(read_state)" 'stopped:4' 'C03 lock rejections do not reopen state'
}

case_stop_waits_for_proven_owner_and_writer() {
    begin_case C04 'stop stays closed until a proven owner releases its lock and S lease, sending TERM exactly once'
    prepare_case c04 || return
    install_control || return
    install_sender_log_seam
    write_owner_fixture
    write_state "$RUNTIME_SERVICE" 'running:7'
    start_owner_fixture || return
    OWNER_EVENT_SEND_LOG="$OWNER_SEND_LOG" run_control_background "$CASE_ROOT/stop.out" stop
    wait_path "$OWNER_TERM" "$CONTROLLER_PID" 'controller owner TERM' || return
    assert_success 'C04 controller remains waiting while owner holds S and business lock' kill -0 "$CONTROLLER_PID"
    assert_equal "$(wc -l < "$OWNER_SEND_LOG")" 1 'C04 owner-event sender is called exactly once'
    : > "$OWNER_RELEASE"
    wait "$OWNER_PID" 2>/dev/null || owner_rc=$?
    owner_rc=${owner_rc:-0}
    wait "$CONTROLLER_PID" || controller_rc=$?
    controller_rc=${controller_rc:-0}
    assert_equal "$owner_rc" 143 'C04 owner exits only through delayed TERM cleanup'
    assert_equal "$controller_rc" 0 'C04 stop completes after actual quiescence'
    assert_equal "$(read_state)" 'stopped:7' 'C04 stop preserves generation'
    assert_absent "$BUSINESS_LOCK" 'C04 owner itself removed business lock before success'
}

case_owner_exit_during_validation_rechecks_quiescence() {
    begin_case C16 'owner disappearance during validation waits for the next FD8 X and lock-absence proof'
    prepare_case c16 || return
    install_control || return
    install_sender_log_seam
    install_owner_exit_during_stop_validation_seam
    write_owner_fixture
    write_state "$RUNTIME_SERVICE" 'running:7'
    start_owner_fixture 1 || return
    OWNER_EVENT_SEND_LOG="$OWNER_SEND_LOG"
    OWNER_EVENT_TEST_RELEASE_DURING_CMDLINE="$OWNER_RELEASE"
    export OWNER_EVENT_SEND_LOG OWNER_EVENT_TEST_RELEASE_DURING_CMDLINE
    run_control "$CASE_ROOT/stop.out" stop
    controller_rc=$?
    unset OWNER_EVENT_SEND_LOG OWNER_EVENT_TEST_RELEASE_DURING_CMDLINE
    owner_rc=0
    wait "$OWNER_PID" 2>/dev/null || owner_rc=$?
    assert_equal "$owner_rc" 0 'C16 owner exits normally during owner validation'
    assert_equal "$controller_rc" 0 'C16 stop succeeds only after a subsequent quiescence proof'
    assert_absent "$BUSINESS_LOCK" 'C16 normal owner exit removed the business lock'
    assert_equal "$(read_state)" 'stopped:7' 'C16 stop preserves the closed generation'
    assert_absent "$OWNER_TERM" 'C16 owner disappearance does not manufacture a TERM request'
}

case_invalid_lock_never_signals_or_deletes() {
    begin_case C05 'wrong owner argv, unrelated process, dangling link, and regular lock all fail closed'
    prepare_case c05 || return
    install_control || return
    install_sender_log_seam
    write_state "$RUNTIME_SERVICE" 'running:8'
    cat > "$CASE_ROOT/unrelated.sh" <<'EOF'
#!/bin/ash
trap 'printf TERM > "$1"; exit 143' TERM
while :; do /bin/sleep 1; done
EOF
    chmod 700 "$CASE_ROOT/unrelated.sh"
    "$CASE_ROOT/unrelated.sh" "$CASE_ROOT/unrelated.term" &
    unrelated_pid=$!; track_pid "$unrelated_pid"; /bin/sleep 1
    cat > "$RUNTIME_SCRIPTS/backup-manager.sh" <<'EOF'
#!/bin/ash
trap 'printf TERM > "$TERM_MARKER"; exit 143' TERM
while :; do /bin/sleep 1; done
EOF
    chmod 700 "$RUNTIME_SCRIPTS/backup-manager.sh"
    for lock_kind in wrongargv unrelated dangling regular; do
        rm -f "$BUSINESS_LOCK"
        case $lock_kind in
            wrongargv)
                TERM_MARKER="$CASE_ROOT/wrongargv.term" /bin/ash "$RUNTIME_SCRIPTS/backup-manager.sh" remove sda1 /devices/mock/sda1 1 &
                bad_pid=$!; track_pid "$bad_pid"; /bin/sleep 1; ln -s "/proc/$bad_pid" "$BUSINESS_LOCK" ;;
            unrelated) ln -s "/proc/$unrelated_pid" "$BUSINESS_LOCK" ;;
            dangling) ln -s /proc/999999 "$BUSINESS_LOCK" ;;
            regular) printf residue > "$BUSINESS_LOCK" ;;
        esac
        assert_failure "C05 $lock_kind lock rejects stop" run_control "$CASE_ROOT/$lock_kind.out" stop
        [ "$lock_kind" = regular ] && assert_equal "$(cat "$BUSINESS_LOCK")" residue 'C05 regular residue remains intact'
        [ "$lock_kind" = dangling ] && assert_success 'C05 dangling link remains intact' test -L "$BUSINESS_LOCK"
    done
    assert_success 'C05 wrong-action manager remains unsignalled and alive' kill -0 "$bad_pid"
    assert_absent "$CASE_ROOT/wrongargv.term" 'C05 wrong-action manager received no TERM'
    assert_absent "$CASE_ROOT/unrelated.term" 'C05 unrelated process received no TERM'
    assert_absent "$CASE_ROOT/sends.log" 'C05 no invalid lock invoked sender seam'
    assert_equal "$(read_state)" 'stopped:8' 'C05 every failure leaves published stopped state'
}

case_repeated_stop_avoids_repeat_term() {
    begin_case C06 'one stop loop reuses prior proven identity instead of sending duplicate TERM'
    prepare_case c06 || return
    install_control || return
    install_sender_log_seam
    write_owner_fixture
    write_state "$RUNTIME_SERVICE" 'running:9'
    start_owner_fixture || return
    OWNER_EVENT_SEND_LOG="$OWNER_SEND_LOG" run_control_background "$CASE_ROOT/stop.out" stop
    wait_path "$OWNER_TERM" "$CONTROLLER_PID" 'first owner TERM' || return
    /bin/sleep 2
    assert_equal "$(wc -l < "$OWNER_SEND_LOG")" 1 'C06 repeated polls skip same owner identity'
    : > "$OWNER_RELEASE"
    wait "$CONTROLLER_PID" || fail 'C06 controller exits after release'
}

case_control_contention_and_restart_failure() {
    begin_case C07 'control contention is immediate and restart never starts after failed stop'
    prepare_case c07 || return
    install_control || return
    write_state "$RUNTIME_SERVICE" 'running:10'
    start_control_holder || return
    assert_control_rc 2 "$CASE_ROOT/contention.out" stop
    assert_equal "$(read_state)" 'running:10' 'C07 contention has no state side effect'
    : > "$CASE_ROOT/control.release"; wait "$HOLDER_PID" || fail 'C07 holder exits'
    printf residue > "$BUSINESS_LOCK"
    assert_failure 'C07 restart fails when stop cannot prove lock owner' run_control "$CASE_ROOT/restart.out" restart
    assert_equal "$(read_state)" 'stopped:10' 'C07 failed stop closes but does not restart or increment'
}

case_dependency_and_state_failures() {
    begin_case C08 'malformed state, missing jq, and flock operational failure never report success'
    prepare_case c08 || return
    install_control || return
    write_state "$RUNTIME_SERVICE" 'broken:1'
    assert_failure 'C08 malformed state rejects start' run_control "$CASE_ROOT/malformed.out" start
    write_state "$RUNTIME_SERVICE" 'stopped:1'
    mkdir "$CASE_ROOT/no-jq-bin"
    for required_tool in readlink dirname awk flock; do
        required_path=$(command -v "$required_tool") || return 1
        ln -s "$required_path" "$CASE_ROOT/no-jq-bin/$required_tool" || return 1
    done
    PATH="$CASE_ROOT/no-jq-bin" control_env /bin/ash "$RUNTIME_SCRIPTS/service-control.sh" stop > "$CASE_ROOT/no-jq.out" 2>&1
    no_jq_rc=$?
    assert_equal "$no_jq_rc" 1 'C08 legal state reaches missing-jq parser failure exactly'
    assert_equal "$(read_state)" 'stopped:1' 'C08 missing jq preserves legal stopped state'
    mkdir "$CASE_ROOT/fake-bin"
    cat > "$CASE_ROOT/fake-bin/flock" <<'EOF'
#!/bin/ash
printf '%s\n' 'fixture flock operational failure' >&2
exit 73
EOF
    chmod 700 "$CASE_ROOT/fake-bin/flock"
    PATH="$CASE_ROOT/fake-bin:$PATH" control_env /bin/ash "$RUNTIME_SCRIPTS/service-control.sh" start > "$CASE_ROOT/flock.out" 2>&1
    flock_rc=$?
    assert_equal "$flock_rc" 1 'C08 flock operational failure maps exactly to one'
    assert_success 'C08 flock diagnostic reaches acquisition classifier' \
        grep -F -q 'service-state: flock acquisition failed' "$CASE_ROOT/flock.out"
    assert_equal "$(read_state)" 'stopped:1' 'C08 failure paths preserve stopped state'
}

case_timeout_preserves_closed_state() {
    begin_case C09 'a test-private short deadline proves timeout keeps stopped state and never kills or clears owner'
    prepare_case c09 || return
    install_control || return
    install_sender_log_seam
    write_owner_fixture
    sed 's/^SERVICE_CONTROL_TIMEOUT=60$/SERVICE_CONTROL_TIMEOUT=2/' "$RUNTIME_SCRIPTS/service-control.sh" > "$RUNTIME_SCRIPTS/service-control.short.sh"
    chmod 700 "$RUNTIME_SCRIPTS/service-control.short.sh"
    write_state "$RUNTIME_SERVICE" 'running:11'
    start_owner_fixture || return
    OWNER_EVENT_SEND_LOG="$OWNER_SEND_LOG" OUTDOOR_BACKUP_SERVICE_DIR="$RUNTIME_SERVICE" OUTDOOR_BACKUP_RC_DIR="$RUNTIME_RC" \
    OUTDOOR_BACKUP_INIT_SCRIPT="$RUNTIME_INIT" /bin/ash "$RUNTIME_SCRIPTS/service-control.short.sh" stop > "$CASE_ROOT/timeout.out" 2>&1
    timeout_rc=$?
    ASSERTIONS=$((ASSERTIONS + 1)); [ "$timeout_rc" -ne 0 ] || fail 'C09 expired stop falsely succeeds'
    assert_equal "$(read_state)" 'stopped:11' 'C09 timeout keeps service closed'
    assert_success 'C09 timeout leaves owner alive' kill -0 "$OWNER_PID"
    [ -L "$BUSINESS_LOCK" ] || fail 'C09 timeout deleted business lock'
    ASSERTIONS=$((ASSERTIONS + 1))
    assert_equal "$(wc -l < "$OWNER_SEND_LOG")" 1 'C09 timeout neither retries TERM nor escalates signal'
    : > "$OWNER_RELEASE"; wait "$OWNER_PID" 2>/dev/null || :
}

case_term_releases_control_without_reopen() {
    begin_case C10 'TERM interrupts waiting controller, releases FD7, and leaves published stopped state intact'
    prepare_case c10 || return
    install_control || return
    install_sender_log_seam
    write_owner_fixture
    write_state "$RUNTIME_SERVICE" 'running:12'
    start_owner_fixture || return
    OWNER_EVENT_SEND_LOG="$OWNER_SEND_LOG" run_control_background "$CASE_ROOT/term.out" stop
    wait_path "$OWNER_TERM" "$CONTROLLER_PID" 'controller TERM delivery' || return
    kill -TERM "$CONTROLLER_PID"
    wait "$CONTROLLER_PID" 2>/dev/null || term_rc=$?
    term_rc=${term_rc:-0}
    ASSERTIONS=$((ASSERTIONS + 1)); [ "$term_rc" -ne 0 ] || fail 'C10 controller TERM falsely returns success'
    control_env /bin/ash -c '. "$1"; service_control_acquire; rc=$?; service_control_release; printf "%s" "$rc"' ash \
        "$RUNTIME_SCRIPTS/service-state.sh" > "$CASE_ROOT/control-free.out"
    assert_equal "$(cat "$CASE_ROOT/control-free.out")" 0 'C10 controller cleanup releases FD7'
    assert_equal "$(read_state)" 'stopped:12' 'C10 trap never reopens stopped state'
    : > "$OWNER_RELEASE"; wait "$OWNER_PID" 2>/dev/null || :
}

case_signal_windows_close_candidate_epoch() {
    begin_case C15 'post-publish TERM and INT plus finalization signal close the candidate generation'
    prepare_case c15-term || return
    install_control || return
    install_state_write_seam || return
    write_state "$RUNTIME_SERVICE" 'stopped:80'
    SERVICE_TEST_SIGNAL_AFTER_RUNNING=TERM assert_control_rc 143 "$CASE_ROOT/term.out" start
    assert_equal "$(read_state)" 'stopped:81' 'C15 post-publish TERM closes new candidate generation'

    prepare_case c15-int || return
    install_control || return
    install_state_write_seam || return
    write_state "$RUNTIME_SERVICE" 'stopped:90'
    int_pid_marker="$CASE_ROOT/controller.pid"
    int_rc_marker="$CASE_ROOT/int.rc"
    SERVICE_TEST_SIGNAL_AFTER_RUNNING=INT run_control_int_supervisor \
        "$CASE_ROOT/int.out" "$int_pid_marker" "$int_rc_marker" start
    wait_path "$int_rc_marker" "$SUPERVISOR_PID" 'C15 post-publish INT child final rc' || return
    assert_equal "$(cat "$int_rc_marker")" 130 'C15 post-publish INT returns exact 130'
    assert_success 'C15 INT supervisor observed completed child exit' \
        wait_nonchild_exit "$SUPERVISOR_PID" 15 'C15 INT supervisor'
    assert_equal "$(read_state)" 'stopped:91' 'C15 post-publish INT closes new candidate generation'

    prepare_case c15-final || return
    install_control || return
    install_release_seam || return
    write_state "$RUNTIME_SERVICE" 'stopped:100'
    final_release_log="$CASE_ROOT/final-release.log"
    SERVICE_TEST_RELEASE_LOG="$final_release_log" SERVICE_TEST_SIGNAL_ON_RELEASE_CALL=2 SERVICE_TEST_SIGNAL_ON_RELEASE=TERM \
        assert_control_rc 143 "$CASE_ROOT/final-signal.out" start
    assert_equal "$(read_state)" 'stopped:101' 'C15 finalization second-release TERM still completes rollback'
    assert_equal "$(cat "$CASE_ROOT/final-signal.out")" \
        'outdoor-backup: service control: service started
outdoor-backup: service control: new running generation rolled back to stopped' \
        'C15 terminal boundary records signal without cutting finalization'
    assert_equal "$(cat "$final_release_log")" 'fd8
fd8
fd7' \
        'C15 finalization signal preserves explicit FD8-before-FD7 cleanup'

    prepare_case c15-final-red || return
    install_control || return
    install_release_seam || return
    write_state "$RUNTIME_SERVICE" 'stopped:120'
    final_release_log="$CASE_ROOT/final-release.log"
    finalization_mutant="$RUNTIME_SCRIPTS/service-control-finalization-mutant.sh"
    awk '
        {
            if ($0 == "    if ! controller_release_control; then") {
                anchor_count++
                print "    [ \"$CONTROL_CANCEL_CODE\" -eq 0 ] || return \"$final_rc\""
            }
            print
        }
        END {
            if (anchor_count != 1) exit 1
        }
    ' "$RUNTIME_SCRIPTS/service-control.sh" > "$finalization_mutant" || {
        fail 'C15 finalization mutant generation failed'
        return 1
    }
    chmod 700 "$finalization_mutant" || {
        fail 'C15 finalization mutant chmod failed'
        return 1
    }
    SERVICE_TEST_RELEASE_LOG="$final_release_log" SERVICE_TEST_SIGNAL_ON_RELEASE_CALL=2 SERVICE_TEST_SIGNAL_ON_RELEASE=TERM \
        run_named_control "$finalization_mutant" "$CASE_ROOT/final-red.out" start
    mutant_rc=$?
    assert_equal "$mutant_rc" 143 'C15 finalization mutant exposes real TERM status'
    assert_equal "$(read_state)" 'stopped:121' 'C15 finalization mutant still rolls back candidate generation'
    assert_equal "$(cat "$final_release_log")" 'fd8
fd8' \
        'C15 finalization mutant omits explicit FD7 cleanup'
    assert_failure 'C15 normal three-release oracle rejects finalization mutant' \
        test "$(cat "$final_release_log")" = 'fd8
fd8
fd7'

    prepare_case c15-red || return
    install_control || return
    install_state_write_seam || return
    sed '/write_rc=$?/a\    CONTROL_CANDIDATE_GENERATION=' "$RUNTIME_SCRIPTS/service-control.sh" \
        > "$RUNTIME_SCRIPTS/service-control-postpublish-mutant.sh"
    chmod 700 "$RUNTIME_SCRIPTS/service-control-postpublish-mutant.sh"
    write_state "$RUNTIME_SERVICE" 'stopped:110'
    SERVICE_TEST_SIGNAL_AFTER_RUNNING=TERM run_named_control \
        "$RUNTIME_SCRIPTS/service-control-postpublish-mutant.sh" "$CASE_ROOT/red.out" start
    mutant_rc=$?
    assert_equal "$mutant_rc" 143 'C15 Red mutant still exposes real TERM status'
    assert_equal "$(read_state)" 'running:111' 'C15 Red mutant loses candidate and leaves running epoch'
}

case_watchdogs_detect_blocking_regressions() {
    begin_case C14 'watchdogs bound blocking flock and unbounded-deadline negative controls'
    prepare_case c14-flock || return
    install_control || return
    write_state "$RUNTIME_SERVICE" 'running:70'
    start_control_holder || return
    sed -i 's/service_state_flock_acquire -x -n 7/service_state_flock_acquire -x 7/' "$RUNTIME_SCRIPTS/service-state.sh" || return 1
    OUTDOOR_BACKUP_SERVICE_DIR="$RUNTIME_SERVICE" OUTDOOR_BACKUP_RC_DIR="$RUNTIME_RC" \
    OUTDOOR_BACKUP_INIT_SCRIPT="$RUNTIME_INIT" /bin/ash "$RUNTIME_SCRIPTS/service-control.sh" \
        stop > "$CASE_ROOT/blocking-flock.out" 2>&1 &
    mutant_pid=$!
    assert_success 'C14 watchdog detects removed nonblocking control acquisition' \
        expect_blocked_within "$mutant_pid" 3
    assert_equal "$(read_state)" 'running:70' 'C14 blocked acquisition has no state side effect'
    : > "$CASE_ROOT/control.release"; wait "$HOLDER_PID" || fail 'C14 control holder exits'

    prepare_case c14-deadline || return
    install_control || return
    write_state "$RUNTIME_SERVICE" 'running:4'
    start_shared_lease_holder || return
    sed 's/^SERVICE_CONTROL_TIMEOUT=60$/SERVICE_CONTROL_TIMEOUT=999999/' \
        "$RUNTIME_SCRIPTS/service-control.sh" > "$RUNTIME_SCRIPTS/service-control-infinite-mutant.sh"
    chmod 700 "$RUNTIME_SCRIPTS/service-control-infinite-mutant.sh"
    OUTDOOR_BACKUP_SERVICE_DIR="$RUNTIME_SERVICE" OUTDOOR_BACKUP_RC_DIR="$RUNTIME_RC" \
    OUTDOOR_BACKUP_INIT_SCRIPT="$RUNTIME_INIT" /bin/ash "$RUNTIME_SCRIPTS/service-control-infinite-mutant.sh" \
        stop > "$CASE_ROOT/infinite-deadline.out" 2>&1 &
    mutant_pid=$!
    assert_success 'C14 watchdog detects unbounded deadline mutant' \
        expect_blocked_within "$mutant_pid" 3
    assert_equal "$(read_state)" 'stopped:4' 'C14 deadline mutant still publishes closed before blocking'
    : > "$CASE_ROOT/lease.release"; wait "$LEASE_PID" || fail 'C14 lease holder exits'
}

case_stop_restart_signal_and_write_failures() {
    begin_case C13 'lease-only stop waits, restart is one control acquisition, writes fail closed, and INT is real 130'
    prepare_case c13-restart || return
    install_control || return
    install_control_acquire_seam || return
    write_state "$RUNTIME_SERVICE" 'stopped:50'
    control_log="$CASE_ROOT/control.log"
    SERVICE_TEST_CONTROL_LOG="$control_log" assert_control_rc 0 "$CASE_ROOT/restart.out" restart
    assert_equal "$(read_state)" 'running:51' 'C13 normal restart closes then starts next generation'
    assert_equal "$(wc -l < "$control_log")" 1 'C13 restart acquires controller exactly once'

    prepare_case c13-lease-stop || return
    install_control || return
    write_state "$RUNTIME_SERVICE" 'running:4'
    start_shared_lease_holder || return
    sed 's/^SERVICE_CONTROL_TIMEOUT=60$/SERVICE_CONTROL_TIMEOUT=2/' "$RUNTIME_SCRIPTS/service-control.sh" > "$RUNTIME_SCRIPTS/service-control.short.sh"
    chmod 700 "$RUNTIME_SCRIPTS/service-control.short.sh"
    run_named_control "$RUNTIME_SCRIPTS/service-control.short.sh" "$CASE_ROOT/lease-stop.out" stop
    lease_stop_rc=$?
    assert_equal "$lease_stop_rc" 1 'C13 lockless shared lease makes stop timeout nonzero'
    assert_equal "$(read_state)" 'stopped:4' 'C13 lockless shared lease cannot produce early success'
    assert_success 'C13 lockless shared lease remains live at timeout' kill -0 "$LEASE_PID"
    : > "$CASE_ROOT/lease.release"; wait "$LEASE_PID" || fail 'C13 lease holder exits after timeout'

    prepare_case c13-write || return
    install_control || return
    install_state_write_seam || return
    write_state "$RUNTIME_SERVICE" 'stopped:60'
    SERVICE_TEST_FAIL_WRITE_MODE=running assert_control_rc 1 "$CASE_ROOT/start-write.out" start
    assert_equal "$(read_state)" 'stopped:60' 'C13 failed running write retains old stopped record'
    SERVICE_TEST_FAIL_WRITE_MODE=running SERVICE_TEST_FAIL_WRITE_RC=73 \
        assert_control_rc 73 "$CASE_ROOT/start-write-73.out" start
    assert_equal "$(read_state)" 'stopped:60' 'C13 nonstandard running write rc preserves old stopped record'
    write_state "$RUNTIME_SERVICE" 'running:61'
    SERVICE_TEST_FAIL_WRITE_MODE=stopped assert_control_rc 1 "$CASE_ROOT/stop-write.out" stop
    assert_equal "$(read_state)" 'running:61' 'C13 failed stopped write cannot claim quiet success'

    prepare_case c13-int || return
    install_control || return
    install_sender_log_seam
    write_owner_fixture
    write_state "$RUNTIME_SERVICE" 'running:62'
    start_owner_fixture || return
    controller_pid_marker="$CASE_ROOT/controller.pid"
    int_rc_marker="$CASE_ROOT/int.rc"
    sed -i '/CONTROL_FINALIZED=0/a\
if [ -n "${SERVICE_TEST_CONTROLLER_PID_FILE:-}" ]; then\
    IFS=" " read -r controller_test_pid _ < /proc/self/stat || exit 1\
    printf "%s\\n" "$controller_test_pid" > "$SERVICE_TEST_CONTROLLER_PID_FILE" || exit 1\
fi' "$RUNTIME_SCRIPTS/service-control.sh" || return 1
    OWNER_EVENT_SEND_LOG="$OWNER_SEND_LOG" run_control_int_supervisor \
        "$CASE_ROOT/int.out" "$controller_pid_marker" "$int_rc_marker" stop
    wait_path "$controller_pid_marker" "$SUPERVISOR_PID" 'INT supervisor child PID marker' || return
    CONTROLLER_PID=$(cat "$controller_pid_marker")
    assert_success 'C13 PID marker identifies a live real controller child' kill -0 "$CONTROLLER_PID"
    wait_path "$OWNER_TERM" "$SUPERVISOR_PID" 'INT controller owner TERM' || return
    kill -INT "$CONTROLLER_PID"
    wait_path "$int_rc_marker" "$SUPERVISOR_PID" 'INT supervisor child final rc' || return
    int_rc=$(cat "$int_rc_marker")
    assert_equal "$int_rc" 130 'C13 delivered SIGINT exits real controller with exact 130'
    assert_success 'C13 supervisor exits after observing child final rc' \
        wait_nonchild_exit "$SUPERVISOR_PID" 15 'INT supervisor'
    assert_success 'C13 real controller has exited before assertion passes' \
        wait_nonchild_exit "$CONTROLLER_PID" 15 'INT controller'
    assert_equal "$(read_state)" 'stopped:62' 'C13 delivered SIGINT leaves state closed'
    : > "$OWNER_RELEASE"; wait "$OWNER_PID" 2>/dev/null || :

    prepare_case c13-int-red || return
    install_control || return
    install_sender_log_seam
    write_owner_fixture
    write_state "$RUNTIME_SERVICE" 'running:63'
    start_owner_fixture || return
    controller_pid_marker="$CASE_ROOT/controller.pid"
    int_rc_marker="$CASE_ROOT/int.rc"
    sed -i '/CONTROL_FINALIZED=0/a\
if [ -n "${SERVICE_TEST_CONTROLLER_PID_FILE:-}" ]; then\
    IFS=" " read -r controller_test_pid _ < /proc/self/stat || exit 1\
    printf "%s\\n" "$controller_test_pid" > "$SERVICE_TEST_CONTROLLER_PID_FILE" || exit 1\
fi' "$RUNTIME_SCRIPTS/service-control.sh" || return 1
    sed -i 's/exit "$final_rc"/exit 0/' "$RUNTIME_SCRIPTS/service-control.sh" || return 1
    OWNER_EVENT_SEND_LOG="$OWNER_SEND_LOG" run_control_int_supervisor \
        "$CASE_ROOT/int-red.out" "$controller_pid_marker" "$int_rc_marker" stop
    wait_path "$controller_pid_marker" "$SUPERVISOR_PID" 'C13 Red controller PID marker' || return
    CONTROLLER_PID=$(cat "$controller_pid_marker")
    wait_path "$OWNER_TERM" "$SUPERVISOR_PID" 'C13 Red controller owner TERM' || return
    kill -INT "$CONTROLLER_PID"
    wait_path "$int_rc_marker" "$SUPERVISOR_PID" 'C13 Red supervisor child final rc' || return
    assert_equal "$(cat "$int_rc_marker")" 0 'C13 Red finalizer-exit mutant exposes false successful child rc'
    assert_success 'C13 Red supervisor still waited for child exit' \
        wait_nonchild_exit "$SUPERVISOR_PID" 15 'C13 Red supervisor'
    assert_success 'C13 Red real controller has exited before rc is accepted' \
        wait_nonchild_exit "$CONTROLLER_PID" 15 'C13 Red controller'
    assert_equal "$(read_state)" 'stopped:63' 'C13 Red proves status oracle, not state cleanup, catches final rc bug'
    : > "$OWNER_RELEASE"; wait "$OWNER_PID" 2>/dev/null || :
}

case_release_failures_rollback_new_epoch() {
    begin_case C12 'release errors are explicit, ordered, nonzero, and compensate only the new generation'
    prepare_case c12 || return
    install_control || return
    install_release_seam || return
    write_state "$RUNTIME_SERVICE" 'stopped:20'
    release_log="$CASE_ROOT/fd8-release.log"
    SERVICE_TEST_RELEASE_LOG="$release_log" SERVICE_TEST_FAIL_FD8_RELEASE=1 \
        assert_control_rc 1 "$CASE_ROOT/fd8.out" start
    assert_equal "$(read_state)" 'stopped:21' 'C12 FD8 release failure rolls back new generation only'
    assert_success 'C12 FD8 diagnostic is explicit' \
        grep -F -q 'explicit admission release failed' "$CASE_ROOT/fd8.out"
    assert_equal "$(sed -n '1,3p' "$release_log")" 'fd8
fd8
fd7' 'C12 finalizer releases FD8 before FD7 after rollback'

    prepare_case c12-fd7 || return
    install_control || return
    install_release_seam || return
    write_state "$RUNTIME_SERVICE" 'stopped:30'
    release_log="$CASE_ROOT/fd7-release.log"
    SERVICE_TEST_RELEASE_LOG="$release_log" SERVICE_TEST_FAIL_FD7_RELEASE=1 \
        assert_control_rc 1 "$CASE_ROOT/fd7.out" start
    assert_equal "$(read_state)" 'stopped:31' 'C12 FD7 release failure rolls back new generation only'
    assert_success 'C12 FD7 diagnostic is explicit' \
        grep -F -q 'explicit controller release failed' "$CASE_ROOT/fd7.out"
    assert_equal "$(cat "$release_log")" 'fd8
fd8
fd7
fd7' 'C12 FD7 rollback precedes the second explicit FD7 release attempt'

    prepare_case c12-unknown || return
    install_control || return
    install_state_write_seam || return
    install_release_seam || return
    write_state "$RUNTIME_SERVICE" 'stopped:35'
    SERVICE_TEST_FAIL_FD8_RELEASE=1 SERVICE_TEST_FAIL_WRITE_MODE=stopped \
        assert_control_rc 1 "$CASE_ROOT/unknown.out" start
    assert_equal "$(read_state)" 'running:36' 'C12 rollback-write failure does not falsely overwrite unknown running state'
    assert_success 'C12 rollback-write failure reports closure uncertainty' \
        grep -F -q 'cannot confirm closed: rollback state write failed' "$CASE_ROOT/unknown.out"

    prepare_case c12-red || return
    install_control || return
    install_release_seam || return
    sed 's/service_lease_release && return 0/service_lease_release || return 0/' \
        "$RUNTIME_SCRIPTS/service-control.sh" | \
        sed 's/controller_rollback_new_running || cleanup_failed=1/:/' \
        > "$RUNTIME_SCRIPTS/service-control-release-mutant.sh"
    chmod 700 "$RUNTIME_SCRIPTS/service-control-release-mutant.sh"
    write_state "$RUNTIME_SERVICE" 'stopped:40'
    SERVICE_TEST_FAIL_FD8_RELEASE=1 run_named_control \
        "$RUNTIME_SCRIPTS/service-control-release-mutant.sh" "$CASE_ROOT/red.out" start
    mutant_rc=$?
    assert_equal "$mutant_rc" 0 'C12 Red mutant swallows release failure as false success'
    assert_equal "$(read_state)" 'running:41' 'C12 Red oracle exposes swallowed-release stale running state'
}

case_max_generation_and_static_deadline() {
    begin_case C11 'max generation rejects start while stop remains available and production deadline is structurally sixty seconds'
    prepare_case c11 || return
    install_control || return
    write_state "$RUNTIME_SERVICE" 'stopped:2147483647'
    assert_success 'C11 production source retains literal sixty-second deadline' \
        grep -F -q 'SERVICE_CONTROL_TIMEOUT=60' "$SOURCE_CONTROL"
    assert_failure 'C11 max generation cannot wrap through start' run_control "$CASE_ROOT/max-start.out" start
    assert_equal "$(read_state)" 'stopped:2147483647' 'C11 max start preserves state'
    assert_success 'C11 stop remains idempotently available at max generation' run_control "$CASE_ROOT/max-stop.out" stop
    assert_equal "$(read_state)" 'stopped:2147483647' 'C11 max stop preserves state'
}

main() {
    trap cleanup EXIT INT TERM
    mkdir -p "$SUITE_ROOT"
    case_red_and_cli_contract
    if [ ! -f "$SOURCE_CONTROL" ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    case_stop_start_and_cold_fallback
    case_stopped_admission_and_start_rejections
    case_stop_waits_for_proven_owner_and_writer
    case_owner_exit_during_validation_rechecks_quiescence
    case_invalid_lock_never_signals_or_deletes
    case_repeated_stop_avoids_repeat_term
    case_control_contention_and_restart_failure
    case_dependency_and_state_failures
    case_timeout_preserves_closed_state
    case_term_releases_control_without_reopen
    case_signal_windows_close_candidate_epoch
    case_watchdogs_detect_blocking_regressions
    case_stop_restart_signal_and_write_failures
    case_release_failures_rollback_new_epoch
    case_max_generation_and_static_deadline
    assert_equal "$CASES" "$EXPECTED_CASES" 'all required controller cases executed'
    assert_equal "$ASSERTIONS" "$EXPECTED_ASSERTIONS" 'all required controller assertions executed exactly'
    printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
    [ "$FAILED" -eq 0 ]
}

main "$@"

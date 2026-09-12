#!/bin/sh
#
# BDD integration tests for the hotplug service-state admission boundary.
# The delivered hotplug script, service-state library, controller, and manager
# execute in the existing target-manager fixture. Only sleep(2) is held behind
# a test-local barrier, so the test can advance the real lifecycle epoch before
# the delayed add reaches the real manager.
#

set -u

IMAGE='openwrt/rootfs:aarch64_generic-24.10.8'
IMAGE_DIGEST='sha256:f6dd33c1d9b7d6f1e0848f2fbb92b8d03fc9b425dc08c3574a44936b93133704'

if [ "${1:-}" != '--inside' ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 1
    EVIDENCE_ROOT=$(mktemp -d /tmp/outdoor-backup-hotplug-service.XXXXXX) || exit 1
    python3 "$REPO_ROOT/tests/run-local-container.py" --evidence "$EVIDENCE_ROOT" -- \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-hotplug-service.sh --inside
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

REPO_ROOT=/src
HOTPLUG_SRC="$REPO_ROOT/files/etc/hotplug.d/block/90-outdoor-backup"
SERVICE_CONTROL_SRC="$REPO_ROOT/files/opt/outdoor-backup/scripts/service-control.sh"
TEST_CAPTURED_STDERR=1
TEST_ASYNC_STDERR=/tmp/outdoor-backup-hotplug-service.stderr
TEST_TARGET_MANAGER_LIBRARY_ONLY=1
# shellcheck disable=SC1090
. "$REPO_ROOT/test-target-manager.sh"

CASES=0
ASSERTIONS=0
FAILED=0
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

assert_absent() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "$2 (exists=[$1])"
}

assert_not_contains() {
    ASSERTIONS=$((ASSERTIONS + 1))
    grep -F -q -- "$1" "$2" && fail "$3 (unexpected=[$1])"
}

assert_contains() {
    ASSERTIONS=$((ASSERTIONS + 1))
    grep -F -q -- "$1" "$2" || fail "$3 (missing=[$1])"
}

track_pid() { ACTIVE_PIDS="$ACTIVE_PIDS $1"; }

cleanup() {
    for child_pid in $ACTIVE_PIDS; do
        kill -TERM "$child_pid" 2>/dev/null || :
        wait "$child_pid" 2>/dev/null || :
    done
    if ! unmount_target; then
        printf '%s\n' 'FAIL: hotplug fixture target unmount failed' >&2
        exit 1
    fi
    rm -rf "$SUITE_ROOT" /opt/outdoor-backup
}

wait_path() {
    watched_path=$1 watched_pid=$2 label=$3 elapsed=0
    while [ "$elapsed" -lt 15 ]; do
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

wait_exit() {
    watched_pid=$1 label=$2 elapsed=0
    while kill -0 "$watched_pid" 2>/dev/null; do
        state=$(awk '{print $3}' "/proc/$watched_pid/stat" 2>/dev/null || :)
        [ "$state" = Z ] && break
        [ "$elapsed" -lt 15 ] || { fail "$label did not exit"; return 124; }
        /bin/sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$watched_pid"
}

prepare_hotplug_case() {
    reset_case || return 1
    INSTALL_ROOT="$TEST_ROOT/installed/opt/outdoor-backup"
    HOTPLUG_BIN="$TEST_ROOT/hotplug-bin"
    mkdir -p "$INSTALL_ROOT" "$HOTPLUG_BIN" || return 1
    cp -LR "$RUNTIME/scripts" "$INSTALL_ROOT/" || return 1
    cp -R "$RUNTIME/conf" "$INSTALL_ROOT/" || return 1
    ln -s "$RUNTIME/var" "$INSTALL_ROOT/var" || return 1
    cp "$SERVICE_CONTROL_SRC" "$INSTALL_ROOT/scripts/service-control.sh" || return 1
    cp "$REPO_ROOT/files/opt/outdoor-backup/scripts/backup-manager.sh" \
        "$INSTALL_ROOT/scripts/backup-manager.real.sh" || return 1
    cat > "$INSTALL_ROOT/scripts/backup-manager.sh" <<'EOF'
#!/bin/ash
printf '%s\000' "$@" > "${TEST_HOTPLUG_MANAGER_ARGV:?}"
printf '%s\n' "${OUTDOOR_BACKUP_SERVICE_GENERATION+x}:${OUTDOOR_BACKUP_SERVICE_GENERATION-}" > "${TEST_HOTPLUG_MANAGER_GENERATION:?}"
/bin/ash "$(dirname "$0")/backup-manager.real.sh" "$@" > "${TEST_HOTPLUG_MANAGER_OUT:?}" 2>&1
manager_rc=$?
printf '%s\n' "$manager_rc" > "${TEST_HOTPLUG_MANAGER_RC:?}"
exit "$manager_rc"
EOF
    chmod 700 "$INSTALL_ROOT/scripts/backup-manager.sh" || return 1
    cat > "$HOTPLUG_BIN/sleep" <<'EOF'
#!/bin/ash
if [ "$#" -eq 1 ] && [ "$1" = 2 ]; then
    : > "${TEST_HOTPLUG_SETTLE_READY:?}"
    while [ ! -e "${TEST_HOTPLUG_SETTLE_RELEASE:?}" ]; do /bin/sleep 1; done
    exit 0
fi
exec "${TEST_HOTPLUG_FIXTURE_SLEEP:?}" "$@"
EOF
    chmod 700 "$HOTPLUG_BIN/sleep" || return 1
    rm -rf /opt/outdoor-backup
    ln -s "$INSTALL_ROOT" /opt/outdoor-backup || return 1
    TEST_HOTPLUG_MANAGER_ARGV="$TEST_ROOT/manager.argv"
    TEST_HOTPLUG_MANAGER_GENERATION="$TEST_ROOT/manager.generation"
    TEST_HOTPLUG_MANAGER_RC="$TEST_ROOT/manager.rc"
    TEST_HOTPLUG_MANAGER_OUT="$TEST_ROOT/manager.out"
    TEST_HOTPLUG_SETTLE_READY="$TEST_ROOT/settle.ready"
    TEST_HOTPLUG_SETTLE_RELEASE="$TEST_ROOT/settle.release"
    TEST_HOTPLUG_FIXTURE_SLEEP="$BIN/sleep"
    export TEST_HOTPLUG_MANAGER_ARGV TEST_HOTPLUG_MANAGER_GENERATION TEST_HOTPLUG_MANAGER_RC TEST_HOTPLUG_MANAGER_OUT
    export TEST_HOTPLUG_SETTLE_READY TEST_HOTPLUG_SETTLE_RELEASE TEST_HOTPLUG_FIXTURE_SLEEP
}

start_hotplug_add() {
    PATH="$HOTPLUG_BIN:$BIN:$PATH" TEST_EFFECTS="$EFFECTS" TEST_NOTICES="$NOTICES" \
        TEST_TIMER_READY="$TEST_ROOT/timer-ready" TEST_TIMER_RELEASE="$TEST_ROOT/timer-release" \
        TEST_TIMER_PID="$TEST_ROOT/timer-pid" TEST_LOCK_LINK="$RUNTIME/var/lock/backup.lock" \
        SUBSYSTEM=block ACTION=add DEVTYPE=partition DEVNAME=sda1 DEVPATH=/devices/mock/card-reader/sda1 SEQNUM=91 \
        OUTDOOR_BACKUP_CONFIG="$INSTALL_ROOT/conf/backup.conf" \
        OUTDOOR_BACKUP_CONFIG_SCRIPT="$INSTALL_ROOT/scripts/config.sh" \
        OUTDOOR_BACKUP_SERVICE_DIR="$SERVICE_RUNTIME" OUTDOOR_BACKUP_RC_DIR="$SERVICE_RC_DIR" \
        OUTDOOR_BACKUP_INIT_SCRIPT="$SERVICE_INIT_SCRIPT" /bin/ash "$HOTPLUG_SRC" >"$TEST_ROOT/hotplug.out" 2>&1 &
    HOTPLUG_PID=$!
    track_pid "$HOTPLUG_PID"
}

run_controller() {
    OUTDOOR_BACKUP_SERVICE_DIR="$SERVICE_RUNTIME" OUTDOOR_BACKUP_RC_DIR="$SERVICE_RC_DIR" \
        OUTDOOR_BACKUP_INIT_SCRIPT="$SERVICE_INIT_SCRIPT" /bin/ash \
        "$INSTALL_ROOT/scripts/service-control.sh" "$1" >"$TEST_ROOT/controller-$1.out" 2>&1
}

case_hs01_running_passes_captured_generation_and_event_argv() {
    begin_case HS01 'running add captures its generation before settle and passes exactly four original event arguments'
    prepare_hotplug_case || { fail 'HS01 fixture setup failed'; return; }
    printf 'running:7' > "$SERVICE_RUNTIME/state"
    start_hotplug_add
    wait_path "$TEST_HOTPLUG_SETTLE_READY" "$HOTPLUG_PID" 'HS01 hotplug settle barrier' || return
    : > "$TEST_HOTPLUG_SETTLE_RELEASE"
    wait_path "$TEST_HOTPLUG_MANAGER_RC" "$$" 'HS01 real manager result' || return
    expected_argv="$TEST_ROOT/expected.argv"
    printf 'add\000sda1\000/devices/mock/card-reader/sda1\00091\000' > "$expected_argv"
    assert_equal "$(cmp -s "$TEST_HOTPLUG_MANAGER_ARGV" "$expected_argv"; printf '%s' "$?")" 0 \
        'HS01 manager receives unchanged four-slot add argv'
    assert_equal "$(cat "$TEST_HOTPLUG_MANAGER_GENERATION")" 'x:7' \
        'HS01 manager receives the captured running generation as an explicit environment value'
}

case_hs02_stopped_and_bad_state_fail_closed_without_settle() {
    begin_case HS02 'stopped, malformed, and missing lifecycle state reject add without sleep or manager dispatch'
    for state_kind in stopped malformed missing-library; do
        prepare_hotplug_case || { fail "HS02 $state_kind fixture setup failed"; return; }
        case "$state_kind" in
            stopped) printf 'stopped:7' > "$SERVICE_RUNTIME/state" ;;
            malformed) printf 'broken:7' > "$SERVICE_RUNTIME/state" ;;
            missing-library) rm -f "$INSTALL_ROOT/scripts/service-state.sh" ;;
        esac
        if start_hotplug_add; then :; fi
        wait "$HOTPLUG_PID" || hotplug_rc=$?
        hotplug_rc=${hotplug_rc:-0}
        # The current production trigger reaches the barrier asynchronously. A
        # bounded post-parent observation distinguishes that dispatch from an
        # add branch that synchronously rejected lifecycle state before spawn.
        /bin/sleep 1
        case "$state_kind" in
            stopped) assert_equal "$hotplug_rc" 0 'HS02 stopped is a normal no-op' ;;
            *) assert_equal "$hotplug_rc" 1 "HS02 $state_kind fails closed" ;;
        esac
        assert_absent "$TEST_HOTPLUG_SETTLE_READY" "HS02 $state_kind never starts settle sleep"
        assert_absent "$TEST_HOTPLUG_MANAGER_ARGV" "HS02 $state_kind never dispatches manager"
        case "$state_kind" in
            malformed) assert_contains 'service state read failed' "$NOTICES" \
                'HS02 malformed state emits an explicit lifecycle read diagnostic' ;;
            missing-library) assert_contains 'service-state library unavailable' "$NOTICES" \
                'HS02 missing library emits an explicit lifecycle library diagnostic' ;;
        esac
    done
}

case_hs03_old_delayed_event_remains_old_after_real_restart() {
    begin_case HS03 'real stop/start during settle rejects the old event while a fresh add uses the new epoch'
    prepare_hotplug_case || { fail 'HS03 fixture setup failed'; return; }
    printf 'running:0' > "$SERVICE_RUNTIME/state"
    start_hotplug_add
    wait_path "$TEST_HOTPLUG_SETTLE_READY" "$HOTPLUG_PID" 'HS03 old hotplug settle barrier' || return
    assert_success 'HS03 real controller stops old generation' run_controller stop
    assert_success 'HS03 real controller starts next generation' run_controller start
    assert_equal "$(cat "$SERVICE_RUNTIME/state")" 'running:1' \
        'HS03 real stop/start advances state epoch during the delayed add'
    : > "$TEST_HOTPLUG_SETTLE_RELEASE"
    wait_path "$TEST_HOTPLUG_MANAGER_RC" "$$" 'HS03 old real manager result' || return
    assert_equal "$(cat "$TEST_HOTPLUG_MANAGER_GENERATION")" 'x:0' \
        'HS03 delayed add retains its pre-settle epoch instead of rereading new state'
    assert_equal "$(cat "$TEST_HOTPLUG_MANAGER_RC")" 2 \
        'HS03 real manager rejects delayed old epoch after restart'
    assert_absent "$RUNTIME/var/status.json" 'HS03 rejected old event writes no status'
    assert_absent "$RUNTIME/var/lock/backup.lock" 'HS03 rejected old event leaves no business lock'

    rm -f "$TEST_HOTPLUG_MANAGER_ARGV" "$TEST_HOTPLUG_MANAGER_GENERATION" "$TEST_HOTPLUG_MANAGER_RC" \
        "$TEST_HOTPLUG_SETTLE_READY" "$TEST_HOTPLUG_SETTLE_RELEASE"
    start_hotplug_add
    wait_path "$TEST_HOTPLUG_SETTLE_READY" "$HOTPLUG_PID" 'HS03 fresh hotplug settle barrier' || return
    : > "$TEST_HOTPLUG_SETTLE_RELEASE"
    wait_path "$TEST_HOTPLUG_MANAGER_RC" "$$" 'HS03 fresh real manager result' || return
    assert_equal "$(cat "$TEST_HOTPLUG_MANAGER_GENERATION")" 'x:1' \
        'HS03 fresh add captures restarted epoch'
    assert_not_contains 'service admission not admitted' "$TEST_HOTPLUG_MANAGER_OUT" \
        'HS03 fresh add passes the real manager admission gate'
    assert_not_contains 'service state error' "$TEST_HOTPLUG_MANAGER_OUT" \
        'HS03 fresh add does not fail the real manager lifecycle parser'
}

case_hs04_remove_dispatches_without_lifecycle_library() {
    begin_case HS04 'remove dispatches unchanged while stopped or lifecycle library is absent'
    prepare_hotplug_case || { fail 'HS04 fixture setup failed'; return; }
    printf 'stopped:7' > "$SERVICE_RUNTIME/state"
    rm -f "$INSTALL_ROOT/scripts/service-state.sh"
    cat > "$INSTALL_ROOT/scripts/backup-manager.sh" <<'EOF'
#!/bin/ash
printf '%s\000' "$@" > "${TEST_HOTPLUG_MANAGER_ARGV:?}"
exit 0
EOF
    chmod 700 "$INSTALL_ROOT/scripts/backup-manager.sh"
    SUBSYSTEM=block ACTION=remove DEVTYPE=disk DEVNAME=sda DEVPATH=/devices/mock/sda SEQNUM=92 \
        /bin/ash "$HOTPLUG_SRC" >"$TEST_ROOT/remove.out" 2>&1
    wait_path "$TEST_HOTPLUG_MANAGER_ARGV" $$ 'HS04 remove manager dispatch' || return
    expected_argv="$TEST_ROOT/remove.expected"
    printf 'remove\000sda\000/devices/mock/sda\00092\000' > "$expected_argv"
    assert_equal "$(cmp -s "$TEST_HOTPLUG_MANAGER_ARGV" "$expected_argv"; printf '%s' "$?")" 0 \
        'HS04 remove preserves its original four event arguments'
}

main() {
    trap cleanup EXIT INT TERM
    case_hs01_running_passes_captured_generation_and_event_argv
    case_hs02_stopped_and_bad_state_fail_closed_without_settle
    case_hs03_old_delayed_event_remains_old_after_real_restart
    case_hs04_remove_dispatches_without_lifecycle_library
    assert_equal "$CASES" 4 'all hotplug service cases executed'
    assert_equal "$ASSERTIONS" 25 'all hotplug service assertions executed exactly'
    printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
    [ "$FAILED" -eq 0 ]
}

main "$@"

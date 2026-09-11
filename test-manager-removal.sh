#!/bin/sh
#
# BDD integration tests for remove-event ownership matching. This suite reuses
# the real target-manager fixture and invokes the shipped manager and hotplug
# entrypoints; it never copies their action branches into a test double.
#
set -u

case "$(uname -m)" in
    arm64|aarch64)
        PLATFORM=linux/aarch64_generic
        IMAGE='openwrt/rootfs@sha256:f6dd33c1d9b7d6f1e0848f2fbb92b8d03fc9b425dc08c3574a44936b93133704'
        ;;
    x86_64|amd64)
        PLATFORM=linux/amd64
        IMAGE='openwrt/rootfs:x86_64-24.10.8@sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9'
        ;;
    *)
        printf 'FAIL: unsupported host architecture for remove-event tests: %s\n' "$(uname -m)" >&2
        exit 1
        ;;
esac

if [ "${1:-}" != '--inside' ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform "$PLATFORM" --network bridge \
        --cap-add SYS_ADMIN --security-opt seccomp=unconfined --tmpfs /tmp:rw,exec --tmpfs /opt:rw,exec \
        -v "$REPO_ROOT:/src:ro" "$IMAGE" /bin/ash /src/test-manager-removal.sh --inside
fi

[ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || {
    printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
    exit 1
}

# Import only fixture infrastructure. Its library-only guard prevents the old
# suite from running while keeping its real target/mount/status doubles.
TEST_CAPTURED_STDERR=1
TEST_ASYNC_STDERR=/tmp/outdoor-backup-manager-removal.stderr
TEST_TARGET_MANAGER_LIBRARY_ONLY=1
. /src/test-target-manager.sh

OWNER_EVENT_SOURCE=/src/files/opt/outdoor-backup/scripts/owner-event.sh
TARGET_DEVICE_SOURCE=/src/files/opt/outdoor-backup/scripts/target-device.sh
HOTPLUG_SOURCE=/src/files/etc/hotplug.d/block/90-outdoor-backup
MR_CASES=0
MR_ASSERTIONS=0
MR_FAILED=0

mr_fail() { printf 'FAIL: %s\n' "$1" >&2; MR_FAILED=$((MR_FAILED + 1)); }
mr_case() { MR_CASES=$((MR_CASES + 1)); printf 'CASE %s: %s\n' "$1" "$2"; }
mr_equal() {
    actual=$1 expected=$2 message=$3
    MR_ASSERTIONS=$((MR_ASSERTIONS + 1))
    [ "$actual" = "$expected" ] || mr_fail "$message (expected=[$expected], actual=[$actual])"
}
mr_success() {
    message=$1
    shift
    MR_ASSERTIONS=$((MR_ASSERTIONS + 1))
    "$@" || mr_fail "$message"
}
mr_failure() {
    message=$1
    shift
    MR_ASSERTIONS=$((MR_ASSERTIONS + 1))
    if "$@"; then mr_fail "$message"; fi
}
mr_absent() {
    path=$1 message=$2
    MR_ASSERTIONS=$((MR_ASSERTIONS + 1))
    [ ! -e "$path" ] && [ ! -L "$path" ] || mr_fail "$message (path=[$path])"
}
mr_contains() {
    text=$1 file=$2 message=$3
    MR_ASSERTIONS=$((MR_ASSERTIONS + 1))
    grep -F -q -- "$text" "$file" 2>/dev/null || mr_fail "$message (missing=[$text])"
}
mr_not_contains() {
    text=$1 file=$2 message=$3
    MR_ASSERTIONS=$((MR_ASSERTIONS + 1))
    grep -F -q -- "$text" "$file" 2>/dev/null && mr_fail "$message (found=[$text])"
}
mr_wait_path() {
    path=$1 attempts=0
    while [ ! -e "$path" ] && [ "$attempts" -lt 15 ]; do
        /bin/sleep 1
        attempts=$((attempts + 1))
    done
    [ -e "$path" ]
}
mr_wait_exit() {
    pid=$1 attempts=0
    while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 15 ]; do
        /bin/sleep 1
        attempts=$((attempts + 1))
    done
    ! kill -0 "$pid" 2>/dev/null
}
mr_run_capture() {
    if run_manager "$@"; then MR_RC=0; else MR_RC=$?; fi
    return 0
}
mr_hash_or_absent() {
    if [ -f "$1" ] && [ ! -L "$1" ]; then sha256sum "$1" | awk '{print $1}'; else printf '%s\n' absent; fi
}

# Replace only the fixture runtime target.sh symlink with the delivered file.
# Rename the real entry and append a wrapper that marks then calls its body;
# production keeps neither the copy nor this observability seam.
instrument_runtime_target_open() {
    TEST_TARGET_OPEN_MARKER="$TEST_ROOT/target-open"
    export TEST_TARGET_OPEN_MARKER
    rm -f "$SCRIPTS/target.sh"
    sed 's/^target_open()[[:space:]]*{/target_open_real() {/' \
        "$REPO_ROOT/files/opt/outdoor-backup/scripts/target.sh" > "$SCRIPTS/target.sh" || return 1
    grep -F -q 'target_open_real() {' "$SCRIPTS/target.sh" || return 1
    cat >> "$SCRIPTS/target.sh" <<'EOF'
target_open() {
    : > "$TEST_TARGET_OPEN_MARKER"
    target_open_real "$@"
}
EOF
    chmod 700 "$SCRIPTS/target.sh"
}

# Copy only the runtime manager and replace the one add-event gate with a
# test marker. This Red control leaves production untouched while proving the
# mutant itself was selected before it is expected to reach target_open.
make_event_gate_mutant() {
    EVENT_GATE_MUTANT="$SCRIPTS/backup-manager-event-gate-mutated.sh"
    EVENT_GATE_BYPASS_MARKER="$TEST_ROOT/event-gate-bypassed"
    export EVENT_GATE_BYPASS_MARKER
    cp "$SCRIPTS/backup-manager.sh" "$EVENT_GATE_MUTANT" || return 1
    sed -i 's/^[[:space:]]*owner_event_validate_event .* || exit 1$/: > "$EVENT_GATE_BYPASS_MARKER"/' \
        "$EVENT_GATE_MUTANT" || return 1
    cmp -s "$SCRIPTS/backup-manager.sh" "$EVENT_GATE_MUTANT" && return 1
    grep -F -q 'owner_event_validate_event' "$EVENT_GATE_MUTANT" && return 1
    grep -F -q 'EVENT_GATE_BYPASS_MARKER' "$EVENT_GATE_MUTANT" || return 1
    rm -f "$SCRIPTS/backup-manager.sh"
    mv "$EVENT_GATE_MUTANT" "$SCRIPTS/backup-manager.sh" || return 1
    EVENT_GATE_MUTANT="$SCRIPTS/backup-manager.sh"
    chmod 700 "$EVENT_GATE_MUTANT"
}

# The exec wrapper ensures $! is the actual manager process, not a background
# helper shell with host job-control signal dispositions.
write_normal_signal_shell() {
    cat > "$BIN/normal-signal-ash" <<'EOF'
#!/bin/ash
exec /bin/ash "$@"
EOF
    chmod 700 "$BIN/normal-signal-ash"
}

# This writer exposes readiness before it loops. Its TERM handler drains its
# child before exit, so manager cleanup ordering is observed rather than slept.
write_active_rsync() {
    cat > "$BIN/rsync" <<'EOF'
#!/bin/ash
: > "$TEST_REMOVE_READY"
(
    trap 'exit 0' TERM
    : > "$TEST_REMOVE_CHILD_READY"
    while :; do printf 'child-write\n' >> "$TEST_REMOVE_TRACE"; /bin/sleep 1; done
) &
child=$!
printf '%s\n' "$child" > "$TEST_REMOVE_CHILD_PID"
trap 'wait "$child" 2>/dev/null; exit 0' TERM
while :; do printf 'leader-write\n' >> "$TEST_REMOVE_TRACE"; /bin/sleep 1; done
EOF
    chmod 700 "$BIN/rsync"
}

# Start a valid six-slot add owner. DEVPATH ends in DEVNAME because this is an
# event identity test, unlike legacy target-manager add fixture calls.
start_active_owner() {
    seq=$1
    write_normal_signal_shell
    write_active_rsync
    TEST_RUN_MANAGER_EXEC=1 TEST_MANAGER_SHELL="$BIN/normal-signal-ash" \
        TEST_REMOVE_READY="$TEST_ROOT/remove-ready" \
        TEST_REMOVE_CHILD_READY="$TEST_ROOT/remove-child-ready" \
        TEST_REMOVE_CHILD_PID="$TEST_ROOT/remove-child-pid" \
        TEST_REMOVE_TRACE="$TEST_ROOT/remove-trace" \
        TEST_MOUNT_AUTO_CARD=1 TEST_RSYNC_STATS=1 \
        run_manager add sda1 /devices/mock/sda/sda1 "$seq" &
    OWNER_PID=$!
    mr_success 'owner transfer leader reached observable readiness' mr_wait_path "$TEST_ROOT/remove-ready"
    mr_success 'owner transfer child reached observable readiness' mr_wait_path "$TEST_ROOT/remove-child-ready"
    mr_success 'owner published the expected lock' test -L "$RUNTIME/var/lock/backup.lock"
}

# Invoke remove as a separately executed production manager and retain its rc.
request_remove() {
    mr_run_capture remove "$@"
}

# End only this test-created process when a case intentionally proves it was
# not auto-cancelled. This is not a broad cleanup or an authorization test.
stop_exact_owner() {
    pid=$1
    kill -TERM "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
}

assert_cancelled_owner() {
    label=$1
    mr_success "$label owner exits after directed TERM" mr_wait_exit "$OWNER_PID"
    owner_rc=0
    wait "$OWNER_PID" 2>/dev/null || owner_rc=$?
    mr_equal "$owner_rc" 143 "$label owner preserves TERM result"
    mr_success "$label records cancelled terminal status, never completed" \
        /bin/sh -c 'jq -e "(.history[0].status == \"error\" and .history[0].error_message == \"cancelled\" and ([.history[].status] | index(\"completed\") == null))" "$1" >/dev/null' sh "$RUNTIME/var/status.json"
    writes_before=$(wc -l < "$TEST_ROOT/remove-trace")
    /bin/sleep 2
    writes_after=$(wc -l < "$TEST_ROOT/remove-trace")
    mr_equal "$writes_after" "$writes_before" "$label writer is drained before manager returns"
    mr_success "$label writer drain precedes source unmount and lock release" \
        /bin/sh -c 'u=$(grep -n "source-umount" "$1" | cut -d: -f1); l=$(grep -n "lock-unlink" "$1" | cut -d: -f1); [ -n "$u" ] && [ -n "$l" ] && [ "$u" -lt "$l" ]' sh "$EFFECTS"
}

case_r01_matching_remove_cancels_once() {
    mr_case R01 'newer matching remove directs one owner TERM through existing cancellation lifecycle'
    reset_case || { mr_fail 'R01 fixture setup failed'; return; }
    start_active_owner 10
    request_remove sda1 /devices/mock/sda/sda1 11
    mr_equal "$MR_RC" 0 'R01 matching remove succeeds'
    assert_cancelled_owner R01
    status_before=$(mr_hash_or_absent "$RUNTIME/var/status.json")
    unlink_count_before=$(grep -F -c lock-unlink "$EFFECTS" || :)
    request_remove sda1 /devices/mock/sda/sda1 12
    mr_equal "$MR_RC" 0 'R01 repeated remove is an authorized no-op after owner exit'
    mr_equal "$(mr_hash_or_absent "$RUNTIME/var/status.json")" "$status_before" \
        'R01 repeated remove does not rewrite terminal status'
    mr_equal "$(grep -F -c lock-unlink "$EFFECTS" || :)" "$unlink_count_before" \
        'R01 repeated remove does not repeat owner cleanup'
}

case_r02_waiter_remove_does_not_touch_owner() {
    mr_case R02 'remove for a waiting manager does not affect an active different owner'
    reset_case || { mr_fail 'R02 fixture setup failed'; return; }
    start_active_owner 10
    add_partition sda sdb1 8:2
    TEST_RUN_MANAGER_EXEC=1 TEST_MANAGER_SHELL="$BIN/normal-signal-ash" \
        TEST_SLEEP_PASSTHROUGH=1 LOCK_TIMEOUT=15 LOCK_INTERVAL=1 \
        run_manager add sdb1 /devices/mock/sdb1 20 &
    waiter_pid=$!
    /bin/sleep 1
    lock_before=$(readlink "$RUNTIME/var/lock/backup.lock")
    status_before=$(mr_hash_or_absent "$RUNTIME/var/status.json")
    trace_before=$(wc -l < "$TEST_ROOT/remove-trace")
    request_remove sdb1 /devices/mock/sdb1 21
    mr_equal "$MR_RC" 0 'R02 unmatched waiting remove is an authorized no-op'
    mr_success 'R02 active owner remains alive' kill -0 "$OWNER_PID"
    mr_equal "$(readlink "$RUNTIME/var/lock/backup.lock")" "$lock_before" \
        'R02 active lock remains unchanged'
    /bin/sleep 2
    trace_after=$(wc -l < "$TEST_ROOT/remove-trace")
    MR_ASSERTIONS=$((MR_ASSERTIONS + 1))
    [ "$trace_after" -gt "$trace_before" ] || mr_fail 'R02 active writer continued after waiter removal'
    mr_equal "$(mr_hash_or_absent "$RUNTIME/var/status.json")" "$status_before" \
        'R02 waiter removal does not rewrite active owner status'
    # Waiters are intentionally outside this batch's authorization contract.
    stop_exact_owner "$waiter_pid"
    stop_exact_owner "$OWNER_PID"
}

case_r03_path_relation_is_exact() {
    mr_case R03 'only exact and direct-parent remove paths authorize the active owner'
    reset_case || { mr_fail 'R03 sibling fixture setup failed'; return; }
    start_active_owner 10
    request_remove sda2 /devices/mock/sda/sda2 11
    mr_equal "$MR_RC" 0 'R03 sibling remove is no-op'
    mr_success 'R03 sibling does not signal owner' kill -0 "$OWNER_PID"
    request_remove sda10 /devices/mock/sda/sda10 11
    mr_equal "$MR_RC" 0 'R03 devname prefix remove is no-op'
    mr_success 'R03 prefix does not signal owner' kill -0 "$OWNER_PID"
    request_remove mock /devices/mock 11
    mr_equal "$MR_RC" 0 'R03 grandparent remove is no-op'
    mr_success 'R03 grandparent does not signal owner' kill -0 "$OWNER_PID"
    request_remove sda /devices/mock/sda 11
    mr_equal "$MR_RC" 0 'R03 direct parent disk remove succeeds'
    assert_cancelled_owner R03
}

case_r04_sequence_and_legacy_forms_are_safe() {
    mr_case R04 'old equal and legacy events cannot cancel a new event owner'
    reset_case || { mr_fail 'R04 fixture setup failed'; return; }
    start_active_owner 10
    request_remove sda1 /devices/mock/sda/sda1 9
    mr_equal "$MR_RC" 0 'R04 older sequence is no-op'
    request_remove sda1 /devices/mock/sda/sda1 10
    mr_equal "$MR_RC" 0 'R04 equal sequence is no-op'
    mr_success 'R04 old/equal sequences leave owner alive' kill -0 "$OWNER_PID"
    request_remove sda1 /devices/mock/sda/sda1 11
    mr_equal "$MR_RC" 0 'R04 newer sequence cancels owner'
    assert_cancelled_owner R04

    reset_case || { mr_fail 'R04 legacy fixture setup failed'; return; }
    write_normal_signal_shell
    write_active_rsync
    TEST_RUN_MANAGER_EXEC=1 TEST_MANAGER_SHELL="$BIN/normal-signal-ash" \
        TEST_REMOVE_READY="$TEST_ROOT/remove-ready" TEST_REMOVE_CHILD_READY="$TEST_ROOT/remove-child-ready" \
        TEST_REMOVE_CHILD_PID="$TEST_ROOT/remove-child-pid" TEST_REMOVE_TRACE="$TEST_ROOT/remove-trace" \
        TEST_MOUNT_AUTO_CARD=1 TEST_RSYNC_STATS=1 run_manager add sda1 /devices/mock/sda/sda1 &
    legacy_pid=$!
    mr_success 'R04 legacy three-argument add reaches active transfer' mr_wait_path "$TEST_ROOT/remove-ready"
    request_remove sda1 /devices/mock/sda/sda1 11
    mr_equal "$MR_RC" 0 'R04 new remove cannot authorize legacy owner without sequence'
    mr_success 'R04 legacy owner remains alive' kill -0 "$legacy_pid"
    request_remove sda1 /devices/mock/sda/sda1
    mr_equal "$MR_RC" 0 'R04 legacy three-argument remove remains compatible no-op'
    mr_contains 'remove event lacks identity' "$NOTICES" 'R04 legacy remove is classified without input echo'
    stop_exact_owner "$legacy_pid"
}

case_r05_bad_events_and_bad_config_have_no_shared_side_effects() {
    mr_case R05 'invalid new remove fails before resources while valid remove ignores broken config'
    reset_case || { mr_fail 'R05 no-owner fixture setup failed'; return; }
    effects_before=$(wc -c < "$EFFECTS")
    request_remove sda1 /devices/mock/sda/sda1 0
    MR_ASSERTIONS=$((MR_ASSERTIONS + 1))
    [ "$MR_RC" -ne 0 ] || mr_fail 'R05 zero sequence unexpectedly succeeded'
    mr_equal "$(wc -c < "$EFFECTS")" "$effects_before" 'R05 invalid event creates no shared effect'
    mr_not_contains pkill "$EFFECTS" 'R05 invalid event never invokes retired pkill control'
    bad_seq='1
2'
    request_remove sda1 /devices/mock/sda/sda1 "$bad_seq"
    MR_ASSERTIONS=$((MR_ASSERTIONS + 1))
    [ "$MR_RC" -ne 0 ] || mr_fail 'R05 newline sequence unexpectedly passed manager validation'
    request_remove sda1 /devices/mock/sda/sda1
    mr_equal "$MR_RC" 0 'R05 legacy remove has no dependency requirement'

    reset_case || { mr_fail 'R05 bad-config fixture setup failed'; return; }
    start_active_owner 10
    printf 'BACKUP_ROOT="relative"\n' > "$RUNTIME/conf/backup.conf"
    request_remove sda1 /devices/mock/sda/sda1 11
    mr_equal "$MR_RC" 0 'R05 valid remove bypasses now-bad runtime configuration'
    assert_cancelled_owner R05
}

write_hotplug_spy() {
    mkdir -p /opt/outdoor-backup/scripts
    cat > /opt/outdoor-backup/scripts/backup-manager.sh <<'EOF'
#!/bin/ash
printf '%s\n' "$#" > "$TEST_HOTPLUG_ARGC"
printf '%s\000' "$@" > "$TEST_HOTPLUG_ARGV"
EOF
    chmod 700 /opt/outdoor-backup/scripts/backup-manager.sh
}
assert_hotplug_argv() {
    expected=$1
    message=$2
    mr_success "$message" \
        /bin/sh -c 'jq -eRs --argjson expected "$1" "split(\"\\u0000\")[:-1] == \$expected" "$2" >/dev/null' sh "$expected" "$TEST_ROOT/hotplug-argv"
}

case_r06_real_hotplug_dispatches_remove_without_reader_config() {
    mr_case R06 'real block hotplug forwards disk and partition remove events without sysfs or reader config'
    reset_case || { mr_fail 'R06 fixture setup failed'; return; }
    write_hotplug_spy
    TEST_HOTPLUG_ARGC="$TEST_ROOT/hotplug-argc" TEST_HOTPLUG_ARGV="$TEST_ROOT/hotplug-argv" \
        SUBSYSTEM=block ACTION=remove DEVTYPE=disk DEVNAME=sda DEVPATH=/devices/mock/sda SEQNUM=71 \
        OUTDOOR_BACKUP_CONFIG_SCRIPT="$TEST_ROOT/missing-config.sh" /bin/ash "$HOTPLUG_SOURCE"
    mr_success 'R06 disk remove invokes manager despite missing reader config' mr_wait_path "$TEST_ROOT/hotplug-argv"
    mr_equal "$(cat "$TEST_ROOT/hotplug-argc")" 4 'R06 disk remove forwards four manager fields'
    assert_hotplug_argv '["remove","sda","/devices/mock/sda","71"]' \
        'R06 disk remove manager argv is exact and fully recorded'

    rm -f "$TEST_ROOT/hotplug-argv" "$TEST_ROOT/hotplug-argc"
    TEST_HOTPLUG_ARGC="$TEST_ROOT/hotplug-argc" TEST_HOTPLUG_ARGV="$TEST_ROOT/hotplug-argv" \
        SUBSYSTEM=block ACTION=remove DEVTYPE=partition DEVNAME=sda1 DEVPATH=/devices/mock/sda/sda1 SEQNUM=72 \
        OUTDOOR_BACKUP_CONFIG_SCRIPT="$TEST_ROOT/missing-config.sh" /bin/ash "$HOTPLUG_SOURCE"
    mr_success 'R06 partition remove invokes manager despite missing reader config' mr_wait_path "$TEST_ROOT/hotplug-argv"
    assert_hotplug_argv '["remove","sda1","/devices/mock/sda/sda1","72"]' \
        'R06 partition remove manager argv is exact and fully recorded'

    rm -f "$TEST_ROOT/hotplug-argv" "$TEST_ROOT/hotplug-argc"
    TEST_HOTPLUG_ARGC="$TEST_ROOT/hotplug-argc" TEST_HOTPLUG_ARGV="$TEST_ROOT/hotplug-argv" \
        SUBSYSTEM=block ACTION=add DEVTYPE=partition DEVNAME=sda1 DEVPATH=/devices/mock/card-reader/sda1 SEQNUM=73 \
        OUTDOOR_BACKUP_CONFIG="$TEST_ROOT/no-config" OUTDOOR_BACKUP_CONFIG_SCRIPT=/src/files/opt/outdoor-backup/scripts/config.sh \
        /bin/ash "$HOTPLUG_SOURCE"
    mr_success 'R06 recognized partition add preserves settle then dispatches manager' mr_wait_path "$TEST_ROOT/hotplug-argv"
    assert_hotplug_argv '["add","sda1","/devices/mock/card-reader/sda1","73"]' \
        'R06 add manager argv is exact and fully recorded'

    rm -f "$TEST_ROOT/hotplug-argv" "$TEST_ROOT/hotplug-argc"
    bad_seq='7
8'
    TEST_HOTPLUG_ARGC="$TEST_ROOT/hotplug-argc" TEST_HOTPLUG_ARGV="$TEST_ROOT/hotplug-argv" \
        SUBSYSTEM=block ACTION=remove DEVTYPE=disk DEVNAME=sda DEVPATH=/devices/mock/sda SEQNUM="$bad_seq" \
        OUTDOOR_BACKUP_CONFIG_SCRIPT="$TEST_ROOT/missing-config.sh" /bin/ash "$HOTPLUG_SOURCE"
    mr_success 'R06 control characters remain quoted data through hotplug dispatch' mr_wait_path "$TEST_ROOT/hotplug-argv"
    assert_hotplug_argv '["remove","sda","/devices/mock/sda","7\n8"]' \
        'R06 quoted control-character sequence manager argv is exact and fully recorded'
}

assert_enabled_add_rejects_before_target() {
    label=$1
    devname=$2
    devpath=$3
    seqnum=$4
    manager_path=$5
    rm -f "$TEST_TARGET_OPEN_MARKER"
    effects_before=$(wc -c < "$EFFECTS")
    MANAGER_SCRIPT=$manager_path
    export MANAGER_SCRIPT
    mr_run_capture add "$devname" "$devpath" "$seqnum"
    unset MANAGER_SCRIPT
    MR_ASSERTIONS=$((MR_ASSERTIONS + 1))
    [ "$MR_RC" -ne 0 ] || mr_fail "$label invalid enabled add unexpectedly succeeded"
    mr_absent "$TEST_TARGET_OPEN_MARKER" "$label rejects before target_open"
    mr_absent "$RUNTIME/var/lock/backup.lock" "$label creates no lock"
    mr_absent "$SOURCE_MOUNT_STATE" "$label does not mount source"
    mr_absent "$SOURCE_MOUNT/FieldBackup.conf" "$label does not write source configuration"
    mr_equal "$(wc -c < "$EFFECTS")" "$effects_before" "$label creates no target or lifecycle effect"
}

case_r07_enabled_add_event_gate_precedes_target() {
    mr_case R07 'enabled bad four-argument add is rejected before target ownership or lifecycle work'
    reset_case || { mr_fail 'R07 zero-sequence fixture setup failed'; return; }
    mr_success 'R07 instruments only the runtime target-open entry' instrument_runtime_target_open
    assert_enabled_add_rejects_before_target R07-zero sda1 /devices/mock/sda/sda1 0 "$SCRIPTS/backup-manager.sh"
    assert_enabled_add_rejects_before_target R07-empty sda1 /devices/mock/sda/sda1 '' "$SCRIPTS/backup-manager.sh"
    assert_enabled_add_rejects_before_target R07-path sda1 /devices/mock/sda/not-sda1 1 "$SCRIPTS/backup-manager.sh"

    reset_case || { mr_fail 'R07 disabled fixture setup failed'; return; }
    mr_success 'R07 instruments disabled runtime target-open entry' instrument_runtime_target_open
    printf 'ENABLED=0\n' >> "$RUNTIME/conf/backup.conf"
    mr_run_capture add sda1 /devices/mock/sda/sda1 0
    mr_equal "$MR_RC" 0 'R07 disabled add retains pre-validation fast success'
    mr_absent "$TEST_TARGET_OPEN_MARKER" 'R07 disabled add does not enter target_open'
    mr_absent "$RUNTIME/var/lock/backup.lock" 'R07 disabled add creates no lock'
    mr_absent "$SOURCE_MOUNT_STATE" 'R07 disabled add does not mount source'
    mr_absent "$SOURCE_MOUNT/FieldBackup.conf" 'R07 disabled add does not write source configuration'
    mr_equal "$(wc -c < "$EFFECTS")" 0 'R07 disabled add creates no lifecycle effect'

    reset_case || { mr_fail 'R07 mutant fixture setup failed'; return; }
    mr_success 'R07 instruments mutant runtime target-open entry' instrument_runtime_target_open
    mr_success 'R07 deletes only the runtime add event gate for Red control' make_event_gate_mutant
    mr_run_capture add bad/name /devices/mock/bad/name 1
    if [ -e "$TEST_TARGET_OPEN_MARKER" ]; then mutant_target_open=yes; else mutant_target_open=no; fi
    printf 'MUTANT_RED R07 gate_bypassed=yes rc=%s target_open=%s\n' \
        "$MR_RC" "$mutant_target_open"
    MR_ASSERTIONS=$((MR_ASSERTIONS + 1))
    [ -e "$EVENT_GATE_BYPASS_MARKER" ] || mr_fail 'R07 mutant manager was not selected for Red control'
    MR_ASSERTIONS=$((MR_ASSERTIONS + 1))
    [ "$MR_RC" -ne 0 ] || mr_fail 'R07 mutant should fail only after target-device validation'
    MR_ASSERTIONS=$((MR_ASSERTIONS + 1))
    [ -e "$TEST_TARGET_OPEN_MARKER" ] || mr_fail 'R07 mutant did not reach target_open; Green gate assertion would be vacuous'
    mr_absent "$RUNTIME/var/lock/backup.lock" 'R07 mutant target guard still creates no lock'
    mr_absent "$SOURCE_MOUNT_STATE" 'R07 mutant target guard still does not mount source'
    mr_absent "$SOURCE_MOUNT/FieldBackup.conf" 'R07 mutant target guard still does not write source configuration'
}

main() {
    trap 'settle_led_fixture; unmount_target; rm -rf "$SUITE_ROOT" /opt/outdoor-backup "$TEST_ASYNC_STDERR"' EXIT INT TERM
    # Source the actual A API in this process as well, proving it remains inert
    # and available to the same fixture that executes the manager.
    . "$TARGET_DEVICE_SOURCE"
    . "$OWNER_EVENT_SOURCE"
    mr_success 'owner-event library validates canonical event in manager fixture' \
        owner_event_validate_event sda1 /devices/mock/sda/sda1 1
    case_r01_matching_remove_cancels_once
    case_r02_waiter_remove_does_not_touch_owner
    case_r03_path_relation_is_exact
    case_r04_sequence_and_legacy_forms_are_safe
    case_r05_bad_events_and_bad_config_have_no_shared_side_effects
    case_r06_real_hotplug_dispatches_remove_without_reader_config
    case_r07_enabled_add_event_gate_precedes_target
    mr_equal "$MR_CASES" 7 'all required manager-removal cases executed'
    if [ "$MR_FAILED" -ne 0 ]; then
        printf 'RESULT cases=%s assertions=%s failed=%s\n' "$MR_CASES" "$MR_ASSERTIONS" "$MR_FAILED"
        exit 1
    fi
    printf 'RESULT cases=%s assertions=%s failed=0\n' "$MR_CASES" "$MR_ASSERTIONS"
}

main "$@"

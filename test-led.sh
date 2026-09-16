#!/bin/sh
#
# BDD regression tests for the four-lamp LED state-machine primitives
# (issue #40). P01-P12 source the delivered common.sh directly: LED sysfs
# and logger are lightweight fixtures, and every led_state_* primitive is
# set-and-exit (no fork, no sleep, no background job), so those cases run
# synchronously in-process.
#
# P13/P14 (PR #41 review findings 5/11) instead drive the real
# backup-manager.sh as a genuine subprocess through a real "add" hotplug
# event, reusing test-target-manager.sh's already-established fixture
# engine (run_manager/reset_case/prepare_fixture_topology/prepare_runtime)
# via its TEST_TARGET_MANAGER_LIBRARY_ONLY=1 reuse convention -- the same
# technique test-manager-removal.sh, test-manager-source-identity.sh,
# test-hotplug-service.sh, test-manager-cancellation.sh, and
# test-live-progress.sh already use to get real manager behavior without
# re-running that suite's own 40 cases. Sourcing backup-manager.sh directly
# is not viable: it unconditionally dispatches on $ACTION at file top under
# set -e and `exit 1`s on anything but add/remove, which under `.` sourcing
# would kill this whole test runner.
#
set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${IN_OPENWRT_TEST:-}" != "1" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 \
        -e IN_OPENWRT_TEST=1 \
        --cap-add SYS_ADMIN --security-opt seccomp=unconfined \
        --tmpfs /tmp:rw,exec --tmpfs /opt:rw,exec \
        -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-led.sh --inside
fi

REPO_ROOT=/src
COMMON="$REPO_ROOT/files/opt/outdoor-backup/scripts/common.sh"
# P01-P12's own lightweight fixture root. Named distinctly from TEST_ROOT so
# it cannot collide with test-target-manager.sh's own TEST_ROOT/SUITE_ROOT
# globals once that suite is sourced below for P13/P14.
LED_UNIT_ROOT="/tmp/outdoor-backup-led-test.$$"
LED_UNIT_BIN="$LED_UNIT_ROOT/bin"
RED="$LED_UNIT_ROOT/red"
GREEN1="$LED_UNIT_ROOT/green1"
GREEN2="$LED_UNIT_ROOT/green2"
GREEN3="$LED_UNIT_ROOT/green3"
# Named distinctly from plain NOTICES: test-target-manager.sh's
# derive_fixture_paths (run at source time below, and again by every
# reset_case) unconditionally overwrites the global NOTICES to its own
# per-case path, which would silently redirect P01-P12's logger-complaint
# assertions to the wrong file if this var shared that name.
LED_UNIT_NOTICES="$LED_UNIT_ROOT/notices"
FILES_BEFORE="$LED_UNIT_ROOT/.files-before"
CASES=0
ASSERTIONS=0
FAILED=0

# Pull in test-target-manager.sh's real-subprocess manager fixture engine
# (run_manager/reset_case/prepare_fixture_topology/prepare_runtime/
# mount_target/unmount_target/settle_led_fixture/set_config_target_uuid)
# without running its own 40 cases. This also runs its top-of-file setup
# (mkdir /var/lock, opkg install jq flock) exactly once. Pass --inside as a
# source argument so its positional re-exec guard sees the already-container
# path; TEST_TARGET_MANAGER_LIBRARY_ONLY=1 only controls its later case runner.
TEST_CAPTURED_STDERR=1
TEST_ASYNC_STDERR="/tmp/outdoor-backup-led-test-async.$$.stderr"
TEST_TARGET_MANAGER_LIBRARY_ONLY=1
. "$REPO_ROOT/test-target-manager.sh" --inside

# test-target-manager.sh's own top-level init zeroed these; re-zero for
# test-led.sh's own counters (both suites' fail()/begin_case()/assert_*
# helpers below are redefined with identical semantics, kept local to this
# file rather than relied on forever).
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
    if [ "$actual" != "$expected" ]; then
        fail "$message (expected=[$expected], actual=[$actual])"
    fi
}

assert_success() {
    message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! "$@"; then
        fail "$message"
    fi
}

assert_file_contains() {
    needle=$1
    file=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ ! -e "$file" ] || ! grep -F -q -- "$needle" "$file"; then
        fail "$message (missing=[$needle])"
    fi
}

assert_file_lacks() {
    needle=$1
    file=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ -e "$file" ] && grep -F -q -- "$needle" "$file"; then
        fail "$message (unexpected=[$needle])"
    fi
}

assert_empty_file() {
    file=$1
    message=$2
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ -s "$file" ]; then
        fail "$message (unexpected content=[$(cat "$file")])"
    fi
}

cleanup() {
    rm -rf "$LED_UNIT_ROOT"
    settle_led_fixture
    unmount_target
    rm -rf "$SUITE_ROOT" /opt/outdoor-backup/conf "$ASYNC_STDERR"
}

# Reset all four LED fixture directories plus the logger/notices trace.
# Each LED gets trigger/brightness/delay_on/delay_off sysfs stand-ins.
prepare_led() {
    rm -rf "$LED_UNIT_ROOT"
    mkdir -p "$LED_UNIT_BIN" "$RED" "$GREEN1" "$GREEN2" "$GREEN3"
    : > "$LED_UNIT_NOTICES"
    for d in "$RED" "$GREEN1" "$GREEN2" "$GREEN3"; do
        : > "$d/trigger"
        : > "$d/brightness"
        : > "$d/delay_on"
        : > "$d/delay_off"
    done
    cat > "$LED_UNIT_BIN/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_NOTICES"
EOF
    chmod 755 "$LED_UNIT_BIN/logger"
}

# Run one or more common.sh functions in-process (no fork needed: every
# led_state_* primitive is synchronous set-and-exit).
run_common() {
    TEST_NOTICES="$LED_UNIT_NOTICES" LED_RED="$RED" LED_GREEN="$GREEN1" \
        LED_GREEN2="$GREEN2" LED_GREEN3="$GREEN3" PATH="$LED_UNIT_BIN:$PATH" \
        /bin/ash -c '. "$1"; shift; "$@"' led-test "$COMMON" "$@"
}

assert_led_state() {
    dir=$1
    trigger=$2
    brightness=$3
    delay_on=$4
    delay_off=$5
    label=$6
    assert_equal "$(cat "$dir/trigger")" "$trigger" "$label trigger"
    assert_equal "$(cat "$dir/brightness")" "$brightness" "$label brightness"
    if [ -n "$delay_on" ]; then
        assert_equal "$(cat "$dir/delay_on")" "$delay_on" "$label delay_on"
        assert_equal "$(cat "$dir/delay_off")" "$delay_off" "$label delay_off"
    fi
}

# Snapshot every regular file under LED_UNIT_ROOT (name only, sorted); used to
# prove led_set/led_state_* never create a stray file (fact 5: no
# application-level file logging is permitted, only logger/syslog).
snapshot_files() {
    find "$LED_UNIT_ROOT" -type f | sort
}

case_p01_led_state_off_writes_none_trigger_and_zero_brightness() {
    begin_case P01 'led_state_off sets trigger=none brightness=0, no delay writes'
    prepare_led
    assert_success 'P01 led_state_off succeeds' run_common led_state_off "$GREEN1"
    assert_led_state "$GREEN1" none 0 '' '' 'P01 off'
    assert_empty_file "$GREEN1/delay_on" 'P01 off does not touch delay_on'
    assert_empty_file "$GREEN1/delay_off" 'P01 off does not touch delay_off'
}

case_p02_led_state_solid_writes_none_trigger_and_one_brightness() {
    begin_case P02 'led_state_solid sets trigger=none brightness=1, no delay writes'
    prepare_led
    assert_success 'P02 led_state_solid succeeds' run_common led_state_solid "$GREEN1"
    assert_led_state "$GREEN1" none 1 '' '' 'P02 solid'
    assert_empty_file "$GREEN1/delay_on" 'P02 solid does not touch delay_on'
    assert_empty_file "$GREEN1/delay_off" 'P02 solid does not touch delay_off'
}

case_p03_led_state_fast_blink_writes_timer_100_100() {
    begin_case P03 'led_state_fast_blink sets trigger=timer delay_on=100 delay_off=100'
    prepare_led
    assert_success 'P03 led_state_fast_blink succeeds' run_common led_state_fast_blink "$GREEN1"
    assert_equal "$(cat "$GREEN1/trigger")" timer 'P03 fast_blink trigger'
    assert_equal "$(cat "$GREEN1/delay_on")" 100 'P03 fast_blink delay_on'
    assert_equal "$(cat "$GREEN1/delay_off")" 100 'P03 fast_blink delay_off'
    assert_empty_file "$GREEN1/brightness" 'P03 fast_blink does not touch brightness'
}

case_p04_led_state_slow_blink_writes_timer_500_500() {
    begin_case P04 'led_state_slow_blink sets trigger=timer delay_on=500 delay_off=500'
    prepare_led
    assert_success 'P04 led_state_slow_blink succeeds' run_common led_state_slow_blink "$RED"
    assert_equal "$(cat "$RED/trigger")" timer 'P04 slow_blink trigger'
    assert_equal "$(cat "$RED/delay_on")" 500 'P04 slow_blink delay_on'
    assert_equal "$(cat "$RED/delay_off")" 500 'P04 slow_blink delay_off'
    assert_empty_file "$RED/brightness" 'P04 slow_blink does not touch brightness'
}

case_p05_led_set_empty_path_is_silent_noop() {
    begin_case P05 'led_set with an empty path is a silent no-op (LED_GREEN="" is legal)'
    prepare_led
    assert_success 'P05 led_state_solid with empty path returns success' run_common led_state_solid ""
    assert_empty_file "$LED_UNIT_NOTICES" 'P05 empty path emits no logger complaint'
}

case_p06_led_set_nonexistent_path_logs_via_logger_only() {
    begin_case P06 'led_set with a non-empty but nonexistent path complains via logger, never a file'
    prepare_led
    before=$(snapshot_files)
    run_common led_state_solid "$LED_UNIT_ROOT/does-not-exist" >/dev/null 2>&1
    assert_file_contains 'led_set' "$LED_UNIT_NOTICES" 'P06 logger receives a led_set complaint'
    after=$(snapshot_files)
    assert_equal "$after" "$before" 'P06 no new file is created anywhere under LED_UNIT_ROOT'
}

case_p07_no_state_primitive_ever_writes_brightness_255() {
    begin_case P07 'no led_state_* primitive ever writes brightness=255 (max_brightness=1 hardware)'
    prepare_led
    run_common led_state_off "$GREEN1" >/dev/null 2>&1
    assert_file_lacks '255' "$GREEN1/brightness" 'P07 off never writes 255'
    run_common led_state_solid "$GREEN1" >/dev/null 2>&1
    assert_file_lacks '255' "$GREEN1/brightness" 'P07 solid never writes 255'
}

case_p08_led_state_progress_maps_segments_per_state_table() {
    begin_case P08 'led_state_progress walks G1/G2/G3 per the 0-33/34-66/67-99 state table'
    prepare_led
    assert_success 'P08 segment 1' run_common led_state_progress 1
    assert_led_state "$GREEN1" timer '' 100 100 'P08 seg1 G1 fast-blink'
    assert_led_state "$GREEN2" none 0 '' '' 'P08 seg1 G2 off'
    assert_led_state "$GREEN3" none 0 '' '' 'P08 seg1 G3 off'

    prepare_led
    assert_success 'P08 segment 2' run_common led_state_progress 2
    assert_led_state "$GREEN1" none 1 '' '' 'P08 seg2 G1 solid'
    assert_led_state "$GREEN2" timer '' 100 100 'P08 seg2 G2 fast-blink'
    assert_led_state "$GREEN3" none 0 '' '' 'P08 seg2 G3 off'

    prepare_led
    assert_success 'P08 segment 3' run_common led_state_progress 3
    assert_led_state "$GREEN1" none 1 '' '' 'P08 seg3 G1 solid'
    assert_led_state "$GREEN2" none 1 '' '' 'P08 seg3 G2 solid'
    assert_led_state "$GREEN3" timer '' 100 100 'P08 seg3 G3 fast-blink'
}

case_p09_led_state_progress_rejects_invalid_segment_via_logger() {
    begin_case P09 'led_state_progress rejects an out-of-range segment via logger, not a crash'
    prepare_led
    before=$(snapshot_files)
    run_common led_state_progress 9 >/dev/null 2>&1
    assert_file_contains 'led_state_progress' "$LED_UNIT_NOTICES" 'P09 logger receives an invalid-segment complaint'
    after=$(snapshot_files)
    assert_equal "$after" "$before" 'P09 no new file is created for an invalid segment'
}

case_p10_led_state_error_maps_green_slot_and_always_slow_blinks_red() {
    begin_case P10 'led_state_error slow-blinks R and lights exactly the requested green slot'
    prepare_led
    assert_success 'P10 unclassified (slot 0)' run_common led_state_error 0
    assert_led_state "$RED" timer '' 500 500 'P10 slot0 R slow-blink'
    assert_led_state "$GREEN1" none 0 '' '' 'P10 slot0 G1 off'
    assert_led_state "$GREEN2" none 0 '' '' 'P10 slot0 G2 off'
    assert_led_state "$GREEN3" none 0 '' '' 'P10 slot0 G3 off'

    prepare_led
    assert_success 'P10 no_space (slot 1)' run_common led_state_error 1
    assert_led_state "$RED" timer '' 500 500 'P10 slot1 R slow-blink'
    assert_led_state "$GREEN1" none 1 '' '' 'P10 slot1 G1 solid'
    assert_led_state "$GREEN2" none 0 '' '' 'P10 slot1 G2 off'
    assert_led_state "$GREEN3" none 0 '' '' 'P10 slot1 G3 off'

    prepare_led
    assert_success 'P10 card_config (slot 2)' run_common led_state_error 2
    assert_led_state "$RED" timer '' 500 500 'P10 slot2 R slow-blink'
    assert_led_state "$GREEN1" none 0 '' '' 'P10 slot2 G1 off'
    assert_led_state "$GREEN2" none 1 '' '' 'P10 slot2 G2 solid'
    assert_led_state "$GREEN3" none 0 '' '' 'P10 slot2 G3 off'

    prepare_led
    assert_success 'P10 device_unknown/verify_failed (slot 3)' run_common led_state_error 3
    assert_led_state "$RED" timer '' 500 500 'P10 slot3 R slow-blink'
    assert_led_state "$GREEN1" none 0 '' '' 'P10 slot3 G1 off'
    assert_led_state "$GREEN2" none 0 '' '' 'P10 slot3 G2 off'
    assert_led_state "$GREEN3" none 1 '' '' 'P10 slot3 G3 solid'
}

case_p11_led_state_error_rejects_invalid_slot_via_logger() {
    begin_case P11 'led_state_error rejects an out-of-range green slot via logger, not a crash'
    prepare_led
    before=$(snapshot_files)
    run_common led_state_error 9 >/dev/null 2>&1
    assert_file_contains 'led_state_error' "$LED_UNIT_NOTICES" 'P11 logger receives an invalid-slot complaint'
    after=$(snapshot_files)
    assert_equal "$after" "$before" 'P11 no new file is created for an invalid slot'
}

case_p12_no_primitive_ever_creates_a_file_outside_the_led_sysfs_fixtures() {
    begin_case P12 'zero application-level file writes across every primitive (fact 5: logger-only)'
    prepare_led
    before=$(snapshot_files)
    run_common led_state_off "$GREEN1" >/dev/null 2>&1
    run_common led_state_solid "$GREEN1" >/dev/null 2>&1
    run_common led_state_fast_blink "$GREEN1" >/dev/null 2>&1
    run_common led_state_slow_blink "$RED" >/dev/null 2>&1
    run_common led_state_progress 1 >/dev/null 2>&1
    run_common led_state_error 1 >/dev/null 2>&1
    after=$(snapshot_files)
    assert_equal "$after" "$before" 'P12 no primitive call creates a new file anywhere under LED_UNIT_ROOT'
}

# $EFFECTS is test-target-manager.sh's own harness-side effects-log path
# (derive_fixture_paths); the fixture-side rsync stub writes into it via the
# TEST_EFFECTS env var run_manager_with_env sets to that same path.
wait_for_effect() {
    needle=$1
    attempts=0
    while ! grep -F -q -- "$needle" "$EFFECTS" 2>/dev/null && [ "$attempts" -lt 15 ]; do
        /bin/sleep 1
        attempts=$((attempts + 1))
    done
    grep -F -q -- "$needle" "$EFFECTS"
}

wait_for_exit() {
    pid=$1
    attempts=0
    while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 20 ]; do
        /bin/sleep 1
        attempts=$((attempts + 1))
    done
    ! kill -0 "$pid" 2>/dev/null
}

# Reset the real-manager fixture (test-target-manager.sh's engine) and wire a
# controllable rsync stub that emits one rsync --info=progress2 line per
# marker release, in the exact suffix syntax backup-progress.sh's awk parser
# requires (to-chk=<remaining>/<total>), letting each case drive
# BACKUP_STATUS_PERCENT to an exact chosen value on demand instead of racing
# a live rsync. TEST_MOUNT_AUTO_CARD=1 supplies a pre-existing card config so
# the run reaches perform_backup instead of the first-write provisioning
# window (this suite is not testing that mount sequence).
reset_led_manager_case() {
    reset_case || return 1
    cat > "$BIN/rsync" <<'EOF'
#!/bin/ash
printf '%s\n' 'led-rsync-start' >> "$TEST_EFFECTS"
step=0
while :; do
    step=$((step + 1))
    marker="$(dirname "$0")/allow-$step"
    while [ ! -e "$marker" ]; do /bin/sleep 1; done
    line="$(cat "$(dirname "$0")/line-$step" 2>/dev/null || :)"
    [ -n "$line" ] || break
    printf '%s\n' "$line"
done
printf '%s\n' 'Number of regular files transferred: 7'
printf '%s\n' 'Total transferred file size: 1,234 bytes'
EOF
    chmod 755 "$BIN/rsync"
    return 0
}

# Queue one progress2 line to be emitted on rsync's next poll, targeting the
# given percent exactly via a total=100 to-chk ratio (remaining=100-percent).
# Args: $1 step number (1-based, matches the release ordering), $2 percent.
queue_led_progress_line() {
    step=$1
    percent=$2
    remaining=$((100 - percent))
    printf '\r %s %s%% 1.00kB/s 0:00:0%s (xfr#%s, to-chk=%s/100)\n' \
        "$percent" "$percent" "$step" "$percent" "$remaining" > "$BIN/line-$step"
}

# Release the given step so the rsync stub's poll advances past it.
release_led_progress_step() {
    : > "$BIN/allow-$1"
}

# Start the manager in the background against a pre-configured card so
# perform_backup runs the real transfer/progress/LED chain.
start_led_manager() {
    TEST_RUN_MANAGER_EXEC=1 TEST_MANAGER_SHELL=/bin/ash TEST_MOUNT_AUTO_CARD=1 \
        TEST_RSYNC_STATS=1 run_manager add sda1 /devices/mock &
    LED_MANAGER_PID=$!
}

# transfer_process_wait_leader polls every 1s and only every even sample is
# processed by backup_status_progress's throttle (BACKUP_STATUS_SAMPLE_COUNT
# % 2 == 0); each queued line must therefore be observed at least twice
# (i.e. left in place across two 1s polls) before the next step is queued,
# or the sample can land on an odd count and be silently dropped. Waiting
# for the segment's own before/after LED file to change is what actually
# proves this step's write happened, and doubles as the throttle-safe delay.
wait_for_trigger_change() {
    dir=$1
    before=$2
    attempts=0
    while [ "$(cat "$dir/trigger" 2>/dev/null || :)" = "$before" ] && [ "$attempts" -lt 20 ]; do
        /bin/sleep 1
        attempts=$((attempts + 1))
    done
    [ "$(cat "$dir/trigger" 2>/dev/null || :)" != "$before" ]
}

# Release a step and hold long enough (>=3 one-second polls) for the sampler
# to see it on an even count even when the immediately preceding sample was
# itself even (worst case: two throttled polls needed before this one is
# processed at all).
release_and_settle() {
    release_led_progress_step "$1"
    /bin/sleep 3
}

case_p13_debounce_never_writes_within_a_segment_and_always_writes_across_a_boundary() {
    begin_case P13 'backup_led_update_progress debounces within a segment and always writes across a segment boundary (PR #41 finding 5)'
    reset_led_manager_case || { fail 'P13 fixture setup failed'; return; }
    # 0, 33 -> segment 1 (no write between them); 34 -> segment 2 (must write);
    # 34, 66 -> segment 2 (no write between them); 67 -> segment 3 (must write);
    # 67, 99 -> segment 3 (no write between them).
    queue_led_progress_line 1 0
    queue_led_progress_line 2 33
    queue_led_progress_line 3 34
    queue_led_progress_line 4 66
    queue_led_progress_line 5 67
    queue_led_progress_line 6 99
    start_led_manager
    assert_success 'P13 real rsync fixture starts through the real manager' \
        wait_for_effect led-rsync-start
    release_and_settle 1
    assert_led_state "$TEST_ROOT/green" timer 0 100 100 \
        'P13 percent=0 enters segment 1 (G1 fast-blink; brightness is stale 0 from the issue #43 scope-1 four-lamp reset at add start, never cleared by fast_blink)'
    seg1_trigger=$(cat "$TEST_ROOT/green2/trigger")
    printf '%s\n' SENTINEL-P13-S1-G1 > "$TEST_ROOT/green/trigger"
    printf '%s\n' SENTINEL-P13-S1-G2 > "$TEST_ROOT/green2/trigger"
    printf '%s\n' SENTINEL-P13-S1-G3 > "$TEST_ROOT/green3/trigger"
    seg1_trigger=$(cat "$TEST_ROOT/green2/trigger")
    release_and_settle 2
    assert_equal "$(cat "$TEST_ROOT/green/trigger")" SENTINEL-P13-S1-G1 \
        'P13 percent=33 keeps the G1 sentinel: same-segment debounce performs no sysfs write'
    assert_equal "$(cat "$TEST_ROOT/green2/trigger")" SENTINEL-P13-S1-G2 \
        'P13 percent=33 keeps the G2 sentinel: same-segment debounce performs no sysfs write'
    assert_equal "$(cat "$TEST_ROOT/green3/trigger")" SENTINEL-P13-S1-G3 \
        'P13 percent=33 keeps the G3 sentinel: same-segment debounce performs no sysfs write'
    release_led_progress_step 3
    assert_success 'P13 percent=34 crosses into segment 2, so G2 trigger must eventually change' \
        wait_for_trigger_change "$TEST_ROOT/green2" "$seg1_trigger"
    /bin/sleep 2
    assert_led_state "$TEST_ROOT/green" none 1 '' '' 'P13 percent=34 segment 2 (G1 solid)'
    assert_led_state "$TEST_ROOT/green2" timer 0 100 100 \
        'P13 percent=34 segment 2 (G2 fast-blink; brightness is stale 0 left over from segment 1s led_state_off, never cleared by fast_blink)'
    assert_led_state "$TEST_ROOT/green3" none 0 '' '' 'P13 percent=34 segment 2 (G3 off)'
    seg2_green3_trigger=$(cat "$TEST_ROOT/green3/trigger")
    printf '%s\n' SENTINEL-P13-S2-G1 > "$TEST_ROOT/green/trigger"
    printf '%s\n' SENTINEL-P13-S2-G2 > "$TEST_ROOT/green2/trigger"
    printf '%s\n' SENTINEL-P13-S2-G3 > "$TEST_ROOT/green3/trigger"
    seg2_green3_trigger=$(cat "$TEST_ROOT/green3/trigger")
    release_and_settle 4
    assert_equal "$(cat "$TEST_ROOT/green/trigger")" SENTINEL-P13-S2-G1 \
        'P13 percent=66 keeps the G1 sentinel: same-segment debounce performs no sysfs write'
    assert_equal "$(cat "$TEST_ROOT/green2/trigger")" SENTINEL-P13-S2-G2 \
        'P13 percent=66 keeps the G2 sentinel: same-segment debounce performs no sysfs write'
    assert_equal "$(cat "$TEST_ROOT/green3/trigger")" SENTINEL-P13-S2-G3 \
        'P13 percent=66 keeps the G3 sentinel: same-segment debounce performs no sysfs write'
    release_led_progress_step 5
    assert_success 'P13 percent=67 crosses into segment 3, so G3 trigger must eventually change' \
        wait_for_trigger_change "$TEST_ROOT/green3" "$seg2_green3_trigger"
    /bin/sleep 2
    assert_led_state "$TEST_ROOT/green" none 1 '' '' 'P13 percent=67 segment 3 (G1 solid)'
    assert_led_state "$TEST_ROOT/green2" none 1 '' '' 'P13 percent=67 segment 3 (G2 solid)'
    assert_led_state "$TEST_ROOT/green3" timer 0 100 100 \
        'P13 percent=67 segment 3 (G3 fast-blink; brightness is stale 0 left over from segment 1/2s led_state_off, never cleared by fast_blink)'
    printf '%s\n' SENTINEL-P13-S3-G1 > "$TEST_ROOT/green/trigger"
    printf '%s\n' SENTINEL-P13-S3-G2 > "$TEST_ROOT/green2/trigger"
    printf '%s\n' SENTINEL-P13-S3-G3 > "$TEST_ROOT/green3/trigger"
    release_and_settle 6
    assert_equal "$(cat "$TEST_ROOT/green/trigger")" SENTINEL-P13-S3-G1 \
        'P13 percent=99 keeps the G1 sentinel: same-segment debounce performs no sysfs write'
    assert_equal "$(cat "$TEST_ROOT/green2/trigger")" SENTINEL-P13-S3-G2 \
        'P13 percent=99 keeps the G2 sentinel: same-segment debounce performs no sysfs write'
    assert_equal "$(cat "$TEST_ROOT/green3/trigger")" SENTINEL-P13-S3-G3 \
        'P13 percent=99 keeps the G3 sentinel: same-segment debounce performs no sysfs write'
    release_led_progress_step 7
    assert_success 'P13 real manager reaches completion' wait_for_exit "$LED_MANAGER_PID"
    manager_rc=0
    wait "$LED_MANAGER_PID" 2>/dev/null || manager_rc=$?
    assert_equal "$manager_rc" 0 'P13 debounce-driven live progress does not alter the successful transfer exit'
}

case_p14_success_terminal_state_lights_all_three_greens_never_touches_red_and_persists() {
    begin_case P14 'led_state_complete lights G1/G2/G3 solid, never writes R, and the terminal state does not self-revert (PR #41 finding 11 / Critical 1)'
    reset_led_manager_case || { fail 'P14 fixture setup failed'; return; }
    queue_led_progress_line 1 67
    start_led_manager
    assert_success 'P14 real rsync fixture starts through the real manager' \
        wait_for_effect led-rsync-start
    release_and_settle 1
    /bin/sleep 2
    assert_led_state "$TEST_ROOT/green3" timer 0 100 100 \
        'P14 mid-run segment 3 leaves G3 walking-lamp fast-blink before completion (brightness is stale 0 from the initial segment-1 led_state_off at backup start)'
    release_led_progress_step 2
    assert_success 'P14 real manager reaches completion' wait_for_exit "$LED_MANAGER_PID"
    manager_rc=0
    wait "$LED_MANAGER_PID" 2>/dev/null || manager_rc=$?
    assert_equal "$manager_rc" 0 'P14 successful backup exits zero'
    assert_led_state "$TEST_ROOT/green" none 1 '' '' 'P14 success terminal state lights G1 solid'
    assert_led_state "$TEST_ROOT/green2" none 1 '' '' 'P14 success terminal state lights G2 solid'
    assert_led_state "$TEST_ROOT/green3" none 1 '' '' \
        'P14 success terminal state flips G3 from the walking-lamp timer trigger to solid (Critical 1 regression guard: progress LEDs must be reclaimed at completion)'
    assert_equal "$(cat "$TEST_ROOT/red/trigger")" none \
        'P14 successful completion never re-touches R after the add-start reset (issue #43 scope 1: R is only ever turned off at add start, never re-written by a successful run)'
    red_hash_after_completion="$(sha256sum "$TEST_ROOT/red/trigger" "$TEST_ROOT/red/brightness" | awk '{print $1}')"
    green_hash_after_completion="$(sha256sum "$TEST_ROOT/green/trigger" "$TEST_ROOT/green/brightness" "$TEST_ROOT/green2/trigger" "$TEST_ROOT/green2/brightness" "$TEST_ROOT/green3/trigger" "$TEST_ROOT/green3/brightness" | sha256sum | awk '{print $1}')"
    /bin/sleep 3
    assert_equal "$(sha256sum "$TEST_ROOT/green/trigger" "$TEST_ROOT/green/brightness" "$TEST_ROOT/green2/trigger" "$TEST_ROOT/green2/brightness" "$TEST_ROOT/green3/trigger" "$TEST_ROOT/green3/brightness" | sha256sum | awk '{print $1}')" \
        "$green_hash_after_completion" \
        'P14 the completion terminal state is genuinely terminal: nothing reverts it seconds later (no lingering auto-off job exists in production)'
    assert_equal "$(sha256sum "$TEST_ROOT/red/trigger" "$TEST_ROOT/red/brightness" | awk '{print $1}')" \
        "$red_hash_after_completion" \
        'P14 R is still never re-written even after the settle window (confirms no delayed reclaim job touches it either)'
}

main() {
    trap cleanup EXIT INT TERM
    case_p01_led_state_off_writes_none_trigger_and_zero_brightness
    case_p02_led_state_solid_writes_none_trigger_and_one_brightness
    case_p03_led_state_fast_blink_writes_timer_100_100
    case_p04_led_state_slow_blink_writes_timer_500_500
    case_p05_led_set_empty_path_is_silent_noop
    case_p06_led_set_nonexistent_path_logs_via_logger_only
    case_p07_no_state_primitive_ever_writes_brightness_255
    case_p08_led_state_progress_maps_segments_per_state_table
    case_p09_led_state_progress_rejects_invalid_segment_via_logger
    case_p10_led_state_error_maps_green_slot_and_always_slow_blinks_red
    case_p11_led_state_error_rejects_invalid_slot_via_logger
    case_p12_no_primitive_ever_creates_a_file_outside_the_led_sysfs_fixtures
    case_p13_debounce_never_writes_within_a_segment_and_always_writes_across_a_boundary
    case_p14_success_terminal_state_lights_all_three_greens_never_touches_red_and_persists
    assert_equal "$CASES" 14 'all required LED cases executed'
    if [ "$ASSERTIONS" -ne 153 ]; then
        fail "all required assertions executed (expected=153, actual=$ASSERTIONS)"
    fi
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

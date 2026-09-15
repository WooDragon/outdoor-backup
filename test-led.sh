#!/bin/sh
#
# BDD regression tests for the four-lamp LED state-machine primitives
# (issue #40). The delivered common.sh is sourced directly; LED sysfs and
# logger are fixtures. Every led_state_* primitive is set-and-exit (no
# fork, no sleep, no background job), so these tests run synchronously.
#
set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${IN_OPENWRT_TEST:-}" != "1" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 \
        -e IN_OPENWRT_TEST=1 \
        -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-led.sh
fi

REPO_ROOT=/src
COMMON="$REPO_ROOT/files/opt/outdoor-backup/scripts/common.sh"
TEST_ROOT="/tmp/outdoor-backup-led-test.$$"
BIN="$TEST_ROOT/bin"
RED="$TEST_ROOT/red"
GREEN1="$TEST_ROOT/green1"
GREEN2="$TEST_ROOT/green2"
GREEN3="$TEST_ROOT/green3"
NOTICES="$TEST_ROOT/notices"
FILES_BEFORE="$TEST_ROOT/.files-before"
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
    rm -rf "$TEST_ROOT"
}

# Reset all four LED fixture directories plus the logger/notices trace.
# Each LED gets trigger/brightness/delay_on/delay_off sysfs stand-ins.
prepare_led() {
    rm -rf "$TEST_ROOT"
    mkdir -p "$BIN" "$RED" "$GREEN1" "$GREEN2" "$GREEN3"
    : > "$NOTICES"
    for d in "$RED" "$GREEN1" "$GREEN2" "$GREEN3"; do
        : > "$d/trigger"
        : > "$d/brightness"
        : > "$d/delay_on"
        : > "$d/delay_off"
    done
    cat > "$BIN/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_NOTICES"
EOF
    chmod 755 "$BIN/logger"
}

# Run one or more common.sh functions in-process (no fork needed: every
# led_state_* primitive is synchronous set-and-exit).
run_common() {
    TEST_NOTICES="$NOTICES" LED_RED="$RED" LED_GREEN="$GREEN1" \
        LED_GREEN2="$GREEN2" LED_GREEN3="$GREEN3" PATH="$BIN:$PATH" \
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

# Snapshot every regular file under TEST_ROOT (name only, sorted); used to
# prove led_set/led_state_* never create a stray file (fact 5: no
# application-level file logging is permitted, only logger/syslog).
snapshot_files() {
    find "$TEST_ROOT" -type f | sort
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
    assert_empty_file "$NOTICES" 'P05 empty path emits no logger complaint'
}

case_p06_led_set_nonexistent_path_logs_via_logger_only() {
    begin_case P06 'led_set with a non-empty but nonexistent path complains via logger, never a file'
    prepare_led
    before=$(snapshot_files)
    run_common led_state_solid "$TEST_ROOT/does-not-exist" >/dev/null 2>&1
    assert_file_contains 'led_set' "$NOTICES" 'P06 logger receives a led_set complaint'
    after=$(snapshot_files)
    assert_equal "$after" "$before" 'P06 no new file is created anywhere under TEST_ROOT'
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
    assert_file_contains 'led_state_progress' "$NOTICES" 'P09 logger receives an invalid-segment complaint'
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
    assert_file_contains 'led_state_error' "$NOTICES" 'P11 logger receives an invalid-slot complaint'
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
    assert_equal "$after" "$before" 'P12 no primitive call creates a new file anywhere under TEST_ROOT'
}

case_p13_backup_led_update_progress_debounces_same_segment_writes() {
    begin_case P13 'backup_led_update_progress only writes sysfs when the segment actually changes'
    prepare_led
    MANAGER="$REPO_ROOT/files/opt/outdoor-backup/scripts/backup-manager.sh"
    # Extract only the backup_led_update_progress function body (not the
    # whole manager script, which unconditionally calls main "$@" under
    # set -e) and eval it alongside the real common.sh primitives.
    FUNC_SRC="$TEST_ROOT/backup_led_update_progress.sh"
    sed -n '/^backup_led_update_progress() {/,/^}/p' "$MANAGER" > "$FUNC_SRC"
    assert_file_contains 'backup_led_update_progress' "$FUNC_SRC" \
        'P13 extracted the backup_led_update_progress function body from backup-manager.sh'
    TEST_NOTICES="$NOTICES" LED_RED="$RED" LED_GREEN="$GREEN1" \
        LED_GREEN2="$GREEN2" LED_GREEN3="$GREEN3" PATH="$BIN:$PATH" \
        /bin/ash -c '
            . "$1"
            . "$2"
            BACKUP_STATUS_LED_SEGMENT=""
            BACKUP_STATUS_PERCENT=10
            backup_led_update_progress
            cp "$3/trigger" "$3/trigger.marker1"
            BACKUP_STATUS_PERCENT=20
            backup_led_update_progress
            cp "$3/trigger" "$3/trigger.marker2"
            printf "changed-but-should-not-be-rewritten\n" > "$3/trigger"
            BACKUP_STATUS_PERCENT=25
            backup_led_update_progress
            cp "$3/trigger" "$3/trigger.marker3"
        ' led-test "$COMMON" "$FUNC_SRC" "$GREEN1"
    assert_equal "$(cat "$GREEN1/trigger.marker1")" timer 'P13 first sample (segment 1) writes trigger=timer'
    assert_equal "$(cat "$GREEN1/trigger.marker2")" timer 'P13 same-segment resample (still 0-33) leaves trigger untouched'
    assert_equal "$(cat "$GREEN1/trigger.marker3")" changed-but-should-not-be-rewritten \
        'P13 same-segment resample does not rewrite sysfs even when the fixture value was hand-mutated'
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
    case_p13_backup_led_update_progress_debounces_same_segment_writes
    assert_equal "$CASES" 13 'all required LED cases executed'
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

#!/bin/sh
#
# BDD regression tests for LED error signalling in the pinned OpenWrt rootfs.
# The delivered common.sh is sourced directly; only LED sysfs and sleep are
# fixtures. The sleep fixture accepts integer seconds only, so fractional
# BusyBox sleeps fail exactly as they do in the target image.
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
GREEN="$TEST_ROOT/green"
TRACE="$TEST_ROOT/trace"
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

assert_failure() {
    message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    if "$@"; then
        fail "$message"
    fi
}

assert_file_contains() {
    needle=$1
    file=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! grep -F -q -- "$needle" "$file"; then
        fail "$message (missing=[$needle])"
    fi
}

assert_file_lacks() {
    needle=$1
    file=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if grep -F -q -- "$needle" "$file"; then
        fail "$message (unexpected=[$needle])"
    fi
}

cleanup() {
    rm -rf "$TEST_ROOT"
}

prepare_led() {
    rm -rf "$TEST_ROOT"
    mkdir -p "$BIN" "$RED" "$GREEN"
    : > "$TRACE"
    : > "$RED/brightness"
    : > "$GREEN/brightness"
    : > "$RED/trigger"
    : > "$GREEN/trigger"
    cat > "$BIN/sleep" <<'EOF'
#!/bin/sh
if [ "$#" -ne 1 ]; then
    printf 'sleep fixture requires exactly one argument\n' >&2
    exit 64
fi
case "$1" in
    ''|*[!0-9]*)
        printf 'sleep fixture rejected non-negative integer=[%s]\n' "$1" >&2
        exit 64
        ;;
esac
printf 'sleep=%s red=%s green=%s\n' "$1" \
    "$(cat "$TEST_RED/brightness" 2>/dev/null)" \
    "$(cat "$TEST_GREEN/brightness" 2>/dev/null)" >> "$TEST_TRACE"
if [ "${TEST_SLEEP_HOLD:-}" = "$1" ]; then
    : > "$TEST_SLEEP_READY"
    while [ ! -e "$TEST_SLEEP_RELEASE" ]; do
        /bin/sleep 1
    done
fi
EOF
    chmod 755 "$BIN/sleep"
}

run_common_helper() {
    helper=$1
    shift
    TEST_RED="$RED" TEST_GREEN="$GREEN" TEST_TRACE="$TRACE" \
        TEST_SLEEP_HOLD="${TEST_SLEEP_HOLD:-}" \
        TEST_SLEEP_READY="$TEST_ROOT/sleep-ready" \
        TEST_SLEEP_RELEASE="$TEST_ROOT/sleep-release" \
        TEST_CAPTURE_JOBS="${TEST_CAPTURE_JOBS:-}" \
        TEST_JOBS_FILE="$TEST_ROOT/jobs" \
        LED_RED="$RED" LED_GREEN="$GREEN" PATH="$BIN:$PATH" \
        /bin/ash -c '. "$1"; shift; "$@"; if [ "${TEST_CAPTURE_JOBS:-}" = "1" ]; then jobs -p > "$TEST_JOBS_FILE"; fi; wait' led-test "$COMMON" "$helper" "$@"
}

start_common_helper() {
    run_common_helper "$@" >"$TEST_ROOT/helper.stdout" 2>"$TEST_ROOT/helper.stderr" &
    HELPER_PID=$!
}

wait_for_file() {
    file=$1
    attempts=0
    while [ ! -e "$file" ] && [ "$attempts" -lt 5 ]; do
        /bin/sleep 1
        attempts=$((attempts + 1))
    done
    [ -e "$file" ]
}

wait_for_helper() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! wait "$HELPER_PID"; then
        fail "$1 (stderr=$(tr '\n' ' ' < "$TEST_ROOT/helper.stderr"))"
    fi
}

assert_no_led_async_stderr() {
    assert_file_lacks 'sleep: invalid number' "$TEST_ROOT/helper.stderr" \
        "$1 did not emit BusyBox invalid-number stderr"
    assert_file_lacks 'nonexistent directory' "$TEST_ROOT/helper.stderr" \
        "$1 did not access an already-removed LED fixture"
    assert_file_lacks 'sleep fixture rejected' "$TEST_ROOT/helper.stderr" \
        "$1 requested only integer sleep durations"
}

assert_trace_line() {
    line=$1
    expected=$2
    message=$3
    actual=$(sed -n "${line}p" "$TRACE")
    assert_equal "$actual" "$expected" "$message"
}

case_l01_real_busybox_accepts_integer_seconds() {
    begin_case L01 'pinned BusyBox and sleep fixture enforce integer timing'
    prepare_led
    assert_failure 'L01 sleep 1 --unknown is rejected' "$BIN/sleep" 1 --unknown
    assert_failure 'L01 sleep with no arguments is rejected' "$BIN/sleep"
    assert_success 'L01 /bin/sleep 1 succeeds in the actual rootfs' /bin/sleep 1
}

case_l02_one_flash_is_a_one_second_burst() {
    begin_case L02 'one-flash error emits one on-off pair then a two-second pause'
    prepare_led
    start_common_helper led_blink_pattern "$RED" 1 4
    wait_for_helper 'L02 one-flash helper completes'
    assert_trace_line 1 'sleep=1 red=1 green=' 'L02 first flash stays on for one second'
    assert_trace_line 2 'sleep=1 red=0 green=' 'L02 first flash turns off for one second'
    assert_trace_line 3 'sleep=2 red=0 green=' 'L02 burst boundary pauses for two seconds'
    assert_equal "$(wc -l < "$TRACE")" 3 'L02 emits exactly one flash cycle'
    assert_equal "$(cat "$RED/brightness")" 0 'L02 leaves red LED off'
    assert_no_led_async_stderr L02
}

case_l03_two_and_three_flashes_preserve_boundaries() {
    begin_case L03 'two- and three-flash errors retain distinct countable bursts'
    prepare_led
    start_common_helper led_blink_pattern "$RED" 2 6
    wait_for_helper 'L03 two-flash helper completes'
    assert_trace_line 1 'sleep=1 red=1 green=' 'L03 two-flash first on phase'
    assert_trace_line 3 'sleep=1 red=1 green=' 'L03 two-flash second on phase'
    assert_trace_line 5 'sleep=2 red=0 green=' 'L03 two-flash pause follows both flashes'
    assert_equal "$(wc -l < "$TRACE")" 5 'L03 two-flash cycle contains five waits'
    assert_equal "$(cat "$RED/brightness")" 0 'L03 two-flash leaves red LED off'

    prepare_led
    start_common_helper led_blink_pattern "$RED" 3 8
    wait_for_helper 'L03 three-flash helper completes'
    assert_trace_line 1 'sleep=1 red=1 green=' 'L03 three-flash first on phase'
    assert_trace_line 3 'sleep=1 red=1 green=' 'L03 three-flash second on phase'
    assert_trace_line 5 'sleep=1 red=1 green=' 'L03 three-flash third on phase'
    assert_trace_line 7 'sleep=2 red=0 green=' 'L03 three-flash pause follows all flashes'
    assert_equal "$(wc -l < "$TRACE")" 7 'L03 three-flash cycle contains seven waits'
    assert_equal "$(cat "$RED/brightness")" 0 'L03 three-flash leaves red LED off'
    assert_no_led_async_stderr L03
}

case_l04_short_pattern_runs_real_integer_timing() {
    begin_case L04 'one short pattern completes under real integer BusyBox timing'
    prepare_led
    LED_RED="$RED" LED_GREEN="$GREEN" PATH="$PATH" \
        /bin/ash -c '. "$1"; led_blink_pattern "$2" 1 4; wait' led-test "$COMMON" "$RED" \
        >"$TEST_ROOT/real.stdout" 2>"$TEST_ROOT/real.stderr" &
    HELPER_PID=$!
    wait_for_helper 'L04 real-timed helper completes'
    assert_equal "$(cat "$RED/brightness")" 0 'L04 real-timed helper leaves red LED off'
    assert_file_lacks 'sleep: invalid number' "$TEST_ROOT/real.stderr" \
        'L04 actual BusyBox received no invalid sleep argument'
}

case_l05_verify_failure_alternates_and_ends_off() {
    begin_case L05 'verify failure alternates red and green for its complete virtual duration'
    prepare_led
    start_common_helper led_err_verify_failed
    wait_for_helper 'L05 verify-failed helper completes'
    assert_trace_line 1 'sleep=1 red=1 green=0' 'L05 starts red on and green off'
    assert_trace_line 2 'sleep=1 red=0 green=1' 'L05 switches to green on and red off'
    assert_trace_line 3 'sleep=1 red=1 green=0' 'L05 repeats red phase'
    assert_trace_line 4 'sleep=1 red=0 green=1' 'L05 repeats green phase'
    assert_equal "$(wc -l < "$TRACE")" 60 'L05 runs thirty two-second alternations over sixty seconds'
    assert_equal "$(cat "$RED/brightness")" 0 'L05 leaves red LED off'
    assert_equal "$(cat "$GREEN/brightness")" 0 'L05 leaves green LED off'
    assert_no_led_async_stderr L05
}

case_l06_missing_led_falls_back_to_unchanged_generic_timer() {
    begin_case L06 'missing green LED falls back to the legacy red timer without changing milliseconds'
    prepare_led
    rm -rf "$GREEN"
    TEST_SLEEP_HOLD=60
    export TEST_SLEEP_HOLD
    start_common_helper led_err_verify_failed
    assert_success 'L06 fallback timer reaches its controlled sleep' \
        wait_for_file "$TEST_ROOT/sleep-ready"
    assert_equal "$(cat "$RED/trigger")" timer 'L06 fallback keeps the timer trigger'
    assert_equal "$(cat "$RED/delay_on")" 500 'L06 fallback preserves 500ms on delay'
    assert_equal "$(cat "$RED/delay_off")" 500 'L06 fallback preserves 500ms off delay'
    : > "$TEST_ROOT/sleep-release"
    wait_for_helper 'L06 fallback helper completes after its explicit release'
    unset TEST_SLEEP_HOLD
    assert_equal "$(cat "$RED/brightness")" 0 'L06 fallback leaves red LED off'
    assert_no_led_async_stderr L06
}

case_l07_missing_red_falls_back_to_one_green_flash() {
    begin_case L07 'missing red LED falls back to one green flash burst'
    prepare_led
    rm -rf "$RED"
    start_common_helper led_err_verify_failed
    wait_for_helper 'L07 green-only fallback helper completes'
    assert_trace_line 1 'sleep=1 red= green=1' 'L07 green fallback starts with one-second on phase'
    assert_trace_line 2 'sleep=1 red= green=0' 'L07 green fallback has one-second off phase'
    assert_trace_line 3 'sleep=2 red= green=0' 'L07 green fallback keeps the two-second burst pause'
    assert_equal "$(wc -l < "$TRACE")" 45 'L07 green fallback runs fifteen one-flash bursts'
    assert_equal "$(cat "$GREEN/brightness")" 0 'L07 green fallback leaves LED off'
    assert_no_led_async_stderr L07
}

case_l08_both_leds_missing_return_without_async_work() {
    begin_case L08 'both missing LEDs return without forking or sleeping'
    prepare_led
    rm -rf "$RED" "$GREEN"
    TEST_CAPTURE_JOBS=1
    export TEST_CAPTURE_JOBS
    assert_success 'L08 both-missing helper returns successfully' \
        run_common_helper led_err_verify_failed
    unset TEST_CAPTURE_JOBS
    assert_equal "$(wc -l < "$TRACE")" 0 'L08 both-missing path leaves sleep trace empty'
    assert_equal "$(wc -l < "$TEST_ROOT/jobs")" 0 'L08 both-missing path creates no asynchronous job'
}

main() {
    trap cleanup EXIT INT TERM
    case_l01_real_busybox_accepts_integer_seconds
    case_l02_one_flash_is_a_one_second_burst
    case_l03_two_and_three_flashes_preserve_boundaries
    case_l04_short_pattern_runs_real_integer_timing
    case_l05_verify_failure_alternates_and_ends_off
    case_l06_missing_led_falls_back_to_unchanged_generic_timer
    case_l07_missing_red_falls_back_to_one_green_flash
    case_l08_both_leds_missing_return_without_async_work
    assert_equal "$CASES" 8 'all required LED cases executed'
    if [ "$ASSERTIONS" -ne 64 ]; then
        fail "all required assertions executed (expected=64, actual=$ASSERTIONS)"
    fi
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

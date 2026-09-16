#!/bin/sh
# BDD regression tests for the LED lifecycle contract (issue #43).
set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${IN_OPENWRT_TEST:-}" != "1" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 \
        -e IN_OPENWRT_TEST=1 \
        -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-led-lifecycle.sh
fi

REPO_ROOT=/src
TEST_CAPTURED_STDERR=1
TEST_ASYNC_STDERR="/tmp/outdoor-backup-led-lifecycle-async.$$.stderr"
TEST_TARGET_MANAGER_LIBRARY_ONLY=1
. "$REPO_ROOT/test-target-manager.sh" --inside
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
    actual=$1; expected=$2; message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$actual" != "$expected" ]; then
        fail "$message (expected=[$expected], actual=[$actual])"
    fi
}

assert_not_equal() {
    actual=$1; unexpected=$2; message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$actual" = "$unexpected" ]; then
        fail "$message (unexpected=[$unexpected])"
    fi
}

assert_absent() {
    path=$1; message=$2
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ -e "$path" ] || [ -L "$path" ]; then
        fail "$message (exists=[$path])"
    fi
}

assert_success() {
    message=$1; shift
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! "$@"; then fail "$message"; fi
}

# LED combination assertion: an empty delay skips delay checks.
assert_led_state() {
    dir=$1; trigger=$2; brightness=$3; delay_on=$4; delay_off=$5; label=$6
    assert_equal "$(cat "$dir/trigger")" "$trigger" "$label trigger"
    assert_equal "$(cat "$dir/brightness")" "$brightness" "$label brightness"
    if [ -n "$delay_on" ]; then
        assert_equal "$(cat "$dir/delay_on")" "$delay_on" "$label delay_on"
        assert_equal "$(cat "$dir/delay_off")" "$delay_off" "$label delay_off"
    fi
}

LED_ROOT="/tmp/outdoor-backup-led-lifecycle.$$"
LED_BIN="$LED_ROOT/bin"
NOTICES="$LED_ROOT/notices"
RED="$LED_ROOT/red"; GREEN1="$LED_ROOT/green1"
GREEN2="$LED_ROOT/green2"; GREEN3="$LED_ROOT/green3"
COMMON="$REPO_ROOT/files/opt/outdoor-backup/scripts/common.sh"

prepare_led() {
    rm -rf "$LED_ROOT"
    mkdir -p "$LED_BIN" "$RED" "$GREEN1" "$GREEN2" "$GREEN3"
    : > "$NOTICES"
    for d in "$RED" "$GREEN1" "$GREEN2" "$GREEN3"; do
        : > "$d/trigger"; : > "$d/brightness"
        : > "$d/delay_on"; : > "$d/delay_off"
    done
    cat > "$LED_BIN/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_NOTICES"
EOF
    chmod 755 "$LED_BIN/logger"
}

prepare_led_red_pristine() {
    rm -rf "$LED_ROOT"
    mkdir -p "$LED_BIN" "$RED" "$GREEN1" "$GREEN2" "$GREEN3"
    : > "$NOTICES"
    for d in "$GREEN1" "$GREEN2" "$GREEN3"; do
        : > "$d/trigger"; : > "$d/brightness"
        : > "$d/delay_on"; : > "$d/delay_off"
    done
    cat > "$LED_BIN/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_NOTICES"
EOF
    chmod 755 "$LED_BIN/logger"
}

run_common() {
    TEST_NOTICES="$NOTICES" LED_RED="$RED" LED_GREEN="$GREEN1" \
        LED_GREEN2="$GREEN2" LED_GREEN3="$GREEN3" PATH="$LED_BIN:$PATH" \
        /bin/ash -c '. "$1"; shift; "$@"' led-lifecycle-test "$COMMON" "$@"
}

led_field() {
    if [ -e "$1" ]; then
        printf '%s' "$(cat "$1")"
    else
        printf '%s' UNWRITTEN
    fi
}

serialize_lamp() {
    printf '%s/%s/%s/%s' \
        "$(led_field "$1/trigger")" "$(led_field "$1/brightness")" \
        "$(led_field "$1/delay_on")" "$(led_field "$1/delay_off")"
}

all_leds_snapshot() {
    printf 'R=%s;G1=%s;G2=%s;G3=%s' \
        "$(serialize_lamp "$RED")" "$(serialize_lamp "$GREEN1")" \
        "$(serialize_lamp "$GREEN2")" "$(serialize_lamp "$GREEN3")"
}

manager_led_sentinel() {
    for d in "$TEST_ROOT/red" "$TEST_ROOT/green" \
        "$TEST_ROOT/green2" "$TEST_ROOT/green3"; do
        printf '%s\n' sentinel > "$d/trigger"
        printf '%s\n' 777 > "$d/brightness"
        printf '%s\n' sentinel > "$d/delay_on"
        printf '%s\n' sentinel > "$d/delay_off"
    done
}

install_manager_led_snapshot_logger() {
    cat > "$BIN/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_NOTICES"
if [ ! -e "$TEST_LED_SNAPSHOT/.captured" ]; then
    mkdir -p "$TEST_LED_SNAPSHOT/red" "$TEST_LED_SNAPSHOT/green" \
        "$TEST_LED_SNAPSHOT/green2" "$TEST_LED_SNAPSHOT/green3"
    for field in trigger brightness delay_on delay_off; do
        cp "$TEST_LED_RED/$field" "$TEST_LED_SNAPSHOT/red/$field"
        cp "$TEST_LED_GREEN/$field" "$TEST_LED_SNAPSHOT/green/$field"
        cp "$TEST_LED_GREEN2/$field" "$TEST_LED_SNAPSHOT/green2/$field"
        cp "$TEST_LED_GREEN3/$field" "$TEST_LED_SNAPSHOT/green3/$field"
    done
    : > "$TEST_LED_SNAPSHOT/.captured"
fi
exit 0
EOF
    chmod 755 "$BIN/logger"
}

run_manager_led_snapshot() {
    snapshot=$1
    shift
    TEST_LED_SNAPSHOT="$snapshot"
    TEST_LED_RED="$TEST_ROOT/red"
    TEST_LED_GREEN="$TEST_ROOT/green"
    TEST_LED_GREEN2="$TEST_ROOT/green2"
    TEST_LED_GREEN3="$TEST_ROOT/green3"
    export TEST_LED_SNAPSHOT TEST_LED_RED TEST_LED_GREEN TEST_LED_GREEN2 TEST_LED_GREEN3
    run_manager "$@"
}

assert_manager_snapshot() {
    snapshot=$1
    expected=$2
    label=$3
    assert_equal "$(serialize_lamp "$snapshot/red")" "$expected" "$label red"
    assert_equal "$(serialize_lamp "$snapshot/green")" "$expected" "$label green"
    assert_equal "$(serialize_lamp "$snapshot/green2")" "$expected" "$label green2"
    assert_equal "$(serialize_lamp "$snapshot/green3")" "$expected" "$label green3"
}

case_manager_add_resets_terminal_leds() {
    begin_case L1 "add resets a prior completed LED state before guard failure"
    reset_case || { fail "L1 fixture setup failed"; return; }
    manager_led_sentinel
    for d in "$TEST_ROOT/green" "$TEST_ROOT/green2" "$TEST_ROOT/green3"; do
        printf '%s\n' none > "$d/trigger"
        printf '%s\n' 1 > "$d/brightness"
    done
    install_manager_led_snapshot_logger
    set_config_target_uuid ''
    snapshot="$TEST_ROOT/reset-snapshot"
    run_manager_led_snapshot "$snapshot" add sda1 /devices/mock || :
    assert_manager_snapshot "$snapshot" "none/0/sentinel/sentinel" \
        "L1 reset snapshot"
}

case_manager_add_lock_reset_race_guard() {
    begin_case L2 "add defers reset while lock exists, including a stale lock"
    reset_case || { fail "L2 live-lock fixture setup failed"; return; }
    manager_led_sentinel
    install_manager_led_snapshot_logger
    set_config_target_uuid ''
    LOCK_LINK="$RUNTIME/var/lock/backup.lock"
    ln -s "/proc/$$" "$LOCK_LINK"
    live_snapshot="$TEST_ROOT/live-lock-snapshot"
    run_manager_led_snapshot "$live_snapshot" add sda1 /devices/mock || :
    assert_manager_snapshot "$live_snapshot" "sentinel/777/sentinel/sentinel" \
        "L2 live lock preserves LEDs"

    reset_case || { fail "L2 unlocked fixture setup failed"; return; }
    manager_led_sentinel
    install_manager_led_snapshot_logger
    set_config_target_uuid ''
    unlocked_snapshot="$TEST_ROOT/unlocked-snapshot"
    run_manager_led_snapshot "$unlocked_snapshot" add sda1 /devices/mock || :
    assert_manager_snapshot "$unlocked_snapshot" "none/0/sentinel/sentinel" \
        "L2 absent lock resets LEDs"

    reset_case || { fail "L2 stale-lock fixture setup failed"; return; }
    manager_led_sentinel
    install_manager_led_snapshot_logger
    set_config_target_uuid ''
    LOCK_LINK="$RUNTIME/var/lock/backup.lock"
    ln -s /proc/2147483647 "$LOCK_LINK"
    stale_snapshot="$TEST_ROOT/stale-lock-snapshot"
    run_manager_led_snapshot "$stale_snapshot" add sda1 /devices/mock || :
    assert_manager_snapshot "$stale_snapshot" "sentinel/777/sentinel/sentinel" \
        "L2 stale lock preserves LEDs"
}

case_cancelled_operator() {
    begin_case L3 "operator cancellation turns green LEDs off without writing red LED"
    prepare_led_red_pristine
    assert_success "operator cancellation returns success" run_common led_state_cancelled_operator
    assert_led_state "$GREEN1" none 0 "" "" "operator G1"
    assert_led_state "$GREEN2" none 0 "" "" "operator G2"
    assert_led_state "$GREEN3" none 0 "" "" "operator G3"
    assert_absent "$RED/trigger" "operator cancellation leaves red trigger unwritten"
    assert_absent "$RED/brightness" "operator cancellation leaves red brightness unwritten"
    assert_absent "$RED/delay_on" "operator cancellation leaves red delay_on unwritten"
    assert_absent "$RED/delay_off" "operator cancellation leaves red delay_off unwritten"
}

case_cancelled_lease() {
    begin_case L4 "lease cancellation shows slow red blink and solid green LEDs"
    prepare_led
    assert_success "lease cancellation returns success" run_common led_state_cancelled_lease
    assert_led_state "$RED" timer "" 500 500 "lease R"
    assert_equal "$(cat "$RED/brightness")" "" "lease R brightness remains unwritten"
    assert_led_state "$GREEN1" none 1 "" "" "lease G1"
    assert_led_state "$GREEN2" none 1 "" "" "lease G2"
    assert_led_state "$GREEN3" none 0 "" "" "lease G3"
}

case_cancelled_paths_differ() {
    begin_case L5 "operator and lease cancellation have distinguishable LED states"
    prepare_led_red_pristine
    assert_success "operator cancellation returns success for comparison" run_common led_state_cancelled_operator
    operator_state=$(all_leds_snapshot)

    prepare_led_red_pristine
    assert_success "lease cancellation returns success for comparison" run_common led_state_cancelled_lease
    lease_state=$(all_leds_snapshot)

    assert_not_equal "$operator_state" "$lease_state" \
        "operator and lease cancellation LED snapshots differ"
}

cleanup() {
    settle_led_fixture 2>/dev/null || :
    unmount_target 2>/dev/null || :
    rm -rf "$LED_ROOT" "$SUITE_ROOT" /opt/outdoor-backup/conf "$TEST_ASYNC_STDERR"
}

main() {
    trap cleanup EXIT INT TERM
    case_manager_add_resets_terminal_leds
    case_manager_add_lock_reset_race_guard
    case_cancelled_operator
    case_cancelled_lease
    case_cancelled_paths_differ
    if [ "$CASES" -ne 5 ]; then
        fail "all required LED lifecycle cases executed (expected=5, actual=$CASES)"
    fi
    if [ "$ASSERTIONS" -ne 42 ]; then
        fail "assertion count gate (expected=42, actual=$ASSERTIONS)"
    fi
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

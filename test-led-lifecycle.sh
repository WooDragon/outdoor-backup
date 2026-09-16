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
    rm -rf "$LED_ROOT"
}

main() {
    trap cleanup EXIT INT TERM
    case_cancelled_operator
    case_cancelled_lease
    case_cancelled_paths_differ
    if [ "$CASES" -ne 3 ]; then
        fail "all required LED lifecycle cases executed (expected=3, actual=$CASES)"
    fi
    if [ "$ASSERTIONS" -ne 26 ]; then
        fail "assertion count gate (expected=26, actual=$ASSERTIONS)"
    fi
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

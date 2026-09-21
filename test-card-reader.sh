#!/bin/sh
#
# BDD integration tests for safe partition-source dispatch. The delivered
# hotplug trigger and config loader run unchanged; only manager/service effects
# are fixture seams.
#
set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${IN_OPENWRT_TEST:-}" != 1 ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 --network bridge \
        -e IN_OPENWRT_TEST=1 -v "$REPO_ROOT:/src:ro" "$IMAGE@$IMAGE_DIGEST" \
        /bin/ash /src/test-card-reader.sh
fi

REPO_ROOT=/src
mkdir -p /var/lock || {
    printf '%s\n' 'FAIL: source-dispatch test cannot create opkg lock directory' >&2
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    if ! opkg update >/dev/null || ! opkg install jq >/dev/null; then
        printf '%s\n' 'FAIL: source-dispatch test requires jq for delivered service-state.sh' >&2
        exit 1
    fi
}
HOTPLUG_SRC="$REPO_ROOT/files/etc/hotplug.d/block/90-outdoor-backup"
CONFIG_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/config.sh"
SERVICE_SRC="$REPO_ROOT/files/opt/outdoor-backup/scripts/service-state.sh"
TEST_ROOT="/tmp/outdoor-backup-source-dispatch.$$"
RUNTIME="$TEST_ROOT/runtime"
MANAGER_LOG="$TEST_ROOT/manager.log"
GENERATION_LOG="$TEST_ROOT/generation.log"
CASES=0
ASSERTIONS=0
FAILED=0

fail() { printf 'FAIL: %s\n' "$1" >&2; FAILED=$((FAILED + 1)); }
begin_case() { CASES=$((CASES + 1)); printf 'CASE %s: %s\n' "$1" "$2"; }
assert_equal() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ "$1" = "$2" ] || fail "$3 (expected=[$2], actual=[$1])"
}
assert_success() {
    ASSERTIONS=$((ASSERTIONS + 1))
    "$@" || fail "$1 should succeed"
}
assert_failure() {
    ASSERTIONS=$((ASSERTIONS + 1))
    "$@" && fail "$1 should fail"
}
assert_absent() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "$2 (path=[$1])"
}
assert_contains() {
    ASSERTIONS=$((ASSERTIONS + 1))
    grep -F -q -- "$1" "$2" || fail "$3 (missing=[$1])"
}

prepare_state() {
    rm -rf "$TEST_ROOT" /opt/outdoor-backup
    mkdir -p "$RUNTIME" /opt/outdoor-backup/scripts "$TEST_ROOT/bin"
    : > "$MANAGER_LOG"
    : > "$GENERATION_LOG"
    cp "$SERVICE_SRC" /opt/outdoor-backup/scripts/service-state.sh
    cat > /opt/outdoor-backup/scripts/backup-manager.sh <<'EOF'
#!/bin/ash
printf '%s\000' "$@" >> "$TEST_MANAGER_LOG"
printf '%s\n' "${OUTDOOR_BACKUP_SERVICE_GENERATION-unset}" >> "$TEST_GENERATION_LOG"
EOF
    chmod 700 /opt/outdoor-backup/scripts/backup-manager.sh
    cat > "$TEST_ROOT/bin/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOGGER_LOG"
EOF
    chmod 755 "$TEST_ROOT/bin/logger"
    printf '%s\n' "${1:-running:7}" > "$RUNTIME/state"
}

wait_for_records() {
    expected=$1 attempts=0
    while [ "$(tr '\000' '\n' < "$MANAGER_LOG" | grep -c '^add\|^remove')" -lt "$expected" ] && [ "$attempts" -lt 5 ]; do
        sleep 1
        attempts=$((attempts + 1))
    done
}

invoke_hotplug() {
    action=$1 devtype=$2 devname=$3 devpath=$4 seqnum=${5-}
    TEST_MANAGER_LOG="$MANAGER_LOG" TEST_GENERATION_LOG="$GENERATION_LOG" \
        TEST_LOGGER_LOG="$TEST_ROOT/logger.log" OUTDOOR_BACKUP_SERVICE_DIR="$RUNTIME" \
        PATH="$TEST_ROOT/bin:$PATH" SUBSYSTEM=block ACTION="$action" DEVTYPE="$devtype" \
        DEVNAME="$devname" DEVPATH="$devpath" SEQNUM="$seqnum" /bin/ash "$HOTPLUG_SRC"
}

case_d01_all_partition_sources_dispatch() {
    begin_case D01 'USB, MMC, and NVMe partitions dispatch without reader classification'
    prepare_state running:7
    invoke_hotplug add partition sda1 /devices/pci/usb/9/sda/sda1 10
    assert_equal "$(wc -c < "$MANAGER_LOG")" 0 'D01 settle delays the first manager dispatch'
    wait_for_records 1
    invoke_hotplug add partition mmcblk0p1 /devices/platform/mmc/mmcblk0/mmcblk0p1 11
    wait_for_records 2
    invoke_hotplug add partition nvme0n1p2 /devices/pci/nvme/nvme0n1/nvme0n1p2 12
    wait_for_records 3
    expected="$TEST_ROOT/d01.expected"
    printf 'add\000sda1\000/devices/pci/usb/9/sda/sda1\00010\000add\000mmcblk0p1\000/devices/platform/mmc/mmcblk0/mmcblk0p1\00011\000add\000nvme0n1p2\000/devices/pci/nvme/nvme0n1/nvme0n1p2\00012\000' > "$expected"
    assert_equal "$(cmp -s "$MANAGER_LOG" "$expected"; printf '%s' "$?")" 0 \
        'D01 all partition sources reach manager with original event fields'
}

case_d02_whole_disks_are_ignored() {
    begin_case D02 'whole-disk add events do not dispatch'
    prepare_state running:7
    invoke_hotplug add disk sda /devices/pci/usb/9/sda 20
    invoke_hotplug add disk mmcblk0 /devices/platform/mmc/mmcblk0 21
    invoke_hotplug add disk nvme0n1 /devices/pci/nvme/nvme0n1 22
    sleep 3
    assert_equal "$(wc -c < "$MANAGER_LOG")" 0 'D02 whole disks do not invoke manager'
}

case_d03_service_state_and_generation_gate() {
    begin_case D03 'running state dispatches captured generation while stopped and corrupt state refuse adds'
    prepare_state running:42
    invoke_hotplug add partition sdz9 /devices/anything/sdz9 30
    wait_for_records 1
    assert_contains 'add' "$MANAGER_LOG" 'D03 running state dispatches add'
    assert_contains 'sdz9' "$MANAGER_LOG" 'D03 running state preserves DEVNAME'
    assert_equal "$(wc -c < "$MANAGER_LOG")" 35 'D03 four manager event fields remain NUL-delimited'
    assert_equal "$(cat "$GENERATION_LOG")" 42 'D03 manager receives the captured service generation'

    prepare_state stopped:42
    invoke_hotplug add partition sdz9 /devices/anything/sdz9 31
    sleep 3
    assert_equal "$(wc -c < "$MANAGER_LOG")" 0 'D03 stopped service suppresses add'

    prepare_state running:42
    rm -f /opt/outdoor-backup/scripts/service-state.sh
    invoke_hotplug add partition sdz9 /devices/anything/sdz9 32 && dispatch_rc=0 || dispatch_rc=$?
    assert_equal "$dispatch_rc" 1 'D03 missing service library fails add closed'
    assert_equal "$(wc -c < "$MANAGER_LOG")" 0 'D03 missing service library does not dispatch'

    prepare_state broken
    invoke_hotplug add partition sdz9 /devices/anything/sdz9 33 && dispatch_rc=0 || dispatch_rc=$?
    assert_equal "$dispatch_rc" 1 'D03 corrupt service state fails add closed'
    assert_equal "$(wc -c < "$MANAGER_LOG")" 0 'D03 corrupt service state does not dispatch'
}

case_d04_remove_unconditionally_delegates() {
    begin_case D04 'remove bypasses service state and dispatches original fields'
    prepare_state broken
    invoke_hotplug remove disk sdz /devices/unrelated/sdz 40
    wait_for_records 1
    expected="$TEST_ROOT/d04.expected"
    printf 'remove\000sdz\000/devices/unrelated/sdz\00040\000' > "$expected"
    assert_equal "$(cmp -s "$MANAGER_LOG" "$expected"; printf '%s' "$?")" 0 \
        'D04 remove delegates despite corrupt service state'
}

case_d05_legacy_reader_options_are_ignored() {
    begin_case D05 'legacy assignments and unknown UCI reader options do not fail config loading'
    prepare_state running:7
    legacy="$TEST_ROOT/legacy.conf"
    uci_dir="$TEST_ROOT/uci"
    mkdir -p "$uci_dir"
    cat > "$legacy" <<'EOF'
CARD_READER_USB_IDS="invalid reader syntax"
CARD_READER_PATH_PREFIXES="/broken/*"
CARD_READER_HEURISTIC_FALLBACK="no"
EOF
    cat > "$uci_dir/outdoor-backup" <<'EOF'
config outdoor-backup 'config'
    option card_reader_usb_ids 'invalid reader syntax'
    option card_reader_path_prefixes '/broken/*'
    option card_reader_heuristic_fallback 'no'
EOF
    # shellcheck disable=SC2016 # The child shell must expand its positional parameters.
    UCI_CONFIG_DIR="$uci_dir" /bin/ash -c '. "$1"; config_load "$2"' \
        config-loader "$CONFIG_SCRIPT" "$legacy"
    config_rc=$?
    assert_equal "$config_rc" 0 'D05 config loader accepts ignored legacy reader fields'
    invoke_hotplug add partition loop77 /devices/arbitrary/not-a-reader/loop77 50
    wait_for_records 1
    assert_contains 'loop77' "$MANAGER_LOG" 'D05 ignored reader fields cannot suppress partition dispatch'
}

main() {
    trap 'rm -rf "$TEST_ROOT" /opt/outdoor-backup' EXIT INT TERM
    mkdir -p "$TEST_ROOT"
    case_d01_all_partition_sources_dispatch
    case_d02_whole_disks_are_ignored
    case_d03_service_state_and_generation_gate
    case_d04_remove_unconditionally_delegates
    case_d05_legacy_reader_options_are_ignored
    assert_equal "$CASES" 5 'all required source-dispatch cases executed'
    ASSERTIONS=$((ASSERTIONS + 1))
    [ "$ASSERTIONS" -eq 17 ] || fail "all required source-dispatch assertions executed (expected=17, actual=$ASSERTIONS)"
    printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
    [ "$FAILED" -eq 0 ]
}

main

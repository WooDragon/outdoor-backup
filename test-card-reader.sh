#!/bin/sh
#
# BDD regression tests for the card-reader whitelist (issue #2), folded into
# the single-channel config loader: default < legacy backup.conf
# < named UCI section outdoor-backup.config.
# Run on the host; the script re-executes itself in a fixed OpenWrt rootfs.
#

set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${IN_OPENWRT_TEST:-}" != "1" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 \
        -e IN_OPENWRT_TEST=1 \
        -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-card-reader.sh
fi

REPO_ROOT=/src
CONFIG_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/config.sh"
HOTPLUG_SRC="$REPO_ROOT/files/etc/hotplug.d/block/90-outdoor-backup"
TEST_ROOT="/tmp/outdoor-backup-reader-test.$$"
UCI_DIR="$TEST_ROOT/uci"
LEGACY_FILE="$TEST_ROOT/backup.conf"
NOTICES_FILE="$TEST_ROOT/notices.log"
ORIGINAL_PATH=$PATH
CASES=0
ASSERTIONS=0
FAILED=0

cleanup_test_data() {
    rm -rf "$TEST_ROOT"
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILED=$((FAILED + 1))
}

begin_case() {
    CASES=$((CASES + 1))
    printf 'CASE %s: %s\n' "$1" "$2"
}

assert_equal() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$1" != "$2" ]; then
        fail "$3 (expected=[$2], actual=[$1])"
    fi
}

assert_success() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! "$@"; then
        fail "$1 should succeed"
    fi
}

assert_failure() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if "$@"; then
        fail "$1 should fail"
    fi
}

assert_file_contains() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! grep -F -q -- "$1" "$2"; then
        fail "$3 (missing [$1])"
    fi
}

# Create a mock sysfs node for a block device.
# Args: $1 dev (e.g. sda)  $2 vid  $3 pid  $4 model  $5 size_sectors
# Empty vid/pid/model/size are simply not created.
mock_device() {
    dev="$1"
    vid="$2"
    pid="$3"
    model="$4"
    size="$5"
    sys="$TEST_ROOT/sys"
    # USB device node carrying the IDs, with the block device's "device"
    # symlink pointing into it (mirrors real sysfs topology).
    usbnode="$sys/devices/usb1/1-1"
    mkdir -p "$usbnode" "$sys/block/$dev"
    [ -n "$vid" ] && printf '%s\n' "$vid" > "$usbnode/idVendor"
    [ -n "$pid" ] && printf '%s\n' "$pid" > "$usbnode/idProduct"
    # block/<dev>/device -> the usb interface under the usb device node
    iface="$usbnode/1-1:1.0/host0/target0/0:0:0:0"
    mkdir -p "$iface"
    ln -snf "$iface" "$sys/block/$dev/device"
    [ -n "$model" ] && printf '%s\n' "$model" > "$iface/model"
    [ -n "$size" ] && printf '%s\n' "$size" > "$sys/block/$dev/size"
}

# Reset UCI dir, legacy file, mock sysfs tree, and effect stubs for one case.
prepare_reader_state() {
    rm -rf "$UCI_DIR" "$TEST_ROOT/sys" "$TEST_ROOT/bin"
    mkdir -p "$UCI_DIR" "$TEST_ROOT/bin"
    rm -f "$LEGACY_FILE"
    : > "$NOTICES_FILE"
    cat > "$TEST_ROOT/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod 755 "$TEST_ROOT/bin/logger"
    PATH="$TEST_ROOT/bin:$ORIGINAL_PATH"
    export PATH
    export UCI_CONFIG_DIR="$UCI_DIR"
}

write_uci() {
    printf '%s\n' "$1" > "$UCI_DIR/outdoor-backup"
}

write_legacy() {
    printf '%s\n' "$1" > "$LEGACY_FILE"
}

# Load the shared config loader directly (bypassing hotplug) for the
# validation-focused cases. Mirrors test-config.sh's load_config helper.
load_config_direct() {
    # shellcheck disable=SC1090
    . "$CONFIG_SCRIPT"
    config_load "$LEGACY_FILE"
}

# Source the hotplug script's detection functions (SOURCED guard keeps the
# ACTION dispatch from firing), run load_reader_config exactly the way the
# add/remove branches do, then report is_sdcard's verdict.
# Args: $1 devname  $2 devpath
# Echoes "MATCH" or "NOMATCH" on stdout; load_reader_config's stderr lands in
# $NOTICES_FILE for cases that need to inspect it.
run_detect() {
    devname="$1"
    devpath="$2"
    (
        set +e
        export OUTDOOR_BACKUP_HOTPLUG_SOURCED=1
        export SYSFS_ROOT="$TEST_ROOT"
        export SUBSYSTEM="block"
        export OUTDOOR_BACKUP_CONFIG="$LEGACY_FILE"
        export OUTDOOR_BACKUP_CONFIG_SCRIPT="$CONFIG_SCRIPT"
        DEVNAME="$devname"
        # shellcheck disable=SC1090
        . "$HOTPLUG_SRC"
        load_reader_config 2>>"$NOTICES_FILE"
        if is_sdcard "$devpath"; then echo "MATCH"; else echo "NOMATCH"; fi
    )
}

# ---------------------------------------------------------------------------
# R1: no UCI file, no legacy file -> built-in defaults (empty whitelist,
# fallback=yes) -> heuristic still fires, equivalent to pre-#2 behavior.
# ---------------------------------------------------------------------------
case_r01_defaults_preserve_heuristic() {
    begin_case R01 "no config sources: defaults keep heuristic behavior"
    prepare_reader_state
    mock_device "sda" "" "" "Generic Card Reader" "1000000"
    r=$(run_detect "sda1" "/devices/pci/usb1/card-reader")
    assert_equal "$r" "MATCH" "R01 heuristic still matches with empty whitelist"
}

# ---------------------------------------------------------------------------
# R2: legacy-only USB ID whitelist hit.
# ---------------------------------------------------------------------------
case_r02_legacy_only_usb_id_hit() {
    begin_case R02 "legacy-only card_reader_usb_ids whitelist hit"
    prepare_reader_state
    write_legacy 'CARD_READER_USB_IDS="05e3:0749"
CARD_READER_HEURISTIC_FALLBACK="no"'
    mock_device "sdb" "05e3" "0749" "Mass Storage" "4000000000"
    r=$(run_detect "sdb1" "/devices/pci0000:00/plain/block")
    assert_equal "$r" "MATCH" "R02 legacy whitelist matches with no heuristic signal"
}

# ---------------------------------------------------------------------------
# R3: UCI-only USB ID whitelist hit.
# ---------------------------------------------------------------------------
case_r03_uci_only_usb_id_hit() {
    begin_case R03 "UCI-only card_reader_usb_ids whitelist hit"
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_usb_ids '05e3:0749'
	option card_reader_heuristic_fallback 'no'"
    mock_device "sdc" "05e3" "0749" "Mass Storage" "4000000000"
    r=$(run_detect "sdc1" "/devices/pci0000:00/plain/block")
    assert_equal "$r" "MATCH" "R03 UCI whitelist matches with no heuristic signal"
}

# ---------------------------------------------------------------------------
# R4: legacy and UCI both set card_reader_usb_ids to different values -> UCI
# wins. The legacy-only ID must NOT match once UCI overrides it.
# ---------------------------------------------------------------------------
case_r04_uci_overrides_legacy() {
    begin_case R04 "UCI card_reader_usb_ids overrides legacy value"
    prepare_reader_state
    write_legacy 'CARD_READER_USB_IDS="aaaa:bbbb"
CARD_READER_HEURISTIC_FALLBACK="no"'
    write_uci "config outdoor-backup 'config'
	option card_reader_usb_ids '05e3:0749'
	option card_reader_heuristic_fallback 'no'"
    mock_device "sdd" "05e3" "0749" "Mass Storage" "4000000000"
    r=$(run_detect "sdd1" "/devices/pci0000:00/plain/block")
    assert_equal "$r" "MATCH" "R04 UCI id matches device"

    prepare_reader_state
    write_legacy 'CARD_READER_USB_IDS="aaaa:bbbb"
CARD_READER_HEURISTIC_FALLBACK="no"'
    write_uci "config outdoor-backup 'config'
	option card_reader_usb_ids '05e3:0749'
	option card_reader_heuristic_fallback 'no'"
    mock_device "sde" "aaaa" "bbbb" "Mass Storage" "4000000000"
    r=$(run_detect "sde1" "/devices/pci0000:00/plain/block2")
    assert_equal "$r" "NOMATCH" "R04 shadowed legacy id no longer matches"
}

# ---------------------------------------------------------------------------
# R5: UCI option present but empty -> UCI CLI normalizes an empty option away
# (get returns nonzero / not "explicitly present"), so it should NOT override
# and the legacy value should still apply. Mirrors test-config.sh's C05.
# ---------------------------------------------------------------------------
case_r05_empty_uci_falls_back_to_legacy() {
    begin_case R05 "UCI option present but empty falls back to legacy"
    prepare_reader_state
    write_legacy 'CARD_READER_USB_IDS="05e3:0749"
CARD_READER_HEURISTIC_FALLBACK="no"'
    write_uci "config outdoor-backup 'config'
	option card_reader_usb_ids ''"
    mock_device "sdf" "05e3" "0749" "Mass Storage" "4000000000"
    r=$(run_detect "sdf1" "/devices/pci0000:00/plain/block")
    assert_equal "$r" "MATCH" "R05 legacy id still applies when UCI option is empty"
}

# ---------------------------------------------------------------------------
# R6: card_reader_path_prefixes via UCI, prefix hit.
# ---------------------------------------------------------------------------
case_r06_uci_path_prefix_hit() {
    begin_case R06 "UCI card_reader_path_prefixes whitelist hit"
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_path_prefixes '/devices/platform/soc/usb3'
	option card_reader_heuristic_fallback 'no'"
    mock_device "sdg" "1234" "5678" "Unknown" "4000000000"
    r=$(run_detect "sdg1" "/devices/platform/soc/usb3/reader-x")
    assert_equal "$r" "MATCH" "R06 UCI path prefix matches"
}

# ---------------------------------------------------------------------------
# R7: card_reader_heuristic_fallback=no via UCI -> strict mode, non-matching
# device is rejected outright.
# ---------------------------------------------------------------------------
case_r07_uci_strict_mode_blocks_unmatched() {
    begin_case R07 "UCI card_reader_heuristic_fallback=no blocks unmatched device"
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_heuristic_fallback 'no'"
    mock_device "sdh" "05e3" "0749" "Card Reader" "1000000"
    r=$(run_detect "sdh1" "/devices/usb/card-reader")
    assert_equal "$r" "NOMATCH" "R07 strict mode ignores heuristic-only signal"
}

# ---------------------------------------------------------------------------
# R8: invalid card_reader_usb_ids -> config_load fails loud with a reason on
# stderr.
# ---------------------------------------------------------------------------
case_r08_invalid_usb_ids_fail_loud() {
    begin_case R08 "invalid card_reader_usb_ids fails loud"
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_usb_ids '05e3:074'"
    r8_err="$TEST_ROOT/r08.err"
    assert_failure load_config_direct 2>"$r8_err" 1>/dev/null
    assert_file_contains "configuration error" "$r8_err" \
        "R08 short vid:pid token reported as configuration error"

    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_usb_ids 'zzzz:0749'"
    r8b_err="$TEST_ROOT/r08b.err"
    assert_failure load_config_direct 2>"$r8b_err" 1>/dev/null
    assert_file_contains "configuration error" "$r8b_err" \
        "R08 non-hex vid:pid token reported as configuration error"
}

# ---------------------------------------------------------------------------
# R9: invalid card_reader_path_prefixes -> config_load fails loud, for both
# a relative path and a path containing a glob character.
# ---------------------------------------------------------------------------
case_r09_invalid_path_prefixes_fail_loud() {
    begin_case R09 "invalid card_reader_path_prefixes fails loud"
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_path_prefixes 'devices/usb1'"
    r9_err="$TEST_ROOT/r09.err"
    assert_failure load_config_direct 2>"$r9_err" 1>/dev/null
    assert_file_contains "configuration error" "$r9_err" \
        "R09 relative path prefix reported as configuration error"

    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_path_prefixes '/devices/*'"
    r9b_err="$TEST_ROOT/r09b.err"
    assert_failure load_config_direct 2>"$r9b_err" 1>/dev/null
    assert_file_contains "configuration error" "$r9b_err" \
        "R09 glob-containing path prefix reported as configuration error"
}

# ---------------------------------------------------------------------------
# R10: invalid card_reader_heuristic_fallback -> config_load fails loud.
# ---------------------------------------------------------------------------
case_r10_invalid_fallback_fails_loud() {
    begin_case R10 "invalid card_reader_heuristic_fallback fails loud"
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_heuristic_fallback 'maybe'"
    r10_err="$TEST_ROOT/r10.err"
    assert_failure load_config_direct 2>"$r10_err" 1>/dev/null
    assert_file_contains "configuration error" "$r10_err" \
        "R10 invalid fallback value reported as configuration error"
}

# ---------------------------------------------------------------------------
# R11: config_load failing for an UNRELATED reason (bad backup_root) must not
# abort hotplug detection -- the card-reader variables are already assigned
# before validation runs (config.sh's contract). Also verify `set -f` was
# restored by load_reader_config's callee so glob expansion works again
# afterward.
# ---------------------------------------------------------------------------
case_r11_unrelated_failure_does_not_abort_detection() {
    begin_case R11 "unrelated config_load failure does not abort hotplug detection"
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option backup_root 'relative/path'
	option card_reader_usb_ids '05e3:0749'
	option card_reader_heuristic_fallback 'no'"
    mock_device "sdi" "05e3" "0749" "Mass Storage" "4000000000"
    r=$(run_detect "sdi1" "/devices/pci0000:00/plain/block")
    assert_equal "$r" "MATCH" \
        "R11 whitelist still applied despite unrelated backup_root failure"
    assert_file_contains "configuration error" "$NOTICES_FILE" \
        "R11 unrelated failure was still reported, just not fatal to hotplug"

    # set -f must be restored: create a real glob match and confirm expansion
    # still happens in a fresh shell that sources the same functions.
    r11_glob_dir="$TEST_ROOT/globcheck"
    rm -rf "$r11_glob_dir"
    mkdir -p "$r11_glob_dir"
    : > "$r11_glob_dir/one.txt"
    : > "$r11_glob_dir/two.txt"
    r11_glob_out="$TEST_ROOT/r11-glob.out"
    (
        export OUTDOOR_BACKUP_HOTPLUG_SOURCED=1
        export SYSFS_ROOT="$TEST_ROOT"
        export SUBSYSTEM="block"
        export OUTDOOR_BACKUP_CONFIG="$LEGACY_FILE"
        export OUTDOOR_BACKUP_CONFIG_SCRIPT="$CONFIG_SCRIPT"
        DEVNAME="sdi1"
        # shellcheck disable=SC1090
        . "$HOTPLUG_SRC"
        load_reader_config 2>/dev/null
        is_sdcard "/devices/pci0000:00/plain/block" >/dev/null
        # shellcheck disable=SC2231
        for f in "$r11_glob_dir"/*.txt; do
            printf '%s\n' "$f"
        done
    ) > "$r11_glob_out"
    r11_glob_count=$(wc -l < "$r11_glob_out")
    assert_equal "$r11_glob_count" "2" \
        "R11 set -f restored: glob expanded to both files after detection"
}

# ---------------------------------------------------------------------------
# R12: heuristic behaviors carried over from the pre-migration suite must keep
# working through the new UCI-first channel.
# ---------------------------------------------------------------------------
case_r12_heuristic_behaviors_preserved() {
    begin_case R12 "1TB+ card saved by whitelist (size cap bypassed)"
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_usb_ids '14cd:1212'
	option card_reader_heuristic_fallback 'no'"
    # 1TB = ~1953125000 sectors, above the 1073741824 heuristic cap.
    mock_device "sdj" "14cd" "1212" "SD 1TB" "1953125000"
    r=$(run_detect "sdj1" "/devices/plain/block")
    assert_equal "$r" "MATCH" "R12a 1TB card matches via whitelist despite size cap"

    begin_case R12b "model-string heuristic hit"
    prepare_reader_state
    mock_device "sdk" "" "" "Card Reader" "1000000"
    r=$(run_detect "sdk1" "/devices/plain/plain")
    assert_equal "$r" "MATCH" "R12b model string heuristic still matches"

    begin_case R12c "path-string heuristic hit"
    prepare_reader_state
    mock_device "sdl" "" "" "Unknown" "1000000"
    r=$(run_detect "sdl1" "/devices/usb1/reader/block")
    assert_equal "$r" "MATCH" "R12c path string heuristic still matches"

    begin_case R12d "strict mode with empty whitelist blocks everything"
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_heuristic_fallback 'no'"
    mock_device "sdm" "05e3" "0749" "Card Reader" "1000000"
    r=$(run_detect "sdm1" "/devices/usb/card-reader")
    assert_equal "$r" "NOMATCH" "R12d strict mode fires for nothing when whitelist empty"

    begin_case R12e "VID:PID match is case-insensitive"
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_usb_ids '05e3:0749'
	option card_reader_heuristic_fallback 'no'"
    mock_device "sdn" "05E3" "0749" "Reader" "1000000"
    r=$(run_detect "sdn1" "/devices/plain")
    assert_equal "$r" "MATCH" "R12e uppercase sysfs id matches lowercase whitelist entry"
}

# ---------------------------------------------------------------------------
# R13: mutation probe. Break the UCI-over-legacy precedence for
# card_reader_usb_ids inside the hotplug/config wiring, and prove the R04
# assertion catches it. If the targeted line is not found, the probe itself
# must fail loud instead of silently passing.
# ---------------------------------------------------------------------------
case_r13_mutation_probe_uci_precedence() {
    begin_case R13 "mutation probe: UCI precedence for card_reader_usb_ids"
    mutated_config="$TEST_ROOT/config.mutated.sh"
    cp "$CONFIG_SCRIPT" "$mutated_config"
    sed -i '/config_apply_uci_option "\$uci_dir" card_reader_usb_ids/d' "$mutated_config"

    ASSERTIONS=$((ASSERTIONS + 1))
    if cmp -s "$CONFIG_SCRIPT" "$mutated_config"; then
        fail "R13 mutation probe: sed did not remove the targeted apply-uci-option line"
        return
    fi

    prepare_reader_state
    write_legacy 'CARD_READER_USB_IDS="aaaa:bbbb"
CARD_READER_HEURISTIC_FALLBACK="no"'
    write_uci "config outdoor-backup 'config'
	option card_reader_usb_ids '05e3:0749'
	option card_reader_heuristic_fallback 'no'"
    mock_device "sdo" "aaaa" "bbbb" "Mass Storage" "4000000000"

    CONFIG_SCRIPT_SAVED="$CONFIG_SCRIPT"
    CONFIG_SCRIPT="$mutated_config"
    r=$(run_detect "sdo1" "/devices/pci0000:00/plain/mutated")
    CONFIG_SCRIPT="$CONFIG_SCRIPT_SAVED"

    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$r" != "MATCH" ]; then
        fail "R13 mutation probe: expected the R04 assertion to flip red under the mutation (got $r)"
    fi
}

# ---------------------------------------------------------------------------
# R14: config.sh unreadable -> the trigger stays alive on the built-in
# heuristic. `.` is a POSIX special builtin: in ash, sourcing a file that
# cannot be opened terminates the whole script, and `if ! . "$f"` does NOT
# catch it. A guard that only inspects the source's exit status is therefore
# dead code, and the trigger dies -- taking the "remove" cleanup path with it.
# ---------------------------------------------------------------------------
case_r14_missing_config_script_does_not_kill_trigger() {
    begin_case R14 "an unreadable config.sh leaves the trigger alive on the heuristic"
    prepare_reader_state
    # A legacy whitelist that WOULD match, to prove it was never read.
    write_legacy 'CARD_READER_USB_IDS="05e3:0749"'
    mock_device "sdp" "05e3" "0749" "Mass Storage" "4000000000"

    r14_saved="$CONFIG_SCRIPT"
    CONFIG_SCRIPT="$TEST_ROOT/no-such-config.sh"
    r=$(run_detect "sdp1" "/devices/pci0000:00/plain/nocfg")
    assert_equal "$r" "NOMATCH" \
        "R14 the trigger returned a verdict instead of dying inside the source"

    # Same missing loader, but a device the heuristic recognizes: proves the
    # fallback is genuinely active rather than everything simply failing.
    prepare_reader_state
    mock_device "sdq" "" "" "Card Reader" "1000000"
    r=$(run_detect "sdq1" "/devices/plain/plain")
    CONFIG_SCRIPT="$r14_saved"
    assert_equal "$r" "MATCH" \
        "R14 the built-in heuristic still runs when the loader is unavailable"
}

main() {
    trap cleanup_test_data EXIT INT TERM
    mkdir -p "$TEST_ROOT"

    case_r01_defaults_preserve_heuristic
    case_r02_legacy_only_usb_id_hit
    case_r03_uci_only_usb_id_hit
    case_r04_uci_overrides_legacy
    case_r05_empty_uci_falls_back_to_legacy
    case_r06_uci_path_prefix_hit
    case_r07_uci_strict_mode_blocks_unmatched
    case_r08_invalid_usb_ids_fail_loud
    case_r09_invalid_path_prefixes_fail_loud
    case_r10_invalid_fallback_fails_loud
    case_r11_unrelated_failure_does_not_abort_detection
    case_r12_heuristic_behaviors_preserved
    case_r13_mutation_probe_uci_precedence
    case_r14_missing_config_script_does_not_kill_trigger

    assert_equal "$CASES" "18" "all required cases executed"
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$ASSERTIONS" -ne 32 ]; then
        fail "all required assertions executed (expected=32, actual=$ASSERTIONS)"
    fi
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

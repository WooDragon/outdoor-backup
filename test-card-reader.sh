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
# Directory holding the real `uci` binary, resolved once up front (before any
# test overrides PATH) so R16 can build a PATH that excludes it specifically
# -- without also losing readlink/cat/grep/tr/dirname, which the hotplug
# detection functions still need.
UCI_REAL_PATH=$(command -v uci 2>/dev/null || printf '')
UCI_REAL_DIR=""
[ -n "$UCI_REAL_PATH" ] && UCI_REAL_DIR=$(dirname "$UCI_REAL_PATH")
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

assert_file_not_contains() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if grep -F -q -- "$1" "$2"; then
        fail "$3 (unexpectedly present: [$1])"
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
    # The logger stub must be OBSERVABLE, not a black hole: the hotplug
    # trigger reports every degradation through log_message -> logger, so a
    # stub that just `exit 0`s would make any assertion about that wording
    # vacuously true. Append the message text to the same $NOTICES_FILE that
    # collects config.sh's stderr, so cases can assert on both channels.
    cat > "$TEST_ROOT/bin/logger" <<EOF
#!/bin/sh
# Last argument is the message; -t <tag> precedes it.
for a in "\$@"; do msg="\$a"; done
printf '%s\n' "\$msg" >> "$NOTICES_FILE"
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

# Run config_load, then config_validate_card_reader, in the same sourced
# session -- proving the layering split: config_load only assigns
# CARD_READER_*, config_validate_card_reader is the sole validator. Writes
# each step's exit status to the given files so the caller can assert on
# both independently; card-reader validation's config_error output lands on
# this function's own stderr (redirect at the call site).
# Args: $1 file to receive config_load's exit status,
#       $2 file to receive config_validate_card_reader's exit status.
load_then_validate_card_reader() {
    load_rc_file="$1"
    validate_rc_file="$2"
    # shellcheck disable=SC1090
    . "$CONFIG_SCRIPT"
    config_load "$LEGACY_FILE"
    printf '%s' "$?" > "$load_rc_file"
    config_validate_card_reader
    printf '%s' "$?" > "$validate_rc_file"
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

# Same as run_detect, but with a PATH that has the real `uci` binary's
# directory removed -- simulating "uci CLI unavailable while the UCI conf
# file exists" (R16) -- while every other utility (readlink, cat, grep, tr,
# dirname, the logger stub) stays reachable, because is_sdcard's own
# machinery still needs them.
run_detect_no_uci() {
    devname="$1"
    devpath="$2"
    no_uci_path="$TEST_ROOT/bin"
    IFS_SAVED=$IFS
    IFS=:
    for d in $ORIGINAL_PATH; do
        [ -n "$UCI_REAL_DIR" ] && [ "$d" = "$UCI_REAL_DIR" ] && continue
        no_uci_path="$no_uci_path:$d"
    done
    IFS=$IFS_SAVED
    (
        set +e
        export OUTDOOR_BACKUP_HOTPLUG_SOURCED=1
        export SYSFS_ROOT="$TEST_ROOT"
        export SUBSYSTEM="block"
        export OUTDOOR_BACKUP_CONFIG="$LEGACY_FILE"
        export OUTDOOR_BACKUP_CONFIG_SCRIPT="$CONFIG_SCRIPT"
        PATH="$no_uci_path"
        export PATH
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
# R8: invalid card_reader_usb_ids -- config_load itself must SUCCEED (it only
# assigns this field now); config_validate_card_reader is the one that fails
# loud with a reason on stderr. This is the layering split from the #11
# review: card-reader validation moved out of the shared loader.
# ---------------------------------------------------------------------------
case_r08_invalid_usb_ids_fail_loud() {
    begin_case R08 "invalid card_reader_usb_ids: config_load succeeds, config_validate_card_reader fails loud"
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_usb_ids '05e3:074'"
    r8_load_rc="$TEST_ROOT/r08.load_rc"
    r8_validate_rc="$TEST_ROOT/r08.validate_rc"
    r8_err="$TEST_ROOT/r08.err"
    load_then_validate_card_reader "$r8_load_rc" "$r8_validate_rc" 2>"$r8_err"
    assert_equal "$(cat "$r8_load_rc")" "0" \
        "R08 config_load succeeds despite the invalid usb_ids token (layering)"
    assert_equal "$(cat "$r8_validate_rc")" "1" \
        "R08 config_validate_card_reader rejects the short vid:pid token"
    assert_file_contains "configuration error" "$r8_err" \
        "R08 short vid:pid token reported as configuration error"

    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_usb_ids 'zzzz:0749'"
    r8b_load_rc="$TEST_ROOT/r08b.load_rc"
    r8b_validate_rc="$TEST_ROOT/r08b.validate_rc"
    r8b_err="$TEST_ROOT/r08b.err"
    load_then_validate_card_reader "$r8b_load_rc" "$r8b_validate_rc" 2>"$r8b_err"
    assert_equal "$(cat "$r8b_load_rc")" "0" \
        "R08 config_load succeeds despite the non-hex usb_ids token (layering)"
    assert_equal "$(cat "$r8b_validate_rc")" "1" \
        "R08 config_validate_card_reader rejects the non-hex vid:pid token"
    assert_file_contains "configuration error" "$r8b_err" \
        "R08 non-hex vid:pid token reported as configuration error"
}

# ---------------------------------------------------------------------------
# R9: invalid card_reader_path_prefixes -- config_load succeeds (assignment
# only), config_validate_card_reader fails loud. Covers a relative path, a
# glob-containing path, the bare "/" (which would match every DEVPATH), and
# a path with a ".." segment.
# ---------------------------------------------------------------------------
case_r09_invalid_path_prefixes_fail_loud() {
    begin_case R09 "invalid card_reader_path_prefixes: config_load succeeds, config_validate_card_reader fails loud"
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_path_prefixes 'devices/usb1'"
    r9_load_rc="$TEST_ROOT/r09.load_rc"
    r9_validate_rc="$TEST_ROOT/r09.validate_rc"
    r9_err="$TEST_ROOT/r09.err"
    load_then_validate_card_reader "$r9_load_rc" "$r9_validate_rc" 2>"$r9_err"
    assert_equal "$(cat "$r9_load_rc")" "0" \
        "R09 config_load succeeds despite the relative path prefix (layering)"
    assert_equal "$(cat "$r9_validate_rc")" "1" \
        "R09 config_validate_card_reader rejects the relative path prefix"
    assert_file_contains "configuration error" "$r9_err" \
        "R09 relative path prefix reported as configuration error"

    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_path_prefixes '/devices/*'"
    r9b_load_rc="$TEST_ROOT/r09b.load_rc"
    r9b_validate_rc="$TEST_ROOT/r09b.validate_rc"
    r9b_err="$TEST_ROOT/r09b.err"
    load_then_validate_card_reader "$r9b_load_rc" "$r9b_validate_rc" 2>"$r9b_err"
    assert_equal "$(cat "$r9b_load_rc")" "0" \
        "R09 config_load succeeds despite the glob-containing path prefix (layering)"
    assert_equal "$(cat "$r9b_validate_rc")" "1" \
        "R09 config_validate_card_reader rejects the glob-containing path prefix"
    assert_file_contains "configuration error" "$r9b_err" \
        "R09 glob-containing path prefix reported as configuration error"

    # "/" alone would match every DEVPATH -- an unusable whitelist that looks
    # syntactically legal to the pre-existing checks.
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_path_prefixes '/'"
    r9c_load_rc="$TEST_ROOT/r09c.load_rc"
    r9c_validate_rc="$TEST_ROOT/r09c.validate_rc"
    r9c_err="$TEST_ROOT/r09c.err"
    load_then_validate_card_reader "$r9c_load_rc" "$r9c_validate_rc" 2>"$r9c_err"
    assert_equal "$(cat "$r9c_load_rc")" "0" \
        "R09 config_load succeeds despite the bare / prefix (layering)"
    assert_equal "$(cat "$r9c_validate_rc")" "1" \
        "R09 config_validate_card_reader rejects the bare / prefix"
    assert_file_contains "configuration error" "$r9c_err" \
        "R09 bare / prefix reported as configuration error"

    # A ".." segment can be used to climb back out of an intended subtree.
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_path_prefixes '/devices/usb1/../usb2'"
    r9d_load_rc="$TEST_ROOT/r09d.load_rc"
    r9d_validate_rc="$TEST_ROOT/r09d.validate_rc"
    r9d_err="$TEST_ROOT/r09d.err"
    load_then_validate_card_reader "$r9d_load_rc" "$r9d_validate_rc" 2>"$r9d_err"
    assert_equal "$(cat "$r9d_load_rc")" "0" \
        "R09 config_load succeeds despite the .. path segment (layering)"
    assert_equal "$(cat "$r9d_validate_rc")" "1" \
        "R09 config_validate_card_reader rejects the .. path segment"
    assert_file_contains "configuration error" "$r9d_err" \
        "R09 .. path segment reported as configuration error"
}

# ---------------------------------------------------------------------------
# R10: invalid card_reader_heuristic_fallback -- config_load succeeds,
# config_validate_card_reader fails loud.
# ---------------------------------------------------------------------------
case_r10_invalid_fallback_fails_loud() {
    begin_case R10 "invalid card_reader_heuristic_fallback: config_load succeeds, config_validate_card_reader fails loud"
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_heuristic_fallback 'maybe'"
    r10_load_rc="$TEST_ROOT/r10.load_rc"
    r10_validate_rc="$TEST_ROOT/r10.validate_rc"
    r10_err="$TEST_ROOT/r10.err"
    load_then_validate_card_reader "$r10_load_rc" "$r10_validate_rc" 2>"$r10_err"
    assert_equal "$(cat "$r10_load_rc")" "0" \
        "R10 config_load succeeds despite the invalid fallback value (layering)"
    assert_equal "$(cat "$r10_validate_rc")" "1" \
        "R10 config_validate_card_reader rejects the invalid fallback value"
    assert_file_contains "configuration error" "$r10_err" \
        "R10 invalid fallback value reported as configuration error"
}

# ---------------------------------------------------------------------------
# R11: config_load failing for an UNRELATED reason (bad backup_root) must not
# abort hotplug detection. Since #11's layering fix, config_load never
# validates CARD_READER_* at all (config_validate_card_reader does, called
# unconditionally by load_reader_config regardless of config_load's own
# outcome) -- so this is no longer about "validation didn't reach the
# card-reader fields yet"; the two are simply independent checks.
#
# Also verify `set -f` is restored by config_validate_card_reader on BOTH its
# failure and success return paths. This is isolated to the validator alone
# (source config.sh directly, no hotplug, no config_load, no detection
# functions) so a forgotten `set +f` on either path shows up immediately in
# a plain glob expansion right after the call -- nothing else in between
# could have restored it.
# ---------------------------------------------------------------------------
case_r11_unrelated_failure_does_not_abort_detection() {
    begin_case R11 "unrelated config_load failure does not abort hotplug detection; set -f restored either way"
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

    r11_glob_dir="$TEST_ROOT/globcheck"
    rm -rf "$r11_glob_dir"
    mkdir -p "$r11_glob_dir"
    : > "$r11_glob_dir/one.txt"
    : > "$r11_glob_dir/two.txt"

    r11_fail_glob_out="$TEST_ROOT/r11-fail-glob.out"
    (
        # shellcheck disable=SC1090
        . "$CONFIG_SCRIPT"
        CARD_READER_USB_IDS="not-a-valid-token"
        CARD_READER_PATH_PREFIXES=""
        CARD_READER_HEURISTIC_FALLBACK="yes"
        config_validate_card_reader 2>/dev/null
        # shellcheck disable=SC2231
        for f in "$r11_glob_dir"/*.txt; do
            printf '%s\n' "$f"
        done
    ) > "$r11_fail_glob_out"
    r11_fail_glob_count=$(wc -l < "$r11_fail_glob_out")
    assert_equal "$r11_fail_glob_count" "2" \
        "R11 set -f restored on config_validate_card_reader's failure path"

    r11_ok_glob_out="$TEST_ROOT/r11-ok-glob.out"
    (
        # shellcheck disable=SC1090
        . "$CONFIG_SCRIPT"
        CARD_READER_USB_IDS="05e3:0749"
        CARD_READER_PATH_PREFIXES="/devices/usb1"
        CARD_READER_HEURISTIC_FALLBACK="no"
        config_validate_card_reader 2>/dev/null
        # shellcheck disable=SC2231
        for f in "$r11_glob_dir"/*.txt; do
            printf '%s\n' "$f"
        done
    ) > "$r11_ok_glob_out"
    r11_ok_glob_count=$(wc -l < "$r11_ok_glob_out")
    assert_equal "$r11_ok_glob_count" "2" \
        "R11 set -f restored on config_validate_card_reader's success path"
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

# ---------------------------------------------------------------------------
# R15: an invalid UCI card_reader_usb_ids must not abort hotplug and must not
# be reported with the retired "unrelated error" wording -- this is the
# genuinely relevant failure case, the mirror image of R11's genuinely
# unrelated one. config_validate_card_reader's failure must actually reset
# the three fields to the degraded default (empty whitelist, fallback=yes),
# not just be observed and ignored: card_reader_heuristic_fallback is
# deliberately also set to 'no' (strict mode) here, so a real device match
# is possible ONLY if the reset genuinely ran and overrode that 'no' back to
# 'yes' -- if hotplug merely logged the validation failure without resetting
# the globals, CARD_READER_HEURISTIC_FALLBACK would still read 'no' and this
# device (which matches no whitelist entry) would come back NOMATCH. Verified
# by mutation: deleting the reset block while keeping the
# config_validate_card_reader call still made the suite pass under the
# earlier (weaker) version of this case, which asserted MATCH against a UCI
# section that never set card_reader_heuristic_fallback at all -- fallback
# was already 'yes' by default, so the reset's absence went unnoticed. This
# version was confirmed to fail loud under that same mutation.
# ---------------------------------------------------------------------------
case_r15_invalid_uci_whitelist_falls_back_to_heuristic() {
    begin_case R15 "invalid UCI card_reader_usb_ids: the reset to degraded default actually happens, not just gets logged"
    prepare_reader_state
    write_uci "config outdoor-backup 'config'
	option card_reader_usb_ids 'zzzz:0749'
	option card_reader_heuristic_fallback 'no'"
    mock_device "sdt" "" "" "Card Reader" "1000000"
    r=$(run_detect "sdt1" "/devices/plain/plain")
    assert_equal "$r" "MATCH" \
        "R15 heuristic matches only because the reset overrode strict-mode fallback=no back to yes"
    assert_file_contains "configuration error" "$NOTICES_FILE" \
        "R15 the invalid token is still logged as a configuration error"
    assert_file_contains "card-reader whitelist is invalid" "$NOTICES_FILE" \
        "R15 hotplug reports the reset through log_message (this also proves the logger channel reaches NOTICES_FILE, so the next assertion is not vacuous)"
    assert_file_not_contains "unrelated" "$NOTICES_FILE" \
        "R15 the retired 'unrelated error' wording must not reappear for a genuinely relevant failure"
}

# ---------------------------------------------------------------------------
# R16: the UCI conf file exists but the `uci` CLI itself is unavailable.
# config_load must fail BEFORE any config_apply_uci_option call (Major 1's
# first half) -- so the hotplug trigger's verdict must come from the legacy
# value, never from the UCI value that was never applied. Constructed with a
# PATH that specifically hides the real `uci` binary's directory (see
# run_detect_no_uci) while keeping readlink/cat/grep/tr/dirname reachable.
# ---------------------------------------------------------------------------
case_r16_uci_cli_missing_uses_legacy_not_uci_value() {
    begin_case R16 "uci CLI unavailable: config_load fails before any UCI value applies; hotplug still decides, using the legacy value"

    # Each mock_device call points its device's sysfs "device" symlink at the
    # SAME shared usb1/1-1 node (see mock_device), so two devices mocked
    # under one prepare_reader_state would clobber each other's idVendor/
    # idProduct -- exactly like R04 above, each half gets its own fresh
    # prepare_reader_state.
    prepare_reader_state
    write_legacy 'CARD_READER_USB_IDS="05e3:0749"
CARD_READER_HEURISTIC_FALLBACK="no"'
    write_uci "config outdoor-backup 'config'
	option card_reader_usb_ids 'aaaa:bbbb'
	option card_reader_heuristic_fallback 'no'"
    mock_device "sdr" "05e3" "0749" "Mass Storage" "4000000000"
    r_legacy=$(run_detect_no_uci "sdr1" "/devices/pci0000:00/plain/legacy-hit")
    assert_equal "$r_legacy" "MATCH" \
        "R16 legacy card_reader_usb_ids value still applies when uci CLI is unavailable"
    assert_file_contains "uci CLI is required" "$NOTICES_FILE" \
        "R16 missing uci CLI is reported with its specific reason"

    prepare_reader_state
    write_legacy 'CARD_READER_USB_IDS="05e3:0749"
CARD_READER_HEURISTIC_FALLBACK="no"'
    write_uci "config outdoor-backup 'config'
	option card_reader_usb_ids 'aaaa:bbbb'
	option card_reader_heuristic_fallback 'no'"
    mock_device "sds" "aaaa" "bbbb" "Mass Storage" "4000000000"
    r_uci_only=$(run_detect_no_uci "sds1" "/devices/pci0000:00/plain/uci-only")
    assert_equal "$r_uci_only" "NOMATCH" \
        "R16 UCI-only value never applied: it was never reached before config_load failed"
}

# ---------------------------------------------------------------------------
# R17: the legacy backup.conf path exists but cannot be sourced (constructed
# as a directory rather than a regular file -- a real, reproducible
# "exists but unreadable" shape on this rootfs; a chmod 000 is not usable
# here because the container runs as root, and root ignores permission
# bits). config_load must return nonzero (fail closed) WITHOUT killing the
# calling script via the `.` special builtin -- it never reaches `.` at all,
# because config.sh's `[ -f ] && [ -r ]` guard rejects the directory first.
# The hotplug trigger still produces a verdict, on the degraded default.
# ---------------------------------------------------------------------------
case_r17_unreadable_legacy_file_fails_closed_without_killing_caller() {
    begin_case R17 "an unreadable (directory) legacy file fails config_load closed without killing the hotplug trigger"
    prepare_reader_state
    rm -rf "$LEGACY_FILE"
    mkdir -p "$LEGACY_FILE"
    mock_device "sdu" "" "" "Card Reader" "1000000"

    r=$(run_detect "sdu1" "/devices/plain/plain")
    assert_equal "$r" "MATCH" \
        "R17 the trigger produced a verdict via the heuristic instead of dying"
    assert_file_contains "configuration error" "$NOTICES_FILE" \
        "R17 the unreadable legacy file is reported as a configuration error"
    assert_file_contains "cannot be read" "$NOTICES_FILE" \
        "R17 the specific reason (cannot be read) is reported"

    rm -rf "$LEGACY_FILE"
}

# ---------------------------------------------------------------------------
# R18: mutation probe. Delete the `set +f` that guards
# config_validate_card_reader's card_reader_usb_ids failure branch, and prove
# R11's failure-path glob assertion goes red under the mutation. If the
# targeted line cannot be located at the expected position, the probe itself
# fails loud instead of silently passing.
# ---------------------------------------------------------------------------
case_r18_mutation_probe_validate_set_f_restored() {
    begin_case R18 "mutation probe: config_validate_card_reader restores set -f on its usb_ids failure path"

    usb_error_line=$(grep -n 'config_error "card_reader_usb_ids: invalid token' "$CONFIG_SCRIPT" | head -1 | cut -d: -f1)
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ -z "$usb_error_line" ]; then
        fail "R18 mutation probe: could not locate the card_reader_usb_ids config_error line in $CONFIG_SCRIPT"
        return
    fi
    set_f_line=$((usb_error_line - 1))
    set_f_content=$(sed -n "${set_f_line}p" "$CONFIG_SCRIPT")

    ASSERTIONS=$((ASSERTIONS + 1))
    case "$set_f_content" in
        *'set +f'*)
            ;;
        *)
            fail "R18 mutation probe: expected line $set_f_line of $CONFIG_SCRIPT to be 'set +f' (got [$set_f_content])"
            return
            ;;
    esac

    mutated_config="$TEST_ROOT/config.mutated-setf.sh"
    cp "$CONFIG_SCRIPT" "$mutated_config"
    sed -i "${set_f_line}d" "$mutated_config"

    ASSERTIONS=$((ASSERTIONS + 1))
    if cmp -s "$CONFIG_SCRIPT" "$mutated_config"; then
        fail "R18 mutation probe: sed did not remove the targeted set +f line"
        return
    fi

    r18_glob_dir="$TEST_ROOT/globcheck-r18"
    rm -rf "$r18_glob_dir"
    mkdir -p "$r18_glob_dir"
    : > "$r18_glob_dir/one.txt"
    : > "$r18_glob_dir/two.txt"
    r18_glob_out="$TEST_ROOT/r18-glob.out"
    (
        # shellcheck disable=SC1090
        . "$mutated_config"
        CARD_READER_USB_IDS="not-a-valid-token"
        CARD_READER_PATH_PREFIXES=""
        CARD_READER_HEURISTIC_FALLBACK="yes"
        config_validate_card_reader 2>/dev/null
        # shellcheck disable=SC2231
        for f in "$r18_glob_dir"/*.txt; do
            printf '%s\n' "$f"
        done
    ) > "$r18_glob_out"
    r18_glob_count=$(wc -l < "$r18_glob_out")

    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$r18_glob_count" = "2" ]; then
        fail "R18 mutation probe: expected the R11 failure-path glob assertion to flip red under the mutation (got count=$r18_glob_count, glob still expanded)"
    fi
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
    case_r15_invalid_uci_whitelist_falls_back_to_heuristic
    case_r16_uci_cli_missing_uses_legacy_not_uci_value
    case_r17_unreadable_legacy_file_fails_closed_without_killing_caller
    case_r18_mutation_probe_validate_set_f_restored

    assert_equal "$CASES" "22" "all required cases executed"
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$ASSERTIONS" -ne 58 ]; then
        fail "all required assertions executed (expected=58, actual=$ASSERTIONS)"
    fi
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

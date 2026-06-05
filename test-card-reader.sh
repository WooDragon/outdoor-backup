#!/bin/bash
#
# BDD test suite for issue #2: configurable card reader whitelist.
# Mocks a sysfs tree under /tmp and sources the hotplug detection functions.
#

# No `set -e`: tests probe both match and no-match paths.

TEST_ROOT="/tmp/outdoor-backup-reader-test"
HOTPLUG_SRC="$(cd "$(dirname "$0")/files/etc/hotplug.d/block" && pwd)/90-outdoor-backup"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0

test_passed() { echo -e "${GREEN}✓ PASSED${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
test_failed() { echo -e "${RED}✗ FAILED${NC}: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Create a mock sysfs node for a block device.
# Args: $1 dev (e.g. sda)  $2 vid  $3 pid  $4 model  $5 size_sectors
# Empty vid/pid/model/size are simply not created.
mock_device() {
	local dev="$1" vid="$2" pid="$3" model="$4" size="$5"
	local sys="$TEST_ROOT/sys"
	# USB device node carrying the IDs, with the block device's "device"
	# symlink pointing into it (mirrors real sysfs topology).
	local usbnode="$sys/devices/usb1/1-1"
	mkdir -p "$usbnode" "$sys/block/$dev"
	[ -n "$vid" ] && printf '%s\n' "$vid" > "$usbnode/idVendor"
	[ -n "$pid" ] && printf '%s\n' "$pid" > "$usbnode/idProduct"
	# block/<dev>/device -> the usb interface under the usb device node
	local iface="$usbnode/1-1:1.0/host0/target0/0:0:0:0"
	mkdir -p "$iface"
	ln -snf "$iface" "$sys/block/$dev/device"
	[ -n "$model" ] && printf '%s\n' "$model" > "$iface/model"
	[ -n "$size" ] && printf '%s\n' "$size" > "$sys/block/$dev/size"
}

# Run is_sdcard against the mock tree with given config.
# Args: $1 devname  $2 devpath  $3 usb_ids  $4 path_prefixes  $5 fallback(yes/no)
# Echoes "MATCH" or "NOMATCH".
run_detect() {
	local devname="$1" devpath="$2" ids="$3" prefixes="$4" fallback="$5"
	(
		set +e
		export OUTDOOR_BACKUP_HOTPLUG_SOURCED=1
		export SYSFS_ROOT="$TEST_ROOT"
		export SUBSYSTEM="block"
		export OUTDOOR_BACKUP_CONFIG="/nonexistent-skip-real-config"
		DEVNAME="$devname"
		# shellcheck disable=SC1090
		. "$HOTPLUG_SRC"
		CARD_READER_USB_IDS="$ids"
		CARD_READER_PATH_PREFIXES="$prefixes"
		CARD_READER_HEURISTIC_FALLBACK="$fallback"
		if is_sdcard "$devpath"; then echo "MATCH"; else echo "NOMATCH"; fi
	)
}

main() {
	echo "========================================"
	echo "  Outdoor Backup - Card Reader Whitelist (#2)"
	echo "========================================"
	rm -rf "$TEST_ROOT"

	test_empty_whitelist_heuristic_unchanged
	test_usb_id_whitelist_hit
	test_usb_id_whitelist_non_reader_ignored
	test_path_prefix_whitelist_hit
	test_fallback_off_empty_whitelist_blocks_all
	test_large_card_whitelist_mode
	test_usb_id_case_insensitive
	test_glob_in_prefix_not_expanded

	echo ""
	echo "========================================"
	echo "  Test Results"
	echo "========================================"
	echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
	echo -e "${RED}Failed: $TESTS_FAILED${NC}"
	rm -rf "$TEST_ROOT"
	[ $TESTS_FAILED -eq 0 ] && { echo -e "${GREEN}All tests passed!${NC}"; exit 0; }
	echo -e "${RED}Some tests failed.${NC}"; exit 1
}

# PLACEHOLDER_TESTS

# Empty whitelist + fallback on -> behaves exactly like the old heuristic.
# A device whose path contains "card" must still be detected.
test_empty_whitelist_heuristic_unchanged() {
	echo ""
	echo "=== #2: empty whitelist falls back to heuristic (unchanged) ==="
	rm -rf "$TEST_ROOT"
	mock_device "sda" "" "" "Generic Card Reader" "1000000"
	local r
	r=$(run_detect "sda1" "/devices/pci/usb1/card-reader" "" "" "yes")
	[ "$r" = "MATCH" ] \
		&& test_passed "heuristic path match works with empty whitelist" \
		|| test_failed "expected MATCH via heuristic, got $r"
}

# VID:PID whitelist hit -> triggers regardless of heuristic.
test_usb_id_whitelist_hit() {
	echo ""
	echo "=== #2: VID:PID whitelist match triggers ==="
	rm -rf "$TEST_ROOT"
	# A device with NO heuristic signal (boring path, big size, plain model)
	# but a whitelisted USB ID must still match.
	mock_device "sdb" "05e3" "0749" "Mass Storage" "4000000000"
	local r
	r=$(run_detect "sdb1" "/devices/pci0000:00/plain/block" "05e3:0749" "" "no")
	[ "$r" = "MATCH" ] \
		&& test_passed "whitelisted VID:PID matches even with no heuristic signal" \
		|| test_failed "expected MATCH via USB ID, got $r"
}

# A non-whitelisted device (e.g. an external SSD) must NOT trigger when only
# the whitelist is authoritative (fallback off).
test_usb_id_whitelist_non_reader_ignored() {
	echo ""
	echo "=== #2: non-whitelisted device ignored (fallback off) ==="
	rm -rf "$TEST_ROOT"
	mock_device "sdc" "0bc2" "ab38" "Portable SSD" "4000000000"
	local r
	r=$(run_detect "sdc1" "/devices/pci/usb2/ssd" "05e3:0749" "" "no")
	[ "$r" = "NOMATCH" ] \
		&& test_passed "industrial SSD not misdetected (whitelist miss, no fallback)" \
		|| test_failed "expected NOMATCH, got $r"
}

# Path-prefix whitelist hit.
test_path_prefix_whitelist_hit() {
	echo ""
	echo "=== #2: device-path prefix whitelist match ==="
	rm -rf "$TEST_ROOT"
	mock_device "sdd" "1234" "5678" "Unknown" "4000000000"
	local r
	r=$(run_detect "sdd1" "/devices/platform/soc/usb3/reader-x" \
		"" "/devices/platform/soc/usb3" "no")
	[ "$r" = "MATCH" ] \
		&& test_passed "path-prefix whitelist matches" \
		|| test_failed "expected MATCH via path prefix, got $r"
}

# Fallback off + empty whitelist -> nothing triggers (documented strict mode).
test_fallback_off_empty_whitelist_blocks_all() {
	echo ""
	echo "=== #2: strict mode (no fallback, empty whitelist) blocks all ==="
	rm -rf "$TEST_ROOT"
	mock_device "sde" "05e3" "0749" "Card Reader" "1000000"
	local r
	r=$(run_detect "sde1" "/devices/usb/card-reader" "" "" "no")
	[ "$r" = "NOMATCH" ] \
		&& test_passed "strict mode fires for nothing when whitelist empty" \
		|| test_failed "expected NOMATCH in strict mode, got $r"
}

# 1TB+ card via whitelist mode: the size heuristic would reject it (>512GB),
# but a whitelist match must still trigger.
test_large_card_whitelist_mode() {
	echo ""
	echo "=== #2: 1TB+ card triggers via whitelist (size cap bypassed) ==="
	rm -rf "$TEST_ROOT"
	# 1TB = ~1953125000 sectors, above the 1073741824 heuristic cap.
	mock_device "sdf" "14cd" "1212" "SD 1TB" "1953125000"
	# Heuristic alone would still match on model "SD"; to isolate the whitelist
	# path, turn fallback off so ONLY the whitelist can match.
	local r
	r=$(run_detect "sdf1" "/devices/plain/block" "14cd:1212" "" "no")
	[ "$r" = "MATCH" ] \
		&& test_passed "1TB card matches via whitelist (no size-cap rejection)" \
		|| test_failed "expected MATCH for whitelisted 1TB card, got $r"
}

# VID:PID comparison must be case-insensitive (sysfs is lowercase; users may
# type uppercase from lsusb output).
test_usb_id_case_insensitive() {
	echo ""
	echo "=== #2: VID:PID match is case-insensitive ==="
	rm -rf "$TEST_ROOT"
	mock_device "sdg" "05E3" "0749" "Reader" "1000000"   # uppercase in sysfs
	local r
	r=$(run_detect "sdg1" "/devices/plain" "05e3:0749" "" "no")
	[ "$r" = "MATCH" ] \
		&& test_passed "uppercase sysfs ID matches lowercase whitelist entry" \
		|| test_failed "case-insensitive match failed, got $r"
}

# A literal '*' in a configured path prefix must be treated literally, not
# expanded against the filesystem (set -f guard). A device whose path does NOT
# contain the literal star must NOT match.
test_glob_in_prefix_not_expanded() {
	echo ""
	echo "=== #2: glob char in path prefix is literal (no FS expansion) ==="
	rm -rf "$TEST_ROOT"
	mock_device "sdh" "1111" "2222" "Unknown" "4000000000"
	# Prefix contains a literal '*'. The real dev_path has no star, so a
	# correctly-literal match must FAIL (NOMATCH). If globbing leaked, the
	# pattern could expand unpredictably.
	local r
	r=$(run_detect "sdh1" "/devices/real/usb/block" "" "/devices/*/star" "no")
	[ "$r" = "NOMATCH" ] \
		&& test_passed "literal '*' prefix does not spuriously match" \
		|| test_failed "glob leaked into prefix matching, got $r"

	# And the literal star DOES match a path that literally contains it.
	r=$(run_detect "sdh1" "/devices/*/star/x" "" "/devices/*/star" "no")
	[ "$r" = "MATCH" ] \
		&& test_passed "literal '*' prefix matches a path containing it" \
		|| test_failed "literal prefix match failed, got $r"
}


main "$@"

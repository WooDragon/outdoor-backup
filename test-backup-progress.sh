#!/bin/sh
#
# BDD tests for the source-only rsync progress parser. Fixtures are created only
# below /tmp, and every assertion calls the shipped parser rather than a copy.
#
set -u

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROGRESS_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/backup-progress.sh"
TEST_ROOT="/tmp/outdoor-backup-progress.$$"
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
	[ "$actual" = "$expected" ] || fail "$message (expected=[$expected], actual=[$actual])"
}

assert_success() {
	message=$1
	shift
	ASSERTIONS=$((ASSERTIONS + 1))
	"$@" || fail "$message"
}

assert_json() {
	json=$1
	filter=$2
	message=$3
	ASSERTIONS=$((ASSERTIONS + 1))
	printf '%s\n' "$json" | jq -e "$filter" >/dev/null 2>&1 || fail "$message (json=[$json])"
}

setup_fixture() {
	rm -rf "$TEST_ROOT"
	mkdir -p "$TEST_ROOT"
	# shellcheck disable=SC1090
	. "$PROGRESS_SCRIPT"
}

write_record() {
	path=$1
	format=$2
	shift 2
	printf '%b' "$format" > "$path"
}

read_progress() {
	backup_progress_read "$1"
}

assert_parse_failure() {
	path=$1
	message=$2
	if output=$(read_progress "$path"); then
		rc=0
	else
		rc=$?
	fi
	ASSERTIONS=$((ASSERTIONS + 1))
	[ "$rc" -ne 0 ] || fail "$message returns failure"
	assert_equal "$output" '' "$message emits no JSON"
}

case_source_is_inert() {
	begin_case P01 'sourcing defines the API without I/O or trap side effects'
	mkdir -p "$TEST_ROOT/source"
	before=$(find "$TEST_ROOT/source" -mindepth 1 -print)
	before_trap=$(trap)
	# shellcheck disable=SC1090
	. "$PROGRESS_SCRIPT"
	after=$(find "$TEST_ROOT/source" -mindepth 1 -print)
	assert_success 'P01 defines backup_progress_read' command -v backup_progress_read
	assert_equal "$after" "$before" 'P01 source creates no fixture files'
	assert_equal "$(trap)" "$before_trap" 'P01 source leaves caller traps unchanged'
}

case_cr_running_record() {
	begin_case P02 'a complete CR running record emits bytes and truncated kB speed'
	setup_fixture
	fixture="$TEST_ROOT/cr-running"
	write_record "$fixture" '\r 360,448 4% 290.38kB/s 0:00:27  \r'
	output=$(read_progress "$fixture") || fail 'P02 parses complete CR record'
	assert_json "$output" '.bytes_done == 360448 and .speed_bytes_per_sec == 297349 and .files_done == null and .entries_done == null and .entries_total == null' \
		'P02 returns the declared JSON contract without invented counters'
}

case_lf_suffix_record() {
	begin_case P03 'a complete LF suffix reports file and to-chk counters'
	setup_fixture
	fixture="$TEST_ROOT/lf-suffix"
	write_record "$fixture" '\r 1,114,113 11% 249.65kB/s 0:00:04 (xfr#2, to-chk=0/8)\n'
	output=$(read_progress "$fixture") || fail 'P03 parses complete LF suffix record'
	assert_json "$output" '.bytes_done == 1114113 and .speed_bytes_per_sec == 255641 and .files_done == 2 and .entries_done == 8 and .entries_total == 8' \
		'P03 maps to-chk remaining/total to completed/total'
}

case_latest_progress_and_retained_suffix() {
	begin_case P04 'latest running values coexist with the window-local prior complete suffix'
	setup_fixture
	fixture="$TEST_ROOT/multiple"
	write_record "$fixture" '\r 1,000 1% 1.00MB/s 0:00:01 (xfr#2, to-chk=3/10)\r 2,000 2% 2.00MB/s 0:00:02  \nrsync stats are not progress\n'
	output=$(read_progress "$fixture") || fail 'P04 parses latest valid progress record'
	assert_json "$output" '.bytes_done == 2000 and .speed_bytes_per_sec == 2097152 and .files_done == 2 and .entries_done == 7 and .entries_total == 10' \
		'P04 ignores trailing stats and preserves only complete earlier suffix data'
}

case_zero_and_incremental_values() {
	begin_case P05 'zero values are valid and an 11 percent record is not completion'
	setup_fixture
	zero_fixture="$TEST_ROOT/zero"
	write_record "$zero_fixture" '\r 0 0% 0.00kB/s 0:00:00 (xfr#0, to-chk=0/0)\n'
	zero_output=$(read_progress "$zero_fixture") || fail 'P05 accepts zero-valued record'
	assert_json "$zero_output" '.bytes_done == 0 and .speed_bytes_per_sec == 0 and .files_done == 0 and .entries_done == 0 and .entries_total == 0' \
		'P05 preserves valid zero values'
	incremental_fixture="$TEST_ROOT/incremental"
	write_record "$incremental_fixture" '\r 1,114,113 11% 249.65kB/s 0:00:04 (xfr#2, to-chk=1/8)\n'
	incremental_output=$(read_progress "$incremental_fixture") || fail 'P05 parses incremental record'
	assert_json "$incremental_output" '.entries_done == 7 and .entries_total == 8 and .entries_done != .entries_total' \
		'P05 never treats the printed percentage as completion'
}

case_ir_chk_has_unknown_entries() {
	begin_case P06 'ir-chk retains xfr number but never invents stable entry totals'
	setup_fixture
	fixture="$TEST_ROOT/ir-chk"
	write_record "$fixture" '\r 3,000 3% 3.00MB/s 0:00:03 (xfr#3, ir-chk=5/20)\n'
	output=$(read_progress "$fixture") || fail 'P06 parses ir-chk record'
	assert_json "$output" '.bytes_done == 3000 and .files_done == 3 and .entries_done == null and .entries_total == null' \
		'P06 reports ir-chk entry progress as unknown'
}

case_window_boundary() {
	begin_case P07 'a tail window discards its first truncated fragment but parses later complete CR data'
	setup_fixture
	fixture="$TEST_ROOT/window"
	awk 'BEGIN { for (fill_index = 0; fill_index < 8200; fill_index++) printf "x" }' > "$fixture"
	printf '\r 9,999 9%% 1.00kB/s 0:00:09 (xfr#9, to-chk=0/9)\n' >> "$fixture"
	output=$(read_progress "$fixture") || fail 'P07 parses complete record after truncated prefix'
	assert_json "$output" '.bytes_done == 9999 and .speed_bytes_per_sec == 1024 and .files_done == 9 and .entries_done == 9 and .entries_total == 9' \
		'P07 rejects only the incomplete first tail fragment'
}

case_lookalike_tail_prefix_is_ignored() {
	begin_case P08 'a tail prefix that resembles progress without a preceding separator is ignored'
	setup_fixture
	fixture="$TEST_ROOT/lookalike-prefix"
	first_fragment=' 6,666 6% 1.00kB/s 0:00:06\r'
	valid_record='\r 7,777 7% 1.00kB/s 0:00:07 (xfr#7, to-chk=0/7)\n'
	first_size=$(printf '%b' "$first_fragment" | wc -c)
	valid_size=$(printf '%b' "$valid_record" | wc -c)
	padding_size=$((8192 - first_size - valid_size))
	awk -v count="$padding_size" 'BEGIN { for (fill_index = 0; fill_index < count; fill_index++) printf "x" }' > "$fixture"
	printf '%b%b' "$first_fragment" "$valid_record" >> "$fixture"
	output=$(read_progress "$fixture") || fail 'P08 parses the later complete record'
	assert_json "$output" '.bytes_done == 7777 and .files_done == 7 and .entries_done == 7 and .entries_total == 7' \
		'P08 ignores a valid-looking unbounded first tail field'
}

case_speed_units_and_rejection() {
	begin_case P09 'kB MB and GB convert deterministically while unknown units are rejected'
	setup_fixture
	for unit_case in kB MB GB; do
		fixture="$TEST_ROOT/speed-$unit_case"
		write_record "$fixture" "\\r 1 1% 1.50${unit_case}/s 0:00:01\\n"
		output=$(read_progress "$fixture") || fail "P08 parses $unit_case"
		case $unit_case in
			kB) expected=1536 ;;
			MB) expected=1572864 ;;
			GB) expected=1610612736 ;;
		esac
		assert_json "$output" ".speed_bytes_per_sec == $expected" "P08 converts $unit_case using binary multipliers"
	done
	unknown_fixture="$TEST_ROOT/speed-unknown"
	write_record "$unknown_fixture" '\r 1 1% 1.50TB/s 0:00:01\n'
	assert_parse_failure "$unknown_fixture" 'P08 rejects unsupported units'
}

case_invalid_and_incomplete_input() {
	begin_case P10 'missing, non-progress, malicious, invalid-number, invalid-counter, and half records emit nothing'
	setup_fixture
	assert_parse_failure "$TEST_ROOT/missing" 'P09 missing file'
	no_progress="$TEST_ROOT/no-progress"
	write_record "$no_progress" 'filename\nNumber of files: 2\n'
	assert_parse_failure "$no_progress" 'P09 diagnostics and stats'
	malicious="$TEST_ROOT/malicious"
	malicious_side_effect="$TEST_ROOT/pwn"
	# shellcheck disable=SC2016 # The literal shell syntax is hostile fixture data.
	write_record "$malicious" '\r 1;touch${IFS}$TEST_ROOT/pwn 1% 1.00kB/s 0:00:01\n'
	assert_parse_failure "$malicious" 'P09 shell-shaped byte field'
	assert_success 'P09 malicious text was not evaluated' test ! -e "$malicious_side_effect"
	bad_number="$TEST_ROOT/bad-number"
	write_record "$bad_number" '\r 1,23 1% 1.00kB/s 0:00:01\n'
	assert_parse_failure "$bad_number" 'P09 invalid thousands grouping'
	bad_counter="$TEST_ROOT/bad-counter"
	write_record "$bad_counter" '\r 1 1% 1.00kB/s 0:00:01 (xfr#1, to-chk=9/8)\n'
	assert_parse_failure "$bad_counter" 'P09 remaining counter exceeds total'
	half_record="$TEST_ROOT/half"
	write_record "$half_record" '\r 1 1% 1.00kB/s 0:00:01 (xfr#1, to-chk=0/8)'
	assert_parse_failure "$half_record" 'P09 unterminated record'
	partial_suffix="$TEST_ROOT/partial-suffix"
	write_record "$partial_suffix" '\r 1 1% 1.00kB/s 0:00:01 (xfr#1, to-chk=0/8\n'
	assert_parse_failure "$partial_suffix" 'P09 incomplete suffix'
}

main() {
	trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
	if [ ! -r "$PROGRESS_SCRIPT" ]; then
		printf 'FAIL: progress module is missing: %s\n' "$PROGRESS_SCRIPT" >&2
		exit 1
	fi
	if ! command -v jq >/dev/null 2>&1; then
		printf '%s\n' 'FAIL: jq is required by this parser test suite' >&2
		exit 1
	fi
	case_source_is_inert
	case_cr_running_record
	case_lf_suffix_record
	case_latest_progress_and_retained_suffix
	case_zero_and_incremental_values
	case_ir_chk_has_unknown_entries
	case_window_boundary
	case_lookalike_tail_prefix_is_ignored
	case_speed_units_and_rejection
	case_invalid_and_incomplete_input
	printf 'RESULT cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
	[ "$CASES" -eq 10 ] || fail "expected 10 cases, ran $CASES"
	[ "$ASSERTIONS" -eq 31 ] || fail "expected 31 assertions, ran $ASSERTIONS"
	[ "$FAILED" -eq 0 ]
}

main "$@"

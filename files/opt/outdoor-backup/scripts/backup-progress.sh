#!/bin/sh
#
# backup-progress.sh - Source-only parser for rsync --info=progress2 output.
#
# The caller owns status publication and cross-poll state. This module reads one
# completed tail window only; sourcing it performs no I/O, installs no trap, and
# starts no process.
#

# Print one JSON snapshot from a complete rsync progress2 tail window.
# Parameters: $1 readable rsync stdout file.
# Returns: 0 after printing JSON; non-zero and no stdout for missing, unreadable,
# or unparseable input. Speed conversion truncates fractional byte/s toward zero.
backup_progress_read() {
	progress_file=${1-}

	[ "$#" -eq 1 ] || return 2
	[ -r "$progress_file" ] || return 1

	# The byte marker preserves whether the final record was CR/LF-terminated.
	# A full 8192-byte tail has an unknowable first boundary, so awk ignores its
	# first field rather than treating a possible fragment as a progress record.
	{ tail -c 8192 -- "$progress_file"; printf '\001'; } |
		LC_ALL=C tr '\r' '\n' |
		LC_ALL=C awk '
		function is_grouped_integer(value, groups, count) {
			if (value ~ /^[0-9][0-9]*$/)
				return 1
			if (value !~ /^[0-9][0-9]*,[0-9][0-9][0-9](,[0-9][0-9][0-9])*$/)
				return 0
			count = split(value, groups, ",")
			return count > 1
		}

		function integer_value(value, normalized) {
			normalized = value
			gsub(/,/, "", normalized)
			return normalized + 0
		}

		function parse_suffix(first, second, kind, remaining, total, file_count) {
			if (first !~ /^\(xfr#[0-9][0-9]*,$/ || second !~ /^(to-chk|ir-chk)=[0-9][0-9]*\/[0-9][0-9]*\)$/)
				return 0
			kind = second
			sub(/=.*/, "", kind)
			remaining = second
			sub(/^[^=]*=/, "", remaining)
			sub(/\/.*/, "", remaining)
			total = second
			sub(/^.*\//, "", total)
			if (remaining + 0 > total + 0)
				return 0
			file_count = first
			sub(/^\(xfr#/, "", file_count)
			sub(/,$/, "", file_count)
			last_files = file_count + 0
			last_suffix = 1
			if (kind == "to-chk") {
				last_entries_done = total - remaining
				last_entries_total = total + 0
			} else {
				last_entries_done = ""
				last_entries_total = ""
			}
			return 1
		}

		function parse_progress(line, fields, count, bytes, percent, speed, unit, amount, factor) {
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
			count = split(line, fields, /[[:space:]]+/)
			if (count != 4 && count != 6)
				return 0
			bytes = fields[1]
			percent = fields[2]
			speed = fields[3]
			if (!is_grouped_integer(bytes) || percent !~ /^[0-9][0-9]*%$/)
				return 0
			if (percent + 0 > 100)
				return 0
			if (speed !~ /^[0-9][0-9]*(\.[0-9][0-9]*)?(kB|MB|GB)\/s$/)
				return 0
			unit = speed
			sub(/^[0-9][0-9]*(\.[0-9][0-9]*)?/, "", unit)
			amount = speed
			sub(/(kB|MB|GB)\/s$/, "", amount)
			if (unit == "kB/s")
				factor = 1024
			else if (unit == "MB/s")
				factor = 1048576
			else
				factor = 1073741824
			if (count == 6 && !parse_suffix(fields[5], fields[6]))
				return 0
			last_bytes = integer_value(bytes)
			last_speed = int((amount + 0) * factor)
			last_progress = 1
			return 1
		}

		{
			marker = sprintf("%c", 1)
			if (index($0, marker) != 0)
				next
			if (record_count > 0)
				parse_progress($0)
			record_count++
		}

		END {
			if (!last_progress)
				exit 1
			if (last_suffix) {
				entries_done = last_entries_done == "" ? "null" : sprintf("%.0f", last_entries_done)
				entries_total = last_entries_total == "" ? "null" : sprintf("%.0f", last_entries_total)
				files_done = sprintf("%.0f", last_files)
			} else {
				files_done = "null"
				entries_done = "null"
				entries_total = "null"
			}
			printf "{\"bytes_done\":%.0f,\"speed_bytes_per_sec\":%.0f,\"files_done\":%s,\"entries_done\":%s,\"entries_total\":%s}\n", last_bytes, last_speed, files_done, entries_done, entries_total
		}
	'
}

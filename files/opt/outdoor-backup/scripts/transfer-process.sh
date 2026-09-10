#!/bin/sh
#
# transfer-process.sh - Source-only private process runner for backup rsync.
#
# The caller owns lifecycle cleanup and signal traps. This library owns exactly
# one setsid-launched process group and never writes stdout, mounts, locks, or
# status files.
#

TRANSFER_PROCESS_PID=""
TRANSFER_PROCESS_STARTTIME=""
TRANSFER_PROCESS_PGID=""
TRANSFER_PROCESS_SESSION=""
TRANSFER_PROCESS_TERM_SENT=0
TRANSFER_PROCESS_TERM_ATTEMPTED=0
TRANSFER_PROCESS_WAIT_NOTICE_SENT=0
TRANSFER_PROCESS_LAUNCH_READY=0
TRANSFER_PROCESS_LAUNCH_STATUS=1

# Write a library-owned warning to stderr and syslog. Parameters: $1 message.
# Returns: always zero; unavailable syslog must not alter transfer lifecycle.
transfer_process_notice() {
	printf '%s\n' "$1" >&2
	logger -t outdoor-backup -p daemon.warning "$1" 2>/dev/null || :
	return 0
}

# Read selected fields from /proc/<pid>/stat. The comm field may contain spaces
# and closing parentheses, therefore discard through its final ") " delimiter.
# Parameters: $1 PID. Returns 0 with TP_* globals, 1 when the process vanished,
# or 2 when a still-present proc entry cannot be parsed safely.
transfer_process_read_stat() {
	local proc_pid=$1
	local proc_line=""
	local proc_rest=""

	[ -d "/proc/$proc_pid" ] || return 1
	if ! IFS= read -r proc_line < "/proc/$proc_pid/stat"; then
		[ -d "/proc/$proc_pid" ] && return 2
		return 1
	fi
	proc_rest=${proc_line##*) }
	[ "$proc_rest" != "$proc_line" ] || return 2
	# shellcheck disable=SC2086 # /proc fields are deliberately split on spaces.
	set -- $proc_rest
	[ "$#" -ge 20 ] || return 2
	case "$1" in [A-Za-z]) ;; *) return 2 ;; esac
	case "$3" in ''|*[!0-9]*) return 2 ;; esac
	case "$4" in ''|*[!0-9]*) return 2 ;; esac
	case "${20}" in ''|*[!0-9]*) return 2 ;; esac
	TP_STATE=$1
	TP_PGID=$3
	TP_SESSION=$4
	TP_STARTTIME=${20}
	return 0
}

# Return whether the expected private session has a non-zombie member.
# Parameters: none. Returns 0 live, 1 empty, 2 when a present proc entry cannot
# be safely inspected (which must never be treated as an empty group).
transfer_process_group_live() {
	local proc_path=""
	local proc_pid=""
	local saw_unreadable=0

	for proc_path in /proc/[0-9]*; do
		[ -d "$proc_path" ] || continue
		proc_pid=${proc_path#/proc/}
		transfer_process_read_stat "$proc_pid"
		case "$?" in
			0)
				if [ "$TP_PGID" = "$TRANSFER_PROCESS_PGID" ] && \
					[ "$TP_SESSION" = "$TRANSFER_PROCESS_SESSION" ] && \
					[ "$TP_STATE" != Z ]; then
					return 0
				fi
				;;
			1) ;;
			2) saw_unreadable=1 ;;
		esac
	done
	[ "$saw_unreadable" -eq 0 ] || return 2
	return 1
}

# Verify that the original leader still names the exact recorded session.
# Parameters: none. Returns 0 only for a living, non-zombie original leader.
transfer_process_leader_matches() {
	[ -n "$TRANSFER_PROCESS_STARTTIME" ] || return 1
	transfer_process_read_stat "$TRANSFER_PROCESS_PID" || return 1
	[ "$TP_STATE" != Z ] || return 1
	[ "$TP_STARTTIME" = "$TRANSFER_PROCESS_STARTTIME" ] || return 1
	[ "$TP_PGID" = "$TRANSFER_PROCESS_PGID" ] || return 1
	[ "$TP_SESSION" = "$TRANSFER_PROCESS_SESSION" ]
}

# Request one group TERM only after verifying the original leader. Parameters:
# none. A vanished or unverifiable leader is never used to authorize a signal.
transfer_process_request_term() {
	[ "$TRANSFER_PROCESS_TERM_ATTEMPTED" -eq 0 ] || return 0
	TRANSFER_PROCESS_TERM_ATTEMPTED=1
	if ! transfer_process_leader_matches; then
		transfer_process_notice 'outdoor-backup: transfer leader cannot safely authorize group cancellation; retaining resources until writers exit'
		return 1
	fi
	kill -TERM "-$TRANSFER_PROCESS_PGID" 2>/dev/null || {
		transfer_process_notice 'outdoor-backup: failed to signal verified transfer process group; retaining resources until writers exit'
		return 1
	}
	TRANSFER_PROCESS_TERM_SENT=1
	return 0
}

# Record once that a cancellation cannot release resources until writers exit.
# Parameters: none. Returns: always zero.
transfer_process_note_waiting() {
	[ "$TRANSFER_PROCESS_WAIT_NOTICE_SENT" -eq 0 ] || return 0
	transfer_process_notice 'outdoor-backup: waiting for transfer writers to exit after cancellation'
	TRANSFER_PROCESS_WAIT_NOTICE_SENT=1
	return 0
}

# Wait until no non-zombie member of this launch's expected session remains.
# Parameters: none. Returns only after an empty group; never kills unknown PIDs.
transfer_process_wait_group() {
	local group_state=1
	local warned=0
	local empty_scans=0

	while :; do
		if [ "${BACKUP_CANCEL_CODE:-0}" -ne 0 ]; then
			transfer_process_request_term || :
			transfer_process_note_waiting
		fi
		transfer_process_group_live
		group_state=$?
		case "$group_state" in
			1)
				empty_scans=$((empty_scans + 1))
				# /proc globbing is a snapshot. Two full empty scans separated by
				# scheduling time avoid declaring empty across a single fork/exit gap.
				[ "$empty_scans" -ge 2 ] && return 0
				;;
			0) empty_scans=0 ;;
			2)
				empty_scans=0
				if [ "$warned" -eq 0 ]; then
					transfer_process_notice 'outdoor-backup: cannot safely inspect active transfer process group; retaining resources'
					warned=1
				fi
				;;
		esac
		/bin/sleep 1
	done
}

# Clear all identity state after the caller can safely release shared resources.
# Parameters: none. Returns: always zero.
transfer_process_clear() {
	TRANSFER_PROCESS_PID=""
	TRANSFER_PROCESS_STARTTIME=""
	TRANSFER_PROCESS_PGID=""
	TRANSFER_PROCESS_SESSION=""
	TRANSFER_PROCESS_TERM_SENT=0
	TRANSFER_PROCESS_TERM_ATTEMPTED=0
	TRANSFER_PROCESS_WAIT_NOTICE_SENT=0
	TRANSFER_PROCESS_LAUNCH_READY=0
	TRANSFER_PROCESS_LAUNCH_STATUS=1
	return 0
}

# Drain this launch then choose its final natural or sticky cancellation result.
# Parameters: $1 previously observed command status. Returns final status.
transfer_process_finish() {
	local final_status=$1

	transfer_process_wait_group
	wait "$TRANSFER_PROCESS_PID" 2>/dev/null || :
	if [ "${BACKUP_CANCEL_CODE:-0}" -ne 0 ]; then
		final_status=$BACKUP_CANCEL_CODE
	fi
	transfer_process_clear
	return "$final_status"
}

# Launch one command in a private session and record its verified identity.
# Parameters: command and arguments. Returns zero; globals retain launch result.
transfer_process_launch() {
	local wait_status=0

	LC_ALL=C setsid "$@" &
	TRANSFER_PROCESS_PID=$!
	TRANSFER_PROCESS_PGID=$TRANSFER_PROCESS_PID
	TRANSFER_PROCESS_SESSION=$TRANSFER_PROCESS_PID
	while [ -z "$TRANSFER_PROCESS_STARTTIME" ]; do
		transfer_process_read_stat "$TRANSFER_PROCESS_PID"
		case "$?" in
			0)
				if [ "$TP_PGID" = "$TRANSFER_PROCESS_PGID" ] && \
					[ "$TP_SESSION" = "$TRANSFER_PROCESS_SESSION" ] && [ "$TP_STATE" != Z ]; then
					TRANSFER_PROCESS_STARTTIME=$TP_STARTTIME
					TRANSFER_PROCESS_LAUNCH_READY=1
					return 0
				fi
				/bin/sleep 1
				;;
			1)
				if wait "$TRANSFER_PROCESS_PID"; then wait_status=0; else wait_status=$?; fi
				transfer_process_finish "$wait_status"
				TRANSFER_PROCESS_LAUNCH_STATUS=$?
				return 0
				;;
			2)
				transfer_process_notice 'outdoor-backup: cannot parse launched transfer process identity; retaining resources until the expected session drains'
				wait "$TRANSFER_PROCESS_PID" 2>/dev/null || :
				transfer_process_finish 1
				TRANSFER_PROCESS_LAUNCH_STATUS=$?
				return 0
				;;
		esac
	done
}

# Poll the verified leader, then preserve its natural exit status for finishing.
# Parameters: none. Returns the observed leader status or one if unverifiable.
transfer_process_wait_leader() {
	local wait_status=0

	while transfer_process_leader_matches; do
		if [ "${BACKUP_CANCEL_CODE:-0}" -ne 0 ]; then
			transfer_process_request_term || :
			transfer_process_note_waiting
		fi
		/bin/sleep 1
	done
	transfer_process_read_stat "$TRANSFER_PROCESS_PID"
	case "$?" in
		1) if wait "$TRANSFER_PROCESS_PID"; then wait_status=0; else wait_status=$?; fi ;;
		0)
			if [ "$TP_STATE" = Z ]; then
				if wait "$TRANSFER_PROCESS_PID"; then wait_status=0; else wait_status=$?; fi
			else
				wait_status=1
			fi
			;;
		*) wait_status=1 ;;
	esac
	return "$wait_status"
}

# Start one command in a private session and return its natural or sticky status.
# Parameters: command and arguments. Returns command status or BACKUP_CANCEL_CODE.
transfer_process_run() {
	transfer_process_clear
	command -v setsid >/dev/null 2>&1 || {
		printf '%s\n' 'outdoor-backup: setsid is required to run rsync safely' >&2
		return 127
	}
	transfer_process_launch "$@"
	[ "$TRANSFER_PROCESS_LAUNCH_READY" -eq 1 ] || return "${TRANSFER_PROCESS_LAUNCH_STATUS:-1}"
	transfer_process_wait_leader
	transfer_process_finish "$?"
	return "$?"
}

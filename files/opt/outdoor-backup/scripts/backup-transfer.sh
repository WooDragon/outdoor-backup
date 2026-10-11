#!/bin/sh
#
# backup-transfer.sh - Source-only rsync transfer helper.
#
# Callers prepare and validate the source and target directories before calling
# backup_transfer. This module neither changes the current directory nor installs
# traps, so the manager remains responsible for lifecycle cleanup on signals.
#

BACKUP_TRANSFER_EXIT=0
BACKUP_TRANSFER_FILES=0
BACKUP_TRANSFER_BYTES=0
BACKUP_TRANSFER_ERROR=""
BACKUP_TRANSFER_TMP_STDOUT=""
BACKUP_TRANSFER_TMP_STDERR=""
BACKUP_TRANSFER_CREATED_STDOUT=""
BACKUP_TRANSFER_CREATED_STDERR=""

# Remove only output files created by this module for the active invocation.
# Parameters: none.
# Returns: always 0; cleanup failures must not mask rsync's real exit status.
backup_transfer_cleanup() {
	if [ -n "$BACKUP_TRANSFER_CREATED_STDOUT" ] && \
		[ "$BACKUP_TRANSFER_CREATED_STDOUT" = "$BACKUP_TRANSFER_TMP_STDOUT" ]; then
		rm -f -- "$BACKUP_TRANSFER_CREATED_STDOUT" 2>/dev/null || :
	fi
	if [ -n "$BACKUP_TRANSFER_CREATED_STDERR" ] && \
		[ "$BACKUP_TRANSFER_CREATED_STDERR" = "$BACKUP_TRANSFER_TMP_STDERR" ]; then
		rm -f -- "$BACKUP_TRANSFER_CREATED_STDERR" 2>/dev/null || :
	fi

	BACKUP_TRANSFER_TMP_STDOUT=""
	BACKUP_TRANSFER_TMP_STDERR=""
	BACKUP_TRANSFER_CREATED_STDOUT=""
	BACKUP_TRANSFER_CREATED_STDERR=""
	return 0
}

# Copy source_dir to target_dir with rsync and report actual transfer statistics.
# Parameters: $1 source directory, $2 prepared target directory, $3 rsync log path.
# Returns: 0 on rsync success; otherwise the real rsync exit code, or 1 when
# runtime output preparation fails.
backup_transfer() {
	[ "$#" -eq 3 ] || return 2
	backup_transfer_execute "$1" "$2" "$3" mirror ''
}

# Date profile accepts only owner-created view/library/replaced paths.
# Args: VIEW LIBRARY LOG quick|checksum REPLACED_DIR (exactly five).
# Returns: 2 invalid input, 1 admission failure, or real runner result.
backup_transfer_date() {
	[ "$#" -eq 5 ] || return 2
	case "$4" in quick|checksum) ;; *) return 2 ;; esac
	[ "$1" = "${MEDIA_DATE_WORK:-}/view" ] && [ -d "$1" ] || return 1
	[ "$2" = "${TARGET_BACKUP_ROOT:-}" ] && [ -d "$2" ] || return 1
	[ "$5" = "${MEDIA_DATE_REPLACED_DIR:-}" ] && [ -d "$5" ] || return 1
	[ "$3" = "${BACKUP_LOG_FILE:-}" ] || return 1
	[ ! -L "$1" ] && [ ! -L "$5" ] || return 1
	case "$2" in "${TARGET_FD_ROOT:-/nonexistent}"/*) ;; *) return 1 ;; esac
	case "$5" in "$2"/.outdoor-backup/replaced/*) ;; *) return 1 ;; esac
	case "${5#"$2"/.outdoor-backup/replaced/}" in ''|*/*|.|..) return 1 ;; esac
	lock_is_owned_by_self && target_anchor_healthy || return 1
	check_cancel_request || return "$?"
	backup_transfer_execute "$1/" "$2/" "$3" "$4" "$5"
}

# One output/runner/statistics lifecycle for both fixed profiles. Not user argv.
# Args: source, target, log, mirror|quick|checksum, replaced path.
backup_transfer_execute() {
	local profile="$4" replaced_dir="$5"
	local source_dir="$1"
	local target_dir="$2"
	local log_file="$3"
	local stdout_file=""
	local stderr_file=""
	local rsync_exit=1
	local files_line=""
	local bytes_line=""

	BACKUP_TRANSFER_EXIT=0
	BACKUP_TRANSFER_FILES=0
	BACKUP_TRANSFER_BYTES=0
	BACKUP_TRANSFER_ERROR=""
	backup_transfer_cleanup

	# Verify the session primitive before creating output files: an unavailable
	# setsid must fail loud without leaving a temp artifact behind.
	if ! command -v setsid >/dev/null 2>&1; then
		BACKUP_TRANSFER_EXIT=127
		BACKUP_TRANSFER_ERROR="rsync"
		printf '%s\n' 'outdoor-backup: setsid is required to run rsync safely' >&2
		return 127
	fi
	if ! command -v transfer_process_run >/dev/null 2>&1; then
		BACKUP_TRANSFER_EXIT=1
		BACKUP_TRANSFER_ERROR="rsync"
		printf '%s\n' 'outdoor-backup: transfer process runner is unavailable' >&2
		return 1
	fi

	if ! stdout_file=$(mktemp "$BASE_DIR/var/.backup-transfer.stdout.XXXXXX"); then
		BACKUP_TRANSFER_EXIT=1
		BACKUP_TRANSFER_ERROR="rsync"
		return 1
	fi
	BACKUP_TRANSFER_TMP_STDOUT=$stdout_file
	BACKUP_TRANSFER_CREATED_STDOUT=$stdout_file

	if ! stderr_file=$(mktemp "$BASE_DIR/var/.backup-transfer.stderr.XXXXXX"); then
		BACKUP_TRANSFER_EXIT=1
		BACKUP_TRANSFER_ERROR="rsync"
		backup_transfer_cleanup
		return 1
	fi
	BACKUP_TRANSFER_TMP_STDERR=$stderr_file
	BACKUP_TRANSFER_CREATED_STDERR=$stderr_file

	case "$profile" in
		mirror)
			set -- rsync --archive --recursive --times --prune-empty-dirs --partial \
				--stats --info=progress2 --outbuf=L --log-file="$log_file" \
				--exclude="${CONFIG_FILE:-FieldBackup.conf}" --exclude=".Trash*" \
				--exclude=".Spotlight*" --exclude=".fseventsd" \
				--exclude="System Volume Information" --exclude="\$RECYCLE.BIN"
			;;
		quick|checksum)
			set -- rsync -aL --prune-empty-dirs --partial-dir=.rsync-partial \
				--backup --backup-dir="$replaced_dir" --stats --info=progress2 \
				--outbuf=L --log-file="$log_file"
			[ "$profile" != checksum ] || set -- "$@" --checksum
			# The manager checks lease+sticky cancellation before every reader launch.
			if check_cancel_request; then :; else
				rsync_exit=$?
				backup_transfer_cleanup
				return "$rsync_exit"
			fi
			;;
		*) backup_transfer_cleanup; return 2 ;;
	esac
	if transfer_process_run "$@" "$source_dir" "$target_dir" \
		>"$stdout_file" 2>"$stderr_file"; then
		rsync_exit=0
	else
		rsync_exit=$?
	fi

	BACKUP_TRANSFER_EXIT=$rsync_exit
	if [ "$rsync_exit" -ne 0 ]; then
		BACKUP_TRANSFER_ERROR="rsync"
		if [ "${BACKUP_CANCEL_CODE:-0}" -ne 0 ] && [ "$rsync_exit" -eq "$BACKUP_CANCEL_CODE" ]; then
			BACKUP_TRANSFER_ERROR="cancelled"
		elif grep -F -e "No space left on device" -e "ENOSPC" "$stdout_file" "$stderr_file" >/dev/null 2>&1; then
			BACKUP_TRANSFER_ERROR="no_space"
		fi
		backup_transfer_cleanup
		return "$rsync_exit"
	fi

	files_line=$(grep -F "Number of regular files transferred:" "$stdout_file" 2>/dev/null || :)
	bytes_line=$(grep -F "Total transferred file size:" "$stdout_file" 2>/dev/null || :)
	BACKUP_TRANSFER_FILES=$(printf '%s' "${files_line#*:}" | tr -cd '0-9')
	BACKUP_TRANSFER_BYTES=$(printf '%s' "${bytes_line#*:}" | tr -cd '0-9')
	[ -n "$BACKUP_TRANSFER_FILES" ] || BACKUP_TRANSFER_FILES=0
	[ -n "$BACKUP_TRANSFER_BYTES" ] || BACKUP_TRANSFER_BYTES=0
	backup_transfer_cleanup
	return 0
}

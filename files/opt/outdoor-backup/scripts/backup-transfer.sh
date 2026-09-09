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
	local source_dir=$1
	local target_dir=$2
	local log_file=$3
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

	if LC_ALL=C rsync \
		--archive \
		--recursive \
		--times \
		--prune-empty-dirs \
		--partial \
		--stats \
		--log-file="$log_file" \
		--exclude="${CONFIG_FILE:-FieldBackup.conf}" \
		--exclude=".Trash*" \
		--exclude=".Spotlight*" \
		--exclude=".fseventsd" \
		--exclude="System Volume Information" \
		--exclude="\$RECYCLE.BIN" \
		"$source_dir" "$target_dir" >"$stdout_file" 2>"$stderr_file"; then
		rsync_exit=0
	else
		rsync_exit=$?
	fi

	BACKUP_TRANSFER_EXIT=$rsync_exit
	if [ "$rsync_exit" -ne 0 ]; then
		BACKUP_TRANSFER_ERROR="rsync"
		if grep -F -e "No space left on device" -e "ENOSPC" "$stdout_file" "$stderr_file" >/dev/null 2>&1; then
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

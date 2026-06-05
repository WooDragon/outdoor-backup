#!/bin/sh
#
# OpenWrt SD Card Backup - Main Backup Manager
# Handles the actual backup process with all safety checks
# POSIX-compliant for ash shell
#

set -e

# Constants
# SCRIPT_DIR/BASE_DIR honor a pre-set value so the test suite can source this
# file with paths pointed at a fixture dir. In production both are unset, so
# they are computed from $0 exactly as before — no behavior change.
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
BASE_DIR="${BASE_DIR:-$(dirname "$SCRIPT_DIR")}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/sdcard}"
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/ssd/SDMirrors}"
LOCK_FILE="$BASE_DIR/var/lock/backup.pid"
# Atomic-mkdir fallback lock, used only when flock is unavailable.
LOCK_DIR="$BASE_DIR/var/lock/backup.lock.d"
CONFIG_FILE="FieldBackup.conf"
LOG_TAG="outdoor-backup"

# Lock state. Set by acquire_lock so release_lock only ever frees a lock we
# actually hold (a process that lost the race must never delete the winner's
# lock). LOCK_METHOD records which primitive won so release matches it.
LOCK_HELD=0
LOCK_METHOD=""

# Load configuration
[ -f "$BASE_DIR/conf/backup.conf" ] && . "$BASE_DIR/conf/backup.conf"
[ -f /etc/config/outdoor-backup ] && . /etc/config/outdoor-backup

# Load common functions
. "$SCRIPT_DIR/common.sh"

# Arguments
ACTION="$1"
DEVNAME="$2"
DEVPATH="$3"

# Error classification for differentiated LED feedback (issue #4).
# Set by the failing stage before it exits; consumed by cleanup() to pick the
# matching LED pattern. Empty means "generic / rsync failure".
ERROR_TYPE=""

# Cleanup function
cleanup() {
	local exit_code=$?

	# Stop LED blinking
	led_backup_stop

	# Release the lock if (and only if) we hold it.
	release_lock

	# Unmount if needed
	if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
		umount "$MOUNT_POINT" 2>/dev/null || true
	fi

	# Final sync
	sync

	if [ $exit_code -eq 0 ]; then
		led_backup_done
		log_info "Backup completed successfully"
	else
		# Dispatch to the LED pattern matching the failure type (issue #4).
		# Each error stage sets ERROR_TYPE before exiting non-zero.
		case "$ERROR_TYPE" in
			no_space)      led_err_no_space ;;
			lock_timeout)  led_err_lock_timeout ;;
			device_unknown) led_err_device_unknown ;;
			verify_failed) led_err_verify_failed ;;
			rsync|*)       led_err_rsync ;;
		esac
		log_error "Backup failed with code $exit_code (type: ${ERROR_TYPE:-rsync})"
	fi

	exit $exit_code
}

# Acquire an exclusive backup lock (issue #8).
#
# The old implementation hand-rolled `echo $$ > lock` + read-back verify: it
# was non-atomic (TOCTOU) and, worse, on a failed verify it looped back with
# NO sleep and NO elapsed increment — a 100% CPU spin that could never reach
# the timeout. Two cards inserted together could peg a core forever.
#
# We use flock as the atomic primitive (same FD-based form common.sh already
# relies on). flock is held for the lifetime of FD 201 and is auto-released by
# the kernel if this process dies — so there is no stale-lock window and no
# PID-reuse hazard. When flock is absent we fall back to mkdir, which is also
# atomic; its contention branch sleeps and increments so the timeout is always
# reachable. The PID is written for human/debug visibility only, never trusted
# for mutual exclusion.
acquire_lock() {
	# Timeout/interval honor pre-set overrides (used by the test suite for
	# fast, deterministic contention checks). Production defaults unchanged.
	local timeout="${LOCK_TIMEOUT:-300}"   # 5 minutes
	local elapsed=0
	local interval="${LOCK_INTERVAL:-5}"

	mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true

	if command -v flock >/dev/null 2>&1; then
		# Open the lock file on a dedicated FD and take a non-blocking lock.
		# Retry with backoff so we honor the same timeout semantics.
		exec 201>"$LOCK_FILE" 2>/dev/null || {
			log_error "Cannot open lock file $LOCK_FILE"
			return 1
		}
		while [ "$elapsed" -lt "$timeout" ]; do
			if flock -n 201; then
				echo "$$" >&201 2>/dev/null || true
				LOCK_HELD=1
				LOCK_METHOD="flock"
				log_info "Lock acquired (flock)"
				return 0
			fi
			log_debug "Waiting for lock (flock held)..."
			sleep "$interval"
			elapsed=$((elapsed + interval))
		done
		exec 201>&- 2>/dev/null || true
		log_error "Failed to acquire lock after ${timeout}s"
		return 1
	fi

	# Fallback: atomic mkdir. `mkdir` of an existing dir fails atomically, so
	# the winner is whoever creates it first — no read-back race.
	while [ "$elapsed" -lt "$timeout" ]; do
		if mkdir "$LOCK_DIR" 2>/dev/null; then
			echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
			LOCK_HELD=1
			LOCK_METHOD="mkdir"
			log_info "Lock acquired (mkdir)"
			return 0
		fi

		# Held: decide whether the holder is alive. If it looks dead, reclaim
		# the stale lock ATOMICALLY: rename the dir to a private name and only
		# the process whose rename succeeds gets to remove it. A blind
		# `rm -rf` + retry would let two losers both delete and both re-mkdir,
		# producing two holders — the very bug #8 is about. `mv` of an already
		# moved/renamed source fails, so the second loser just loops and
		# competes for a fresh `mkdir` cleanly.
		local pid
		pid=$(cat "$LOCK_DIR/pid" 2>/dev/null) || true
		if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
			local stale="${LOCK_DIR}.stale.$$"
			if mv "$LOCK_DIR" "$stale" 2>/dev/null; then
				rm -rf "$stale" 2>/dev/null || true
				log_info "Removed stale lock (PID $pid gone)"
			fi
			# Whether or not we won the rename, loop and retry mkdir.
			continue
		fi

		log_debug "Waiting for lock (PID ${pid:-unknown})..."
		sleep "$interval"
		elapsed=$((elapsed + interval))
	done

	log_error "Failed to acquire lock after ${timeout}s"
	return 1
}

# Release the lock, but only if this process actually holds it. A process that
# lost the race (LOCK_HELD=0) must never free the winner's lock.
release_lock() {
	[ "$LOCK_HELD" = "1" ] || return 0

	case "$LOCK_METHOD" in
		flock)
			# Closing the FD drops the kernel lock. We deliberately do NOT
			# unlink the sentinel file: removing the inode while another waiter
			# still holds an open FD on it lets a newcomer create a fresh inode
			# and lock that, producing two simultaneous holders (the classic
			# flock-unlink race). The file persists; its pid content is debug
			# only and is overwritten on the next acquire.
			exec 201>&- 2>/dev/null || true
			;;
		mkdir)
			rm -rf "$LOCK_DIR" 2>/dev/null || true
			;;
	esac

	LOCK_HELD=0
	log_info "Lock released"
}

# Mount SD card
mount_sdcard() {
	# Create mount point
	mkdir -p "$MOUNT_POINT"

	# Try to mount with different filesystems
	for fs in auto exfat ntfs3 ext4 ext3 ext2 vfat; do
		if mount -t "$fs" "/dev/$DEVNAME" "$MOUNT_POINT" 2>/dev/null; then
			log_info "Mounted $DEVNAME as $fs"
			return 0
		fi
	done

	log_error "Failed to mount $DEVNAME"
	return 1
}

# Setup SD card configuration
setup_sdcard_config() {
	local config_path="$MOUNT_POINT/$CONFIG_FILE"

	# Check if config exists
	if [ -f "$config_path" ]; then
		# Load existing config
		. "$config_path"
		log_info "Loaded config for SD: $SD_NAME ($SD_UUID)"
	else
		# Check if SD card is read-only
		if ! touch "$config_path" 2>/dev/null; then
			log_error "SD card is read-only, cannot create config"
			return 1
		fi

		# Generate new config
		SD_UUID=$(generate_uuid)
		BACKUP_MODE="PRIMARY"

		cat > "$config_path" << EOF
# OpenWrt SD Card Backup Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# Unique identifier for this SD card
SD_UUID="$SD_UUID"

# Backup mode: PRIMARY (SD→SSD) or REPLICA (SSD→SD)
BACKUP_MODE="$BACKUP_MODE"

# Creation timestamp
CREATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

		# Load the new config
		. "$config_path"

		# Generate initial alias (timestamp format) and create entry in aliases.json
		# This ensures first-time insertion shows a meaningful name in WebUI
		local initial_alias="SDCard_$(date +%Y%m%d_%H%M%S)"
		update_alias_last_seen "$SD_UUID" "$initial_alias" || log_warn "Failed to create initial alias"

		log_info "Created new config for SD: $initial_alias ($SD_UUID)"
	fi

	return 0
}

# Perform rsync backup
perform_backup() {
	local source_dir=""
	local target_dir=""
	local log_file=""
	local display_name=""

	# Get display name with alias support
	display_name=$(get_display_name "$SD_UUID")

	# Update last_seen timestamp in aliases.json
	# NOTE: Don't pass SD_NAME here to avoid overwriting existing alias
	update_alias_last_seen "$SD_UUID" || log_warn "Failed to update alias timestamp"

	# Determine backup direction
	if [ "$BACKUP_MODE" = "REPLICA" ]; then
		# Replica mode: SSD → SD
		source_dir="$BACKUP_ROOT/$SD_UUID/"
		target_dir="$MOUNT_POINT/"
		log_file="$BACKUP_ROOT/.logs/replica_${SD_UUID}_$(date +%Y%m%d_%H%M%S).log"

		log_info "Starting REPLICA backup: SSD → SD ($display_name)"
	else
		# Primary mode: SD → SSD
		source_dir="$MOUNT_POINT/"
		target_dir="$BACKUP_ROOT/$SD_UUID/"
		log_file="$BACKUP_ROOT/.logs/backup_${SD_UUID}_$(date +%Y%m%d_%H%M%S).log"

		log_info "Starting PRIMARY backup: SD → SSD ($display_name)"
	fi

	# Check minimum free space on the TARGET (issue #5).
	#
	# The old code ran `du -sm` over the whole card and compared the card's
	# TOTAL size against target free space. That was both slow (full-tree walk
	# duplicating rsync's own scan) and wrong (an incremental re-backup of a
	# 100GB card was rejected whenever the SSD had <100GB free, even though only
	# a few GB of delta needed copying). We let rsync handle the real delta and
	# only guard against a target that is already critically full — an O(1) df
	# check using MIN_FREE_SPACE (MB) from backup.conf.
	local min_free="${MIN_FREE_SPACE:-1024}"
	local target_free
	target_free=$(get_available_space_mb "$target_dir")
	if [ -n "$target_free" ] && [ "$target_free" -lt "$min_free" ] 2>/dev/null; then
		log_error "Insufficient free space on target: ${target_free}MB < ${min_free}MB minimum"
		ERROR_TYPE="no_space"
		return 1
	fi

	# Create target directory
	mkdir -p "$target_dir"
	mkdir -p "$(dirname "$log_file")"

	# Record start time
	local start_time
	start_time=$(date +%s)

	# Publish initial "running" status so the WebUI shows the backup immediately
	# (issue #7). bytes_total/files_total are unknown until rsync --stats
	# completes, so they start at 0 and are filled in on completion.
	write_status "running" "$SD_UUID" "$display_name" "$DEVNAME" \
		"$start_time" 0 0 0 0 0 0 "$target_dir" "" "" \
		|| log_warn "Failed to write initial status.json"

	# Perform rsync
	log_info "Executing rsync from $source_dir to $target_dir"

	# Run rsync and capture its TRUE exit code (issue #6).
	#
	# The old `rsync ... | while read` ate the exit code: $? reflected the
	# while loop (always 0), so every failure was reported as success and lit
	# the green LED — a data-integrity bug. We capture rsync's real status via
	# a temp file written inside the subshell, while the pipe still streams
	# output for throttled progress parsing feeding status.json (issue #7).
	local rsync_status_file="$BASE_DIR/var/.rsync_exit.$$"
	local rsync_bytes_file="$BASE_DIR/var/.rsync_bytes.$$"
	rm -f "$rsync_status_file" "$rsync_bytes_file"

	# --partial (issue #1): keep partially-transferred files on interruption so
	# the NEXT backup resumes/repairs them via rsync's normal delta algorithm,
	# instead of the old --ignore-existing which skipped any same-named file
	# forever (leaving interrupted partials permanently truncated).
	#
	# We deliberately do NOT use --append/--append-verify: those decide by SIZE
	# only and blindly append to existing bytes. Cameras reuse filenames
	# (DSC_9999 -> DSC_0001, reformat-and-reshoot), so a same-named-but-changed
	# file would be corrupted by a blind append. Plain rsync (size+mtime quick
	# check + delta) correctly re-sends changed files and skips unchanged ones,
	# fixing the partial-resume bug without any corruption risk.
	local throttle_interval=5   # seconds between status.json progress writes
	local last_write=0
	local bytes_done=0

	{
		# Wrap in if/else so `set -e` does not abort the subshell on rsync
		# failure before we record the exit code. The else branch runs with
		# $? still holding rsync's real status (used for #4 disk-full LED).
		if rsync \
			--archive \
			--recursive \
			--times \
			--prune-empty-dirs \
			--partial \
			--stats \
			--info=progress2 \
			--log-file="$log_file" \
			--exclude="$CONFIG_FILE" \
			--exclude=".Trash*" \
			--exclude=".Spotlight*" \
			--exclude=".fseventsd" \
			--exclude="System Volume Information" \
			--exclude="\$RECYCLE.BIN" \
			"$source_dir" "$target_dir"
		then
			echo 0 > "$rsync_status_file"
		else
			echo $? > "$rsync_status_file"
		fi
	} 2>&1 | tr '\r' '\n' | while IFS= read -r line; do
		# --info=progress2 emits a single rolling summary line (raw bytes, no
		# --human-readable so the numbers stay machine-parseable):
		#   <bytes-done> <percent>% <speed> <eta> (xfr#N, to-chk=...)
		# Throttle status.json writes so I/O does not scale with file count.
		case "$line" in
			*%*)
				now=$(date +%s)
				if [ $((now - last_write)) -ge "$throttle_interval" ]; then
					last_write=$now
					# First whitespace-delimited field = bytes transferred.
					bytes_done=$(printf '%s' "$line" | awk '{print $1}' | tr -d ',')
					pct=$(printf '%s' "$line" | grep -o '[0-9]\{1,3\}%' | head -1 | tr -d '%')
					case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
					case "$bytes_done" in ''|*[!0-9]*) bytes_done=0 ;; esac
					# Persist the latest byte count so the post-loop code can use
					# it as a fallback total (the loop runs in a pipe subshell;
					# its variables can't propagate back via the shell).
					echo "$bytes_done" > "$rsync_bytes_file" 2>/dev/null || true
					# files_total/files_done are unknown mid-transfer with
					# progress2; report 0 and let the completed entry fill the
					# real count from --stats rather than showing a fake number.
					write_status "running" "$SD_UUID" "$display_name" \
						"$DEVNAME" "$start_time" "$pct" 0 0 \
						0 "$bytes_done" 0 "$target_dir" "" "" 2>/dev/null || true
				fi
				;;
		esac
	done

	# Read the captured rsync exit code; default to failure if the file is
	# missing (subshell never reached the echo => rsync was killed).
	local rsync_exit=1
	if [ -f "$rsync_status_file" ]; then
		rsync_exit=$(cat "$rsync_status_file" 2>/dev/null)
		case "$rsync_exit" in ''|*[!0-9]*) rsync_exit=1 ;; esac
		rm -f "$rsync_status_file"
	fi

	local end_time
	end_time=$(date +%s)
	local duration=$((end_time - start_time))

	# Parse final transfer stats from rsync --stats output in the log file.
	# These feed the completed history entry and give the WebUI a real file
	# count and byte total once the transfer is done. If a given rsync build
	# doesn't route --stats to the log file, fall back to the last byte count
	# captured from the progress stream (via the temp file) so the total isn't
	# silently zero.
	local stat_files stat_bytes progress_bytes
	stat_files=$(grep -i "Number of regular files transferred" "$log_file" 2>/dev/null \
		| tail -1 | grep -o '[0-9,]*$' | tr -d ',')
	stat_bytes=$(grep -i "Total transferred file size" "$log_file" 2>/dev/null \
		| tail -1 | grep -o '[0-9,]*' | tail -1 | tr -d ',')
	progress_bytes=0
	if [ -f "$rsync_bytes_file" ]; then
		progress_bytes=$(cat "$rsync_bytes_file" 2>/dev/null)
		case "$progress_bytes" in ''|*[!0-9]*) progress_bytes=0 ;; esac
		rm -f "$rsync_bytes_file"
	fi
	case "$stat_files" in ''|*[!0-9]*) stat_files=0 ;; esac
	case "$stat_bytes" in ''|*[!0-9]*) stat_bytes=$progress_bytes ;; esac

	# Log summary
	log_info "Backup completed in ${duration}s (exit code: $rsync_exit)"

	# Write summary to log file
	cat >> "$log_file" << EOF

=== Backup Summary ===
SD Card: $display_name ($SD_UUID)
Mode: $BACKUP_MODE
Duration: ${duration} seconds
Exit Code: $rsync_exit
Completed: $(date '+%Y-%m-%d %H:%M:%S')
EOF

	# Branch on the TRUE rsync exit code (issue #6).
	if [ "$rsync_exit" -ne 0 ]; then
		log_error "rsync failed with exit code $rsync_exit"
		# rsync uses exit code 11/12 for I/O / disk-full errors; surface those
		# as the "no space" LED so the operator knows to free up storage (#4).
		case "$rsync_exit" in
			11|12) ERROR_TYPE="no_space" ;;
			*)     ERROR_TYPE="rsync" ;;
		esac
		write_status "failed" "$SD_UUID" "$display_name" "$DEVNAME" \
			"$start_time" 0 "$stat_files" "$stat_files" "$stat_bytes" \
			"$stat_bytes" 0 "$target_dir" "$target_dir" \
			"rsync exit $rsync_exit" || true
		return "$rsync_exit"
	fi

	# rsync succeeded: record completed status + history entry (issue #7).
	write_status "completed" "$SD_UUID" "$display_name" "$DEVNAME" \
		"$start_time" 100 "$stat_files" "$stat_files" "$stat_bytes" \
		"$stat_bytes" 0 "$target_dir" "$target_dir" "" \
		|| log_warn "Failed to write final status.json"

	return 0
}

# Handle remove action
handle_remove() {
	log_info "Handling SD card removal"

	# Kill any running rsync for this device
	pkill -f "rsync.*$MOUNT_POINT" 2>/dev/null || true

	# Cleanup will be done by trap
	exit 0
}

# Main execution
main() {
	# Setup signal handlers
	trap cleanup EXIT
	trap cleanup INT TERM

	case "$ACTION" in
		add)
			# Start LED indication
			led_backup_start

			# Acquire lock. A timeout here means another backup holds the lock;
			# flag it so cleanup() shows the lock-timeout LED (2 flashes, #4).
			acquire_lock || { ERROR_TYPE="lock_timeout"; exit 1; }

			# Mount SD card. Failure means the inserted device isn't a mountable
			# card -> device-unknown LED (1 flash, #4).
			mount_sdcard || { ERROR_TYPE="device_unknown"; exit 1; }

			# Setup configuration
			setup_sdcard_config || exit 1

			# Perform backup (sets ERROR_TYPE itself on no_space / rsync failure)
			perform_backup || exit 1

			# Success - cleanup will handle the rest
			exit 0
			;;

		remove)
			handle_remove
			;;

		*)
			log_error "Invalid action: $ACTION"
			exit 1
			;;
	esac
}

# Run main function.
# Guard allows the test suite to source this file and call perform_backup() /
# acquire_lock() directly without triggering the real mount/lock flow.
# Production execution is unchanged: the variable is unset, so main runs as before.
if [ "${OUTDOOR_BACKUP_SOURCED:-0}" != "1" ]; then
	main "$@"
fi

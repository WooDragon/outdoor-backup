#!/bin/sh
#
# OpenWrt SD Card Backup - Main Backup Manager
# Handles the actual backup process with all safety checks.
# POSIX-compliant for OpenWrt ash shell.
#

set -e

# Constants
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
MOUNT_POINT="/mnt/sdcard"
BACKUP_ROOT="/mnt/ssd/SDMirrors"
LOCK_LINK="$BASE_DIR/var/lock/backup.lock"
LOCK_HELD=0
LOCK_IDENTITY="${LOCK_IDENTITY:-backup-manager.sh}"
CONFIG_FILE="FieldBackup.conf"
LOG_TAG="outdoor-backup"

# Lifecycle state is intentionally manager-owned: source-only libraries must not
# install traps or decide whether an event is a successful backup.
ERROR_TYPE=""
STATUS_STARTED=0
STATUS_TERMINAL_WRITTEN=0
BACKUP_STARTED_AT=0
BACKUP_DISPLAY_NAME=""

# Arguments are checked before loading common.sh because an add event may be
# intentionally disabled and must not create LED, lock, mount, or I/O effects.
ACTION="${1:-}"
DEVNAME="${2:-}"
DEVPATH="${3:-}"

case "$ACTION" in
	add|remove)
		;;
	*)
		printf 'outdoor-backup: invalid action: %s\n' "$ACTION" >&2
		exit 1
		;;
esac

# config.sh owns defaults, legacy compatibility, real UCI loading, and input
# validation. Failure here is deliberately before common functions and traps.
. "$SCRIPT_DIR/config.sh"
config_load "$BASE_DIR/conf/backup.conf" || exit 1

if [ "$ACTION" = "add" ] && [ "$ENABLED" = "0" ]; then
	config_notice "backup disabled; ignoring add event for $DEVNAME"
	exit 0
fi

# Target libraries are inert when sourced. An add must prove and pin its target
# before common.sh can create logs, aliases, LEDs, locks, or source mounts.
. "$SCRIPT_DIR/target.sh"
. "$SCRIPT_DIR/target-device.sh"

# Signal a rejected target without entering the backup lifecycle. common.sh is
# deliberately sourced only here: it defines the configured LED helper without
# creating package state. DEBUG stays off so the error indication cannot log.
guard_failure() {
	# The LED helper backgrounds its auto-off timer. Close the anchor before it
	# forks so that timer cannot keep the target mount busy after guard failure.
	target_close
	(
		DEBUG=0
		. "$SCRIPT_DIR/common.sh"
		led_backup_error
	) >/dev/null 2>&1 || :
}

if [ "$ACTION" = "add" ]; then
	# An unconfigured UUID is a configuration state, not a mount probe. Report it
	# before touching an optional default mount path or any application resource.
	if [ -z "$TARGET_UUID" ]; then
		target_device_notice 'target UUID is unconfigured'
		guard_failure
		exit 1
	fi
	if ! target_open "$TARGET_MOUNT" || \
		! target_device_validate "$TARGET_DEVICE" "$TARGET_UUID" "$DEVNAME" || \
		! target_prepare_root "$BACKUP_ROOT"; then
		guard_failure
		exit 1
	fi
fi

# Load add-only lifecycle dependencies only after the target guard succeeds.
# Remove intentionally needs neither a target mount nor a status/transfer API.
# There is no environment bypass: add tests execute this production manager.
. "$SCRIPT_DIR/common.sh"
if [ "$ACTION" = add ]; then
	. "$SCRIPT_DIR/status.sh"
	. "$SCRIPT_DIR/backup-transfer.sh"
fi

# Return success only for an integer that ash can compare safely. Args: $1 MB.
# The limit avoids arithmetic overflow on 32-bit OpenWrt targets.
is_safe_mb_value() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "${#1}" -lt 10 ] && return 0
	# Length is bounded before numeric comparison, so ash cannot overflow here.
	[ "${#1}" -eq 10 ] && [ "$1" -le 2147483647 ]
}

# Write a running snapshot. Args: none. Returns nonzero when atomic status fails.
write_running_status() {
	write_status running "$SD_UUID" "$BACKUP_DISPLAY_NAME" "$DEVNAME" \
		"$BACKUP_STARTED_AT" 0 0 0 0 0 0 "$TARGET_FD_ROOT" \
		"$TARGET_BACKUP_PATH/$SD_UUID" '' "$TARGET_BACKUP_PATH"
}

# Record one failed terminal state while the anchored target is still writable.
# Args: $1 human-readable reason. A failed write is retained as a lifecycle error.
write_failed_status() {
	[ "$STATUS_STARTED" -eq 1 ] || return 0
	[ "$STATUS_TERMINAL_WRITTEN" -eq 0 ] || return 0
	if write_status failed "$SD_UUID" "$BACKUP_DISPLAY_NAME" "$DEVNAME" \
		"$BACKUP_STARTED_AT" 0 0 0 0 0 0 "$TARGET_FD_ROOT" \
		"$TARGET_BACKUP_PATH/$SD_UUID" "$1" "$TARGET_BACKUP_PATH"; then
		STATUS_TERMINAL_WRITTEN=1
		return 0
	fi
	log_error 'Failed to persist failed backup status'
	return 1
}

# Choose the existing, operator-visible LED error pattern for an evidence-based
# failure type. Args: none. Always returns zero to preserve the real exit code.
signal_failure_led() {
	case "$ERROR_TYPE" in
		device_unknown) led_err_device_unknown ;;
		lock_timeout) led_err_lock_timeout ;;
		no_space) led_err_no_space ;;
		card_config) led_err_card_config ;;
		verify_failed) led_err_verify_failed ;;
		*) led_err_rsync ;;
	esac
	return 0
}

# Cleanup first removes transient transfer state and releases all target/source
# descriptors. LED timers are started only afterwards so they cannot inherit FD 9.
cleanup() {
	exit_code=$?

	if [ "$ACTION" = add ]; then
		backup_transfer_cleanup
	fi
	if [ "$exit_code" -ne 0 ]; then
		write_failed_status "${ERROR_TYPE:-rsync}" || :
	fi
	led_backup_stop
	release_lock
	if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
		umount "$MOUNT_POINT" 2>/dev/null || true
	fi
	sync
	target_close

	if [ "$exit_code" -eq 0 ]; then
		led_backup_done
		log_info 'Backup completed successfully'
	else
		signal_failure_led
		log_error "Backup failed with code $exit_code"
	fi
	exit "$exit_code"
}

# Judge whether the lock link's target is still a live, genuine holder. The
# link payload (the holder's /proc/<pid> path) and its publication are the
# same syscall, so there is no state where a link exists without an already
# usable identity: dereferencing a dead holder's link yields a dangling
# /proc entry, and cmdline is simply unreadable through it. Args: none.
# Returns 0 when alive, nonzero when stale (dead, reused PID, or zombie).
lock_holder_alive() {
	[ -r "$LOCK_LINK/cmdline" ] || return 1
	# Body identity check requires literal match: "." in regex matches any char
	tr '\0' ' ' < "$LOCK_LINK/cmdline" 2>/dev/null | grep -Fq -- "$LOCK_IDENTITY"
}

# Get exclusive lock via an atomic symlink publish. Args: none. Returns 0, or
# nonzero after a bounded wait. Every loop iteration advances elapsed so
# timeout is reachable. Never use `ln -sf`: -f overwrites an existing link
# instead of failing, which destroys the mutual exclusion this depends on.
acquire_lock() {
	timeout=${LOCK_TIMEOUT:-300}
	interval=${LOCK_INTERVAL:-5}
	elapsed=0
	mkdir -p "$(dirname "$LOCK_LINK")"
	while [ "$elapsed" -lt "$timeout" ]; do
		if ln -s "/proc/$$" "$LOCK_LINK" 2>/dev/null; then
			LOCK_HELD=1
			log_info 'Lock acquired'
			return 0
		fi
		if ! lock_holder_alive; then
			stale="$LOCK_LINK.stale.$$"
			if mv "$LOCK_LINK" "$stale" 2>/dev/null; then
				rm -f "$stale"
				log_info 'Removed stale lock'
			fi
		fi
		sleep "$interval"
		elapsed=$((elapsed + interval))
	done
	log_error "Failed to acquire lock after ${timeout}s"
	return 1
}

# Release the lock only if this process is its actual holder; a competitor that
# lost the race must never delete the winner's lock. The in-process flag is not
# enough: if this lock was reclaimed while we still believed we held it, the
# name now belongs to someone else and removing it would take their lock.
# Reading the link and unlinking it are two calls, so a reclaim landing between
# them still removes the newcomer's link. There is no "unlink only if it still
# points here" syscall; closing that gap would mean a different primitive. It is
# reachable only if a competitor judges a live, identity-matching holder stale,
# which lock_holder_alive does not do.
release_lock() {
	[ "$LOCK_HELD" = "1" ] || return 0
	LOCK_HELD=0
	if [ "$(readlink "$LOCK_LINK" 2>/dev/null)" != "/proc/$$" ]; then
		log_warn 'Lock was reclaimed by another process; leaving it alone'
		return 0
	fi
	rm -f "$LOCK_LINK" 2>/dev/null || true
	log_info 'Lock released'
}

# Mount the source card. Args: none. Returns nonzero when no supported FS mounts.
mount_sdcard() {
	mkdir -p "$MOUNT_POINT"
	for fs in auto exfat ntfs3 ext4 ext3 ext2 vfat; do
		if mount -t "$fs" "/dev/$DEVNAME" "$MOUNT_POINT" 2>/dev/null; then
			log_info "Mounted $DEVNAME as $fs"
			return 0
		fi
	done
	log_error "Failed to mount $DEVNAME"
	return 1
}

# Setup card metadata without executing removable-media content. Args: none.
setup_sdcard_config() {
	config_path="$MOUNT_POINT/$CONFIG_FILE"
	. "$SCRIPT_DIR/card-config.sh"
	if [ -f "$config_path" ]; then
		if ! card_config_load "$config_path"; then
			log_error 'Invalid card configuration; refusing backup'
			return 1
		fi
		if [ "$BACKUP_MODE" != PRIMARY ]; then
			log_error 'REPLICA mode is not supported by automatic backup; refusing reverse synchronization'
			return 1
		fi
		log_info "Loaded config for SD: $SD_NAME ($SD_UUID)"
	else
		if ! touch "$config_path" 2>/dev/null; then
			log_error 'SD card is read-only, cannot create config'
			return 1
		fi
		SD_UUID=$(generate_uuid)
		BACKUP_MODE=PRIMARY
		cat > "$config_path" <<EOF
# OpenWrt SD Card Backup Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# Unique identifier for this SD card
SD_UUID="$SD_UUID"

# Backup mode: PRIMARY only (automatic backup is SD→SSD)
BACKUP_MODE="$BACKUP_MODE"

# Creation timestamp
CREATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
		if ! card_config_load "$config_path"; then
			log_error 'Generated card configuration failed validation'
			return 1
		fi
		initial_alias="SDCard_$(date +%Y%m%d_%H%M%S)"
		update_alias_last_seen "$SD_UUID" "$initial_alias" || log_warn 'Failed to create initial alias'
		log_info "Created new config for SD: $initial_alias ($SD_UUID)"
	fi
	BACKUP_ROOT=$TARGET_BACKUP_ROOT
	return 0
}

# Create the two target directories under the anchor. Args: none. Returns 0/1.
prepare_backup_target() {
	target_relative=${TARGET_BACKUP_ROOT#"$TARGET_FD_ROOT"/}
	target_prepare_directory "$target_relative/$SD_UUID" || return 1
	target_prepare_directory "$target_relative/.logs" || return 1
}

# Reject unsafe or insufficient free space after the target leaf exists. Args: none.
check_minimum_free_space() {
	minimum_free=${MIN_FREE_SPACE:-1024}
	if ! is_safe_mb_value "$minimum_free"; then
		log_error 'MIN_FREE_SPACE must be a non-negative decimal MB value within shell range'
		return 1
	fi
	target_free=$(get_available_space_mb "$TARGET_BACKUP_ROOT/$SD_UUID")
	if ! is_safe_mb_value "$target_free"; then
		log_error 'Cannot determine a trustworthy target free-space value'
		return 1
	fi
	if [ "$target_free" -lt "$minimum_free" ]; then
		ERROR_TYPE=no_space
		log_error "Insufficient free space: need ${minimum_free}MB, available ${target_free}MB"
		return 1
	fi
	return 0
}

# Append the transfer result. Args: $1 display name, $2 duration, $3 rsync exit.
write_backup_summary() {
	if ! cat >> "$BACKUP_LOG_FILE" <<EOF

=== Transfer Summary ===
SD Card: $1 ($SD_UUID)
Mode: $BACKUP_MODE
Duration: $2 seconds
Rsync Exit Code: $3
Transfer Finished: $(date '+%Y-%m-%d %H:%M:%S')
EOF
	then
		log_error 'Failed to write backup summary'
		return 1
	fi
	return 0
}

# Verify the final target state after the final persistent write. Args: none.
verify_final_target() {
	if ! target_anchor_healthy || ! target_device_validate "$TARGET_DEVICE" "$TARGET_UUID" "$DEVNAME"; then
		ERROR_TYPE=verify_failed
		return 1
	fi
	return 0
}

# Finalize a successful transfer after all durable target writes and revalidation.
# Args: $1 transfer exit code (zero). Returns nonzero if no completed state is safe.
complete_backup() {
	transfer_exit=$1
	backup_finished_at=$(date +%s)
	backup_duration=$((backup_finished_at - BACKUP_STARTED_AT))
	log_info "Rsync transfer finished in ${backup_duration}s (exit code: $transfer_exit)"
	write_backup_summary "$BACKUP_DISPLAY_NAME" "$backup_duration" "$transfer_exit" || {
		ERROR_TYPE=rsync
		return 1
	}
	verify_final_target || return 1
	if ! write_status completed "$SD_UUID" "$BACKUP_DISPLAY_NAME" "$DEVNAME" \
		"$BACKUP_STARTED_AT" 100 "$BACKUP_TRANSFER_FILES" "$BACKUP_TRANSFER_FILES" \
		"$BACKUP_TRANSFER_BYTES" "$BACKUP_TRANSFER_BYTES" 0 "$TARGET_FD_ROOT" \
		"$TARGET_BACKUP_PATH/$SD_UUID" '' "$TARGET_BACKUP_PATH"; then
		ERROR_TYPE=rsync
		log_error 'Failed to persist completed backup status'
		return 1
	fi
	STATUS_TERMINAL_WRITTEN=1
	return 0
}

# Perform a one-way transfer and record atomic state transitions. Args: none.
perform_backup() {
	BACKUP_ROOT=$TARGET_BACKUP_ROOT
	if ! target_anchor_healthy || ! is_valid_uuid "$SD_UUID"; then
		ERROR_TYPE=verify_failed
		log_error 'Invalid target anchor or SD UUID; refusing target tree update'
		return 1
	fi
	prepare_backup_target || { ERROR_TYPE=verify_failed; return 1; }
	BACKUP_DISPLAY_NAME=$(get_display_name "$SD_UUID")
	update_alias_last_seen "$SD_UUID" || log_warn 'Failed to update alias timestamp'
	check_minimum_free_space || return 1
	if ! target_anchor_healthy; then
		ERROR_TYPE=verify_failed
		return 1
	fi

	BACKUP_STARTED_AT=$(date +%s)
	BACKUP_LOG_FILE="$TARGET_BACKUP_ROOT/.logs/backup_${SD_UUID}_$(date +%Y%m%d_%H%M%S).log"
	if ! write_running_status; then
		ERROR_TYPE=rsync
		log_error 'Failed to persist running backup status'
		return 1
	fi
	STATUS_STARTED=1
	log_info "Starting PRIMARY backup: SD → SSD ($BACKUP_DISPLAY_NAME)"
	if backup_transfer "$MOUNT_POINT/" "$TARGET_BACKUP_ROOT/$SD_UUID/" "$BACKUP_LOG_FILE"; then
		complete_backup 0
		return $?
	else
		transfer_exit=$?
	fi
	ERROR_TYPE=$BACKUP_TRANSFER_ERROR
	[ -n "$ERROR_TYPE" ] || ERROR_TYPE=rsync
	write_failed_status "$ERROR_TYPE" || :
	return "$transfer_exit"
}

# Handle remove without requiring a mounted target. Args: none.
handle_remove() {
	log_info 'Handling SD card removal'
	pkill -f "rsync.*$MOUNT_POINT" 2>/dev/null || true
	exit 0
}

# Run the requested lifecycle action. Args: event action arguments.
main() {
	trap cleanup EXIT
	trap cleanup INT TERM
	case "$ACTION" in
		add)
			led_backup_start
			if ! acquire_lock; then
				ERROR_TYPE=lock_timeout
				exit 1
			fi
			if ! mount_sdcard; then
				ERROR_TYPE=device_unknown
				exit 1
			fi
			if ! setup_sdcard_config; then
				ERROR_TYPE=card_config
				exit 1
			fi
			if perform_backup; then
				exit 0
			else
				backup_exit=$?
				exit "$backup_exit"
			fi
			;;
		remove) handle_remove ;;
		*) log_error "Invalid action: $ACTION"; exit 1 ;;
	esac
}

main "$@"

#!/bin/sh
#
# OpenWrt SD Card Backup - Main Backup Manager
# Handles the actual backup process with all safety checks
# POSIX-compliant for ash shell
#

set -e

# Constants
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
MOUNT_POINT="/mnt/sdcard"
BACKUP_ROOT="/mnt/ssd/SDMirrors"
LOCK_FILE="$BASE_DIR/var/lock/backup.pid"
CONFIG_FILE="FieldBackup.conf"
LOG_TAG="outdoor-backup"

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

if [ "$ACTION" = "add" ]; then
	# An unconfigured UUID is a configuration state, not a mount probe. Report it
	# before touching an optional default mount path or any application resource.
	if [ -z "$TARGET_UUID" ]; then
		target_device_notice 'target UUID is unconfigured'
		exit 1
	fi
	if ! target_open "$TARGET_MOUNT" || \
		! target_device_validate "$TARGET_DEVICE" "$TARGET_UUID" "$DEVNAME" || \
		! target_prepare_root "$BACKUP_ROOT"; then
		target_close
		exit 1
	fi
fi

# Load common functions only after target guard success for add, or a valid
# remove event, which intentionally does not require the target to be mounted.
. "$SCRIPT_DIR/common.sh"

# Cleanup function
cleanup() {
	local exit_code=$?

	# Stop LED blinking
	led_backup_stop

	# Remove lock file if we own it
	if [ -f "$LOCK_FILE" ]; then
		if [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$$" ]; then
			rm -f "$LOCK_FILE"
			log_info "Lock released"
		fi
	fi

	# Unmount if needed
	if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
		umount "$MOUNT_POINT" 2>/dev/null || true
	fi

	# Final sync
	sync

	# The target FD is owned by this manager. Closing is idempotent for remove.
	target_close

	if [ $exit_code -eq 0 ]; then
		led_backup_done
		log_info "Backup completed successfully"
	else
		led_backup_error
		log_error "Backup failed with code $exit_code"
	fi

	exit $exit_code
}

# Get exclusive lock
acquire_lock() {
	local timeout=300  # 5 minutes
	local elapsed=0

	while [ $elapsed -lt $timeout ]; do
		# Check if lock exists
		if [ -f "$LOCK_FILE" ]; then
			local pid=$(cat "$LOCK_FILE" 2>/dev/null)

			# Check if process is still running
			if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
				log_debug "Waiting for lock (PID $pid)..."
				sleep 5
				elapsed=$((elapsed + 5))
			else
				# Stale lock, remove it
				rm -f "$LOCK_FILE"
				log_info "Removed stale lock"
			fi
		else
			# Try to create lock
			echo "$$" > "$LOCK_FILE"

			# Verify we got the lock (race condition check)
			if [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$$" ]; then
				log_info "Lock acquired"
				return 0
			fi
		fi
	done

	log_error "Failed to acquire lock after ${timeout}s"
	return 1
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

	# A card config may contain a historical BACKUP_ROOT. The target anchor set
	# the only root this invocation may use before the card was mounted.
	BACKUP_ROOT="$TARGET_BACKUP_ROOT"
	return 0
}

# Perform rsync backup
perform_backup() {
	local source_dir=""
	local target_dir=""
	local log_file=""
	local display_name=""
	local target_relative=""

	# Card configuration is root-managed data only for this run: restore the
	# target root that was pinned before the source card was mounted.
	BACKUP_ROOT="$TARGET_BACKUP_ROOT"
	target_anchor_healthy || return 1
	if ! is_valid_uuid "$SD_UUID"; then
		log_error "Invalid SD UUID; refusing target tree update"
		return 1
	fi
	target_relative=${TARGET_BACKUP_ROOT#"$TARGET_FD_ROOT"/}
	target_prepare_directory "$target_relative/$SD_UUID" || return 1
	target_prepare_directory "$target_relative/.logs" || return 1

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

	# Check available space
	local source_size=$(get_dir_size_mb "$source_dir")
	local target_free=$(get_available_space_mb "$target_dir")

	if [ "$source_size" -gt "$target_free" ]; then
		log_error "Insufficient space: need ${source_size}MB, available ${target_free}MB"
		return 1
	fi

	# Directories were created through the anchor FD above; no bare mount path
	# may create or resolve target state from this point onward.
	target_anchor_healthy || return 1

	# Record start time
	local start_time=$(date +%s)

	# Perform rsync
	log_info "Executing rsync from $source_dir to $target_dir"

	rsync \
		--archive \
		--recursive \
		--times \
		--prune-empty-dirs \
		--ignore-existing \
		--stats \
		--human-readable \
		--progress \
		--log-file="$log_file" \
		--exclude="$CONFIG_FILE" \
		--exclude=".Trash*" \
		--exclude=".Spotlight*" \
		--exclude=".fseventsd" \
		--exclude="System Volume Information" \
		--exclude="\$RECYCLE.BIN" \
		"$source_dir" "$target_dir" 2>&1 | while read -r line; do
			# Parse progress for logging (optional)
			case "$line" in
				*%*)
					log_debug "Progress: $line"
					;;
			esac
		done

	local rsync_exit=$?
	local end_time=$(date +%s)
	local duration=$((end_time - start_time))

	# Log summary
	log_info "Backup completed in ${duration}s (exit code: $rsync_exit)"

	# Write summary to log file. This function is invoked with `||` by main, so
	# do not rely on set -e to propagate a failed redirection or cat process.
	if ! cat >> "$log_file" << EOF

=== Backup Summary ===
SD Card: $display_name ($SD_UUID)
Mode: $BACKUP_MODE
Duration: ${duration} seconds
Exit Code: $rsync_exit
Completed: $(date '+%Y-%m-%d %H:%M:%S')
EOF
	then
		log_error "Failed to write backup summary"
		return 1
	fi

	# The summary is the final target write. Revalidate after it so a detach or
	# device change during that write cannot be reported as a completed backup.
	target_anchor_healthy || return 1
	if ! target_device_validate "$TARGET_DEVICE" "$TARGET_UUID" "$DEVNAME"; then
		return 1
	fi
	return $rsync_exit
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

			# Acquire lock
			acquire_lock || exit 1

			# Mount SD card
			mount_sdcard || exit 1

			# Setup configuration
			setup_sdcard_config || exit 1

			# Perform backup
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

# Run main function
main "$@"

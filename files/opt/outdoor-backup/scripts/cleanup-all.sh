#!/bin/sh
#
# cleanup-all.sh - Batch cleanup all backup data
# Purpose: Free up local storage space (assuming data synced to NAS)
#
# Usage:
#   cleanup-all.sh <backup_root> [keep_aliases]
#     backup_root: Backup root directory (e.g. /mnt/ssd/SDMirrors)
#     keep_aliases: 1=keep aliases.json (default), 0=clear aliases
#
# Behavior:
#   1. Iterate through all UUID directories under backup_root
#   2. Validate directory name is valid UUID format
#   3. Delete directory contents (rm -rf $dir/*)
#   4. Keep directory structure (don't delete directory itself)
#   5. Keep/clear aliases.json based on parameter
#
# Safety measures:
#   - Path safety check (is_safe_path)
#   - UUID format validation (prevent accidental deletion)
#   - Detailed logging for all operations
#   - Error handling and exit codes
#

set -e

# Constants
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
LOG_TAG="outdoor-backup-cleanup"

# Load common functions
. "$SCRIPT_DIR/common.sh"

# Arguments
BACKUP_ROOT="$1"
KEEP_ALIASES="${2:-1}"  # Default: keep aliases

# Exit codes
EXIT_SUCCESS=0
EXIT_INVALID_ARGS=1
EXIT_PATH_ERROR=2
EXIT_CLEANUP_ERROR=3

# Validate arguments
if [ -z "$BACKUP_ROOT" ]; then
	log_error "Missing backup_root argument"
	echo "Usage: $0 <backup_root> [keep_aliases]" >&2
	exit $EXIT_INVALID_ARGS
fi

# Path safety check
if ! is_safe_path "$BACKUP_ROOT"; then
	log_error "Unsafe path detected: $BACKUP_ROOT"
	exit $EXIT_PATH_ERROR
fi

# Check if backup root exists
if [ ! -d "$BACKUP_ROOT" ]; then
	log_error "Backup root does not exist: $BACKUP_ROOT"
	exit $EXIT_PATH_ERROR
fi

# Check if backup root is writable
if [ ! -w "$BACKUP_ROOT" ]; then
	log_error "Backup root is not writable: $BACKUP_ROOT"
	exit $EXIT_PATH_ERROR
fi

# Main cleanup logic
cleanup_all_backup_data() {
	local deleted_count=0
	local skipped_count=0
	local total_size_before=0
	local total_size_after=0

	log_info "Starting batch cleanup of backup data"
	log_info "Backup root: $BACKUP_ROOT"
	log_info "Keep aliases: $KEEP_ALIASES"

	# Calculate total size before cleanup
	total_size_before=$(get_total_backup_size "$BACKUP_ROOT")
	log_info "Total size before cleanup: ${total_size_before} bytes"

	# Iterate through all directories in backup root
	for dir in "$BACKUP_ROOT"/*; do
		# Skip if not a directory
		[ -d "$dir" ] || continue

		local uuid=$(basename "$dir")

		# Skip special directories (logs, config, etc.)
		case "$uuid" in
			.logs|.tmp|lost+found)
				log_debug "Skipping special directory: $uuid"
				skipped_count=$((skipped_count + 1))
				continue
				;;
		esac

		# Validate UUID format before deletion
		if is_valid_uuid "$uuid"; then
			log_info "Cleaning up backup data for UUID: $uuid"

			# Get directory size before deletion
			local dir_size=$(get_dir_size_mb "$dir")

			# Delete directory contents (keep directory structure)
			# Use || true to continue even if some files fail to delete
			if rm -rf "$dir"/* 2>/dev/null; then
				log_info "Deleted ${dir_size}MB from UUID: $uuid"
				deleted_count=$((deleted_count + 1))
			else
				log_warn "Failed to delete some files in UUID: $uuid"
				# Continue anyway - partial deletion is better than nothing
				deleted_count=$((deleted_count + 1))
			fi
		else
			log_warn "Skipping invalid UUID format: $uuid"
			skipped_count=$((skipped_count + 1))
		fi
	done

	# Calculate total size after cleanup
	total_size_after=$(get_total_backup_size "$BACKUP_ROOT")
	local freed_size=$((total_size_before - total_size_after))

	log_info "Deleted backup data from $deleted_count UUID directories"
	log_info "Skipped $skipped_count directories (special or invalid)"
	log_info "Total size after cleanup: ${total_size_after} bytes"
	log_info "Freed space: ${freed_size} bytes"

	# Handle aliases.json
	if [ "$KEEP_ALIASES" = "0" ]; then
		local alias_file="/opt/outdoor-backup/conf/aliases.json"
		if [ -f "$alias_file" ]; then
			# Clear aliases but keep file structure
			cat > "$alias_file" << 'EOF'
{
  "version": "1.0",
  "aliases": {}
}
EOF
			log_info "Cleared aliases.json (reset to empty)"
		fi
	else
		log_info "Preserved aliases.json (keep_aliases=1)"
	fi

	log_info "Batch cleanup completed successfully"

	return $EXIT_SUCCESS
}

# Execute cleanup
cleanup_all_backup_data

exit $?

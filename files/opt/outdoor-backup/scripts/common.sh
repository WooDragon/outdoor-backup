#!/bin/sh
#
# Common functions for SD Card Backup System
# POSIX-compliant for OpenWrt ash shell
#

# LED paths - R5S default, override in config
LED_GREEN="${LED_GREEN:-/sys/class/leds/green:lan}"
LED_RED="${LED_RED:-/sys/class/leds/red:sys}"

# Logging functions
log_info() {
	logger -t "$LOG_TAG" -p info "$1"
	echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" >> "$BASE_DIR/log/backup.log"
}

log_error() {
	logger -t "$LOG_TAG" -p err "$1"
	echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" >> "$BASE_DIR/log/backup.log"
}

log_warn() {
	logger -t "$LOG_TAG" -p warn "$1"
	echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $1" >> "$BASE_DIR/log/backup.log"
}

log_debug() {
	if [ "${DEBUG:-0}" = "1" ]; then
		logger -t "$LOG_TAG" -p debug "$1"
		echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $1" >> "$BASE_DIR/log/backup.log"
	fi
}

# LED control functions
led_set() {
	local led_path="$1"
	local trigger="$2"
	local delay_on="$3"
	local delay_off="$4"
	local brightness="$5"

	[ -d "$led_path" ] || return 1

	# Set trigger
	if [ -n "$trigger" ]; then
		echo "$trigger" > "$led_path/trigger" 2>/dev/null || true
	fi

	# Set timing for blink
	if [ -n "$delay_on" ] && [ "$trigger" = "timer" ]; then
		echo "$delay_on" > "$led_path/delay_on" 2>/dev/null || true
		echo "$delay_off" > "$led_path/delay_off" 2>/dev/null || true
	fi

	# Set brightness
	if [ -n "$brightness" ]; then
		echo "$brightness" > "$led_path/brightness" 2>/dev/null || true
	fi
}

led_backup_start() {
	# Fast blink - backup in progress
	led_set "$LED_GREEN" "timer" "100" "100"
	log_debug "LED set to fast blink"
}

led_backup_done() {
	# Solid on - backup complete
	led_set "$LED_GREEN" "none" "" "" "1"
	log_debug "LED set to solid on"

	# Auto-off after 30 seconds
	(
		sleep 30
		led_set "$LED_GREEN" "none" "" "" "0"
	) &
}

led_backup_error() {
	# Slow blink red - error occurred
	led_set "$LED_RED" "timer" "500" "500"
	log_debug "LED set to error blink"

	# Auto-off after 60 seconds
	(
		sleep 60
		led_set "$LED_RED" "none" "" "" "0"
	) &
}

led_backup_stop() {
	# Turn off all LEDs
	led_set "$LED_GREEN" "none" "" "" "0"
	led_set "$LED_RED" "none" "" "" "0"
	log_debug "LEDs turned off"
}

# Check if path is safe (prevent directory traversal)
is_safe_path() {
	local path="$1"
	case "$path" in
		*../*|*/../*|*/..|\.\.)
			return 1
			;;
		*)
			return 0
			;;
	esac
}

# Get filesystem type of device
get_fs_type() {
	local device="$1"
	blkid -o value -s TYPE "$device" 2>/dev/null
}

# Check if device is mounted
is_mounted() {
	local device="$1"
	mount | grep -q "^${device} "
}

# Get mount point of device
get_mount_point() {
	local device="$1"
	mount | grep "^${device} " | awk '{print $3}'
}

# Calculate directory size in MB
get_dir_size_mb() {
	local dir="$1"
	if [ -d "$dir" ]; then
		du -sm "$dir" 2>/dev/null | awk '{print $1}'
	else
		echo "0"
	fi
}

# Check available space in MB
get_available_space_mb() {
	local path="$1"
	df -m "$path" 2>/dev/null | awk 'NR==2 {print $4}'
}

# UUID generation (OpenWrt doesn't always have uuidgen)
generate_uuid() {
	if command -v uuidgen >/dev/null 2>&1; then
		uuidgen
	elif [ -r /proc/sys/kernel/random/uuid ]; then
		cat /proc/sys/kernel/random/uuid
	else
		# Fallback: use timestamp + random
		echo "$(date +%s)-$(dd if=/dev/urandom bs=12 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
	fi
}

# Alias management functions (for WebUI support)
# File: /opt/outdoor-backup/conf/aliases.json

# Get alias for a given UUID
# Args: $1 = UUID
# Returns: alias string (empty if not found or no alias set)
get_alias() {
	local uuid="$1"
	local alias_file="/opt/outdoor-backup/conf/aliases.json"

	# Return empty if file doesn't exist
	[ -f "$alias_file" ] || return 0

	# Parse JSON using awk to extract alias field for the UUID
	# JSON structure: "uuid": {"alias": "value", ...}
	# We need to:
	# 1. Find the line with "uuid":
	# 2. Read forward to find "alias":
	# 3. Extract the value between quotes
	awk -v uuid="$uuid" '
		/"'"$uuid"'"[[:space:]]*:[[:space:]]*\{/ {
			in_uuid = 1
			next
		}
		in_uuid && /"alias"[[:space:]]*:/ {
			# Extract value between quotes after "alias":
			match($0, /"alias"[[:space:]]*:[[:space:]]*"([^"]*)"/, arr)
			if (arr[1] != "") {
				print arr[1]
			}
			exit
		}
		in_uuid && /\}/ {
			in_uuid = 0
		}
	' "$alias_file" 2>/dev/null
}

# Update last_seen timestamp for a UUID
# Args: $1 = UUID
# Creates new entry if UUID doesn't exist (with empty alias/notes)
# Uses atomic write (tmp file + mv) for safety
update_alias_last_seen() {
	local uuid="$1"
	local alias_file="/opt/outdoor-backup/conf/aliases.json"
	local temp_file="${alias_file}.tmp"
	local now=$(date +%s)

	# Ensure directory exists
	mkdir -p "$(dirname "$alias_file")"

	# Initialize if file doesn't exist
	if [ ! -f "$alias_file" ]; then
		cat > "$alias_file" << 'EOF'
{
  "version": "1.0",
  "aliases": {}
}
EOF
		log_debug "Created aliases.json"
	fi

	# Check if UUID exists in file
	if grep -q "\"$uuid\"" "$alias_file" 2>/dev/null; then
		# Update existing entry: replace last_seen value
		awk -v uuid="$uuid" -v now="$now" '
			/"'"$uuid"'"[[:space:]]*:[[:space:]]*\{/ {
				in_uuid = 1
			}
			in_uuid && /"last_seen"[[:space:]]*:/ {
				# Replace the timestamp value
				sub(/:[[:space:]]*[0-9]+/, ": " now)
			}
			in_uuid && /\}/ {
				in_uuid = 0
			}
			{ print }
		' "$alias_file" > "$temp_file"
	else
		# Add new entry before closing "aliases" object
		# Find the last } before final }, insert new entry
		awk -v uuid="$uuid" -v now="$now" '
			# Track if we are in the aliases object
			/"aliases"[[:space:]]*:[[:space:]]*\{/ {
				in_aliases = 1
				print
				next
			}
			# Found closing brace of aliases, check if empty
			in_aliases && /^[[:space:]]*\}/ {
				# Check if aliases was empty by reading ahead
				# If previous line was opening brace, no comma needed
				if (prev_line ~ /\{[[:space:]]*$/) {
					# Empty aliases, add first entry without comma
					print "    \"" uuid "\": {"
				} else {
					# Non-empty, add comma and new entry
					print ","
					print "    \"" uuid "\": {"
				}
				print "      \"alias\": \"\","
				print "      \"notes\": \"\","
				print "      \"created_at\": " now ","
				print "      \"last_seen\": " now
				print "    }"
				in_aliases = 0
			}
			{
				prev_line = $0
				print
			}
		' "$alias_file" > "$temp_file"
	fi

	# Atomic replace
	if [ -f "$temp_file" ]; then
		mv "$temp_file" "$alias_file" || {
			log_error "Failed to update aliases.json"
			rm -f "$temp_file"
			return 1
		}
		log_debug "Updated last_seen for UUID: ${uuid:0:8}..."
	else
		log_error "Failed to generate temp file for aliases update"
		return 1
	fi

	return 0
}

# Get display name for SD card (prioritized fallback)
# Args: $1 = UUID
# Priority: 1. Alias (from aliases.json) → 2. UUID prefix (SD_xxxxxxxx)
# Returns: display name string
get_display_name() {
	local uuid="$1"

	# Priority 1: Check for alias
	local alias=$(get_alias "$uuid")
	if [ -n "$alias" ]; then
		echo "$alias"
		return 0
	fi

	# Priority 2: Fallback to UUID prefix
	echo "SD_${uuid:0:8}"
}

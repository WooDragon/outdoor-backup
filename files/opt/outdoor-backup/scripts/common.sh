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

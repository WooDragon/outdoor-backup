#!/bin/sh
#
# Common functions for SD Card Backup System
# POSIX-compliant for OpenWrt ash shell
#

# LED paths - R5S default, override in config
# Four-lamp primitive layout: LED_RED is the power LED (error indicator only,
# never touched by non-error states); LED_GREEN/LED_GREEN2/LED_GREEN3 map to
# wan/lan-1/lan-2 and carry the progress walking-lamp + completion signal.
#
# ${VAR-default} (not ${VAR:-default}) is deliberate: an explicitly empty
# value is the documented "no LED wired for this slot" contract shared with
# config_normalize_optional_path/led_set (issue #40 fact 4) and must be
# preserved as empty, not overwritten by the default. Only a genuinely unset
# variable (the config loader never ran, or never touched this slot) falls
# back to the R5S onboard path.
LED_GREEN="${LED_GREEN-/sys/class/leds/green:wan}"
LED_GREEN2="${LED_GREEN2-/sys/class/leds/green:lan-1}"
LED_GREEN3="${LED_GREEN3-/sys/class/leds/green:lan-2}"
LED_RED="${LED_RED-/sys/class/leds/red:power}"

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
#
# Fail-loud contract: an empty $led_path is a legitimate "no LED configured
# for this slot" and must stay silent (no logger, no error). A non-empty but
# invalid/unwritable path is a real misconfiguration and must complain via
# logger -- never via a file write (the test suite asserts zero application
# log writes; see test-target-manager.sh's zero-log-file guard).
led_set() {
	local led_path="$1"
	local trigger="$2"
	local delay_on="$3"
	local delay_off="$4"
	local brightness="$5"

	[ -n "$led_path" ] || return 0

	if [ ! -d "$led_path" ]; then
		logger -t "$LOG_TAG" -p err "led_set: LED path does not exist: $led_path" 2>/dev/null || :
		return 1
	fi

	# Set trigger
	if [ -n "$trigger" ]; then
		if ! echo "$trigger" > "$led_path/trigger" 2>/dev/null; then
			logger -t "$LOG_TAG" -p err "led_set: failed to write trigger '$trigger' to $led_path/trigger" 2>/dev/null || :
		fi
	fi

	# Set timing for blink
	if [ -n "$delay_on" ] && [ "$trigger" = "timer" ]; then
		if ! echo "$delay_on" > "$led_path/delay_on" 2>/dev/null; then
			logger -t "$LOG_TAG" -p err "led_set: failed to write delay_on '$delay_on' to $led_path/delay_on" 2>/dev/null || :
		fi
		if ! echo "$delay_off" > "$led_path/delay_off" 2>/dev/null; then
			logger -t "$LOG_TAG" -p err "led_set: failed to write delay_off '$delay_off' to $led_path/delay_off" 2>/dev/null || :
		fi
	fi

	# Set brightness
	if [ -n "$brightness" ]; then
		if ! echo "$brightness" > "$led_path/brightness" 2>/dev/null; then
			logger -t "$LOG_TAG" -p err "led_set: failed to write brightness '$brightness' to $led_path/brightness" 2>/dev/null || :
		fi
	fi
}

# ---------------------------------------------------------------------------
# Four-lamp state-machine primitives (issue #40)
#
# R (LED_RED, power) is not touched by every primitive below -- see
# CLAUDE.md's LED write-surface table for the authoritative list of which
# composite states write it (led_state_error, led_state_reset_idle, and
# led_state_cancelled_lease all do; led_state_cancelled_operator and
# led_state_unconfigured deliberately never do). "Not touching R" means
# literally issuing no write against it, matching the pre-existing behavior
# of a successful run never touching the power LED. Every function here is
# set-and-exit: it writes the target sysfs node(s) once and returns, no fork,
# no sleep, no background job. The kernel "timer" trigger keeps blinking on
# its own after the write returns.
#
# max_brightness on every real R5S LED is 1: "solid on" is brightness=1, not
# 255 (issue #40 fact 1). An empty led_path is a legal "unconfigured slot"
# (issue #40 fact 4) and is silently skipped by led_set; never gate on it here.
#
# Segment/which-green argument contract used below:
#   segment / green slot: 1 = G1 (LED_GREEN/wan), 2 = G2 (LED_GREEN2/lan-1),
#   3 = G3 (LED_GREEN3/lan-2), 0 = none (all green off).
# ---------------------------------------------------------------------------

# Turn a single LED fully off. Args: $1 led sysfs path.
led_state_off() {
	led_set "$1" "none" "" "" "0"
}

# Turn a single LED solid on. Args: $1 led sysfs path.
led_state_solid() {
	led_set "$1" "none" "" "" "1"
}

# Fast-blink a single LED (100ms/100ms). Args: $1 led sysfs path.
led_state_fast_blink() {
	led_set "$1" "timer" "100" "100"
}

# Slow-blink a single LED (500ms/500ms). Args: $1 led sysfs path.
led_state_slow_blink() {
	led_set "$1" "timer" "500" "500"
}

# Progress walking lamp for one segment (0-33 / 34-66 / 67-99). Pure and
# stateless: the caller (backup-manager.sh) is responsible for calling this
# only when the segment actually changes, to satisfy the cross-segment
# debounce requirement. R is left untouched. Args: $1 segment (1, 2, or 3).
led_state_progress() {
	local segment="$1"

	case "$segment" in
		1)
			led_state_fast_blink "$LED_GREEN"
			led_state_off "$LED_GREEN2"
			led_state_off "$LED_GREEN3"
			;;
		2)
			led_state_solid "$LED_GREEN"
			led_state_fast_blink "$LED_GREEN2"
			led_state_off "$LED_GREEN3"
			;;
		3)
			led_state_solid "$LED_GREEN"
			led_state_solid "$LED_GREEN2"
			led_state_fast_blink "$LED_GREEN3"
			;;
		*)
			logger -t "$LOG_TAG" -p err "led_state_progress: invalid segment '$segment'" 2>/dev/null || :
			return 1
			;;
	esac
}

# Error signalling: R slow blink, plus at most one green LED solid to
# distinguish the error class (0 = no green, matching "unclassified"/rsync).
# Args: $1 which green slot to light solid (0, 1, 2, or 3).
led_state_error() {
	local which_green="$1"

	led_state_slow_blink "$LED_RED"
	case "$which_green" in
		0)
			led_state_off "$LED_GREEN"
			led_state_off "$LED_GREEN2"
			led_state_off "$LED_GREEN3"
			;;
		1)
			led_state_solid "$LED_GREEN"
			led_state_off "$LED_GREEN2"
			led_state_off "$LED_GREEN3"
			;;
		2)
			led_state_off "$LED_GREEN"
			led_state_solid "$LED_GREEN2"
			led_state_off "$LED_GREEN3"
			;;
		3)
			led_state_off "$LED_GREEN"
			led_state_off "$LED_GREEN2"
			led_state_solid "$LED_GREEN3"
			;;
		*)
			logger -t "$LOG_TAG" -p err "led_state_error: invalid green slot '$which_green'" 2>/dev/null || :
			return 1
			;;
	esac
}

# Terminal success signalling (issue #40 / #41 PR review Critical 1): all
# three green LEDs solid, R left untouched. This is the "完成" row of the
# state table and is a real terminal state, not a transient one -- it must
# persist until the next card insertion resets it (reset timing is out of
# scope for this PR). Deliberately set-and-exit like every other primitive:
# no sleep, no fork, no auto-off. Args: none.
led_state_complete() {
	led_state_solid "$LED_GREEN"
	led_state_solid "$LED_GREEN2"
	led_state_solid "$LED_GREEN3"
}

# Target-unconfigured signalling: G3 slow-blinks, G1/G2 stay off, R is left
# untouched (no write issued against it at all -- this is a configuration
# state, not an error the red LED should represent). Distinguished from the
# device/anchor identity failure class (led_state_error slot 3: G3 SOLID +
# R slow-blink) by which trigger G3 gets and by R being untouched here.
# Args: none.
led_state_unconfigured() {
	led_state_off "$LED_GREEN"
	led_state_off "$LED_GREEN2"
	led_state_slow_blink "$LED_GREEN3"
}

# ---------------------------------------------------------------------------
# Composite primitives (issue #43): none of these compose from anything but
# the six atomic primitives above, whose internal sysfs write sequences are
# unchanged by this addition.
# ---------------------------------------------------------------------------

# Full four-lamp reset to idle/off, including R (issue #43 scope 1). This is
# the "next card insertion clears the previous terminal state" primitive and
# is deliberately the only reset-style primitive that writes R: every other
# non-error primitive in this file leaves R untouched by design.
# Args: none.
led_state_reset_idle() {
	led_state_off "$LED_RED"
	led_state_off "$LED_GREEN"
	led_state_off "$LED_GREEN2"
	led_state_off "$LED_GREEN3"
}

# Operator-cancel signalling (issue #43 scope 2, path A): the card was pulled
# by the operator, so every lamp is turned off -- except R, which must not be
# touched at all (no write issued against it, matching the "R untouched"
# contract of led_state_unconfigured above). Args: none.
led_state_cancelled_operator() {
	led_state_off "$LED_GREEN"
	led_state_off "$LED_GREEN2"
	led_state_off "$LED_GREEN3"
}

# Lease-cancel signalling (issue #43 scope 2, path B): the service lease is no
# longer current (service stop/restart/package upgrade while the card is still
# inserted) -- R slow-blinks, G1 and G2 go solid, G3 goes off. Args: none.
led_state_cancelled_lease() {
	led_state_slow_blink "$LED_RED"
	led_state_solid "$LED_GREEN"
	led_state_solid "$LED_GREEN2"
	led_state_off "$LED_GREEN3"
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

# Check available space in MB on the filesystem holding $1.
# Walks up to the nearest existing ancestor so a not-yet-created target dir
# still yields the correct figure (df can't stat a path that doesn't exist).
get_available_space_mb() {
	local path="$1"
	# Climb until we hit a path that exists (worst case "/").
	while [ ! -e "$path" ] && [ "$path" != "/" ] && [ -n "$path" ]; do
		path=$(dirname "$path")
	done
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
#
# ALIASES_FILE honors a pre-set override (used by the test suite to redirect
# writes into a fixture). Production leaves it unset, so it resolves to the
# canonical absolute path exactly as before — no behavior change.
ALIASES_FILE="${ALIASES_FILE:-/opt/outdoor-backup/conf/aliases.json}"

# Get alias for a given UUID
# Args: $1 = UUID
# Returns: alias string (empty if not found or no alias set)
get_alias() {
	local uuid="$1"
	local alias_file="$ALIASES_FILE"

	# Return empty if file doesn't exist
	[ -f "$alias_file" ] || return 0

	# Parse JSON using awk to extract alias field for the UUID
	# JSON structure: "uuid": {"alias": "value", ...}
	# We need to:
	# 1. Find the line with "uuid":
	# 2. Read forward to find "alias":
	# 3. Extract the value between quotes
	awk -v uuid="$uuid" '
		$0 ~ "\"" uuid "\"[[:space:]]*:[[:space:]]*\\{" {
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
# Args: $1 = UUID, $2 = initial_alias (optional, used on first creation)
# Creates new entry if UUID doesn't exist (with optional initial alias)
# Uses atomic write (tmp file + mv) for safety
# Uses file lock to prevent concurrent write conflicts
update_alias_last_seen() {
	local uuid="$1"
	local initial_alias="$2"  # Optional: set initial alias on first creation
	local alias_file="$ALIASES_FILE"
	local temp_file="${alias_file}.tmp"
	local lock_file="${alias_file}.lock"
	local now=$(date +%s)
	local lock_fd

	# Ensure directory exists
	mkdir -p "$(dirname "$alias_file")"

	# Acquire file lock (maximum 10 seconds wait)
	# Use file descriptor 200 for lock file
	exec 200>"$lock_file" 2>/dev/null || {
		log_warn "Failed to open lock file for aliases.json"
		return 1
	}

	# Use flock if available (busybox flock or util-linux flock)
	if command -v flock >/dev/null 2>&1; then
		if ! flock -w 10 200; then
			exec 200>&-
			log_warn "Failed to acquire lock for aliases.json (timeout after 10s)"
			return 1
		fi
	else
		# Fallback: simple lock with timeout (not as robust)
		local retry=0
		while [ -f "$lock_file" ] && [ $retry -lt 100 ]; do
			sleep 0.1
			retry=$((retry + 1))
		done
		if [ $retry -ge 100 ]; then
			exec 200>&-
			log_warn "Failed to acquire lock for aliases.json (timeout)"
			return 1
		fi
	fi

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
			$0 ~ "\"" uuid "\"[[:space:]]*:[[:space:]]*\\{" {
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
		# Use initial_alias if provided, otherwise empty string
		local alias_value="${initial_alias:-}"

		awk -v uuid="$uuid" -v now="$now" -v alias="$alias_value" '
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
				# Use provided alias or empty string
				print "      \"alias\": \"" alias "\","
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

		# Log initial alias creation
		if [ -n "$initial_alias" ]; then
			log_info "Created alias entry with initial name: $initial_alias"
		fi
	fi

	# Atomic replace
	if [ -f "$temp_file" ]; then
		mv "$temp_file" "$alias_file" || {
			log_error "Failed to update aliases.json"
			rm -f "$temp_file"
			# Release lock before returning
			exec 200>&-
			rm -f "$lock_file"
			return 1
		}
		log_debug "Updated last_seen for UUID: ${uuid:0:8}..."
	else
		log_error "Failed to generate temp file for aliases update"
		# Release lock before returning
		exec 200>&-
		rm -f "$lock_file"
		return 1
	fi

	# Release file lock
	exec 200>&-
	rm -f "$lock_file"

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

# Validate UUID format (RFC 4122 standard)
# Args: $1 = UUID string
# Returns: 0=valid, 1=invalid
# Format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (8-4-4-4-12 hex digits)
is_valid_uuid() {
	local uuid="$1"

	# Check length (36 characters)
	[ ${#uuid} -eq 36 ] || return 1

	# Check format using case pattern matching
	# Pattern: 8 hex - 4 hex - 4 hex - 4 hex - 12 hex
	case "$uuid" in
		[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
			return 0
			;;
		*)
			return 1
			;;
	esac
}

# Calculate total backup size (in bytes)
# Args: $1 = backup_root path
# Returns: total size in bytes (stdout)
# Note: Excludes special directories (.logs, .tmp, etc.)
get_total_backup_size() {
	local backup_root="$1"

	# Validate path
	[ -d "$backup_root" ] || {
		echo "0"
		return 1
	}

	# Use du to calculate size
	# Different systems support different flags:
	# - Linux: du -sb (bytes)
	# - macOS/BSD: du -sk (kilobytes), multiply by 1024
	# Try -sb first, fall back to -sk if not supported
	local size_bytes
	size_bytes=$(du -sb "$backup_root" 2>/dev/null | awk '{print $1}')

	if [ -z "$size_bytes" ] || [ "$size_bytes" = "0" ]; then
		# Fall back to -sk (kilobytes) and convert to bytes
		local size_kb
		size_kb=$(du -sk "$backup_root" 2>/dev/null | awk '{print $1}')
		size_bytes=$((size_kb * 1024))
	fi

	echo "${size_bytes:-0}"
}

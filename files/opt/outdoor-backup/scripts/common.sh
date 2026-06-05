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
	# Slow blink red - generic error (kept as fallback / rsync failure)
	led_set "$LED_RED" "timer" "500" "500"
	log_debug "LED set to error blink"

	# Auto-off after 60 seconds
	(
		sleep 60
		led_set "$LED_RED" "none" "" "" "0"
	) &
}

# ---------------------------------------------------------------------------
# Differentiated LED error codes (issue #4)
#
# Field diagnostics: the operator has no SSH/network, the LED is the only
# interface. A countable blink pattern (N flashes + pause, repeating) is far
# easier to read by eye than a duty-cycle difference, so each error type maps
# to a distinct flash count.
#
# Pattern table:
#   device unknown   -> red, 1 flash  + pause
#   lock timeout     -> red, 2 flashes + pause
#   no space         -> red, 3 flashes + pause
#   rsync failure    -> red, slow blink (legacy led_backup_error)
#   verify failed    -> red/green alternating slow blink
# ---------------------------------------------------------------------------

# Blink a LED a fixed number of times, then pause, repeating for a duration.
# Uses manual brightness toggling (not the kernel "timer" trigger) so we can
# produce a countable N-flash burst the kernel timer can't express.
# Args: $1=led_path  $2=flash_count  $3=duration_seconds
led_blink_pattern() {
	local led_path="$1"
	local flash_count="$2"
	local duration="${3:-60}"

	# No LED hardware at this path -> nothing to do (matches led_set behavior)
	[ -d "$led_path" ] || return 0

	# Take manual control of the LED
	echo "none" > "$led_path/trigger" 2>/dev/null || true

	# Run the blink loop in the background so the caller can exit; the loop
	# self-terminates after $duration to avoid leaving an orphan forever.
	(
		local elapsed=0
		local on_ms=200    # flash on
		local off_ms=200   # gap between flashes within a burst
		local pause_s=2    # pause between bursts, defines the "count" boundary

		while [ "$elapsed" -lt "$duration" ]; do
			local i=0
			while [ "$i" -lt "$flash_count" ]; do
				echo "1" > "$led_path/brightness" 2>/dev/null || true
				sleep 0.2
				echo "0" > "$led_path/brightness" 2>/dev/null || true
				sleep 0.2
				i=$((i + 1))
			done
			sleep "$pause_s"
			# One burst cycle = flash_count*(on+off) + pause
			elapsed=$((elapsed + (flash_count * (on_ms + off_ms)) / 1000 + pause_s))
		done

		# Leave the LED off when finished
		echo "0" > "$led_path/brightness" 2>/dev/null || true
	) &
}

# Device not recognized as SD card / reader (1 flash)
led_err_device_unknown() {
	led_blink_pattern "$LED_RED" 1 60
	log_debug "LED error: device unknown (1 flash)"
}

# Lock acquisition timeout / concurrent backup (2 flashes)
led_err_lock_timeout() {
	led_blink_pattern "$LED_RED" 2 60
	log_debug "LED error: lock timeout (2 flashes)"
}

# Insufficient free space on target (3 flashes)
led_err_no_space() {
	led_blink_pattern "$LED_RED" 3 60
	log_debug "LED error: no space (3 flashes)"
}

# rsync transfer failure (legacy slow red blink)
led_err_rsync() {
	led_backup_error
	log_debug "LED error: rsync failure (slow blink)"
}

# Post-backup integrity verification failed (red/green alternating slow blink)
led_err_verify_failed() {
	# Both LEDs needed; bail gracefully if either is absent
	if [ ! -d "$LED_RED" ] || [ ! -d "$LED_GREEN" ]; then
		# Fall back to generic error so the failure is still visible
		led_backup_error
		return 0
	fi

	echo "none" > "$LED_RED/trigger" 2>/dev/null || true
	echo "none" > "$LED_GREEN/trigger" 2>/dev/null || true

	(
		local elapsed=0
		while [ "$elapsed" -lt 60 ]; do
			echo "1" > "$LED_RED/brightness" 2>/dev/null || true
			echo "0" > "$LED_GREEN/brightness" 2>/dev/null || true
			sleep 0.5
			echo "0" > "$LED_RED/brightness" 2>/dev/null || true
			echo "1" > "$LED_GREEN/brightness" 2>/dev/null || true
			sleep 0.5
			elapsed=$((elapsed + 1))
		done
		echo "0" > "$LED_RED/brightness" 2>/dev/null || true
		echo "0" > "$LED_GREEN/brightness" 2>/dev/null || true
	) &

	log_debug "LED error: verify failed (red/green alternating)"
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

# ---------------------------------------------------------------------------
# status.json writer (issue #7)
#
# WebUI reads /opt/outdoor-backup/var/status.json to render the live progress
# bar, storage gauge and history table. Before this, no writer existed and the
# UI was permanently stuck at "No backup in progress".
#
# Field schema is fixed by the frontend (status.htm) and the developer guide:
#   { version, last_update, storage{root,total_bytes,used_bytes,free_bytes},
#     current_backup{active,uuid,name,device,started_at,progress_percent,
#                    files_total,files_done,bytes_total,bytes_done,
#                    speed_bytes_per_sec},
#     history[ {uuid,name,last_backup_at,status,files_count,bytes_total,
#               backup_path,error_message} ] }
#
# Writes are atomic (temp + mv) like aliases.json. Progress updates are
# throttled by the caller (see backup-manager.sh) so I/O does not scale with
# file count — echoing #6's concern about per-file overhead.
# ---------------------------------------------------------------------------

STATUS_FILE="${STATUS_FILE:-$BASE_DIR/var/status.json}"

# Escape a string for safe embedding inside a JSON double-quoted value.
# Card names come from user input (WebUI alias), so this must handle every
# character JSON forbids unescaped: backslash, double-quote, tab, CR and —
# critically — embedded newlines. An unescaped newline would both break the
# whole status.json parse and split a history.jsonl entry across two physical
# lines, corrupting the one-object-per-line invariant the array join relies on.
json_escape() {
	# Pipeline:
	#  - sed escapes \, " and tab (tab -> \t) line by line.
	#  - tr strips every remaining C0 control byte (0x01-0x08, 0x0b-0x1f),
	#    which JSON forbids unescaped; this also removes CR. Tab (0x09, already
	#    converted) and LF (0x0a, needed as the record separator) are kept.
	#  - awk rejoins the surviving lines with a literal \n and emits no trailing
	#    newline (printf, not print), so embedded newlines become valid \n.
	printf '%s' "$1" \
		| sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' \
		| tr -d '\001-\010\013-\037' \
		| awk 'NR>1 { printf "\\n" } { printf "%s", $0 }'
}

# Collect storage stats for a path into three globals (bytes).
# Args: $1 = path on the target filesystem
# Sets: _ST_TOTAL _ST_USED _ST_FREE (0 if path missing / df unavailable)
status_collect_storage() {
	local path="$1"
	_ST_TOTAL=0
	_ST_USED=0
	_ST_FREE=0

	# df -k is the portable form (POSIX 1k blocks). BusyBox and coreutils agree.
	# Columns: Filesystem 1K-blocks Used Available ...
	local line
	line=$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $2" "$3" "$4}')
	[ -n "$line" ] || return 0

	local total_k used_k free_k
	total_k=$(echo "$line" | awk '{print $1}')
	used_k=$(echo "$line" | awk '{print $2}')
	free_k=$(echo "$line" | awk '{print $3}')

	# Guard against non-numeric df output before arithmetic.
	case "$total_k" in ''|*[!0-9]*) total_k=0 ;; esac
	case "$used_k" in ''|*[!0-9]*) used_k=0 ;; esac
	case "$free_k" in ''|*[!0-9]*) free_k=0 ;; esac

	_ST_TOTAL=$((total_k * 1024))
	_ST_USED=$((used_k * 1024))
	_ST_FREE=$((free_k * 1024))
}

# Write status.json atomically.
#
# Args (all optional, default to current_backup=null when phase=idle):
#   $1  phase        running | completed | failed | idle
#   $2  uuid
#   $3  name         display name (alias or SD_xxxxxxxx)
#   $4  device       e.g. sda1
#   $5  started_at   unix ts of backup start
#   $6  progress     0-100 integer
#   $7  files_total
#   $8  files_done
#   $9  bytes_total
#   $10 bytes_done
#   $11 speed        bytes/sec
#   $12 storage_path path whose df stats feed the storage{} block
#   $13 backup_path  target dir, recorded into history on completed/failed
#   $14 error_message
#
# On completed/failed, appends one history entry (newest first, capped at 20).
# History is preserved across runs by reading the previous file.
write_status() {
	local phase="$1" uuid="$2" name="$3" device="$4" started_at="$5"
	local progress="$6" files_total="$7" files_done="$8"
	local bytes_total="$9" bytes_done="${10}" speed="${11}"
	local storage_path="${12}" backup_path="${13}" error_message="${14}"

	local now temp
	now=$(date +%s)
	temp="${STATUS_FILE}.tmp.$$"
	mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || true

	# Storage block (best-effort; zeros if path unavailable)
	status_collect_storage "${storage_path:-/}"

	# current_backup is an object while running, JSON null otherwise.
	local current_json="null"
	if [ "$phase" = "running" ]; then
		current_json=$(cat << EOF
{
      "active": true,
      "uuid": "$(json_escape "$uuid")",
      "name": "$(json_escape "$name")",
      "device": "$(json_escape "$device")",
      "started_at": ${started_at:-$now},
      "progress_percent": ${progress:-0},
      "files_total": ${files_total:-0},
      "files_done": ${files_done:-0},
      "bytes_total": ${bytes_total:-0},
      "bytes_done": ${bytes_done:-0},
      "speed_bytes_per_sec": ${speed:-0}
    }
EOF
)
	fi

	# Build the history array: new entry (if terminal phase) + carried-over.
	local history_json
	history_json=$(status_build_history "$phase" "$uuid" "$name" \
		"$files_done" "$bytes_done" "$backup_path" "$error_message" "$now")

	# Assemble and write atomically.
	cat > "$temp" << EOF
{
  "version": "1.0",
  "last_update": ${now},
  "storage": {
    "root": "$(json_escape "${storage_path:-/}")",
    "total_bytes": ${_ST_TOTAL},
    "used_bytes": ${_ST_USED},
    "free_bytes": ${_ST_FREE}
  },
  "current_backup": ${current_json},
  "history": ${history_json}
}
EOF

	mv "$temp" "$STATUS_FILE" 2>/dev/null || {
		rm -f "$temp"
		return 1
	}
	return 0
}

# Maintain backup history and emit it as a JSON array string.
#
# History is persisted as newline-delimited compact JSON (one object per line)
# in var/history.jsonl — newest first. This keeps dedup-by-UUID and the size
# cap as trivial line operations instead of fragile nested-JSON parsing.
# The frontend table shows one row per card, so the latest entry for a UUID
# replaces older ones rather than accumulating duplicate rows.
#
# Args: $1 phase  $2 uuid  $3 name  $4 files_count  $5 bytes_total
#       $6 backup_path  $7 error_message  $8 now
# Returns: a JSON array (stdout), e.g. [ {...}, {...} ]
status_build_history() {
	local phase="$1" uuid="$2" name="$3" files_count="$4" bytes_total="$5"
	local backup_path="$6" error_message="$7" now="$8"
	local hist_file
	hist_file="$(dirname "$STATUS_FILE")/history.jsonl"
	local max_entries=20

	# On terminal phases, prepend a fresh entry for this card.
	if [ "$phase" = "completed" ] || [ "$phase" = "failed" ]; then
		local status_val="completed"
		[ "$phase" = "failed" ] && status_val="error"

		# error_message is JSON null unless a message was provided.
		local err_json="null"
		[ -n "$error_message" ] && err_json="\"$(json_escape "$error_message")\""

		local entry
		entry=$(printf '{"uuid": "%s", "name": "%s", "last_backup_at": %s, "status": "%s", "files_count": %s, "bytes_total": %s, "backup_path": "%s", "error_message": %s}' \
			"$(json_escape "$uuid")" "$(json_escape "$name")" "${now}" \
			"$status_val" "${files_count:-0}" "${bytes_total:-0}" \
			"$(json_escape "$backup_path")" "$err_json")

		local tmp_hist="${hist_file}.tmp.$$"
		mkdir -p "$(dirname "$hist_file")" 2>/dev/null || true
		{
			printf '%s\n' "$entry"
			# Carry over previous entries, dropping any for the same UUID,
			# keeping at most max_entries-1 of them (newest first). The grep is
			# anchored to the line start ('{"uuid": "<uuid>"') so a card whose
			# name merely contains another card's uuid text can't be deleted.
			if [ -f "$hist_file" ]; then
				grep -v "^{\"uuid\": \"$uuid\"" "$hist_file" 2>/dev/null \
					| head -n $((max_entries - 1))
			fi
		} > "$tmp_hist"
		mv "$tmp_hist" "$hist_file" 2>/dev/null || rm -f "$tmp_hist"
	fi

	# Emit the array. Empty / missing file -> [].
	if [ ! -s "$hist_file" ]; then
		printf '[]'
		return 0
	fi

	# Join lines with commas into a JSON array.
	awk 'BEGIN { printf "[" }
	     NF { if (n++) printf ","; printf "\n    %s", $0 }
	     END { if (n) printf "\n  "; printf "]" }' "$hist_file"
}




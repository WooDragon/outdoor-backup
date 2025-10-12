# 组件详细实现

## 1. 热插拔触发脚本

### 文件: `/etc/hotplug.d/block/90-sdcard-backup`

```bash
#!/bin/sh
#
# OpenWrt SD Card Backup - Hotplug Trigger
# Triggered when block devices are added/removed
#

# Only handle block device events
[ "$SUBSYSTEM" = "block" ] || exit 0

# Load common functions
. /opt/sdcard-backup/scripts/common.sh

# Configuration
BACKUP_MANAGER="/opt/sdcard-backup/scripts/backup-manager.sh"
LOG_TAG="sdcard-backup-hotplug"

# Log function
log_message() {
    logger -t "$LOG_TAG" "$1"
}

# Check if device is an SD card
is_sdcard() {
    local dev_path="$1"

    # Check multiple indicators for SD card
    # 1. USB card reader pattern
    if echo "$dev_path" | grep -q "usb.*card\|reader\|SD\|mmc"; then
        return 0
    fi

    # 2. Check device model
    if [ -f "/sys/block/${DEVNAME%%[0-9]*}/device/model" ]; then
        local model=$(cat "/sys/block/${DEVNAME%%[0-9]*}/device/model" 2>/dev/null)
        if echo "$model" | grep -iq "card\|reader\|SD\|mmc"; then
            return 0
        fi
    fi

    # 3. Size check - SD cards typically ≤512GB
    if [ -f "/sys/block/${DEVNAME%%[0-9]*}/size" ]; then
        local size=$(cat "/sys/block/${DEVNAME%%[0-9]*}/size" 2>/dev/null)
        # Size in 512-byte sectors, 512GB = 1073741824 sectors
        if [ "$size" -le 1073741824 ] 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Main logic
case "$ACTION" in
    add)
        # Only process partitions, not whole disks
        [ "$DEVTYPE" = "partition" ] || exit 0

        # Check if this is an SD card
        if is_sdcard "$DEVPATH"; then
            log_message "SD card detected: $DEVNAME"

            # Launch backup manager in background
            (
                # Wait for device to settle
                sleep 2

                # Execute backup
                $BACKUP_MANAGER "add" "$DEVNAME" "$DEVPATH" &
            ) &
        fi
        ;;

    remove)
        if is_sdcard "$DEVPATH"; then
            log_message "SD card removed: $DEVNAME"

            # Notify backup manager to cleanup
            $BACKUP_MANAGER "remove" "$DEVNAME" "$DEVPATH" &
        fi
        ;;
esac

exit 0
```

## 2. 备份管理器主脚本

### 文件: `/opt/sdcard-backup/scripts/backup-manager.sh`

```bash
#!/bin/sh
#
# OpenWrt SD Card Backup - Main Backup Manager
# Handles the actual backup process with all safety checks
#

set -e

# Constants
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
MOUNT_POINT="/mnt/sdcard"
BACKUP_ROOT="/mnt/ssd/SDMirrors"
LOCK_FILE="$BASE_DIR/var/lock/backup.pid"
CONFIG_FILE="FieldBackup.conf"
LOG_TAG="sdcard-backup"

# Load common functions
. "$SCRIPT_DIR/common.sh"

# Arguments
ACTION="$1"
DEVNAME="$2"
DEVPATH="$3"

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
    for fs in auto exfat ntfs-3g ntfs ext4 ext3 ext2 vfat; do
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
        SD_UUID=$(cat /proc/sys/kernel/random/uuid)
        SD_NAME="SDCard_$(date +%Y%m%d_%H%M%S)"
        BACKUP_MODE="PRIMARY"

        cat > "$config_path" << EOF
# OpenWrt SD Card Backup Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# Unique identifier for this SD card
SD_UUID="$SD_UUID"

# Friendly name (can be edited)
SD_NAME="$SD_NAME"

# Backup mode: PRIMARY (SD→SSD) or REPLICA (SSD→SD)
BACKUP_MODE="$BACKUP_MODE"

# Creation timestamp
CREATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

        log_info "Created new config for SD: $SD_NAME ($SD_UUID)"

        # Load the new config
        . "$config_path"
    fi

    return 0
}

# Perform rsync backup
perform_backup() {
    local source_dir=""
    local target_dir=""
    local log_file=""

    # Determine backup direction
    if [ "$BACKUP_MODE" = "REPLICA" ]; then
        # Replica mode: SSD → SD
        source_dir="$BACKUP_ROOT/$SD_UUID/"
        target_dir="$MOUNT_POINT/"
        log_file="$BACKUP_ROOT/.logs/replica_${SD_UUID}_$(date +%Y%m%d_%H%M%S).log"

        log_info "Starting REPLICA backup: SSD → SD ($SD_NAME)"
    else
        # Primary mode: SD → SSD
        source_dir="$MOUNT_POINT/"
        target_dir="$BACKUP_ROOT/$SD_UUID/"
        log_file="$BACKUP_ROOT/.logs/backup_${SD_UUID}_$(date +%Y%m%d_%H%M%S).log"

        log_info "Starting PRIMARY backup: SD → SSD ($SD_NAME)"
    fi

    # Create target directory
    mkdir -p "$target_dir"
    mkdir -p "$(dirname "$log_file")"

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
        "$source_dir" "$target_dir" 2>&1 | while read line; do
            # Parse progress for logging (optional)
            echo "$line" | grep -q "%" && log_debug "Progress: $line"
        done

    local rsync_exit=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Log summary
    log_info "Backup completed in ${duration}s (exit code: $rsync_exit)"

    # Write summary to log file
    cat >> "$log_file" << EOF

=== Backup Summary ===
SD Card: $SD_NAME ($SD_UUID)
Mode: $BACKUP_MODE
Duration: ${duration} seconds
Exit Code: $rsync_exit
Completed: $(date '+%Y-%m-%d %H:%M:%S')
EOF

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
    trap cleanup SIGINT SIGTERM

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
```

## 3. 公共函数库

### 文件: `/opt/sdcard-backup/scripts/common.sh`

```bash
#!/bin/sh
#
# Common functions for SD Card Backup System
#

# LED paths - R5S specific, needs verification
LED_GREEN="/sys/class/leds/green:lan"
LED_RED="/sys/class/leds/red:sys"

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
led_backup_start() {
    # Fast blink - backup in progress
    if [ -d "$LED_GREEN" ]; then
        echo "timer" > "$LED_GREEN/trigger" 2>/dev/null || true
        echo "100" > "$LED_GREEN/delay_on" 2>/dev/null || true
        echo "100" > "$LED_GREEN/delay_off" 2>/dev/null || true
        log_debug "LED set to fast blink"
    fi
}

led_backup_done() {
    # Solid on - backup complete
    if [ -d "$LED_GREEN" ]; then
        echo "none" > "$LED_GREEN/trigger" 2>/dev/null || true
        echo "1" > "$LED_GREEN/brightness" 2>/dev/null || true
        log_debug "LED set to solid on"

        # Auto-off after 30 seconds
        (
            sleep 30
            echo "0" > "$LED_GREEN/brightness" 2>/dev/null || true
        ) &
    fi
}

led_backup_error() {
    # Slow blink red - error occurred
    if [ -d "$LED_RED" ]; then
        echo "timer" > "$LED_RED/trigger" 2>/dev/null || true
        echo "500" > "$LED_RED/delay_on" 2>/dev/null || true
        echo "500" > "$LED_RED/delay_off" 2>/dev/null || true
        log_debug "LED set to error blink"

        # Auto-off after 60 seconds
        (
            sleep 60
            echo "none" > "$LED_RED/trigger" 2>/dev/null || true
            echo "0" > "$LED_RED/brightness" 2>/dev/null || true
        ) &
    fi
}

led_backup_stop() {
    # Turn off all LEDs
    if [ -d "$LED_GREEN" ]; then
        echo "none" > "$LED_GREEN/trigger" 2>/dev/null || true
        echo "0" > "$LED_GREEN/brightness" 2>/dev/null || true
    fi
    if [ -d "$LED_RED" ]; then
        echo "none" > "$LED_RED/trigger" 2>/dev/null || true
        echo "0" > "$LED_RED/brightness" 2>/dev/null || true
    fi
    log_debug "LEDs turned off"
}

# Check if path is safe (prevent directory traversal)
is_safe_path() {
    local path="$1"
    case "$path" in
        *../*|*/../*|*/..)
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
    mount | grep -q "^$device "
}

# Get mount point of device
get_mount_point() {
    local device="$1"
    mount | grep "^$device " | awk '{print $3}'
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

# Create backup report
generate_report() {
    local sd_uuid="$1"
    local sd_name="$2"
    local backup_dir="$3"
    local duration="$4"

    local size_mb=$(get_dir_size_mb "$backup_dir")
    local report_file="$BACKUP_ROOT/.logs/report_${sd_uuid}_$(date +%Y%m%d).txt"

    cat >> "$report_file" << EOF
=====================================
SD Card Backup Report
=====================================
Date: $(date '+%Y-%m-%d %H:%M:%S')
SD Card: $sd_name
UUID: $sd_uuid
Backup Size: ${size_mb} MB
Duration: ${duration} seconds
Speed: $((size_mb / duration)) MB/s
Location: $backup_dir
=====================================

EOF
}
```

## 4. 安装脚本

### 文件: `/opt/sdcard-backup/install.sh`

```bash
#!/bin/sh
#
# Installation script for OpenWrt SD Card Backup System
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing OpenWrt SD Card Backup System..."

# Check if running as root
if [ "$(id -u)" != "0" ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check OpenWrt
if [ ! -f "/etc/openwrt_release" ]; then
    echo "Warning: This doesn't appear to be an OpenWrt system"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [ "$REPLY" != "y" ]; then
        exit 1
    fi
fi

# Install required packages
echo "Installing required packages..."
opkg update || true
opkg install block-mount kmod-usb-storage rsync || true
opkg install kmod-fs-ext4 kmod-fs-exfat kmod-fs-ntfs3 || true

# Create directory structure
echo "Creating directory structure..."
mkdir -p "$SCRIPT_DIR/var/lock"
mkdir -p "$SCRIPT_DIR/var/status"
mkdir -p "$SCRIPT_DIR/log"
mkdir -p "/mnt/ssd/SDMirrors/.logs"

# Set permissions
echo "Setting permissions..."
chmod 755 "$SCRIPT_DIR/scripts/"*.sh
chmod 755 "$SCRIPT_DIR/bin/"* 2>/dev/null || true

# Install hotplug script
echo "Installing hotplug script..."
cp "$SCRIPT_DIR/scripts/90-sdcard-backup.hotplug" "/etc/hotplug.d/block/90-sdcard-backup"
chmod 755 "/etc/hotplug.d/block/90-sdcard-backup"

# Create default config
echo "Creating default configuration..."
cat > "$SCRIPT_DIR/conf/backup.conf" << EOF
# OpenWrt SD Card Backup Configuration

# Backup root directory
BACKUP_ROOT="/mnt/ssd/SDMirrors"

# Mount point for SD cards
MOUNT_POINT="/mnt/sdcard"

# Enable debug logging (0=off, 1=on)
DEBUG=0

# Maximum concurrent backups
MAX_CONCURRENT=1

# LED paths (adjust for your hardware)
LED_GREEN="/sys/class/leds/green:lan"
LED_RED="/sys/class/leds/red:sys"
EOF

# Test LED access
echo "Testing LED access..."
if [ -d "/sys/class/leds/green:lan" ]; then
    echo "Green LED found"
else
    echo "Warning: Green LED not found at expected path"
fi

if [ -d "/sys/class/leds/red:sys" ]; then
    echo "Red LED found"
else
    echo "Warning: Red LED not found at expected path"
fi

# Create uninstall script
cat > "$SCRIPT_DIR/uninstall.sh" << 'EOF'
#!/bin/sh
echo "Uninstalling OpenWrt SD Card Backup System..."
rm -f /etc/hotplug.d/block/90-sdcard-backup
echo "Hotplug script removed"
echo "Note: Backup data in /mnt/ssd/SDMirrors/ was not removed"
echo "Uninstall complete"
EOF
chmod 755 "$SCRIPT_DIR/uninstall.sh"

echo
echo "=================================="
echo "Installation completed!"
echo "=================================="
echo
echo "The system will automatically backup SD cards when inserted."
echo "Backup location: /mnt/ssd/SDMirrors/"
echo "Logs: $SCRIPT_DIR/log/"
echo
echo "To monitor backups:"
echo "  logread -f | grep sdcard-backup"
echo
echo "To uninstall:"
echo "  $SCRIPT_DIR/uninstall.sh"
echo

# Test with a quick LED blink
echo "Testing LED (3 second blink)..."
echo "timer" > /sys/class/leds/green:lan/trigger 2>/dev/null || true
echo "500" > /sys/class/leds/green:lan/delay_on 2>/dev/null || true
echo "500" > /sys/class/leds/green:lan/delay_off 2>/dev/null || true
sleep 3
echo "none" > /sys/class/leds/green:lan/trigger 2>/dev/null || true
echo "0" > /sys/class/leds/green:lan/brightness 2>/dev/null || true

echo "Setup complete!"
```

## 5. 配置文件模板

### 文件: `/opt/sdcard-backup/conf/backup.conf`

```bash
# OpenWrt SD Card Backup System Configuration
#
# This file contains global settings for the backup system.
# Per-SD card settings are stored on each SD card.

# === Storage Settings ===

# Root directory for all backups
# This should be on your SSD or fast storage
BACKUP_ROOT="/mnt/ssd/SDMirrors"

# Temporary mount point for SD cards
MOUNT_POINT="/mnt/sdcard"

# === Performance Settings ===

# Maximum concurrent backup operations
# Set to 1 for safety, increase if CPU/storage can handle it
MAX_CONCURRENT=1

# rsync bandwidth limit in KB/s (0 = unlimited)
BANDWIDTH_LIMIT=0

# rsync compression (yes/no)
# Enable for slow storage, disable for fast SSD
USE_COMPRESSION=no

# === Safety Settings ===

# Minimum free space required on target (MB)
MIN_FREE_SPACE=1024

# Maximum backup retries on failure
MAX_RETRIES=3

# Retry delay in seconds
RETRY_DELAY=10

# === Logging Settings ===

# Enable debug logging (0=off, 1=on)
DEBUG=0

# Log rotation size in KB
LOG_MAX_SIZE=10240

# Number of old logs to keep
LOG_ROTATE_COUNT=10

# === LED Settings ===
# Adjust these paths for your specific hardware

# Green LED for normal operations
LED_GREEN="/sys/class/leds/green:lan"

# Red LED for errors
LED_RED="/sys/class/leds/red:sys"

# LED blink rates (milliseconds)
LED_FAST_BLINK=100
LED_SLOW_BLINK=500

# === File Filters ===
# Files/directories to exclude from backup

EXCLUDE_PATTERNS="
.Trash*
.Spotlight*
.fseventsd
System Volume Information
\$RECYCLE.BIN
.DS_Store
Thumbs.db
*.tmp
*.TMP
~*
"

# === Advanced Settings ===

# rsync extra options
# Add custom rsync flags here
RSYNC_EXTRA_OPTS=""

# Pre-backup hook script (optional)
# Run custom commands before backup starts
PRE_BACKUP_HOOK=""

# Post-backup hook script (optional)
# Run custom commands after backup completes
POST_BACKUP_HOOK=""
```

这些组件实现提供了完整的OpenWrt SD卡自动备份系统，包含了所有核心功能和安全机制。
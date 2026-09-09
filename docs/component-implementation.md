# 组件详细实现

## 1. 热插拔触发脚本

### 文件: `/etc/hotplug.d/block/90-outdoor-backup`

```bash
#!/bin/sh
#
# OpenWrt SD Card Backup - Hotplug Trigger
# Triggered when block devices are added/removed
#

# Only handle block device events
[ "$SUBSYSTEM" = "block" ] || exit 0

# Load common functions
. /opt/outdoor-backup/scripts/common.sh

# Configuration
BACKUP_MANAGER="/opt/outdoor-backup/scripts/backup-manager.sh"
LOG_TAG="outdoor-backup-hotplug"

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

### 文件：`/opt/outdoor-backup/scripts/backup-manager.sh`

管理器先由 [`config.sh`](../files/opt/outdoor-backup/scripts/config.sh) 加载有效配置。有效值的顺序是 defaults < legacy `backup.conf` < 显式 UCI option。`TARGET_MOUNT` 的默认值为 `/mnt/ssd`，`TARGET_UUID` 的默认值为空。`add` 事件要求用户配置非空的目标 UUID；`remove` 事件不依赖目标介质在场，仍进入清理路径。

目标守卫在加载 `common.sh`、注册 cleanup trap、操作 LED 或锁、挂载来源卡、读取别名和创建应用日志之前运行。管理器按以下顺序调用当前实现：

1. [`target.sh`](../files/opt/outdoor-backup/scripts/target.sh) 以 FD 9 打开目标挂载，要求配置路径本身不是符号链接、目录存在、挂载记录精确匹配该路径，并同时具有 VFS 与文件系统级 `rw` 选项。
2. [`target-device.sh`](../files/opt/outdoor-backup/scripts/target-device.sh) 校验官方 `block info` 返回的 UUID，并用 sysfs 证明目标、来源卡和系统 backing disk 的物理盘不同。它接受 direct `sd`、`mmc`、`nvme`，只为明确指向 `/dev/` 分区的 R5S 系统 loop 追溯 backing；unknown、file-backed loop、`dm` 与 `md` 均失败关闭。它解析 `block info` 的整条键值 token；`LABEL` 值内的同形文本不算 UUID，畸形引号会被拒绝。
3. `target_prepare_root` 要求 `BACKUP_ROOT` 是目标挂载的严格子目录，并经 `/proc/<manager-pid>/fd/9` 创建目录。既有符号链接组件，包括 `.logs`，会被拒绝。守卫拒绝覆盖目标挂载点、`BACKUP_ROOT` 祖先或备份树内子挂载；不相交目录的挂载不会被误拒。

守卫失败时向 stderr 和 syslog 报错，然后在应用资源操作前退出。守卫成功后，目标目录和日志都经 FD 9 引用。管理器在目标准备、`rsync` 前、`rsync` 后及末尾的设备复验中检查锚点。目标卸载、替换或只读重挂载不应产生成功结果。日志摘要写入失败，以及摘要后的 detached 或只读复检失败，均返回非零。

静态符号链接检查不是 `openat2`。恶意 root 并发替换目标目录不在此 shell 实现的保证范围内。来源卡配置仍可执行，REPLICA 方向的语义尚未随 #14b 改动，将由 #15 处理。现有 rsync 管道的整体退出码处理仍属 PR9 范围；本文档不声称所有 `ENOSPC` 均被正确报告，也不声称实现完全安全。

> **前置阅读**：目标存储的可执行配置、重试方法和用户可见限制，修改部署或运维行为前必须先读取：[README.md 的 Configuration 章节](../README.md#configuration)。

运行时细节以 [`backup-manager.sh`](../files/opt/outdoor-backup/scripts/backup-manager.sh)、[`target.sh`](../files/opt/outdoor-backup/scripts/target.sh) 和 [`target-device.sh`](../files/opt/outdoor-backup/scripts/target-device.sh) 为单一事实源；本文档不复制生产算法。

## 3. 公共函数库

### 文件: `/opt/outdoor-backup/scripts/common.sh`

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

### 文件: `/opt/outdoor-backup/install.sh`

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

# Set permissions
echo "Setting permissions..."
chmod 755 "$SCRIPT_DIR/scripts/"*.sh
chmod 755 "$SCRIPT_DIR/bin/"* 2>/dev/null || true

# Install hotplug script
echo "Installing hotplug script..."
cp "$SCRIPT_DIR/scripts/90-outdoor-backup.hotplug" "/etc/hotplug.d/block/90-outdoor-backup"
chmod 755 "/etc/hotplug.d/block/90-outdoor-backup"

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
rm -f /etc/hotplug.d/block/90-outdoor-backup
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
echo "  logread -f | grep outdoor-backup"
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

### 文件: `/opt/outdoor-backup/conf/backup.conf`

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
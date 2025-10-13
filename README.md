# Outdoor Backup - OpenWrt SD Card Backup System

Automatic SD card backup system for OpenWrt routers with internal storage (SSD/HDD). Designed for devices like NanoPi R5S running OpenWrt (including Lean's LEDE fork).

**Outdoor Backup** 是为户外摄影、航拍、数据采集等场景设计的 OpenWrt IPK 包，实现 SD 卡插入即自动备份到路由器内置存储。

## Features

- ✅ **Automatic Backup**: Hotplug-triggered backup on SD card insertion
- ✅ **Incremental Sync**: rsync with `--ignore-existing` for safety
- ✅ **LED Indicators**: Visual feedback for backup status
- ✅ **Concurrent Protection**: PID-based locking prevents conflicts
- ✅ **Multi-Filesystem**: Supports ext4, exFAT, NTFS, FAT32
- ✅ **Bidirectional**: Primary (SD→Storage) and Replica (Storage→SD) modes
- ✅ **Production Ready**: POSIX-compliant shell, fully error-handled

## Quick Start

### Prerequisites

- OpenWrt 19.07+ (tested on Lean's LEDE)
- Internal storage mounted at `/mnt/ssd/`
- USB port for SD card reader
- Required kernel modules (auto-installed with package):
  - `kmod-usb-storage`
  - `kmod-fs-ext4`, `kmod-fs-exfat`, `kmod-fs-ntfs3`

### Installation

#### Method 1: Build from Source (Recommended for Lean's LEDE)

```bash
# 1. Clone into OpenWrt package feeds
cd ~/lede/package
git clone https://github.com/your-repo/outdoor-backup.git

# 2. Update feeds
cd ~/lede
./scripts/feeds update -a
./scripts/feeds install -a

# 3. Configure package
make menuconfig
# Navigate to: Utilities -> outdoor-backup
# Press Y to select

# 4. Build package
make package/outdoor-backup/compile V=s

# 5. Install on device
cd bin/packages/*/base/
scp outdoor-backup_*.ipk root@router:/tmp/
ssh root@router "opkg install /tmp/outdoor-backup_*.ipk"
```

#### Method 2: Direct IPK Installation

```bash
# If you have a pre-built .ipk file
scp outdoor-backup_*.ipk root@router:/tmp/
ssh root@router "opkg install /tmp/outdoor-backup_*.ipk"
```

### First Run

1. **Insert SD card** - The system automatically:
   - Detects the card via hotplug
   - Creates `FieldBackup.conf` on the card
   - Starts rsync backup to `/mnt/ssd/SDMirrors/{UUID}/`
   - Shows LED status

2. **Monitor progress**:
   ```bash
   # Watch system logs
   logread -f | grep outdoor-backup

   # Check backup status
   ls -lh /mnt/ssd/SDMirrors/

   # View detailed logs
   tail -f /opt/outdoor-backup/log/backup.log
   ```

## Configuration

### Option 1: Simple Config File

Edit `/opt/outdoor-backup/conf/backup.conf`:

```bash
# Change backup location
BACKUP_ROOT="/mnt/ssd/SDMirrors"

# Enable debug logging
DEBUG=1

# Adjust LED paths for your hardware
LED_GREEN="/sys/class/leds/green:lan"
LED_RED="/sys/class/leds/red:sys"
```

### Option 2: UCI (OpenWrt Style)

```bash
# Edit via UCI
uci set outdoor-backup.config.backup_root='/mnt/nvme/backups'
uci set outdoor-backup.config.debug='1'
uci commit outdoor-backup
```

### Per-SD Card Configuration

Each SD card gets a `FieldBackup.conf` file:

```bash
# Automatically generated on first insertion
SD_UUID="550e8400-e29b-41d4-a716-446655440000"
SD_NAME="Canon_5D4_Card1"           # Edit this to rename
BACKUP_MODE="PRIMARY"                # PRIMARY or REPLICA
CREATED_AT="2024-01-15 10:30:00"
```

**Modes**:
- `PRIMARY`: SD → Internal Storage (default)
- `REPLICA`: Internal Storage → SD (for restoring backups)

## Package Structure

```
outdoor-backup/
├── Makefile                          # OpenWrt package definition
├── files/                            # Files to install
│   ├── opt/outdoor-backup/
│   │   ├── scripts/
│   │   │   ├── backup-manager.sh    # Core backup logic
│   │   │   └── common.sh            # Shared functions
│   │   ├── conf/
│   │   │   └── backup.conf          # Global config
│   │   ├── var/lock/                # PID lock directory
│   │   └── log/                     # Log files
│   └── etc/
│       ├── hotplug.d/block/90-outdoor-backup  # Hotplug trigger
│       ├── init.d/outdoor-backup              # Service script
│       └── config/outdoor-backup              # UCI config
├── docs/                             # Design documentation
├── README.md                         # User manual
├── BUILD.md                          # Build guide
└── IPK_PACKAGING.md                  # Packaging guide
```

## Building the IPK

### Build Variables in Makefile

| Variable | Description |
|----------|-------------|
| `PKG_NAME` | Package name: `outdoor-backup` |
| `PKG_VERSION` | Version number (increment on changes) |
| `PKG_RELEASE` | Build number (increment on Makefile changes) |
| `DEPENDS` | Auto-installs: rsync, block-mount, filesystem modules |

### Build Commands

```bash
# Clean build
make package/outdoor-backup/clean

# Compile with verbose output
make package/outdoor-backup/compile V=s

# Find built package
find bin/ -name "outdoor-backup*.ipk"
```

### Customization Points

1. **LED Paths**: Edit `files/opt/outdoor-backup/conf/backup.conf`
2. **Mount Point**: Change `BACKUP_ROOT` in config
3. **Hotplug Priority**: Rename `90-outdoor-backup` (higher number = later execution)
4. **Dependencies**: Add to `DEPENDS` in Makefile

## Maintenance

### Service Management

```bash
# Enable/disable service
/etc/init.d/outdoor-backup enable
/etc/init.d/outdoor-backup disable

# Start/stop (primarily controls directory setup)
/etc/init.d/outdoor-backup start
/etc/init.d/outdoor-backup stop

# Reload configuration
/etc/init.d/outdoor-backup reload
```

### Troubleshooting

**SD card not detected?**
```bash
# Check hotplug events
logread -f | grep hotplug

# Verify device enumeration
ls -l /dev/sd*

# Test hotplug script manually
SUBSYSTEM=block ACTION=add DEVNAME=sda1 DEVTYPE=partition \
  /etc/hotplug.d/block/90-outdoor-backup
```

**Backup not starting?**
```bash
# Check lock file
cat /opt/outdoor-backup/var/lock/backup.pid
ps | grep $(cat /opt/outdoor-backup/var/lock/backup.pid)

# Remove stale lock
rm /opt/outdoor-backup/var/lock/backup.pid

# Check rsync
which rsync
rsync --version
```

**LED not working?**
```bash
# Find correct LED paths
ls /sys/class/leds/

# Test LED manually
echo "timer" > /sys/class/leds/green:lan/trigger
echo "100" > /sys/class/leds/green:lan/delay_on
echo "100" > /sys/class/leds/green:lan/delay_off
```

### Logs

| Location | Content |
|----------|---------|
| `logread` | System-wide backup events |
| `/opt/outdoor-backup/log/backup.log` | Detailed backup log |
| `/mnt/ssd/SDMirrors/.logs/` | Per-backup rsync logs |

### Uninstallation

```bash
# Remove package (preserves backup data)
opkg remove outdoor-backup

# Cleanup backup data (if desired)
rm -rf /mnt/ssd/SDMirrors/
```

## Development

### Testing Without Installation

```bash
# Copy scripts to device
scp -r files/opt/outdoor-backup root@router:/tmp/

# Run manually
ssh root@router "/tmp/outdoor-backup/scripts/backup-manager.sh add sda1 /devices/platform/usb"
```

### Debugging

```bash
# Enable debug mode
uci set outdoor-backup.config.debug='1'
uci commit

# Or edit config file
echo 'DEBUG=1' >> /opt/outdoor-backup/conf/backup.conf

# Watch debug logs
logread -f | grep outdoor-backup
```

### Shellcheck Validation

```bash
# Lint all scripts (POSIX mode for ash shell)
find files/ -name "*.sh" -exec shellcheck --shell=sh {} +
```

## Performance

Expected performance on NanoPi R5S (4-core ARM, SATA SSD):

| Data Size | Time | Speed |
|-----------|------|-------|
| 10GB | ~1 min | ~170 MB/s |
| 50GB | ~5 min | ~170 MB/s |
| 100GB | ~10 min | ~170 MB/s |

*Performance depends on SD card speed, filesystem, and file count.*

## Compatibility

- **OpenWrt Versions**: 19.07, 21.02, 22.03, 23.05, Lean's LEDE
- **Architectures**: ARM (primary), MIPS, x86_64
- **Devices Tested**:
  - NanoPi R5S (ARM64)
  - Other devices with internal storage

## WebUI Management Interface

### Overview

A LuCI-based web interface for visual monitoring and management of the backup system.

**Features**:
- Real-time backup progress monitoring (progress bar, file count, speed, ETA)
- Storage space visualization (pie chart, usage percentage)
- Backup history viewer
- SD card alias management (solve UUID readability issue)
- Batch cleanup with multi-step confirmation
- Log viewing and filtering

### Installation

```bash
# Install WebUI package (requires outdoor-backup core package)
opkg install luci-app-outdoor-backup_*.ipk
```

### Access

After installation, access the WebUI at:

```
http://192.168.1.1/cgi-bin/luci/admin/services/outdoor-backup
```

**Navigation**: `LuCI Home → Services → Outdoor Backup`

### Key Features

#### 1. Status Monitoring
- Current backup progress with real-time updates
- Storage usage bar (color-coded: green → yellow → red)
- Backup history table with status badges

#### 2. Alias Management
- Give SD cards human-readable names (e.g., "Canon_5D4_Card1")
- Solve UUID readability problem (from `SD_550e8400` to custom names)
- Add notes for each card
- Alias mapping preserved after batch cleanup

#### 3. Batch Cleanup
Clear all backup data after backing up to NAS, with multi-layer protection:

**Safety Mechanisms**:
1. Preview dialog (shows cards and sizes)
2. Confirmation text input (must type "清空备份数据")
3. Checkbox confirmation ("I have backed up to NAS")
4. Button disabled until all conditions met
5. Shell script safety check (`--force` flag)

**Preserved Data**:
- Alias mappings (`aliases.json`)
- Configuration files
- Log files

#### 4. Log Viewing
- Last 100 lines with color highlighting
- Log level filtering (ERROR/WARN/INFO/DEBUG)
- Auto-refresh option (10 seconds)
- Download full log

### Quick Start

**Set SD Card Alias**:
1. Insert SD card and wait for backup completion
2. Access Status page
3. Click "Edit" in backup history table
4. Enter alias (e.g., "Canon_5D4_Card1") and notes
5. Click "Save Alias"
6. Next insertion will automatically show alias

**Batch Cleanup**:
1. Click "⚠️ Batch Cleanup..." button at bottom of Status page
2. Review preview dialog (cards, sizes)
3. Click "Next Step"
4. Type "清空备份数据" in input box
5. Check "I have backed up to NAS"
6. Click "Confirm Cleanup"
7. Wait for completion (auto-refresh)

### Documentation

- **[docs/WEBUI_USER_GUIDE.md](docs/WEBUI_USER_GUIDE.md)** - User Manual
  - Feature overview and screenshots
  - Step-by-step usage guide
  - Alias management workflow
  - Batch cleanup safety measures
  - Troubleshooting tips

- **[docs/WEBUI_DEVELOPER_GUIDE.md](docs/WEBUI_DEVELOPER_GUIDE.md)** - Developer Guide
  - Architecture overview
  - API documentation (6 endpoints)
  - Data structure specifications (status.json, aliases.json)
  - Development workflow and code standards
  - Security mechanisms (XSS, command injection, file locking)
  - Known limitations and future improvements

- **[docs/webui-design.md](docs/webui-design.md)** - Design Document
  - UI wireframes
  - Data structure design
  - LuCI implementation details

### Technical Stack

| Component | Technology |
|-----------|------------|
| Backend | Lua 5.1, LuCI Framework |
| Frontend | HTML5/CSS3, JavaScript (ES5, no framework) |
| Data Format | JSON (status.json, aliases.json) |
| Configuration | UCI (OpenWrt config system) |

### Browser Compatibility

| Browser | Support |
|---------|---------|
| Chrome 80+ | ✅ Fully supported (Recommended) |
| Firefox 75+ | ✅ Fully supported (Recommended) |
| Safari 13+ | ✅ Supported |
| Edge 80+ | ✅ Supported |
| IE 11 | ❌ Not supported |

---

## Documentation

- [BUILD.md](BUILD.md) - 构建指南（Lean's LEDE）
- [IPK_PACKAGING.md](IPK_PACKAGING.md) - IPK 打包原理详解
- [CLAUDE.md](CLAUDE.md) - 项目技术文档（Claude Code 使用）
- [docs/](docs/) - 架构设计和组件实现文档
  - [webui-design.md](docs/webui-design.md) - WebUI 设计文档
  - [WEBUI_USER_GUIDE.md](docs/WEBUI_USER_GUIDE.md) - WebUI 用户手册
  - [WEBUI_DEVELOPER_GUIDE.md](docs/WEBUI_DEVELOPER_GUIDE.md) - WebUI 开发者文档

## License

GPL-2.0-only (compatible with OpenWrt licensing)

## Contributing

1. Test on your hardware
2. Report LED paths for your device model
3. Submit improvements via pull request
4. Add device-specific configurations

## Related Projects

- Original: [FieldBackup](https://github.com/xyu/FieldBackup) - RAVPower FileHub version
- OpenWrt Docs: [Package Development](https://openwrt.org/docs/guide-developer/packages)

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

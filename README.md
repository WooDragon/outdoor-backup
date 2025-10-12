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

## Documentation

- [BUILD.md](BUILD.md) - 构建指南（Lean's LEDE）
- [IPK_PACKAGING.md](IPK_PACKAGING.md) - IPK 打包原理详解
- [CLAUDE.md](CLAUDE.md) - 项目技术文档（Claude Code 使用）
- [docs/](docs/) - 架构设计和组件实现文档

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

### v1.0.0 (2024-01)
- Initial IPK package release
- Automatic hotplug-based backup
- LED status indicators
- Multi-filesystem support
- UCI configuration integration

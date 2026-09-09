# Outdoor Backup - OpenWrt SD Card Backup System

Automatic SD card backup system for OpenWrt routers with internal storage (SSD/HDD). Designed for devices like NanoPi R5S running OpenWrt (including Lean's LEDE fork).

**Outdoor Backup** 是为户外摄影、航拍、数据采集等场景设计的 OpenWrt IPK 包，实现 SD 卡插入即自动备份到路由器内置存储。

## Features

- ✅ **Automatic Backup**: Hotplug-triggered backup on SD card insertion
- ✅ **Incremental Sync**: rsync updates files when size or modification time differs, preserves partial transfers, and does not delete target files
- ✅ **LED Indicators**: Visual feedback for backup status
- ✅ **Concurrent Protection**: PID-based locking prevents conflicts
- ✅ **Multi-Filesystem**: Supports ext4, exFAT, NTFS, FAT32
- ✅ **One-way Automatic Backup**: PRIMARY cards back up from SD to configured storage; existing REPLICA cards are refused
- ✅ **Production Ready**: POSIX-compliant shell, fully error-handled

## Quick Start

### Prerequisites

- OpenWrt 19.07+ (tested on Lean's LEDE)
- A user-configured target storage mount; `/mnt/ssd/` is the compatibility default
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

Configure and mount the target storage before inserting an SD card. The manager does not format, mount, or select a target disk automatically. Follow [Configure target storage](#configure-target-storage) first.

1. **Insert an SD card**. After the target guard accepts the configured target, the system detects the card through hotplug, creates `FieldBackup.conf` when necessary, starts the backup, and shows LED status.

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

### Runtime precedence and compatibility

The runtime loader applies values in this order:

1. Built-in defaults.
2. The root-owned legacy file `/opt/outdoor-backup/conf/backup.conf`.
3. Explicit options in the named UCI section `outdoor-backup.config`.

`TARGET_MOUNT` defaults to `/mnt/ssd`. `TARGET_UUID` defaults to an empty value. The loader reads UCI through the `uci` CLI. It does not `source` or `eval` `/etc/config/outdoor-backup`; a UCI value is data, not shell code. The legacy file remains sourced for backward compatibility and can retain legacy-only settings.

The factory UCI conffile contains only `config outdoor-backup 'config'`. OpenWrt preserves a modified conffile during upgrades. The package does not migrate values from `backup.conf`, remove that file, or delete existing UCI options. Therefore, an existing explicit UCI option continues to override the legacy value after an upgrade.

### Configure target storage

The target UUID is a required user choice. The manager rejects an `add` event while `target_uuid` is empty. It never guesses which disk is an SSD, formats a disk, or mounts a disk itself.

1. Read the block inventory. Identify the intended SSD line yourself and copy its UUID exactly. Do not use a shell expression that selects a disk by position or name.

   ```sh
   block info
   ```

2. Configure `/etc/config/fstab` manually with that same UUID and a mount point you choose. The following UCI form creates one explicit mount entry. Replace both placeholders before running it.

   ```sh
   TARGET_UUID='<UUID_FROM_THE_INTENDED_SSD>'
   TARGET_MOUNT='/mnt/ssd'

   uci set fstab.outdoor_backup_target='mount'
   uci set fstab.outdoor_backup_target.uuid="$TARGET_UUID"
   uci set fstab.outdoor_backup_target.target="$TARGET_MOUNT"
   uci set fstab.outdoor_backup_target.enabled='1'
   uci commit fstab
   block mount
   ```

   Confirm that the same UUID is mounted at exactly `$TARGET_MOUNT` and that the mount is writable. Do not configure a subdirectory as `target_mount`.

3. Configure the manager. `backup_root` must be a strict child of `target_mount`.

   ```sh
   BACKUP_ROOT="$TARGET_MOUNT/SDMirrors"

   uci set outdoor-backup.config.target_mount="$TARGET_MOUNT"
   uci set outdoor-backup.config.target_uuid="$TARGET_UUID"
   uci set outdoor-backup.config.backup_root="$BACKUP_ROOT"
   uci commit outdoor-backup
   ```

`/mnt/ssd` is a compatibility default, not a requirement. For example, choose `/mnt/nvme`, mount the selected UUID there, and set both `target_mount` and `backup_root` to `/mnt/nvme` and `/mnt/nvme/SDMirrors`. A future firmware image can configure those values once for all devices. This package does not deploy PhotoPrism.

When a target-storage failure occurs, prepare the target storage first and then remove and reinsert the source SD card. Do not run `rsync` manually as a retry. This release does not provide an automatic SSD-ready queue or a coldplug retry mechanism.

### Target guard behavior and limits

Before an `add` event can create application state, the manager opens the configured target through FD 9 and requires an exact live `/proc/<manager-pid>/mountinfo` record. Both VFS and filesystem-specific mount options must be `rw`. The target's `block info` UUID must equal `target_uuid`. Sysfs must prove that the source card, target storage, and physical system backing disks are different.

The guard accepts direct `sd`, `mmc`, and `nvme` disks. It can trace a system loop device only when its backing file explicitly names a `/dev/` block partition. Unknown backing, a deleted backing file, a file-backed loop, `dm`, and `md` devices fail closed because the manager cannot prove their identity. It parses complete key-value tokens from `block info`; UUID-shaped text inside a `LABEL` value is not treated as a UUID, and malformed quoting is rejected. The manager uses `/proc/<manager-pid>/fd/9` for target directories and per-backup logs. It checks the anchor before work, before `rsync`, and after `rsync`; target detach or a read-only remount cannot produce a successful backup. A log-summary write failure and a detached or read-only recheck failure after the summary return nonzero.

The static directory check rejects a symlink at the configured mount path or in an existing target-directory component, including `BACKUP_ROOT/.logs`. The guard rejects mounts covering the target mount point, an ancestor of `BACKUP_ROOT`, or a child mount inside the backup tree; mounts in disjoint directories are not rejected. This shell implementation does not provide an `openat2` guarantee against a malicious root process that replaces target directories concurrently. It does not claim complete real-device compatibility.

If the initial target guard fails, the manager writes the reason to stderr and error-level syslog. It may signal the optional red LED, but it does not enter the source mount, `rsync`, alias, lock, or application-log lifecycle. The manager closes the target FD before the LED helper starts its delayed child process. A missing LED does not turn this failure into success. `enabled=0` exits an `add` event before any LED side effect.

Automatic backup supports the PRIMARY direction only: SD card to the configured storage target. The data-only card reader still accepts `REPLICA` in an existing `FieldBackup.conf` for compatibility. The manager rejects that card with an explicit error before `rsync`. It does not change the card configuration or UUID, update an alias, create the target UUID directory, or create a per-backup log. The manager does not convert `REPLICA` to `PRIMARY`. Remaining #15 work concerns stable card identity, read-only cards, and cloned cards; #15 remains open.

The manager calls `backup-transfer.sh` after its source and target guards succeed. That module invokes the production `rsync` command directly and captures its real exit status. It uses `--partial` so an interrupted transfer can retain partial target data. It does not use `--ignore-existing`, `--append`, `--append-verify`, or `--delete`. Normal rsync quick-check behavior updates a file when its size or modification time differs. It does not guarantee detection of a content change that preserves both values. An `ENOSPC` classification requires the transfer diagnostics to contain `No space left on device` or `ENOSPC`; other rsync exits, including exit 11 or 12 without that diagnostic, remain rsync failures.

### Runtime status and LuCI storage fields

`status.sh` requires `jq` and atomically replaces the single snapshot at `/opt/outdoor-backup/var/status.json`. The snapshot contains `current_backup`, `storage`, and `history`; no `history.jsonl` state file exists. Each terminal event replaces any older event for the same UUID. The history is newest first and contains at most 20 entries. The storage counters come from `df` through the active target FD, while `storage.root` and each history `backup_path` are stable canonical display paths.

While the manager transfers data, `current_backup.active` is true and all progress, file-count, byte-count, and speed fields are `0` because the runtime does not measure live progress. On completion, the manager records the actual `rsync --stats` file and byte counters. It writes `completed` only after rsync succeeds, the summary write succeeds, and the final target-health and device-identity checks succeed. A failed terminal-status write or any failed prerequisite prevents a completed state.

The LuCI form exposes `target_mount`, `target_uuid`, and the `backup_root` boundary. It requires a valid UUID when `enabled=1`. It permits an empty UUID when `enabled=0`. Field validation only checks submitted values and paths. It does not mount or format a disk. Use the fstab procedure above to mount the real target UUID.

### Set other UCI overrides

Set only values that must override the lower layers. The supported UCI options are `enabled`, `backup_root`, `mount_point`, `target_mount`, `target_uuid`, `debug`, `led_green`, and `led_red`.

```sh
# Use absolute, non-root, non-nested paths.
uci set outdoor-backup.config.mount_point='/run/outdoor-card'
uci set outdoor-backup.config.debug='1'
uci commit outdoor-backup
```

To return one setting to the legacy file or the built-in default, delete that UCI option and commit. Do not delete the whole configuration merely to inherit one value.

```sh
uci delete outdoor-backup.config.backup_root
uci commit outdoor-backup
```

An empty UCI option is normalized by UCI as unset, so it also inherits the lower layer. Final empty or invalid storage paths in `backup_root`, `mount_point`, or `target_mount`, invalid target UUID characters, and values other than `0` or `1` for `enabled` or `debug` make the manager stop before resource operations and report the reason to stderr and syslog with the `outdoor-backup` tag. The `enabled=0` switch exits an `add` event before target checks, LED, lock, mount, or I/O work. A `remove` event still reaches cleanup. LED paths retain their existing optional semantics: an empty legacy LED value falls back to the default in `common.sh`, and LED sysfs paths do not use storage-path validation.

### Maintain legacy configuration

Edit `/opt/outdoor-backup/conf/backup.conf` only when a legacy value should apply, including legacy-only settings. An explicit UCI option has higher precedence. Remove that specific option with `uci delete` and `uci commit` when the legacy value should take effect again.

### Per-SD Card Configuration

When a writable card has no configuration, the manager creates `{SD_ROOT}/FieldBackup.conf` with a new UUID and `PRIMARY` mode. The manager reads an existing file as data. It never `source`s or `eval`s the file.

```bash
# Automatically generated on first insertion
SD_UUID="550e8400-e29b-41d4-a716-446655440000"
BACKUP_MODE="PRIMARY"                # Generated automatic-backup mode
CREATED_AT="2024-01-15 10:30:00"
```

The reader exports only `SD_UUID`, `BACKUP_MODE`, `CREATED_AT`, and the legacy `SD_NAME`. It ignores other syntactically valid assignments. It rejects malformed records, duplicate recognized fields, an absent UUID, or an invalid UUID. On rejection, it does not rewrite the existing card file or replace the in-memory card identity. `BACKUP_MODE` defaults to `PRIMARY` when absent.

To set a friendly name for an SD card, use the WebUI alias management feature instead of editing this file.

**Automatic-backup modes**:
- `PRIMARY`: SD card → configured storage target. New card configurations use this value.
- `REPLICA`: A legacy data value accepted by the reader for compatibility. Automatic backup does not restore from storage to the card. When the manager reads an existing `REPLICA` card, it returns an explicit error without running `rsync`, changing the card configuration or UUID, updating an alias, creating the target UUID directory, or creating a per-backup log.

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
- Snapshot-backed running status and completed rsync statistics; no live progress, speed, or ETA writer
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
- Current backup running state from the atomic status snapshot; it does not report live progress or transfer rate
- Storage counters obtained through the anchored target FD
- UUID-unique backup history from the same snapshot

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

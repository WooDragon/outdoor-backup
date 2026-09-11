# Outdoor Backup - OpenWrt SD Card Backup System

Automatic SD card backup system for OpenWrt routers with internal storage (SSD/HDD). Designed for devices like NanoPi R5S running OpenWrt (including Lean's LEDE fork).

**Outdoor Backup** 是为户外摄影、航拍、数据采集等场景设计的 OpenWrt IPK 包，实现 SD 卡插入即自动备份到路由器内置存储。

## Features

- ✅ **Automatic Backup**: Hotplug-triggered backup on SD card insertion
- ✅ **Incremental Sync**: rsync updates files when size or modification time differs, preserves partial transfers, and does not delete target files
- ✅ **Controlled Cancellation**: Before terminal publication, `SIGINT` or `SIGTERM` requests cancellation at a safe phase boundary; partial rsync data is preserved and accepted cancellation cannot report success
- ✅ **Owner-Aware Removal**: A four-argument block `remove` event can request cancellation only from the matching active backup owner; an unrelated card removal does not modify that owner's shared state
- ✅ **LED Indicators**: Visual feedback for backup status
- ✅ **Concurrent Protection**: PID-based locking prevents conflicts
- ✅ **Multi-Filesystem**: Supports ext4, exFAT, NTFS, FAT32
- ✅ **One-way Automatic Backup**: PRIMARY cards back up from SD to configured storage; existing REPLICA cards are refused
- ✅ **Production Ready**: POSIX-compliant shell, fully error-handled

## Quick Start

### Prerequisites

- OpenWrt 19.07+ (tested on Lean's LEDE)
- BusyBox with the `setsid` applet. ImmortalWrt 24.10.6 includes it by default. OpenWrt 19.07.10 does not; use a custom image that enables it.
- A user-configured target storage mount; `/mnt/ssd/` is the compatibility default
- USB port for SD card reader
- Required kernel modules (auto-installed with package):
  - `kmod-usb-storage`
  - `kmod-fs-ext4`, `kmod-fs-exfat`, `kmod-fs-ntfs3`

The package checks for `setsid` before it starts `rsync`. A missing applet causes a clear failure and starts no transfer. Installing this IPK cannot add the applet to an existing BusyBox binary.

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

1. **Insert an SD card**. After the target guard accepts the configured target, the system detects the card through hotplug and mounts it read-only. When no formal `FieldBackup.conf` exists, it uses a bounded read-write window to publish a complete configuration before it starts the backup. The LED then shows the backup status.

2. **Monitor progress**:
   ```bash
   # Watch system logs
   logread -f | grep outdoor-backup

   # Check backup status
   ls -lh /mnt/ssd/SDMirrors/

   # View detailed logs
   tail -f /opt/outdoor-backup/log/backup.log
   ```

## LED Status Reference

In the field there is no screen or SSH — the LED is the only diagnostic
interface. Each state maps to a distinct, countable pattern so you can tell at
a glance what happened:

| State | LED pattern | Meaning |
|-------|-------------|---------|
| Backup in progress | Green fast blink | Transfer running |
| Backup complete | Green solid (30s) | Done, verified |
| Device not recognized | Red, **1 flash** + pause | Inserted device not detected as an SD card / reader |
| Lock timeout / busy | Red, **2 flashes** + pause | Another backup is already running; waited and gave up |
| Insufficient space | Red, **3 flashes** + pause | Target free space below `MIN_FREE_SPACE` (or disk full) |
| Card configuration rejected | Red, **4 flashes** + pause | SD card configuration was rejected by policy (e.g. an existing REPLICA card) |
| rsync transfer failed | Red slow blink | rsync exited non-zero (read/write error) |
| Integrity verify failed | Red/green alternating | Transfer reported done but post-check disagreed |

Count the red flashes between pauses to identify the fault. All error patterns
auto-clear after 60 seconds.

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

Automatic backup supports the PRIMARY direction only: SD card to the configured storage target. The data-only card reader still accepts `REPLICA` in an existing `FieldBackup.conf` for compatibility. The manager rejects that card with an explicit error before `rsync`. It does not change the card configuration or UUID, update an alias, create the target UUID directory, or create a per-backup log. The manager does not convert `REPLICA` to `PRIMARY`. #15 now binds each configured card UUID to an observed source filesystem UUID. It does not make the filesystem UUID a physical-card identity. A full clone with the same source filesystem UUID remains indistinguishable; source replacement and multi-partition handling remain #16 work.

The manager calls `backup-transfer.sh` after its source and target guards succeed. That module launches `rsync` through `transfer_process_run` in a private session and captures its real exit status. It uses `--partial` so an interrupted transfer can retain partial target data. It does not use `--ignore-existing`, `--append`, `--append-verify`, or `--delete`. Normal rsync quick-check behavior updates a file when its size or modification time differs. It does not guarantee detection of a content change that preserves both values. An `ENOSPC` classification requires the transfer diagnostics to contain `No space left on device` or `ENOSPC`; other rsync exits, including exit 11 or 12 without that diagnostic, remain rsync failures.

During an active transfer, `SIGINT` and `SIGTERM` request cancellation. The manager preserves the first signal as exit code 130 or 143. It stops before later independent side-effect phases. It waits for its own rsync process group to stop before cleanup. If a running snapshot exists, an accepted cancellation records `status="error"` and `error_message="cancelled"`. Earlier cancellation returns nonzero without rewriting the existing snapshot. A source-card configuration publication or read-only restoration already underway may finish before the next checkpoint. The final terminal-publication boundary stops accepting new cancellation requests. Signals after that boundary are ignored.

A hotplug `remove` event now calls the manager with `remove DEVNAME DEVPATH SEQNUM`. The manager validates the fields only for that four-argument form. It then identifies a current lock owner by its lock link, `/proc` start time, and raw NUL-delimited manager argv. The event must name the same partition or its direct parent disk path and carry a later positive 64-bit decimal `SEQNUM`. The manager rereads the mutable lock and process evidence before it sends one `TERM`. A failed or mismatched check is a no-op, so removing card B does not cancel a matching owner for card A. The `SEQNUM` comparison is event ordering evidence, not a card identity.

The hotplug trigger always calls the manager with four event slots: `remove DEVNAME DEVPATH "${SEQNUM:-}"` (and the equivalent `add` call). A missing or empty `SEQNUM` remains an empty fourth argument; it does not silently become a three-argument call. The manager rejects the four-argument event when `SEQNUM` is missing or empty: an enabled `add` exits nonzero before target setup and does not start a backup, while `remove` exits nonzero without signalling an owner. A three-argument call is only explicit legacy compatibility: `remove DEVNAME DEVPATH` remains a successful no-op with a syslog notice, and legacy `add` calls remain compatible but receive no automatic remove cancellation. Operators should not invent a `SEQNUM` to request production cancellation.

Owner-event matching requires `jq` support for raw slurp (`-Rs`), complete preservation of NUL bytes from `/proc/<PID>/cmdline`, and the jq string operations used by the matcher. This change has native-ARM, native-`/proc` regression coverage on OpenWrt 24.10.8. It does not independently verify that capability on OpenWrt 19.07. Before deploying on an older release, operators should verify this jq capability and the existing `setsid` prerequisite. A matching no-op is not evidence that automatic cancellation works after a card removal.

This release does not cancel lock waiters. A waiter has no source-generation recheck after it acquires the lock, so the implementation cannot guarantee that an old queued task will not process a reused device node. This limitation applies to both three-argument and four-argument add calls. Legacy three-argument add calls have a separate limitation: they do not receive automatic remove identity matching. The implementation makes no hotplug delivery, latency, or zero-loss guarantee. POSIX `/proc` inspection plus `kill` still has a final time-of-check/time-of-use gap and is not equivalent to pidfd. Service/package-stop broad `pkill` behavior and crash-mount recovery remain follow-up work under #16. There is no LuCI cancellation control, rollback, immediate-release promise, or `SIGKILL` escalation. A process that ignores `TERM` can retain the mount and lock.

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

An empty UCI option is normalized by UCI as unset, so it also inherits the lower layer. Final empty or invalid storage paths in `backup_root`, `mount_point`, or `target_mount`, invalid target UUID characters, and values other than `0` or `1` for `enabled` or `debug` make the manager stop before resource operations and report the reason to stderr and syslog with the `outdoor-backup` tag. The `enabled=0` switch exits an `add` event before target checks, LED, lock, mount, or I/O work. A `remove` event bypasses configuration and target setup before it enters the owner-aware cancellation sender. The remove sender neither registers nor executes its own cleanup. A matched owner performs resource cleanup through its existing sticky-cancellation and cleanup lifecycle. LED paths retain their existing optional semantics: an empty legacy LED value falls back to the default in `common.sh`, and LED sysfs paths do not use storage-path validation.

### Maintain legacy configuration

Edit `/opt/outdoor-backup/conf/backup.conf` only when a legacy value should apply, including legacy-only settings. An explicit UCI option has higher precedence. Remove that specific option with `uci delete` and `uci commit` when the legacy value should take effect again.

### Per-SD Card Configuration

The source card is mounted read-only. This limits user-space writes during the steady state. It is not forensic write protection: an ext4 dirty journal can still replay when the filesystem mounts. `rsync` always reads from the read-only mount.

Immediately after the initial read-only mount, and before any read-write initialization window, the manager reads the source filesystem UUID through the exact `block info /dev/<DEVNAME>` reader. It normalizes ASCII letters to lowercase and rejects an empty or unsafe value. A failed UUID read stops initialization before the card is mounted read-write.

The one exception is bounded and explicit. When no formal `FieldBackup.conf` exists, the manager unmounts the source and mounts it read-write. It writes the complete data to a uniquely named temporary file in that directory. It checks the write and publishes the file with a same-filesystem rename. It checks `sync` after publication. A rename is not proof against power loss. The manager then unmounts and mounts the source read-only before it does anything else.

A failed read-write mount or a failed configuration write means that the manager cannot initialize the card. The manager reports a card-configuration error and does not run `rsync`. If the read-only mount cannot be restored, it also stops before `rsync`. Cleanup attempts to unmount the source only when this manager successfully mounted it. A failed explicit unmount preserves that manager-owned cleanup state for one final cleanup attempt. Cleanup does not promise that every failed run restores a read-only mount. A manager that did not acquire the current lock does not unmount the source, modify status, change LEDs, release the lock, or claim backup completion. After the read-only mount succeeds, the manager rereads the formal file as a flow check. That reread does not prove physical-media durability or card identity. A `SIGKILL` can leave a temporary file behind. The manager never treats that name as `FieldBackup.conf` and does not scan or delete other temporary files.

An occupied source mount point is rejected even after a dead lock holder has been reclaimed. A hard kill or crash can therefore leave a source mount that requires manual inspection and recovery. Acquiring the application lock does not prove ownership of an existing mount, so this release does not automatically unmount it. Device-scoped crash recovery remains part of the task-ownership follow-up.

The implementation uses full unmount and mount transitions rather than `remount`, because the filesystem types it tries do not all implement `remount` uniformly. This is an implementation choice, not the only filesystem transition method.

The manager reads an existing formal file as data. It never `source`s or `eval`s the file. It rejects a symbolic link or another non-regular object at that name.

Before an alias update or `rsync`, it checks the anchored target record `.card-identities/<SD_UUID>.json`. The v1 record contains only `version`, `sd_uuid`, and normalized `fs_uuid`. The record path is below the active `/proc/<manager-pid>/fd/9` backup root.

When the record is missing, the manager creates it through a same-directory temporary file, `jq`, rename, `sync`, and final anchor validation. An existing record must be a non-link regular file with the exact v1 schema and the current values. A malformed object, a link, a directory, or a different source filesystem UUID rejects the backup. The manager does not replace the record, update the alias, run `rsync`, or report a successful status after that rejection.

Existing backup directories without a record use first observation to establish this binding. This preserves their directory names, aliases, and data. This trust-on-first-use rule cannot prove the historical origin of existing data. A filesystem UUID identifies a filesystem rather than a physical SD card. A block-level clone with the same filesystem UUID remains indistinguishable.

Batch data cleanup retains `.card-identities`, independently of the alias-retention option. Removing backup data does not reset a card binding. A rejected record may be malformed or may belong to another source filesystem; inspect the record and verify the source before any manual repair. Do not delete an identity record merely to bypass a rejection: the next insertion would establish a new first-observation binding to the existing UUID directory.

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

### Card Reader Whitelist (optional)

By default the system guesses which devices are SD cards/readers from their
path, model string, and size (≤512GB). That heuristic mis-fires on 1TB+ cards
and on readers with unusual sysfs paths. For reliable, unattended operation you
can whitelist your exact reader.

The whitelist shares the same single config channel as everything else
(`config.sh`): default < legacy `backup.conf` < the named UCI section
`outdoor-backup.config`. The recommended way to set it is UCI:

```bash
uci set outdoor-backup.config.card_reader_usb_ids='05e3:0749 14cd:1212'
uci set outdoor-backup.config.card_reader_path_prefixes='/devices/platform/soc/usb1'
uci set outdoor-backup.config.card_reader_heuristic_fallback='no'
uci commit outdoor-backup
```

An explicitly-present UCI option always wins over the legacy `backup.conf`
value; `backup.conf` remains fully supported as the lower-priority layer, so
existing setups that only edit `backup.conf` keep working unchanged:

```bash
# USB VID:PID whitelist (most precise), space-separated lowercase hex
CARD_READER_USB_IDS="05e3:0749 14cd:1212"

# Device-path prefix whitelist (when a reader has a stable path)
CARD_READER_PATH_PREFIXES="/devices/platform/soc/usb1"

# Keep heuristic as fallback (default "yes"); set "no" for strict whitelist-only
CARD_READER_HEURISTIC_FALLBACK="yes"
```

**Finding your reader's VID:PID** — insert the reader and run:

```bash
lsusb
# e.g. "Bus 001 Device 005: ID 05e3:0749 Genesys Logic, Inc. Card Reader"
#                              ^^^^^^^^^ this is VID:PID

# Or directly from sysfs:
for d in /sys/bus/usb/devices/*; do
    [ -r "$d/idVendor" ] && echo "$(cat "$d/idVendor"):$(cat "$d/idProduct")  $(cat "$d/product" 2>/dev/null)"
done
```

A whitelist match is authoritative and checked first; the heuristic runs only
when nothing matches (and `CARD_READER_HEURISTIC_FALLBACK="yes"`). An empty
whitelist with fallback on behaves exactly like previous versions.

**Value constraints and failure behavior**: `card_reader_usb_ids` must be
space-separated `vvvv:pppp` hex tokens; `card_reader_path_prefixes` entries
must be absolute paths with no glob characters (`*`, `?`, `[`), must not be
the bare `/` (it would match every device path, i.e. disable the whitelist),
and must not contain a `.` or `..` path segment; `card_reader_heuristic_fallback`
must be `yes` or `no`.

These three fields have exactly one consumer — the hotplug trigger — and it
is the only thing that validates them. `config.sh`'s shared loader only
assigns them; a value outside the constraints above does not make
`backup-manager.sh`'s own config load fail, because the manager never reads
`CARD_READER_*` in the first place. Concretely: an invalid whitelist does
not make the backup manager reject an `add` event, and it does not stop a
`remove` event's owner-aware cancellation from reaching the manager. The
hotplug trigger records exactly which field and which token was invalid,
then falls back to the built-in heuristic (equivalent to an empty whitelist
with `card_reader_heuristic_fallback=yes`) and keeps working.

`backup.conf` existing but being unreadable is a different, fail-closed
situation: `config_load` returns an error and none of the caller's
subsequent effects (mounting, backing up, or, on the hotplug side, reading
the whitelist from that file) happen with default values silently
substituted — the manager exits, and the hotplug trigger falls back to the
built-in heuristic exactly as it does for an invalid whitelist. Fix the
underlying config either way; the manager invocation will keep failing
until you do.

## Package Structure

```
outdoor-backup/
├── Makefile                          # OpenWrt package definition
├── files/                            # Files to install
│   ├── opt/outdoor-backup/
│   │   ├── scripts/
│   │   │   ├── backup-manager.sh    # Core backup logic
│   │   │   ├── transfer-process.sh  # rsync process-group lifecycle
│   │   │   ├── owner-event.sh       # exact remove-event owner matching
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
# Check the lock: it is a symlink pointing at the holder's /proc/<pid>
ls -l /opt/outdoor-backup/var/lock/backup.lock
cat /opt/outdoor-backup/var/lock/backup.lock/cmdline

# Force-clear a lock (only if you have confirmed no backup is really running)
rm -f /opt/outdoor-backup/var/lock/backup.lock

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

`test-owner-event.sh` 和 `test-manager-removal.sh` 需要真实 `/proc` argv。它们在 ARM 主机选择官方 `openwrt/rootfs@sha256:f6dd33c1d9b7d6f1e0848f2fbb92b8d03fc9b425dc08c3574a44936b93133704` 的 `linux/aarch64_generic` 实体，在 x86 主机选择既有固定 `linux/amd64` 实体 `openwrt/rootfs:x86_64-24.10.8@sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9`。其他测试套件的平台不变；生产代码不为 Rosetta 增加分支。

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
  - [component-implementation.md](docs/component-implementation.md) - 传输进程组、取消边界和测试范围

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

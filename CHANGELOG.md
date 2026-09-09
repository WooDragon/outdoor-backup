# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed
- Current package build metadata in `Makefile` is `PKG_VERSION` `1.2.0` and `PKG_RELEASE` `1` (`1.2.0-1`). The runtime package now depends on `jq` as well as `rsync`. This Unreleased section records development work. No external release evidence was checked for this documentation update, and this entry does not mark a release. The historical `[v1.1.0] - 2025-01` section remains unchanged below.
- Added the #13 runtime configuration loader. It applies built-in defaults, then the root-owned legacy `backup.conf`, then explicit options from the named `outdoor-backup.config` UCI section.
- Replaced shell sourcing of `/etc/config/outdoor-backup` with `uci` CLI reads. UCI values remain data and are not executed as shell text.
- Changed the factory UCI conffile to contain only its named section. Package upgrades preserve modified conffiles and do not migrate or delete the legacy configuration or existing UCI options.
- Added fail-fast validation for empty or invalid paths, invalid boolean controls, and equal or nested backup and mount paths. Disabled `add` events exit before resource operations; `remove` events retain their cleanup path.
- Configuration failures before resource operations and disabled-event reasons are also recorded in syslog; tests write only to an isolated UCI directory.
- #14a historical milestone: installation and startup initialize only runtime directories and do not pre-create `/mnt/ssd/SDMirrors/.logs`.
- #14b: Added a configured-target guard for `add` events. It requires a nonempty target UUID, an exact writable target mount, matching `block info` UUID, and sysfs proof that source, target, and system backing disks are distinct. It parses complete key-value tokens from `block info`; UUID-shaped text inside a `LABEL` value is not treated as a UUID, and malformed quoting is rejected.
- #14b: Target state is anchored through FD 9. `BACKUP_ROOT` must be a strict target-mount child; static symlink components, target detach, target replacement, and read-only remounts fail closed before success. The guard rejects mounts covering the target mount point, an ancestor of `BACKUP_ROOT`, or a child mount inside the backup tree; mounts in disjoint directories are not rejected. A log-summary write failure and a detached or read-only recheck failure after the summary return nonzero.
- #14b: The guard accepts direct `sd`, `mmc`, and `nvme` devices and the R5S system loop case only when its backing file explicitly names a `/dev/` block partition. Unknown devices, file-backed loops, `dm`, and `md` fail closed.
- `FieldBackup.conf` is now parsed by `card-config.sh` as removable-media data. The manager never `source`s or `eval`s it. The reader exports only `SD_UUID`, `BACKUP_MODE`, `CREATED_AT`, and legacy `SD_NAME`; other syntactically valid assignments are ignored. Malformed records, missing UUIDs, and invalid UUIDs fail without rewriting the card file.
- An initial target-guard failure reports stderr and error-level syslog. It may show the optional red LED, but it does not enter source mounting, `rsync`, alias, lock, or application-log work. The manager closes the target FD before the LED delay child starts. A missing LED preserves a nonzero failure. Disabled `add` events retain zero LED side effects.
- Added LuCI `target_mount` and `target_uuid` fields plus `backup_root` boundary text. The form requires a UUID for `enabled=1` and permits an empty UUID for `enabled=0`. Form validation does not mount or format storage.
- The guard now describes its identity boundary consistently: it matches exact kernel mountinfo paths, rejects symlink components and backup-tree-overlapping mounts, and fails closed for unknown or deleted loop backing that cannot prove identity. The implementation does not claim `openat2` protection or complete real-device compatibility.
- #15a: Automatic backup supports only the PRIMARY direction from an SD card to configured storage. The data-only card reader accepts an existing `REPLICA` value for compatibility, but the manager rejects reverse synchronization with an explicit error. It preserves the existing card configuration and sentinel bytes. It does not run `rsync`, update an alias, create a target UUID leaf, or create a per-backup log. The configured `BACKUP_ROOT` may be created before the manager reads the card, and the application error log records the rejection. This behavior does not claim that mounting a writable card produces no filesystem metadata writes. New card configurations generate `PRIMARY` only. The manager does not convert `REPLICA` to `PRIMARY`. #15 remains open for stable card identity, read-only cards, and cloned cards.
- Added `backup-transfer.sh`. It invokes the production `rsync` command directly, retains the real rsync exit status, uses `--partial`, and records successful `--stats` counters. It does not use `--ignore-existing`, `--append`, `--append-verify`, or `--delete`. Files whose size or modification time differs are eligible for update; an equal-size, equal-mtime content change is outside this comparison.
- Added `status.sh`. It uses `jq` to atomically replace the sole status snapshot, `status.json`, with `current_backup`, `storage`, and UUID-unique history ordered newest first and limited to 20 records. It does not create `history.jsonl` or hand-write JSON.
- The manager writes a running snapshot before transfer. It records zero for progress and rate fields because it does not measure live transfer progress. It records completed statistics from successful rsync output only after the summary write and final target-health and identity checks succeed. It writes a failed terminal state when possible; a terminal-status write failure cannot yield completed status.
- The target free-space guard calls `df` through the anchored target FD after the backup leaf exists. `MIN_FREE_SPACE` defaults to 1024 MB and accepts a non-negative decimal integer; `0` disables the reserve. An unknown `df` value fails closed. The manager labels no-space only when the free-space guard rejects the reserve or rsync diagnostics contain an ENOSPC indication; rsync exits 11 and 12 alone are not classified as full storage.
- Cleanup releases transfer and target descriptors before it starts an LED timer. The manager maps the existing `ERROR_TYPE` values `device_unknown`, `lock_timeout`, `no_space`, `card_config`, `rsync`, and `verify_failed` to the common LED helpers. A rejected card configuration, including an existing `REPLICA` card, now classifies as `card_config` instead of the generic `rsync` transfer failure, because it is a card-side configuration problem, not a transfer problem, and the two require different operator remediation. The broad PID lock and `remove`-path `pkill` limitations remain scheduled for #8/PR10 and #16.

### Verified
- This PR's recorded local verification covers all ten suites: `test-config.sh` (20 scenarios, 92 assertions), `test-storage-lifecycle.sh` (4 scenarios, 21 assertions), `test-target-anchor.sh` (16 scenarios, 96 assertions), `test-target-device.sh` (10 scenarios, 39 assertions), `test-target-manager.sh` (22 scenarios, 212 assertions), `test-card-config.sh` (9 scenarios, 48 assertions), `test-luci-target-config.sh` (8 scenarios, 28 assertions), `test-status.sh` (9 scenarios, 47 assertions), `test-backup-core.sh` (10 scenarios, 114 assertions), and `test-led.sh` (9 scenarios, 78 assertions). Combined: 117 scenarios, 775 assertions, all passing.
- 本轮修复了提前记录整体完成、测试 stderr 重放自复制、旧状态快照校验与临时文件断言；补齐真实增量/空格路径/IO失败及缺灯回退覆盖。
- The backup-core coverage uses the production rsync executable, a real FD-anchored tmpfs target, and a real ENOSPC condition. Its partial-target recovery fixture constructs an incomplete target file; it does not simulate an interrupted rsync process by killing one.
- The manager suite uses explicit substitutes for sysfs, source mounting, and rsync. It is not hardware end-to-end coverage.
- This entry does not claim execution of any other suite, CI, package build, firmware build, deployment, or real-device validation. The historical `test-backup-core` 34-scenario/24-case statement is superseded for this PR and must not be read as current verification.
- #8/PR10 and #16 retain the broad PID-lock and remove-path `pkill` work. #15 retains stable card identity, read-only cards, and cloned cards.

## [v1.1.0] - 2025-01

### Added
- **WebUI Management Interface** (luci-app-outdoor-backup)
  - Real-time backup status monitoring with progress bar
  - SD card alias management system (solve UUID readability)
  - Batch cleanup with multi-step confirmation
  - Log viewing with filtering and highlighting
  - 6 RESTful API endpoints
  - Comprehensive security mechanisms (XSS/injection protection)
- **Shell Script Enhancements**
  - Alias support functions (get_alias, update_alias_last_seen)
  - Batch cleanup script with safety checks
  - File locking mechanism for concurrent safety

### Fixed
- Fixed awk string interpolation in alias parsing
- Fixed double execution in cleanup API
- Fixed race condition in temp file handling
- Added input validation and XSS protection

## [v1.0.0] - 2024-01

### Added
- Initial IPK package release
- Automatic hotplug-based backup
- LED status indicators
- Multi-filesystem support
- UCI configuration integration

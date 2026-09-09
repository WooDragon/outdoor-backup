# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed
- Current package build metadata in `Makefile` is `PKG_VERSION` `1.1.0` and `PKG_RELEASE` `2` (`1.1.0-2`). This Unreleased section records development work. No external release evidence was checked for this documentation update, and this entry does not mark a release. The historical `[v1.1.0] - 2025-01` section remains unchanged below.
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

### Verified
- Ran `shellcheck --shell=bash files/opt/outdoor-backup/scripts/config.sh` successfully. The manager retains 9 historical lint findings; this entry does not claim a clean full-script lint, a package build, or a deployment.
- The current CI `severity=error` check passes for all scripts. This does not mean that historical warnings have been cleared.
- #15a verification: the original M03a test failed against the old manager because it accepted `REPLICA` without an error, ran `rsync`, and created the target UUID directory and log. M03a now checks that the manager rejects reverse synchronization while preserving the card configuration and sentinel bytes. It also checks that the manager does not run `rsync`, update aliases, create a target UUID leaf, or create a per-backup log. The configured `BACKUP_ROOT` may exist before the card is read, and the application error log records the rejection; this verification does not claim a writable mount has no filesystem metadata writes. This entry does not assert new test counts or unrun test results. It does not claim that other test scripts, a package build, or hardware end-to-end `rsync` validation ran.
- The target-anchor and manager tests use actual OpenWrt 24.10.8 `ash`, tmpfs mounts, mountinfo, FD behavior, detach, and read-only remounts. Their sysfs, `block info`, source-mount, and rsync inputs are explicit fixtures. `block-mount` is installed in an isolated container and its empty-device return contract is confirmed; this is not a real SSD UUID test. The LuCI test uses constrained CBI doubles and real Lua. It is not browser E2E coverage.
- #14 remains open: final package CI, firmware CI, and real-device validation have not run. The existing `test-cleanup.sh` missing-`--force` failure remains pending #12.

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

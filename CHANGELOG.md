# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed
- Raised `PKG_RELEASE` from `1` to `2` while retaining `PKG_VERSION` `1.0.0`.
- Added the #13 runtime configuration loader. It applies built-in defaults, then the root-owned legacy `backup.conf`, then explicit options from the named `outdoor-backup.config` UCI section.
- Replaced shell sourcing of `/etc/config/outdoor-backup` with `uci` CLI reads. UCI values remain data and are not executed as shell text.
- Changed the factory UCI conffile to contain only its named section. Package upgrades preserve modified conffiles and do not migrate or delete the legacy configuration or existing UCI options.
- Added fail-fast validation for empty or invalid paths, invalid boolean controls, and equal or nested backup and mount paths. Disabled `add` events exit before resource operations; `remove` events retain their cleanup path.
- Configuration failures before resource operations and disabled-event reasons are also recorded in syslog; tests write only to an isolated UCI directory.
- #14a: Installation and startup now initialize only runtime directories and do not pre-create `/mnt/ssd/SDMirrors/.logs`; `PKG_RELEASE` is `3`.
- #14b: Added a configured-target guard for `add` events. It requires a nonempty target UUID, an exact writable target mount, matching `block info` UUID, and sysfs proof that source, target, and system backing disks are distinct. It parses complete key-value tokens from `block info`; UUID-shaped text inside a `LABEL` value is not treated as a UUID, and malformed quoting is rejected.
- #14b: Target state is anchored through FD 9. `BACKUP_ROOT` must be a strict target-mount child; static symlink components, target detach, target replacement, and read-only remounts fail closed before success. The guard rejects mounts covering the target mount point, an ancestor of `BACKUP_ROOT`, or a child mount inside the backup tree; mounts in disjoint directories are not rejected. A log-summary write failure and a detached or read-only recheck failure after the summary return nonzero.
- #14b: The guard accepts direct `sd`, `mmc`, and `nvme` devices and the R5S system loop case only when its backing file explicitly names a `/dev/` block partition. Unknown devices, file-backed loops, `dm`, and `md` fail closed.

### Verified
- Ran `test-config.sh` in the pinned `openwrt/rootfs:x86_64-24.10.8` container with OpenWrt `ash` and `uci`: 19 cases, 81 assertions, 0 failures. This is not a NanoPi R5S hardware test.
- Ran `shellcheck --shell=bash files/opt/outdoor-backup/scripts/config.sh` successfully. The manager retains 9 historical lint findings; this entry does not claim a clean full-script lint, a package build, or a deployment.
- The current CI `severity=error` check passes for all scripts. This does not mean that historical warnings have been cleared.
- Ran `test-storage-lifecycle.sh` in the pinned `openwrt/rootfs:x86_64-24.10.8@sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9` container: 4 cases, 21 assertions, 0 failures.
- Ran `test-config.sh`: 20 cases, 92 assertions, 0 failures. Ran `test-target-anchor.sh`: 16 cases, 96 assertions, 0 failures. Ran `test-target-device.sh`: 10 cases, 39 assertions, 0 failures. Ran `test-target-manager.sh`: 9 cases, 44 assertions, 0 failures.
- The target-anchor and manager tests use actual OpenWrt 24.10.8 `ash`, tmpfs mounts, mountinfo, FD behavior, detach, and read-only remounts. Their sysfs, `block info`, source-mount, and rsync inputs are explicit fixtures. `block-mount` is installed in an isolated container and its empty-device return contract is confirmed; this is not a real SSD UUID test.
- Final CI and the real-device E matrix have not run. The existing `test-cleanup.sh` missing-`--force` failure remains pending #12.

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

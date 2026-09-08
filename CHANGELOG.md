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

### Verified
- Ran `test-config.sh` in the pinned `openwrt/rootfs:x86_64-24.10.8` container with OpenWrt `ash` and `uci`: 19 cases, 81 assertions, 0 failures. This is not a NanoPi R5S hardware test.
- Ran `shellcheck --shell=bash files/opt/outdoor-backup/scripts/config.sh` successfully. The manager retains 9 historical lint findings; this entry does not claim a clean full-script lint, a package build, or a deployment.
- The current CI `severity=error` check passes for all scripts. This does not mean that historical warnings have been cleared.

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

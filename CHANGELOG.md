# Changelog

All notable changes to this project will be documented in this file.

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

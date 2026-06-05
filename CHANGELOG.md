# Changelog

All notable changes to this project will be documented in this file.

## [v1.2.0] - 2026-06

### Fixed (data integrity)
- **rsync exit code no longer swallowed** (#6): the progress pipe used to make
  `$?` reflect the `while` loop (always 0), so every failure was reported as
  success with a green LED. The true rsync exit code is now captured via a temp
  file inside the pipeline; failures light the red error LED.
- **Interrupted backups now resume safely** (#1): replaced `--ignore-existing`
  with `--partial`. Partially-transferred files are kept on interruption and
  repaired by rsync's normal delta algorithm next run, instead of being skipped
  forever (silent truncation). `--append-verify` was deliberately NOT used: it
  matches by size only and blind-appends, which would corrupt same-named-but-
  changed files (cameras reuse filenames). Plain size+mtime matching re-sends
  changed files and skips unchanged ones.
- **Incremental backups no longer mis-rejected on space** (#5): removed the
  slow, incorrect whole-card `du` precheck that compared the card's TOTAL size
  against target free space (rejecting incremental re-backups of nearly full
  cards). Replaced with an O(1) `df` check against `MIN_FREE_SPACE`.

### Added
- **status.json writer** (#7): `backup-manager.sh` now writes throttled
  start/progress/done updates to `var/status.json`, so the WebUI live progress
  bar, storage gauge and history table finally show real data. History is keyed
  by UUID (one row per card, newest wins) and capped.
- **Differentiated LED error codes** (#4): each failure type maps to a distinct
  countable red-flash pattern for unattended field diagnostics —
  device-unknown (1 flash), lock-timeout (2), no-space (3), rsync-failure (slow
  blink), verify-failed (red/green alternating). See README LED reference.

### Internal
- Added testability seams (`SCRIPT_DIR`/`BASE_DIR`/`STATUS_FILE`/`ALIASES_FILE`
  overrides, `OUTDOOR_BACKUP_SOURCED` guard) — no production behavior change.
- New BDD suite `test-backup-core.sh` (24 cases, mock-rsync E2E).

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

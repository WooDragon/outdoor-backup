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
- **acquire_lock CPU spin + TOCTOU eliminated** (#8): the old PID lock did a
  non-atomic `echo $$ > lock` + read-back verify, and on a failed verify looped
  back with no sleep and no timeout increment — a 100% CPU spin that never timed
  out (two cards inserted together could peg a core forever). Rewritten to use
  `flock` as the atomic primitive (kernel auto-releases on death — no stale-lock
  window) with an atomic `mkdir` fallback. Both contention paths sleep and
  increment so the timeout is always reachable. release_lock frees only a lock
  this process actually holds, never unlinks the flock sentinel (avoids the
  flock-unlink double-holder race), and reclaims a stale mkdir lock via atomic
  rename (single winner under concurrent reclaim).

### Added
- **status.json writer** (#7): `backup-manager.sh` now writes throttled
  start/progress/done updates to `var/status.json`, so the WebUI live progress
  bar, storage gauge and history table finally show real data. History is keyed
  by UUID (one row per card, newest wins) and capped.
- **Differentiated LED error codes** (#4): each failure type maps to a distinct
  countable red-flash pattern for unattended field diagnostics —
  device-unknown (1 flash), lock-timeout (2), no-space (3), rsync-failure (slow
  blink), verify-failed (red/green alternating). See README LED reference.
- **Configurable card-reader whitelist** (#2): SD card/reader detection can now
  be pinned to specific devices instead of relying solely on the brittle
  heuristic (device path + model + ≤512GB size cap, which mis-fires on 1TB+
  cards and unusual reader paths). New `backup.conf` options
  `CARD_READER_USB_IDS` (VID:PID), `CARD_READER_PATH_PREFIXES`, and
  `CARD_READER_HEURISTIC_FALLBACK`. A whitelist match is authoritative and
  checked first; the heuristic remains as fallback (default on), so existing
  deployments behave identically with an empty whitelist. README documents how
  to find a reader's VID:PID.

### Internal
- Added testability seams (`SCRIPT_DIR`/`BASE_DIR`/`STATUS_FILE`/`ALIASES_FILE`
  overrides, `OUTDOOR_BACKUP_SOURCED` guard) — no production behavior change.
- New BDD suites `test-backup-core.sh` (34 cases, mock-rsync E2E),
  `test-lock.sh` (12 cases incl. concurrency smoke test) and
  `test-card-reader.sh` (9 cases, mocked sysfs).

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

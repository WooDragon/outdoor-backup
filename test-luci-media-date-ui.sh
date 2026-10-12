#!/bin/sh
# Host-only production renderer + DOM regression; no guest, device or browser.
set -eu
repo=$(dirname -- "$0")
command -v node >/dev/null 2>&1 || { printf '%s\n' 'BLOCKED: node is required' >&2; exit 2; }
node "$repo/tests/media-date/luci-ui.js" --dom-only
node "$repo/test-live-progress-ui.js"
node "$repo/test-status-modal.js"

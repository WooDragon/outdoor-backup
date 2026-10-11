#!/bin/sh
# Actual rsync acceptance only in an owned OpenWrt guest; no host-copy fallback.
# ci-suite.sh prepares the verified ExifTool source provider before this entry.
set -eu
case "$0" in
    /*) suite_root=${0%/*} ;;
    *) printf '%s\n' 'Run this suite by absolute path' >&2; exit 1 ;;
esac
if [ ! -f /.dockerenv ] || [ ! -r /etc/openwrt_release ]; then
    printf '%s\n' 'BLOCKED: actual date transfer requires an owned OpenWrt guest' \
        'ran=0 passed=0 failed=0 blocked=14 assertions=0' >&2
    exit 2
fi
exec python3 "$suite_root/tests/media-date/rsync-scenarios.py"

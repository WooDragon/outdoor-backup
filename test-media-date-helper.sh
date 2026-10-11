#!/bin/sh
# Execute delivered helper scenarios only in the real rootfs guest, /src read-only.
set -eu
[ "${1:-}" = --inside ] && [ -r /etc/openwrt_release ] && [ -f /.dockerenv ] || {
    printf '%s\n' 'BLOCKED: helper suite requires the bounded real OpenWrt guest' >&2
    exit 2
}
case "$0" in /*) ROOT=${0%/*} ;; *) exit 2 ;; esac
exec python3 "$ROOT/tests/media-date/package-helper-runner.py"

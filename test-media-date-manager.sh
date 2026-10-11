#!/bin/sh
# Host-only inert interface suite; not an OpenWrt manager lifecycle acceptance.
# No cwd changes, device mounts, package installation, or host media reads.
set -eu
case "$0" in
    /*) suite_root=${0%/*} ;;
    *) printf '%s\n' 'Run this suite by absolute path' >&2; exit 1 ;;
esac
exec python3 "$suite_root/tests/media-date/manager-contracts.py"

#!/bin/sh
# Given the canonical feed recipes, check ownership with install-only fixtures.
# Host --recipe-fixtures is explicitly not target SDK/IPK acceptance.
set -eu
case "${1:-}" in
    --inside)
        [ -r /etc/openwrt_release ] && [ -f /.dockerenv ] || exit 2
        ;;
    --recipe-fixtures) ;;
    *) printf '%s\n' 'usage: test-media-date-package.sh --inside|--recipe-fixtures' >&2; exit 2 ;;
esac
case "$0" in /*) ROOT=${0%/*} ;; *) exit 2 ;; esac
exec python3 "$ROOT/tests/media-date/package-contracts.py"

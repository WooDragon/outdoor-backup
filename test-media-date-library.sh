#!/bin/sh
# Synthetic library contract suite; never mounts, installs or publishes packages.
# Argument: optional --synthetic (the only supported execution mode here).
case "${1:---synthetic}" in --synthetic) ;; *) exit 2 ;; esac
ROOT=$(dirname "$0")
case "$ROOT" in /*) ;; *) printf '%s\n' 'invoke with an absolute suite path' >&2; exit 2 ;; esac
exec python3 "$ROOT/tests/media-date/library-scenarios.py" "$ROOT"

#!/bin/sh
# Given/When/Then regressions against delivered modules in a temporary fixture.
set -eu
ROOT=$(dirname "$0")
case "$ROOT" in /*) ;; *) exit 2 ;; esac
exec python3 "$ROOT/tests/media-date/regressions-scenarios.py" "$ROOT"

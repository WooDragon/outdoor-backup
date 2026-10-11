#!/bin/sh
# Shared synthetic fixture: --inside runs native Linux drain; host supports owned guest.
# Never mounts a real device; blocked drain cases are not suite success.
set -eu
ROOT=$(dirname "$0")
exec python3 "$ROOT/tests/media-date/lifecycle-scenarios.py" "$ROOT" "$@"

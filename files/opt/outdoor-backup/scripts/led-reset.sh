#!/bin/sh
#
# Standalone LED idle-reset for service start/restart (issue #43 scope 3).
#
# This script is invoked (never sourced) by init.d's start()/restart() paths,
# and only when the business lock is absent -- an in-progress backup's
# progress/terminal LEDs must never be wiped by a service start/restart that
# races with an active card being processed. init.d itself must never
# config_load: doing so directly in the rc.common process would leak
# unrelated config side effects into that context. This script is its own
# subprocess, so it may load configuration safely and in isolation.
#
# Args: none. Exit: always 0 -- a reset failure must not fail service start.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
DEBUG=0
LOG_TAG="outdoor-backup"

. "$SCRIPT_DIR/config.sh"
config_load "$BASE_DIR/conf/backup.conf" || exit 0

. "$SCRIPT_DIR/common.sh"
led_state_reset_idle || :

exit 0

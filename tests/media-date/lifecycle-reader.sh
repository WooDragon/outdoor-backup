#!/bin/sh
# Disposable guest reader. Args: fixture base, private view, exact manager PID,
# cancel-live|stop-live. Child deliberately outlives TERM to test real drain.
set -eu
base=$1
view=$2
manager_pid=$3
mode=$4
case "$manager_pid" in ''|*[!0-9]*) exit 2 ;; esac
trap 'exit 143' TERM
(
    trap '' TERM
    sleep 3
    if [ -d "$view" ]; then
        printf '%s\n' child-view-retained >> "$base/events"
    else
        printf '%s\n' child-view-deleted-too-early >> "$base/events"
    fi
) &
(
    sleep 1
    if [ "$mode" = stop-live ]; then : > "$base/lease-stopped"; fi
    # This PID is supplied by the current fixture manager, never discovered/guessed.
    kill -TERM "$manager_pid"
) &
wait

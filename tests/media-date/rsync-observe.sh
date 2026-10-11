#!/bin/ash
# Transparent executable observer: NUL-safe argv, stdout/stderr evidence, no copy.
# RSYNC_FAULT=slow adds only a test-owned rate limit to enable deterministic SIGINT.
# All normal invocations execute the unchanged production argv on /usr/bin/rsync.
printf '%s\0' "$@" > "$RSYNC_EVIDENCE/argv.nul"
printf '%s\n' actual-rsync >> "$RSYNC_EVIDENCE/invocations"
printf '%s\n' "$$" > "$RSYNC_EVIDENCE/pid"
if [ "${RSYNC_FAULT:-}" = slow ]; then
    set -- --bwlimit=128 "$@"
fi
printf '%s\0' /usr/bin/rsync "$@" > "$RSYNC_EVIDENCE/effective-argv.nul"
# FIFOs keep stdout/stderr visible to the real helper while saving diagnostics.
mkfifo "$RSYNC_EVIDENCE/out.pipe" "$RSYNC_EVIDENCE/err.pipe" || exit 1
tee "$RSYNC_EVIDENCE/stdout" < "$RSYNC_EVIDENCE/out.pipe" &
tee "$RSYNC_EVIDENCE/stderr" < "$RSYNC_EVIDENCE/err.pipe" >&2 &
exec /usr/bin/rsync "$@" > "$RSYNC_EVIDENCE/out.pipe" 2> "$RSYNC_EVIDENCE/err.pipe"

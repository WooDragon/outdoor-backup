#!/bin/sh
# Strict legacy CLI wrapper. No configuration, media probing, writes or lock policy.
# Usage: cleanup-all.sh --force|-f BACKUP_ROOT [0|1] (keep aliases defaults to 1).
# Confirmation is CLI-only; trusted administrative consumers invoke manager directly.

# Reject without loading any stateful dependency. Args: fixed code, optional exit status.
cleanup_cli_reject() {
    printf 'outdoor-backup: cleanup error=%s\n' "$1" >&2
    exit "${2-1}"
}

case "${1-}" in
    --force|-f) shift ;;
    *) cleanup_cli_reject force_required ;;
esac
[ "$#" -eq 1 ] || [ "$#" -eq 2 ] || cleanup_cli_reject badargs
[ -n "$1" ] || cleanup_cli_reject badargs
case "$1" in -*) cleanup_cli_reject badargs ;; esac
KEEP_ALIASES=${2-1}
case "$KEEP_ALIASES" in 0|1) ;; *) cleanup_cli_reject badargs ;; esac
SCRIPT_PATH=$(readlink -f "$0") || cleanup_cli_reject failure 3
SCRIPT_DIR=$(dirname "$SCRIPT_PATH") || cleanup_cli_reject failure 3
[ -f "$SCRIPT_DIR/backup-manager.sh" ] && [ -r "$SCRIPT_DIR/backup-manager.sh" ] || cleanup_cli_reject failure 3
exec /bin/sh "$SCRIPT_DIR/backup-manager.sh" cleanup "$1" "$KEEP_ALIASES"

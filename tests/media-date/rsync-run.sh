#!/bin/ash
# Synthetic transfer driver. $1 repo, $2 base, $3 work, $4 library, $5 mode,
# $6 replaced, $7 log. Admission seams do NOT validate real disks/leases.
# Returns the actual delivered runner's result and records its statistics.
set -u
. "$1/files/opt/outdoor-backup/scripts/transfer-process.sh"
. "$1/files/opt/outdoor-backup/scripts/backup-transfer.sh"
BASE_DIR=$2
MEDIA_DATE_WORK=$3
TARGET_BACKUP_ROOT=$4
TARGET_FD_ROOT=${4%/*}
MEDIA_DATE_REPLACED_DIR=$6
BACKUP_LOG_FILE=$7
BACKUP_CANCEL_CODE=0
lock_is_owned_by_self() { return 0; }
target_anchor_healthy() { return 0; }
check_cancel_request() { return 0; }
backup_transfer_date "$MEDIA_DATE_WORK/view" "$TARGET_BACKUP_ROOT" "$BACKUP_LOG_FILE" "$5" "$MEDIA_DATE_REPLACED_DIR"
result=$?
printf '%s\n' "rc=$result files=$BACKUP_TRANSFER_FILES bytes=$BACKUP_TRANSFER_BYTES error=$BACKUP_TRANSFER_ERROR" > "$BASE_DIR/result"
exit "$result"

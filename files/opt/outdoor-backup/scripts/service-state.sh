#!/bin/sh
# Service lifecycle state and flock primitives. This file is source-only:
# definitions below perform no I/O, install no traps, and alter no locale.

# Return 0 only for canonical decimal generations in [0, 2147483647].
service_state_generation_valid() {
    case ${1-} in
        0) return 0 ;;
        ''|0*|*[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -lt 10 ] && return 0
    [ "${#1}" -eq 10 ] && [ "$1" -le 2147483647 ]
}

# Read the kernel PID of this shell without relying on ash's inherited $$.
service_state_self_pid() {
    IFS=' ' read -r SERVICE_STATE_SELF_PID _ < /proc/self/stat || return 1
    case $SERVICE_STATE_SELF_PID in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# Read an FD's mount/inode identity only while it holds the requested flock mode.
# Arguments: fixed FD number; expected kernel lock mode (READ or WRITE).
# Returns: 0 and sets SERVICE_STATE_FD_MNT_ID/SERVICE_STATE_FD_INO, or 1.
service_state_fd_lock_identity() {
    [ "$#" -eq 2 ] || return 1
    SERVICE_STATE_FD_NUMBER=$1
    SERVICE_STATE_FD_MODE=$2
    case $SERVICE_STATE_FD_NUMBER:$SERVICE_STATE_FD_MODE in
        7:WRITE|8:READ|8:WRITE) ;;
        *) return 1 ;;
    esac
    SERVICE_STATE_FD_INFO=$(awk -v mode="$SERVICE_STATE_FD_MODE" '
        $1 == "mnt_id:" { mount_id = $2 }
        $1 == "ino:" { inode = $2 }
        $1 == "lock:" && $3 == "FLOCK" && $4 == "ADVISORY" && $5 == mode { locked = 1 }
        END {
            if (mount_id != "" && inode != "" && locked)
                printf "%s %s\n", mount_id, inode
            else
                exit 1
        }
    ' "/proc/self/fdinfo/$SERVICE_STATE_FD_NUMBER") || return 1
    set -- $SERVICE_STATE_FD_INFO
    [ "$#" -eq 2 ] || return 1
    case $1 in ''|*[!0-9]*) return 1 ;; esac
    case $2 in ''|*[!0-9]*) return 1 ;; esac
    SERVICE_STATE_FD_MNT_ID=$1
    SERVICE_STATE_FD_INO=$2
}

# Return 0 only when the FD still names the recorded lock and owns its flock mode.
# Arguments: FD number, flock mode, recorded mount ID, recorded inode.
service_state_fd_lock_matches() {
    [ "$#" -eq 4 ] || return 1
    service_state_fd_lock_identity "$1" "$2" || return 1
    [ "$SERVICE_STATE_FD_MNT_ID" = "$3" ] && [ "$SERVICE_STATE_FD_INO" = "$4" ]
}

# Return the configured private runtime directory without creating it.
service_state_runtime_dir() {
    printf '%s\n' "${OUTDOOR_BACKUP_SERVICE_DIR:-/var/run/outdoor-backup}"
}

# Reject links and all objects except an existing regular file.
service_state_regular_file() {
    [ ! -L "$1" ] && [ -f "$1" ]
}

# Create or validate the private runtime directory, rejecting a link or file.
service_state_runtime_prepare() {
    SERVICE_STATE_RUNTIME=$(service_state_runtime_dir) || return 1
    if [ -e "$SERVICE_STATE_RUNTIME" ] || [ -L "$SERVICE_STATE_RUNTIME" ]; then
        [ ! -L "$SERVICE_STATE_RUNTIME" ] && [ -d "$SERVICE_STATE_RUNTIME" ] || return 1
        return 0
    fi
    mkdir -m 700 "$SERVICE_STATE_RUNTIME" || return 1
    [ ! -L "$SERVICE_STATE_RUNTIME" ] && [ -d "$SERVICE_STATE_RUNTIME" ]
}

# Return an existing or newly created regular lock file without replacing it.
service_state_lock_file() {
    SERVICE_STATE_LOCK_PATH=$1
    if [ -e "$SERVICE_STATE_LOCK_PATH" ] || [ -L "$SERVICE_STATE_LOCK_PATH" ]; then
        service_state_regular_file "$SERVICE_STATE_LOCK_PATH" || return 1
        return 0
    fi
    : > "$SERVICE_STATE_LOCK_PATH" || return 1
    service_state_regular_file "$SERVICE_STATE_LOCK_PATH"
}

# Run a nonblocking flock acquisition and distinguish contention from tool errors.
# Arguments: flock options followed by the already-open FD. Returns 0 for success,
# 2 only for BusyBox's silent rc=1 contention contract, and 1 otherwise.
service_state_flock_acquire() {
    SERVICE_STATE_FLOCK_DIAGNOSTIC=$(flock "$@" 2>&1)
    SERVICE_STATE_FLOCK_RC=$?
    [ "$SERVICE_STATE_FLOCK_RC" -eq 0 ] && return 0
    if [ "$SERVICE_STATE_FLOCK_RC" -eq 1 ] && [ -z "$SERVICE_STATE_FLOCK_DIAGNOSTIC" ]; then
        return 2
    fi
    printf '%s\n' 'service-state: flock acquisition failed' >&2
    [ -z "$SERVICE_STATE_FLOCK_DIAGNOSTIC" ] || printf '%s\n' "$SERVICE_STATE_FLOCK_DIAGNOSTIC" >&2
    return 1
}

# Parse one raw state file read exactly once before exposing shell variables.
# Arguments: state-file path. Returns 0 and prints mode:generation, otherwise 1.
service_state_parse_record() {
    [ "$#" -eq 1 ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -erRs '
        def valid_generation:
            length >= 1 and length <= 10 and
            (explode | all(. >= 48 and . <= 57)) and
            (. == "0" or .[0:1] != "0") and
            (length < 10 or . <= "2147483647");
        . as $raw |
        (if endswith("\n") then .[0:-1] else . end) as $record |
        ($record | split(":")) as $parts |
        select($parts | length == 2) |
        $parts[0] as $mode |
        $parts[1] as $generation |
        select($mode == "running" or $mode == "stopped") |
        select($generation | valid_generation) |
        "\($mode):\($generation)"
    ' "$1"
}

# Read one strict physical state record into SERVICE_STATE_MODE/GENERATION.
service_state_read() {
    SERVICE_STATE_MODE=
    SERVICE_STATE_GENERATION=
    SERVICE_STATE_RUNTIME=$(service_state_runtime_dir) || return 1
    SERVICE_STATE_PATH="$SERVICE_STATE_RUNTIME/state"

    if [ ! -e "$SERVICE_STATE_PATH" ] && [ ! -L "$SERVICE_STATE_PATH" ]; then
        service_state_rc_enabled && SERVICE_STATE_MODE=running || SERVICE_STATE_MODE=stopped
        SERVICE_STATE_GENERATION=0
        return 0
    fi
    service_state_regular_file "$SERVICE_STATE_PATH" || return 1
    SERVICE_STATE_RECORD=$(service_state_parse_record "$SERVICE_STATE_PATH") || return 1
    case $SERVICE_STATE_RECORD in
        running:*) SERVICE_STATE_NEW_MODE=running; SERVICE_STATE_NEW_GENERATION=${SERVICE_STATE_RECORD#running:} ;;
        stopped:*) SERVICE_STATE_NEW_MODE=stopped; SERVICE_STATE_NEW_GENERATION=${SERVICE_STATE_RECORD#stopped:} ;;
        *) return 1 ;;
    esac
    SERVICE_STATE_MODE=$SERVICE_STATE_NEW_MODE
    SERVICE_STATE_GENERATION=$SERVICE_STATE_NEW_GENERATION
    return 0
}

# Recognize only a resolved /etc/rc.d/SNNoutdoor-backup link to the init script.
service_state_rc_enabled() {
    SERVICE_STATE_RC_DIR=${OUTDOOR_BACKUP_RC_DIR:-/etc/rc.d}
    SERVICE_STATE_INIT=${OUTDOOR_BACKUP_INIT_SCRIPT:-/etc/init.d/outdoor-backup}
    for SERVICE_STATE_RC_LINK in "$SERVICE_STATE_RC_DIR"/S[0-9][0-9]outdoor-backup; do
        [ -L "$SERVICE_STATE_RC_LINK" ] || continue
        SERVICE_STATE_LINK_TARGET=$(readlink -f "$SERVICE_STATE_RC_LINK") || continue
        SERVICE_STATE_INIT_TARGET=$(readlink -f "$SERVICE_STATE_INIT") || continue
        [ "$SERVICE_STATE_LINK_TARGET" = "$SERVICE_STATE_INIT_TARGET" ] && return 0
    done
    return 1
}

# Return 0 only when the original process still owns FD 7's recorded X flock.
service_control_owner() {
    [ "${SERVICE_CONTROL_HELD:-0}" = 1 ] || return 1
    service_state_self_pid || return 1
    [ "$SERVICE_STATE_SELF_PID" = "${SERVICE_CONTROL_OWNER_PID:-}" ] || return 1
    service_state_fd_lock_matches 7 WRITE "${SERVICE_CONTROL_MNT_ID:-}" "${SERVICE_CONTROL_INO:-}"
}

# Acquire the controller lock on fixed FD 7. Returns 2 for ordinary contention.
service_control_acquire() {
    [ ! -e /proc/self/fd/7 ] || return 1
    command -v flock >/dev/null 2>&1 || return 1
    service_state_runtime_prepare || return 1
    service_state_lock_file "$SERVICE_STATE_RUNTIME/control.lock" || return 1
    if exec 7<> "$SERVICE_STATE_LOCK_PATH"; then
        :
    else
        return 1
    fi
    service_state_flock_acquire -x -n 7
    SERVICE_STATE_FLOCK_RC=$?
    if [ "$SERVICE_STATE_FLOCK_RC" -ne 0 ]; then
        exec 7>&-
        return "$SERVICE_STATE_FLOCK_RC"
    fi
    service_state_fd_lock_identity 7 WRITE || { flock -u 7; exec 7>&-; return 1; }
    SERVICE_CONTROL_MNT_ID=$SERVICE_STATE_FD_MNT_ID
    SERVICE_CONTROL_INO=$SERVICE_STATE_FD_INO
    service_state_self_pid || { flock -u 7; exec 7>&-; return 1; }
    SERVICE_CONTROL_HELD=1
    SERVICE_CONTROL_OWNER_PID=$SERVICE_STATE_SELF_PID
    return 0
}

# Clear this shell's control ownership record after it no longer owns FD 7.
service_control_clear() {
    SERVICE_CONTROL_HELD=0
    SERVICE_CONTROL_OWNER_PID=
    SERVICE_CONTROL_MNT_ID=
    SERVICE_CONTROL_INO=
}

# Release the original OFD; a child closes only a verified inherited copy.
service_control_release() {
    [ "${SERVICE_CONTROL_HELD:-0}" = 1 ] || return 0
    service_state_self_pid || return 1
    if [ "$SERVICE_STATE_SELF_PID" != "${SERVICE_CONTROL_OWNER_PID:-}" ]; then
        service_state_fd_lock_matches 7 WRITE "${SERVICE_CONTROL_MNT_ID:-}" "${SERVICE_CONTROL_INO:-}" || return 1
        exec 7>&- || return 1
        service_control_clear
        return 0
    fi
    service_control_owner || return 1
    flock -u 7 || return 1
    exec 7>&- || return 1
    service_control_clear
    return 0
}

# Return 0 only when the original process still owns FD 8's recorded flock.
service_lease_owner() {
    [ "${SERVICE_LEASE_HELD:-0}" = 1 ] || return 1
    service_state_self_pid || return 1
    [ "$SERVICE_STATE_SELF_PID" = "${SERVICE_LEASE_OWNER_PID:-}" ] || return 1
    case ${SERVICE_LEASE_TYPE:-} in
        shared) SERVICE_LEASE_FLOCK_MODE=READ ;;
        exclusive) SERVICE_LEASE_FLOCK_MODE=WRITE ;;
        *) return 1 ;;
    esac
    service_state_fd_lock_matches 8 "$SERVICE_LEASE_FLOCK_MODE" "${SERVICE_LEASE_MNT_ID:-}" "${SERVICE_LEASE_INO:-}"
}

# Clear this shell's lease ownership record after it no longer owns FD 8.
service_lease_clear() {
    SERVICE_LEASE_HELD=0
    SERVICE_LEASE_OWNER_PID=
    SERVICE_LEASE_TYPE=
    SERVICE_LEASE_GENERATION=
    SERVICE_LEASE_MNT_ID=
    SERVICE_LEASE_INO=
}

# Close FD 8 after failed admission before any ownership record was installed.
service_lease_reject() {
    exec 8>&-
    service_lease_clear
}

# Acquire an S lease and admit only the current running generation.
service_lease_acquire() {
    [ "$#" -le 1 ] || return 1
    if [ "$#" -eq 1 ]; then
        [ -n "$1" ] && service_state_generation_valid "$1" || return 1
        SERVICE_LEASE_EXPECTED=$1
    else
        SERVICE_LEASE_EXPECTED=
    fi
    [ ! -e /proc/self/fd/8 ] || return 1
    command -v flock >/dev/null 2>&1 || return 1
    service_state_runtime_prepare || return 1
    service_state_lock_file "$SERVICE_STATE_RUNTIME/admission.lock" || return 1
    if exec 8<> "$SERVICE_STATE_LOCK_PATH"; then
        :
    else
        return 1
    fi
    service_state_flock_acquire -s -n 8 || {
        SERVICE_STATE_FLOCK_RC=$?
        exec 8>&-
        return "$SERVICE_STATE_FLOCK_RC"
    }
    service_state_fd_lock_identity 8 READ || { service_lease_reject; return 1; }
    SERVICE_LEASE_MNT_ID=$SERVICE_STATE_FD_MNT_ID
    SERVICE_LEASE_INO=$SERVICE_STATE_FD_INO
    service_state_read
    SERVICE_STATE_READ_RC=$?
    if [ "$SERVICE_STATE_READ_RC" -ne 0 ]; then
        service_lease_reject
        return 1
    fi
    if [ "$SERVICE_STATE_MODE" != running ] || \
        { [ -n "$SERVICE_LEASE_EXPECTED" ] && [ "$SERVICE_LEASE_EXPECTED" != "$SERVICE_STATE_GENERATION" ]; }; then
        service_lease_reject
        return 2
    fi
    service_state_self_pid || { service_lease_reject; return 1; }
    SERVICE_LEASE_HELD=1
    SERVICE_LEASE_OWNER_PID=$SERVICE_STATE_SELF_PID
    SERVICE_LEASE_TYPE=shared
    SERVICE_LEASE_GENERATION=$SERVICE_STATE_GENERATION
    return 0
}

# Test a held shared lease against current state without releasing or updating it.
service_lease_current() {
    service_lease_owner || return 1
    [ "${SERVICE_LEASE_TYPE:-}" = shared ] || return 1
    service_state_read || return 1
    [ "$SERVICE_STATE_MODE" = running ] && [ "$SERVICE_STATE_GENERATION" = "$SERVICE_LEASE_GENERATION" ] && return 0
    return 2
}

# Acquire admission X on FD 8. Returns 2 for ordinary contention.
service_admission_exclusive() {
    [ ! -e /proc/self/fd/8 ] || return 1
    command -v flock >/dev/null 2>&1 || return 1
    service_state_runtime_prepare || return 1
    service_state_lock_file "$SERVICE_STATE_RUNTIME/admission.lock" || return 1
    if exec 8<> "$SERVICE_STATE_LOCK_PATH"; then
        :
    else
        return 1
    fi
    service_state_flock_acquire -x -n 8 || {
        SERVICE_STATE_FLOCK_RC=$?
        exec 8>&-
        return "$SERVICE_STATE_FLOCK_RC"
    }
    service_state_fd_lock_identity 8 WRITE || { flock -u 8; exec 8>&-; return 1; }
    SERVICE_LEASE_MNT_ID=$SERVICE_STATE_FD_MNT_ID
    SERVICE_LEASE_INO=$SERVICE_STATE_FD_INO
    service_state_self_pid || { flock -u 8; exec 8>&-; return 1; }
    SERVICE_LEASE_HELD=1
    SERVICE_LEASE_OWNER_PID=$SERVICE_STATE_SELF_PID
    SERVICE_LEASE_TYPE=exclusive
    SERVICE_LEASE_GENERATION=
    return 0
}

# Release the original FD 8 owner; a child closes only its verified inherited copy.
service_lease_release() {
    [ "${SERVICE_LEASE_HELD:-0}" = 1 ] || return 0
    service_state_self_pid || return 1
    case ${SERVICE_LEASE_TYPE:-} in
        shared) SERVICE_LEASE_FLOCK_MODE=READ ;;
        exclusive) SERVICE_LEASE_FLOCK_MODE=WRITE ;;
        *) return 1 ;;
    esac
    if [ "$SERVICE_STATE_SELF_PID" != "${SERVICE_LEASE_OWNER_PID:-}" ]; then
        service_state_fd_lock_matches 8 "$SERVICE_LEASE_FLOCK_MODE" "${SERVICE_LEASE_MNT_ID:-}" "${SERVICE_LEASE_INO:-}" || return 1
        exec 8>&- || return 1
        service_lease_clear
        return 0
    fi
    service_lease_owner || return 1
    flock -u 8 || return 1
    exec 8>&- || return 1
    service_lease_clear
    return 0
}

# Atomically publish a strict state record; running requires this caller's X.
service_state_write() {
    [ "$#" -eq 2 ] || return 1
    SERVICE_STATE_WRITE_MODE=$1
    SERVICE_STATE_WRITE_GENERATION=$2
    case $SERVICE_STATE_WRITE_MODE in running|stopped) ;; *) return 1 ;; esac
    service_state_generation_valid "$SERVICE_STATE_WRITE_GENERATION" || return 1
    service_control_owner || return 1
    if [ "$SERVICE_STATE_WRITE_MODE" = running ]; then
        service_lease_owner || return 1
        [ "${SERVICE_LEASE_TYPE:-}" = exclusive ] || return 1
    fi
    service_state_runtime_prepare || return 1
    SERVICE_STATE_PATH="$SERVICE_STATE_RUNTIME/state"
    if [ -e "$SERVICE_STATE_PATH" ] || [ -L "$SERVICE_STATE_PATH" ]; then
        service_state_regular_file "$SERVICE_STATE_PATH" || return 1
    fi
    SERVICE_STATE_OLD_UMASK=$(umask) || return 1
    umask 077
    SERVICE_STATE_TMP=$(mktemp "$SERVICE_STATE_RUNTIME/.state.XXXXXX")
    SERVICE_STATE_TMP_RC=$?
    umask "$SERVICE_STATE_OLD_UMASK"
    [ "$SERVICE_STATE_TMP_RC" -eq 0 ] || return 1
    if ! service_state_regular_file "$SERVICE_STATE_TMP" || \
        ! printf '%s:%s' "$SERVICE_STATE_WRITE_MODE" "$SERVICE_STATE_WRITE_GENERATION" > "$SERVICE_STATE_TMP"; then
        rm -f "$SERVICE_STATE_TMP"
        return 1
    fi
    if ! mv "$SERVICE_STATE_TMP" "$SERVICE_STATE_PATH"; then
        rm -f "$SERVICE_STATE_TMP"
        return 1
    fi
    return 0
}

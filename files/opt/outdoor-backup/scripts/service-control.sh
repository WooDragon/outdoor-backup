#!/bin/sh
#
# Administrative lifecycle controller for outdoor-backup. It owns only FD7/FD8
# and the service record; the backup manager owns data, status, LEDs, mounts,
# and its business lock.
#

SCRIPT_PATH=$(readlink -f "$0") || exit 1
case $SCRIPT_PATH in /*) ;; *) exit 1 ;; esac
SCRIPT_DIR=$(dirname "$SCRIPT_PATH") || exit 1
BASE_DIR=$(dirname "$SCRIPT_DIR") || exit 1
BUSINESS_LOCK="$BASE_DIR/var/lock/backup.lock"
SERVICE_CONTROL_TIMEOUT=60
CONTROL_ACTION=${1-}
CONTROL_PREVIOUS_IDENTITY=
CONTROL_CANDIDATE_GENERATION=
CONTROL_PREVIOUS_GENERATION=
CONTROL_CANCEL_CODE=0
CONTROL_FINALIZED=0

# Emit one coarse, non-sensitive lifecycle diagnostic. Argument: message.
controller_notice() {
    printf 'outdoor-backup: service control: %s\n' "$1" >&2
    logger -t outdoor-backup -p daemon.notice "$1" 2>/dev/null || :
}

# Return zero only if no business-lock object exists, including a dangling link.
business_lock_absent() {
    [ ! -e "$BUSINESS_LOCK" ] && [ ! -L "$BUSINESS_LOCK" ]
}

# Print whole monotonic seconds from /proc/uptime, or return nonzero.
monotonic_seconds() {
    IFS='. ' read -r uptime_seconds _ < /proc/uptime || return 1
    case $uptime_seconds in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$uptime_seconds"
}

# Return the first recorded cancellation status, or zero when none is pending.
controller_abort_if_cancelled() {
    [ "$CONTROL_CANCEL_CODE" -eq 0 ] && return 0
    return "$CONTROL_CANCEL_CODE"
}

# Release FD8 explicitly and preserve a real library failure.
controller_release_lease() {
    service_lease_release && return 0
    controller_notice 'explicit admission release failed'
    return 1
}

# Release FD7 explicitly and preserve a real library failure.
controller_release_control() {
    service_control_release && return 0
    controller_notice 'explicit controller release failed'
    return 1
}

# Compensate only the candidate epoch prepared before an attempted running write.
# A state/lock disagreement is reported as unknown: no process may overwrite a
# different epoch merely because this process once intended to publish one.
controller_rollback_candidate() {
    [ -n "$CONTROL_CANDIDATE_GENERATION" ] || return 0
    if ! service_control_owner; then
        controller_notice 'cannot confirm closed: controller ownership is lost'
        return 1
    fi
    if ! service_state_read; then
        controller_notice 'cannot confirm closed: rollback state read failed'
        return 1
    fi
    case "$SERVICE_STATE_MODE:$SERVICE_STATE_GENERATION" in
        "stopped:$CONTROL_PREVIOUS_GENERATION"|"stopped:$CONTROL_CANDIDATE_GENERATION")
            CONTROL_CANDIDATE_GENERATION=
            return 0
            ;;
        "running:$CONTROL_CANDIDATE_GENERATION") ;;
        *)
            controller_notice 'cannot confirm closed: state differs from candidate generation'
            return 1
            ;;
    esac
    if ! service_state_write stopped "$CONTROL_CANDIDATE_GENERATION"; then
        controller_notice 'cannot confirm closed: rollback state write failed'
        return 1
    fi
    CONTROL_CANDIDATE_GENERATION=
    controller_notice 'new running generation rolled back to stopped'
    return 0
}

# Finalize one process exit. FD8 is attempted before the terminal boundary. At
# that boundary future INT/TERM are intentionally ignored: before FD7 release
# we must make a finite, proved close decision, not let a late signal interrupt
# cleanup after the last point at which this shell may still own controller FD7.
controller_finalize() {
    original_rc=$1
    final_rc=$original_rc
    cleanup_failed=0
    [ "$CONTROL_FINALIZED" -eq 0 ] || return "$original_rc"
    CONTROL_FINALIZED=1
    if [ "$original_rc" -ne 0 ]; then
        controller_rollback_candidate || cleanup_failed=1
    fi
    if ! controller_release_lease; then
        cleanup_failed=1
        controller_rollback_candidate || cleanup_failed=1
    fi
    trap '' INT TERM
    if [ "$final_rc" -eq 0 ] && [ "$CONTROL_CANCEL_CODE" -ne 0 ]; then
        final_rc=$CONTROL_CANCEL_CODE
    fi
    if [ "$final_rc" -ne 0 ]; then
        controller_rollback_candidate || cleanup_failed=1
    fi
    if ! controller_release_control; then
        cleanup_failed=1
        controller_rollback_candidate || cleanup_failed=1
        controller_release_control || cleanup_failed=1
    fi
    if [ "$cleanup_failed" -ne 0 ] && [ "$final_rc" -eq 0 ]; then
        final_rc=1
    fi
    return "$final_rc"
}

# Preserve main status through exactly one EXIT finalization. Signal handlers
# remain installed until the terminal boundary and can only record sticky state.
controller_on_exit() {
    original_rc=$?
    trap - EXIT
    controller_finalize "$original_rc"
    final_rc=$?
    exit "$final_rc"
}

# Record only the first signal; never recursively exit out of finalization.
controller_interrupted() {
    [ "$CONTROL_CANCEL_CODE" -eq 0 ] && CONTROL_CANCEL_CODE=$1
    return 0
}

# Start while FD7 is held. A candidate is recorded before the running publish so
# a TERM in either command boundary can still compensate exactly that epoch.
start_locked() {
    service_state_read || return 1
    case $SERVICE_STATE_MODE in
        running)
            controller_notice 'start requested while already running'
            return 0
            ;;
        stopped) ;;
        *) return 1 ;;
    esac
    [ "$SERVICE_STATE_GENERATION" -lt 2147483647 ] || {
        controller_notice 'start rejected at maximum generation'
        return 1
    }
    controller_abort_if_cancelled || return $?
    service_admission_exclusive
    admission_rc=$?
    [ "$admission_rc" -eq 0 ] || {
        controller_notice 'start rejected because admission is unavailable'
        return "$admission_rc"
    }
    controller_abort_if_cancelled || return $?
    if ! business_lock_absent; then
        controller_notice 'start rejected because business lock exists'
        controller_release_lease || return 1
        return 1
    fi
    CONTROL_PREVIOUS_GENERATION=$SERVICE_STATE_GENERATION
    CONTROL_CANDIDATE_GENERATION=$((SERVICE_STATE_GENERATION + 1))
    controller_abort_if_cancelled || return $?
    service_state_write running "$CONTROL_CANDIDATE_GENERATION"
    write_rc=$?
    controller_abort_if_cancelled || return $?
    if [ "$write_rc" -ne 0 ]; then
        if ! controller_release_lease; then
            controller_notice 'running state write failed; retaining write status'
        fi
        return "$write_rc"
    fi
    if ! controller_release_lease; then
        controller_rollback_candidate || :
        return 1
    fi
    controller_notice 'service started'
    return 0
}

# Ask a proven current manager owner to stop. Returns 2 only when it vanished.
request_owner_stop() {
    business_lock_absent && return 2
    owner_event_stop "$BUSINESS_LOCK" "$SCRIPT_DIR/backup-manager.sh" \
        "$CONTROL_PREVIOUS_IDENTITY"
    owner_rc=$?
    if [ "$owner_rc" -eq 0 ]; then
        CONTROL_PREVIOUS_IDENTITY=$OWNER_EVENT_STOP_IDENTITY
        return 0
    fi
    business_lock_absent && return 2
    return "$owner_rc"
}

# Stop while FD7 is held. Quiescence is proved only by FD8 X plus no business lock.
stop_locked() {
    controller_abort_if_cancelled || return $?
    service_state_read || return 1
    stop_generation=$SERVICE_STATE_GENERATION
    service_state_write stopped "$stop_generation" || return 1
    controller_abort_if_cancelled || return $?
    controller_notice 'service closed; waiting for active work to quiesce'
    stop_started=$(monotonic_seconds) || return 1
    stop_deadline=$((stop_started + SERVICE_CONTROL_TIMEOUT))
    while :; do
        controller_abort_if_cancelled || return $?
        service_admission_exclusive
        admission_rc=$?
        if [ "$admission_rc" -eq 0 ]; then
            if business_lock_absent; then
                controller_release_lease || return 1
                controller_abort_if_cancelled || return $?
                controller_notice 'stop completed after quiescence'
                return 0
            fi
            controller_release_lease || return 1
        elif [ "$admission_rc" -ne 2 ]; then
            controller_notice 'stop failed while checking admission'
            return 1
        fi
        controller_abort_if_cancelled || return $?
        request_owner_stop
        owner_rc=$?
        [ "$owner_rc" -eq 0 ] || [ "$owner_rc" -eq 2 ] || {
            controller_notice 'stop failed because business lock owner is unproven'
            return 1
        }
        stop_now=$(monotonic_seconds) || return 1
        if [ "$stop_now" -ge "$stop_deadline" ]; then
            controller_notice 'stop timed out before quiescence'
            return 1
        fi
        sleep 1 || return 1
    done
}

# Restart inside one FD7 acquisition; a failed stop never reaches start.
restart_locked() {
    stop_locked || return $?
    controller_abort_if_cancelled || return $?
    start_locked
}

case "$#:$CONTROL_ACTION" in
    1:start|1:stop|1:restart) ;;
    *) printf '%s\n' 'usage: service-control.sh start|stop|restart' >&2; exit 1 ;;
esac

# source-only approved libraries; owner-event needs target-device's validator.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/service-state.sh" || exit 1
# shellcheck disable=SC1091
. "$SCRIPT_DIR/target-device.sh" || exit 1
# shellcheck disable=SC1091
. "$SCRIPT_DIR/owner-event.sh" || exit 1
trap controller_on_exit EXIT
trap 'controller_interrupted 130' INT
trap 'controller_interrupted 143' TERM

service_control_acquire
control_rc=$?
if [ "$control_rc" -ne 0 ]; then
    controller_notice 'controller lock is unavailable'
    exit "$control_rc"
fi
controller_abort_if_cancelled || exit $?

case $CONTROL_ACTION in
    start) start_locked ;;
    stop) stop_locked ;;
    restart) restart_locked ;;
esac
main_rc=$?
if [ "$main_rc" -eq 0 ] && [ "$CONTROL_CANCEL_CODE" -ne 0 ]; then
    main_rc=$CONTROL_CANCEL_CODE
fi
exit "$main_rc"

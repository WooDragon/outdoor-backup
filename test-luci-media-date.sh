#!/bin/sh
# Run only in the explicitly owned synthetic OpenWrt guest. /src is read-only.
set -eu
[ "${1:-}" = --inside ] || {
    printf '%s\n' 'Run with: docker exec ob-luci-media-date-20261011 /bin/sh /src/test-luci-media-date.sh --inside' >&2
    exit 2
}
# Own the native default socket: luci.util.ubus() connects without a socket override.
# Refuse even an existing directory rather than reusing somebody else's bus.
socket_dir=/var/run/ubus
socket="$socket_dir/ubus.sock"
ubusd_pid=
rpcd_pid=
diag="${TEST_EVIDENCE:-/tmp}/luci-rpc-bootstrap"
mkdir -p "$diag" /var/run
mkdir "$socket_dir" || { printf '%s\n' 'FAIL: native ubus directory already exists; refusing foreign bus' >&2; exit 1; }

# Stop and reap only our direct children; preserve failures and startup diagnostics.
cleanup_rpc() {
    result=$?
    trap - EXIT INT TERM
    for daemon_pid in "$rpcd_pid" "$ubusd_pid"; do
        [ -n "$daemon_pid" ] || continue
        if kill -0 "$daemon_pid" 2>/dev/null; then
            kill -TERM "$daemon_pid" 2>/dev/null || result=1
        fi
        daemon_rc=0
        wait "$daemon_pid" || daemon_rc=$?
        case "$daemon_rc" in 0|143) ;; *) result=1 ;; esac
        printf 'pid=%s wait_rc=%s\n' "$daemon_pid" "$daemon_rc" >> "$diag/cleanup.log"
    done
    rm -f "$socket" || result=1
    rmdir "$socket_dir" || result=1
    printf 'socket_removed=%s exit=%s\n' "$([ ! -e "$socket" ] && printf yes || printf no)" "$result" >> "$diag/cleanup.log"
    exit "$result"
}
trap cleanup_rpc EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Bound readiness, including child death, with the real client (not a mock RPC).
rpc_fail() {
    printf 'FAIL: %s; diagnostics: %s\n' "$1" "$diag" >&2
    exit 1
}
/sbin/ubusd -s "$socket" > "$diag/ubusd.stdout" 2> "$diag/ubusd.stderr" &
ubusd_pid=$!
tries=0
while [ ! -S "$socket" ]; do
    kill -0 "$ubusd_pid" 2>/dev/null || rpc_fail 'owned ubusd exited before socket readiness'
    tries=$((tries + 1))
    [ "$tries" -lt 10 ] || rpc_fail 'owned ubusd socket readiness timed out'
    sleep 1
done
/sbin/rpcd -s "$socket" > "$diag/rpcd.stdout" 2> "$diag/rpcd.stderr" &
rpcd_pid=$!
tries=0
while :; do
    kill -0 "$ubusd_pid" 2>/dev/null && kill -0 "$rpcd_pid" 2>/dev/null || rpc_fail 'owned RPC daemon exited before session readiness'
    if ubus -s "$socket" -t 1 list session > "$diag/session.object" 2> "$diag/session.stderr" &&
        [ "$(cat "$diag/session.object")" = session ]; then
        break
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 10 ] || rpc_fail 'real rpcd session object readiness timed out'
    sleep 1
done
ubus -s "$socket" -t 1 -v list session > "$diag/session.methods" 2>> "$diag/session.stderr" || rpc_fail 'cannot inspect real session methods'
printf 'owned ubusd/rpcd ready; socket=%s\n' "$socket"
mkdir -p /opt/outdoor-backup/scripts /opt/outdoor-backup/conf /tmp/luci-date-bin
cp /src/files/opt/outdoor-backup/scripts/config.sh /opt/outdoor-backup/scripts/config.sh
printf '%s\n' '#!/bin/sh' 'if [ "$(readlink /proc/self/fd/9)" = /tmp/luci-date-fd ]; then printf "inherited\n"; else printf "closed\n"; fi > /tmp/luci-child-fd' 'exec /usr/bin/jq "$@"' > /tmp/luci-date-bin/jq
chmod +x /tmp/luci-date-bin/jq
printf '%s\n' 'synthetic FD anchor' > /tmp/luci-date-fd
PATH="/tmp/luci-date-bin:$PATH" lua /src/tests/media-date/luci-contracts.lua 9</tmp/luci-date-fd

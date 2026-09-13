#!/bin/ash
# Execute exactly one existing root test suite inside the pinned OpenWrt CI guest.

set -u

UPSTREAM_COMMIT='5fa11a1b5689154d296fdacf1e16a7abccb897b9'
FUNCTIONS_SHA256='0a834605bca24da7d31e15f6f37767290d12f95b1cdb5804f797684b329f66dc'
RC_COMMON_SHA256='dd8ae95c78d10cccf78cb487874f163ace4c1ee14dace05fe28393b19ba639e4'
FUNCTIONS_URL="https://raw.githubusercontent.com/immortalwrt/immortalwrt/$UPSTREAM_COMMIT/package/base-files/files/lib/functions.sh"
RC_COMMON_URL="https://raw.githubusercontent.com/immortalwrt/immortalwrt/$UPSTREAM_COMMIT/package/base-files/files/etc/rc.common"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

require_opkg() {
    opkg update >/dev/null || fail 'cannot refresh OpenWrt package metadata'
    opkg install --force-space "$@" >/dev/null || fail "cannot install required packages: $*"
}

prepare_state_reader() {
    mkdir -p /tmp/reader/runtime /var/lock || fail 'cannot create service-state reader fixture'
    printf 'running:7\n' > /tmp/reader/runtime/state || fail 'cannot write service-state reader fixture'
    [ "$(id -u)" = 0 ] || fail 'service-state reader fixture requires guest root'
    chmod 755 /tmp/reader /tmp/reader/runtime || fail 'cannot set service-state reader directory modes'
    chmod 600 /tmp/reader/runtime/state || fail 'cannot protect service-state reader state'
    : > /tmp/state-reader-uid || fail 'cannot create service-state UID evidence file'
    chmod 666 /tmp/state-reader-uid || fail 'cannot make service-state UID evidence writable'
    rm -f /tmp/state-reader-never-created.pid || fail 'cannot clear state-reader pidfile'
    [ ! -e /tmp/state-reader-never-created.pid ] && [ ! -L /tmp/state-reader-never-created.pid ] || fail 'state-reader pidfile already exists'

    if start-stop-daemon -S -p /tmp/state-reader-never-created.pid -c 65534:65534 -x /bin/ash -- -c '
        id -u > /tmp/state-reader-uid || exit 1
        OUTDOOR_BACKUP_SERVICE_DIR=/tmp/reader/runtime
        export OUTDOOR_BACKUP_SERVICE_DIR
        . /src/files/opt/outdoor-backup/scripts/service-state.sh
        service_state_read
        printf "rc=%s\\n" "$?"
    ' > "$TEST_EVIDENCE/reader.stdout" 2> "$TEST_EVIDENCE/reader.stderr"; then
        reader_command_rc=0
    else
        reader_command_rc=$?
    fi
    printf '%s\n' "$reader_command_rc" > "$TEST_EVIDENCE/reader.rc" || fail 'cannot save service-state reader command status'
    cat /tmp/state-reader-uid > "$TEST_EVIDENCE/reader.uid" || fail 'cannot save service-state reader UID evidence'
    rm -f /tmp/state-reader-uid

    [ "$reader_command_rc" -eq 0 ] || fail 'service-state UID reader did not complete its observation command'
    [ "$(cat "$TEST_EVIDENCE/reader.uid")" = 65534 ] || fail 'service-state reader did not run as UID 65534'
    [ "$(cat "$TEST_EVIDENCE/reader.stdout")" = 'rc=1' ] || fail 'service-state reader did not observe state read failure'
    grep -F -q 'Permission denied' "$TEST_EVIDENCE/reader.stderr" || fail 'service-state reader did not receive a real permission-denied diagnostic'
}

prepare_lifecycle_wrappers() {
    upstream_root="$TEST_EVIDENCE/upstream"
    mkdir -p "$upstream_root" || fail 'cannot create lifecycle wrapper evidence directory'
    require_opkg curl ca-bundle
    curl --fail --silent --show-error --location "$FUNCTIONS_URL" > "$upstream_root/functions.sh" || fail 'cannot fetch pinned ImmortalWrt functions.sh'
    curl --fail --silent --show-error --location "$RC_COMMON_URL" > "$upstream_root/rc.common" || fail 'cannot fetch pinned ImmortalWrt rc.common'
    [ "$(sha256sum "$upstream_root/functions.sh" | awk '{print $1}')" = "$FUNCTIONS_SHA256" ] || fail 'pinned functions.sh checksum changed'
    [ "$(sha256sum "$upstream_root/rc.common" | awk '{print $1}')" = "$RC_COMMON_SHA256" ] || fail 'pinned rc.common checksum changed'
    printf '%s\n' "$UPSTREAM_COMMIT" > "$upstream_root/commit" || fail 'cannot save lifecycle wrapper commit marker'
}

validate_suite() {
    [ "$#" -eq 1 ] || {
        printf '%s\n' 'usage: ci-suite.sh test-*.sh' >&2
        exit 64
    }
    suite=$1
    [ "$suite" = "${suite##*/}" ] && [ "$suite" = "${suite##*\\}" ] || {
        printf 'FAIL: suite must be a basename: %s\n' "$suite" >&2
        exit 64
    }
    case $suite in
        test-backup-core.sh|test-card-config.sh|test-card-identity.sh|test-card-reader.sh|test-cleanup.sh|test-config.sh|test-hotplug-service.sh|test-led.sh|test-lock.sh|test-luci-target-config.sh|test-manager-cancellation.sh|test-manager-removal.sh|test-manager-service.sh|test-manager-source-identity.sh|test-owner-event.sh|test-service-control.sh|test-service-lifecycle.sh|test-service-state.sh|test-source-identity.sh|test-status.sh|test-storage-lifecycle.sh|test-target-anchor.sh|test-target-device.sh|test-target-manager.sh|test-transfer-process.sh) ;;
        *)
            printf 'FAIL: unsupported suite: %s\n' "$suite" >&2
            exit 64
            ;;
    esac
}

main() {
    [ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || fail 'ci-suite requires the pinned OpenWrt guest'
    [ -d /src ] && [ -d /evidence ] || fail 'ci-suite requires /src and /evidence mounts'
    validate_suite "$@"
    mkdir -p /var/lock || fail 'cannot create OpenWrt package lock directory'
    TEST_EVIDENCE=/evidence
    export TEST_EVIDENCE

    case $suite in
        test-service-state.sh)
            require_opkg jq
            prepare_state_reader
            exec /bin/ash "/src/$suite" --inside
            ;;
        test-service-lifecycle.sh)
            prepare_lifecycle_wrappers
            exec /bin/ash "/src/$suite" --inside
            ;;
        test-cleanup.sh)
            require_opkg bash jq
            exec /bin/bash "/src/$suite"
            ;;
        test-config.sh|test-card-reader.sh|test-led.sh)
            exec env IN_OPENWRT_TEST=1 /bin/ash "/src/$suite"
            ;;
        test-owner-event.sh)
            exec env IN_OWNER_EVENT_TEST=1 /bin/ash "/src/$suite"
            ;;
        *)
            exec /bin/ash "/src/$suite" --inside
            ;;
    esac
}

main "$@"

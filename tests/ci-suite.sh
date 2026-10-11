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

# Test-only provider bootstrap. This is verified source loading, NOT an IPK install.
prepare_media_date() {
    require_opkg python3 perl perlbase-essential perlbase-findbin perlbase-json-pp \
        perlbase-digest perlbase-encode perlbase-fcntl perlbase-time perlbase-cwd \
        perlbase-b perlbase-file perlbase-storable perlbase-test perlbase-mro jq rsync curl ca-bundle
    python3 -c 'import importlib.util, io, json, os, pathlib, re, shutil, subprocess, sys, tempfile, unittest' || \
        fail 'BLOCKED: actual OpenWrt Python test modules unavailable'
    provider_root=/tmp/outdoor-test-exiftool
    mkdir -p "$provider_root" || fail 'cannot create test-owned provider directory'
    curl --fail --silent --show-error --location \
        https://downloads.sourceforge.net/project/exiftool/Image-ExifTool-13.59.tar.gz \
        -o "$provider_root/source.tar.gz" || fail 'BLOCKED: fixed ExifTool test source unavailable'
    printf '%s  %s\n' \
        668ea3acececb7235fbd0f4900e72d5f12c9b07e5c778fd36cb1e9b5828fd65a \
        "$provider_root/source.tar.gz" | sha256sum -c - || fail 'ExifTool test source hash mismatch'
    tar -xzf "$provider_root/source.tar.gz" -C "$provider_root" || fail 'cannot extract verified ExifTool test source'
    PERL5LIB="$provider_root/Image-ExifTool-13.59/lib:/src/files/opt/outdoor-backup/lib"
    export PERL5LIB
    perl -MImage::ExifTool -MJSON::PP -MDigest::SHA -MEncode -MFindBin -MCwd -MFcntl -MTime::Local -MB \
        -e 'die "ExifTool version mismatch" unless $Image::ExifTool::VERSION eq "13.59"; print "actual guest moduleload OK\n"' || \
        fail 'BLOCKED: actual guest Perl module load failed'
    printf '%s\n' 'provider=verified-source-moduleload; synthetic packaging; SDK/IPK/G3=BLOCKED (no actual provider IPK installed)' \
        > "$TEST_EVIDENCE/provider.txt"
    cat "$TEST_EVIDENCE/provider.txt"
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
        test-media-date-regressions.sh|test-media-date-package.sh|test-media-date-helper.sh|test-media-date-manager.sh|test-media-date-transfer.sh|test-media-date-library.sh|test-media-date-lifecycle.sh|test-luci-media-date.sh|test-backup-core.sh|test-backup-progress.sh|test-card-config.sh|test-card-identity.sh|test-card-reader.sh|test-cleanup.sh|test-config.sh|test-feed-layout.sh|test-hotplug-service.sh|test-led-lifecycle.sh|test-led.sh|test-live-progress.sh|test-lock.sh|test-luci-acl.sh|test-luci-target-config.sh|test-luci-target-fd.sh|test-luci-target-selection.sh|test-manager-cancellation.sh|test-manager-removal.sh|test-manager-service.sh|test-manager-source-identity.sh|test-owner-event.sh|test-service-control.sh|test-service-lifecycle.sh|test-service-state.sh|test-source-identity.sh|test-status.sh|test-storage-lifecycle.sh|test-target-anchor.sh|test-target-device.sh|test-target-list.sh|test-target-manager.sh|test-transfer-process.sh) ;;
        *)
            printf 'FAIL: unsupported suite: %s\n' "$suite" >&2
            exit 64
            ;;
    esac
}

main() {
    [ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || fail 'ci-suite requires the pinned OpenWrt guest'
    [ -d /src ] && [ -d /evidence ] || fail 'ci-suite requires /src and /evidence mounts'
    mkdir -p /var/lock || fail 'cannot create OpenWrt package lock directory'
    TEST_EVIDENCE=/evidence
    export TEST_EVIDENCE
    if [ "$#" -eq 1 ] && [ "$1" = --probe-media-date-modules ]; then
        prepare_media_date
        printf '%s\n' 'module probe only; behavior cases=0; SDK/IPK/G3=BLOCKED'
        return 0
    fi
    validate_suite "$@"

    case $suite in
        test-media-date-package.sh)
            require_opkg python3 coreutils-install
            exec /bin/ash "/src/$suite" --inside
            ;;
        test-media-date-helper.sh)
            prepare_media_date
            exec /bin/ash "/src/$suite" --inside
            ;;
        test-media-date-library.sh)
            prepare_media_date
            exec /bin/ash "/src/$suite" --synthetic
            ;;
        test-media-date-manager.sh|test-media-date-transfer.sh)
            prepare_media_date
            exec /bin/ash "/src/$suite"
            ;;
        test-media-date-regressions.sh)
            prepare_media_date
            require_opkg lua
            exec /bin/ash "/src/$suite"
            ;;
        test-media-date-lifecycle.sh)
            prepare_media_date
            printf 'native lifecycle kernel=%s arch=%s; real /proc; source=/src (read-only)\n' "$(uname -s)" "$(uname -m)"
            exec /bin/ash "/src/$suite" --inside "$TEST_EVIDENCE/lifecycle.json"
            ;;
        test-luci-media-date.sh)
            require_opkg ubusd ubus rpcd libuci-lua lua luci-base luci-compat luci-lib-jsonc luci-lib-nixio jq node
            /bin/ash "/src/$suite" --inside || fail 'LuCI media-date Lua contracts failed'
            [ -r /www/luci-static/resources/luci.js ] || fail 'BLOCKED: installed guest LuCI XHR source unavailable'
            exec node /src/tests/media-date/luci-ui.js /www/luci-static/resources/luci.js
            ;;
        test-backup-progress.sh)
            require_opkg jq
            exec /bin/ash "/src/$suite" --inside
            ;;
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
        test-config.sh|test-card-reader.sh|test-led.sh|test-led-lifecycle.sh|test-luci-acl.sh)
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

# Host-side allowlist preflight performs no guest mutation or dependency install.
if [ "${1:-}" = --validate-suite ]; then
    shift
    validate_suite "$@"
    exit 0
fi
main "$@"

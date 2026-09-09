#!/bin/sh
#
# BDD regression tests for storage lifecycle safety.
# The host entry point always replaces itself with the pinned OpenWrt container.
#

set -eu

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 \
        -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-storage-lifecycle.sh --inside
fi

if [ ! -f /.dockerenv ]; then
    printf '%s\n' 'FAIL: --inside requires the Docker container marker /.dockerenv' >&2
    exit 1
fi
if [ ! -r /etc/openwrt_release ] || \
    ! grep -q '^DISTRIB_ID=' /etc/openwrt_release || \
    ! grep -q 'OpenWrt' /etc/openwrt_release; then
    printf '%s\n' 'FAIL: --inside requires an OpenWrt rootfs' >&2
    exit 1
fi

REPO_ROOT=/src
MAKEFILE="$REPO_ROOT/Makefile"
INIT_SCRIPT=/etc/init.d/outdoor-backup
STORAGE_ROOT=/mnt/ssd/SDMirrors
ALIAS_FILE=/opt/outdoor-backup/conf/aliases.json
SERVICE_LINK=/etc/rc.d/S99outdoor-backup
STAGING_ROOT=/tmp/staging
TEST_ROOT="/tmp/outdoor-backup-storage-lifecycle.$$"
POSTINST_FILE="$TEST_ROOT/postinst"
SENTINEL_FILE="$STORAGE_ROOT/sentinel"
CASES=0
ASSERTIONS=0
FAILED=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILED=$((FAILED + 1))
}

begin_case() {
    CASES=$((CASES + 1))
    printf 'CASE %s: %s\n' "$1" "$2"
}

assert_success() {
    message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! "$@"; then
        fail "$message"
    fi
}

assert_equal() {
    actual=$1
    expected=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$actual" != "$expected" ]; then
        fail "$message (expected=[$expected], actual=[$actual])"
    fi
}

assert_path_exists() {
    path=$1
    message=$2
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ ! -e "$path" ]; then
        fail "$message (missing path: $path)"
    fi
}

assert_path_absent() {
    path=$1
    message=$2
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ -e "$path" ] || [ -L "$path" ]; then
        fail "$message (path exists: $path)"
    fi
}

assert_symlink() {
    path=$1
    message=$2
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ ! -L "$path" ]; then
        fail "$message (not a symlink: $path)"
    fi
}

assert_files_equal() {
    first_file=$1
    second_file=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! cmp -s "$first_file" "$second_file"; then
        fail "$message"
    fi
}

cleanup_test_data() {
    rm -rf "$TEST_ROOT" "$STAGING_ROOT" "$STORAGE_ROOT"
    rm -f "$ALIAS_FILE" "$SERVICE_LINK"
}

reset_owned_state() {
    rm -rf "$STORAGE_ROOT" "$STAGING_ROOT"
    rm -f "$ALIAS_FILE" "$SERVICE_LINK"
}

prepare_fixture() {
    mkdir -p /var/lock /opt/outdoor-backup /etc/init.d /etc/config \
        /etc/hotplug.d/block
    cp -R "$REPO_ROOT/files/opt/outdoor-backup/." /opt/outdoor-backup/
    cp "$REPO_ROOT/files/etc/init.d/outdoor-backup" "$INIT_SCRIPT"
    cp "$REPO_ROOT/files/etc/config/outdoor-backup" /etc/config/outdoor-backup
    cp "$REPO_ROOT/files/etc/hotplug.d/block/90-outdoor-backup" \
        /etc/hotplug.d/block/90-outdoor-backup
    chmod 755 "$INIT_SCRIPT"
    rm -f "$ALIAS_FILE" "$SERVICE_LINK"
}

extract_postinst() {
    mkdir -p "$TEST_ROOT"
    if ! awk '
        $0 == "define Package/outdoor-backup/postinst" {
            definitions += 1
            if (in_block) {
                invalid = 1
            }
            in_block = 1
            next
        }
        in_block && $0 == "endef" {
            if (lines == 0) {
                invalid = 1
            }
            in_block = 0
            next
        }
        in_block {
            gsub(/\$\$/, "$")
            print
            lines += 1
            if ($0 ~ /[^[:space:]]/) {
                nonempty = 1
            }
        }
        END {
            if (definitions != 1 || in_block || invalid || !nonempty) {
                exit 1
            }
        }
    ' "$MAKEFILE" > "$POSTINST_FILE"; then
        printf '%s\n' 'FAIL: Makefile postinst definition is not exactly one non-empty block' >&2
        exit 1
    fi
    chmod 755 "$POSTINST_FILE"
}

run_postinst() {
    unset IPKG_INSTROOT
    /bin/ash "$POSTINST_FILE"
}

run_staged_postinst() {
    IPKG_INSTROOT="$STAGING_ROOT" /bin/ash "$POSTINST_FILE"
}

run_start_service() {
    /bin/ash -c '. "$1"; start_service' outdoor-backup-init "$INIT_SCRIPT"
}

case_l01_install_without_storage() {
    begin_case L01 'postinst does not create absent backup storage'
    reset_owned_state
    assert_success 'L01 actual postinst should return zero' run_postinst
    assert_path_absent "$STORAGE_ROOT" \
        'L01 postinst created the absent backup storage directory'
    assert_path_exists "$ALIAS_FILE" \
        'L01 postinst did not initialize aliases.json'
    assert_path_exists "$SERVICE_LINK" \
        'L01 postinst did not enable the service at START99'
    assert_symlink "$SERVICE_LINK" \
        'L01 generated START99 entry is not a symlink'
    assert_equal "$(readlink "$SERVICE_LINK" 2>/dev/null || true)" \
        '../init.d/outdoor-backup' \
        'L01 generated START99 link targets the delivered init script'
}

case_l02_start_without_storage() {
    begin_case L02 'start_service preserves absent backup storage'
    reset_owned_state
    rm -rf /opt/outdoor-backup/var/lock /opt/outdoor-backup/log
    assert_success 'L02 actual start_service should return zero' run_start_service
    assert_path_absent "$STORAGE_ROOT" \
        'L02 start_service created the absent backup storage directory'
    assert_path_exists /opt/outdoor-backup/var/lock \
        'L02 start_service did not create the runtime lock directory'
    assert_path_exists /opt/outdoor-backup/log \
        'L02 start_service did not create the runtime log directory'
}

case_l03_staging_install_skips_runtime_actions() {
    begin_case L03 'staged postinst skips runtime initialization'
    reset_owned_state
    assert_success 'L03 staged actual postinst should return zero' run_staged_postinst
    assert_path_absent "$STORAGE_ROOT" \
        'L03 staged postinst created backup storage'
    assert_path_absent "$ALIAS_FILE" \
        'L03 staged postinst created aliases.json'
    assert_path_absent "$SERVICE_LINK" \
        'L03 staged postinst enabled the service'
}

case_l04_existing_storage_is_untouched() {
    begin_case L04 'existing backup storage remains untouched'
    reset_owned_state
    mkdir -p "$(dirname "$SENTINEL_FILE")"
    printf '%s\n' 'storage sentinel must remain unchanged' > "$SENTINEL_FILE"
    cp "$SENTINEL_FILE" "$TEST_ROOT/sentinel.before"
    sentinel_before_hash=$(sha256sum "$SENTINEL_FILE")
    assert_success 'L04 actual postinst should return zero' run_postinst
    assert_success 'L04 actual start_service should return zero' run_start_service
    sentinel_after_hash=$(sha256sum "$SENTINEL_FILE" 2>/dev/null || printf '%s' missing)
    assert_equal "$sentinel_after_hash" "$sentinel_before_hash" \
        'L04 sentinel hash changed'
    assert_files_equal "$SENTINEL_FILE" "$TEST_ROOT/sentinel.before" \
        'L04 sentinel content changed'
    assert_path_absent "$STORAGE_ROOT/.logs" \
        'L04 lifecycle created an extra .logs directory'
}

main() {
    if [ ! -r /etc/rc.common ]; then
        printf '%s\n' 'FAIL: OpenWrt rootfs lacks native /etc/rc.common' >&2
        exit 1
    fi
    trap cleanup_test_data EXIT INT TERM
    prepare_fixture
    extract_postinst
    case_l01_install_without_storage
    case_l02_start_without_storage
    case_l03_staging_install_skips_runtime_actions
    case_l04_existing_storage_is_untouched

    assert_equal "$CASES" '4' 'all required cases executed'
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$ASSERTIONS" -ne 21 ]; then
        fail "all required assertions executed (expected=21, actual=$ASSERTIONS)"
    fi
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' \
            "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

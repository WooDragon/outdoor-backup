#!/bin/sh
#
# BDD tests for the target mount FD anchor primitive.
# The host entry point replaces itself with a pinned, short-lived OpenWrt
# container. Every mount and path below is owned by this test process.
#

set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 --network none --read-only \
        --cap-add SYS_ADMIN --security-opt seccomp=unconfined --tmpfs /tmp \
        -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-target-anchor.sh --inside
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
TARGET_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/target.sh"
TEST_ROOT="/tmp/outdoor-backup-target-anchor.$$"
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

assert_failure() {
    message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    if "$@"; then
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

assert_absent() {
    path=$1
    message=$2
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ -e "$path" ] || [ -L "$path" ]; then
        fail "$message (path exists: $path)"
    fi
}

assert_present() {
    path=$1
    message=$2
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ ! -e "$path" ]; then
        fail "$message (path missing: $path)"
    fi
}

mount_tmpfs() {
    mkdir -p "$1"
    mount -t tmpfs -o rw,size=1m tmpfs "$1"
}

unmount_owned() {
    if [ -n "$(mount_id_for_path "$1")" ]; then
        umount "$1" 2>/dev/null || :
    fi
}

reset_target_state() {
    target_close >/dev/null 2>&1 || :
    unmount_owned "$TEST_ROOT/target"
    unmount_owned "$TEST_ROOT/space target"
    rm -rf "$TEST_ROOT"
    mkdir -p "$TEST_ROOT"
}

cleanup_test_data() {
    target_close >/dev/null 2>&1 || :
    unmount_owned "$TEST_ROOT/target"
    unmount_owned "$TEST_ROOT/space target"
    rm -rf "$TEST_ROOT"
}

mount_id_for_path() {
    expected=$1
    awk -v expected="$expected" '
        function decode(value) {
            gsub(/\\040/, " ", value)
            gsub(/\\011/, "\t", value)
            gsub(/\\012/, "\n", value)
            gsub(/\\134/, "\\", value)
            return value
        }
        decode($5) == expected { print $1; exit }
    ' /proc/self/mountinfo
}

case_t00_source_is_side_effect_free() {
    begin_case T00 'sourcing the library creates no target state or anchor FD'
    # shellcheck disable=SC2016 # The fresh shell must evaluate its own state.
    assert_success 'T00 source has no runtime target state' /bin/ash -c '
        . "$1"
        test -z "${TARGET_MOUNT_ID+x}" && test -z "${TARGET_FD_ROOT+x}" &&
            test ! -e /proc/$$/fd/9
    ' target-source "$TARGET_SCRIPT"
}

case_t01_invalid_parameters_and_absent_paths() {
    begin_case T01 'rejects malformed, missing, and symlink mount paths'
    reset_target_state
    for invalid_path in '' / relative /bad//path /bad/./path /bad/../path \
        /bad/. /bad/.. "$(printf '/bad\npath')"; do
        assert_failure "T01 rejects [$invalid_path]" target_open "$invalid_path"
    done
    assert_failure 'T01 rejects absent directory without creating it' \
        target_open "$TEST_ROOT/absent"
    assert_absent "$TEST_ROOT/absent" 'T01 open created the absent directory'
    mkdir -p "$TEST_ROOT/real-directory"
    ln -s "$TEST_ROOT/real-directory" "$TEST_ROOT/link-directory"
    assert_failure 'T01 rejects a symlink itself as the mount path' \
        target_open "$TEST_ROOT/link-directory"
}

case_t02_non_mount_and_read_only_rejected() {
    begin_case T02 'rejects ordinary directories and read-only mounts before use'
    reset_target_state
    mkdir -p "$TEST_ROOT/ordinary"
    assert_failure 'T02 ordinary directory is not an independent mount' \
        target_open "$TEST_ROOT/ordinary"
    assert_equal "${TARGET_MOUNT_ID:-}" '' 'T02 ordinary directory left no target state'
    mount_tmpfs "$TEST_ROOT/target"
    mount -o remount,ro "$TEST_ROOT/target"
    assert_failure 'T02 read-only mount is rejected before FD use' \
        target_open "$TEST_ROOT/target"
    assert_equal "${TARGET_MOUNT_ID:-}" '' 'T02 read-only rejection left no target state'
    mount -o remount,rw "$TEST_ROOT/target"
    unmount_owned "$TEST_ROOT/target"
}

case_t02b_external_fd_is_preserved() {
    begin_case T02b 'refuses a caller-owned FD 9 without closing it'
    reset_target_state
    mkdir -p "$TEST_ROOT/caller-fd"
    mount_tmpfs "$TEST_ROOT/target"
    exec 9<"$TEST_ROOT/caller-fd"
    assert_failure 'T02b refuses target open while caller owns FD 9' \
        target_open "$TEST_ROOT/target"
    assert_present /proc/$$/fd/9 'T02b did not preserve caller FD 9'
    assert_equal "$(readlink /proc/$$/fd/9)" "$TEST_ROOT/caller-fd" \
        'T02b changed caller FD 9 target'
    exec 9<&-
    unmount_owned "$TEST_ROOT/target"
}

case_t03_open_tracks_exact_mount() {
    begin_case T03 'opens a rw tmpfs and records its exact mount identity'
    reset_target_state
    mount_tmpfs "$TEST_ROOT/target"
    expected_id=$(mount_id_for_path "$TEST_ROOT/target")
    assert_success 'T03 opens a rw tmpfs target' target_open "$TEST_ROOT/target/"
    assert_equal "$TARGET_MOUNT_PATH" "$TEST_ROOT/target" 'T03 normalizes trailing slash'
    assert_equal "$TARGET_MOUNT_ID" "$expected_id" 'T03 stores the mountinfo ID, not an ancestor ID'
    assert_equal "$TARGET_FS_TYPE" tmpfs 'T03 stores filesystem type'
    assert_present "$TARGET_FD_ROOT" 'T03 retains an open FD path'
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! printf data > "$TARGET_FD_ROOT/proof"; then
        fail 'T03 writes through the anchored FD'
    fi
    assert_equal "$(cat "$TEST_ROOT/target/proof")" data 'T03 anchored FD reaches target mount'
}

case_t04_normal_unmount_is_busy() {
    begin_case T04 'open target FD prevents ordinary unmount without damage'
    assert_failure 'T04 normal umount is EBUSY while FD is open' umount "$TEST_ROOT/target"
    assert_success 'T04 target remains healthy after failed normal umount' target_anchor_healthy
    assert_equal "$(cat "$TEST_ROOT/target/proof")" data 'T04 failed normal umount preserved target data'
}

case_t05_lazy_detach_fails_health_and_keeps_old_vfs() {
    begin_case T05 'lazy detach invalidates health while FD remains on old VFS'
    target_close
    unmount_owned "$TEST_ROOT/target"
    mkdir -p "$TEST_ROOT/target"
    printf '%s\n' lower > "$TEST_ROOT/target/lower-sentinel"
    mount_tmpfs "$TEST_ROOT/target"
    assert_success 'T05 opens mounted target before lazy detach' target_open "$TEST_ROOT/target"
    assert_success 'T05 lazy detaches the mount' umount -l "$TEST_ROOT/target"
    assert_failure 'T05 detached mount is unhealthy despite open FD' target_anchor_healthy
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! printf old > "$TARGET_FD_ROOT/old-fd-only"; then
        fail 'T05 writes through FD after lazy detach'
    fi
    assert_absent "$TEST_ROOT/target/old-fd-only" 'T05 FD write leaked into naked lower directory'
    assert_present "$TEST_ROOT/target/lower-sentinel" 'T05 lower directory changed unexpectedly'
    target_close
}

case_t06_replacement_mount_does_not_pass_old_anchor() {
    begin_case T06 'same path on a replacement tmpfs cannot validate old FD'
    reset_target_state
    mount_tmpfs "$TEST_ROOT/target"
    assert_success 'T06 opens first tmpfs' target_open "$TEST_ROOT/target"
    old_id=$TARGET_MOUNT_ID
    assert_success 'T06 lazy detaches first tmpfs' umount -l "$TEST_ROOT/target"
    mount_tmpfs "$TEST_ROOT/target"
    new_id=$(mount_id_for_path "$TEST_ROOT/target")
    assert_failure 'T06 replacement mount does not validate old anchor' target_anchor_healthy
    assert_equal "$TARGET_MOUNT_ID" "$old_id" 'T06 health failure does not adopt replacement ID'
    assert_failure 'T06 replacement ID differs from old ID' test "$new_id" = "$old_id"
    target_close
    unmount_owned "$TEST_ROOT/target"
}

case_t07_remount_read_only_fails_health() {
    begin_case T07 'rw-to-ro remount invalidates the anchored target'
    reset_target_state
    mount_tmpfs "$TEST_ROOT/target"
    assert_success 'T07 opens rw target' target_open "$TEST_ROOT/target"
    mount -o remount,ro "$TEST_ROOT/target"
    assert_failure 'T07 remount ro fails health check' target_anchor_healthy
    target_close
    unmount_owned "$TEST_ROOT/target"
}

case_t08_close_is_idempotent() {
    begin_case T08 'close invalidates health and may be called twice'
    reset_target_state
    mount_tmpfs "$TEST_ROOT/target"
    assert_success 'T08 opens target' target_open "$TEST_ROOT/target"
    assert_success 'T08 first close succeeds' target_close
    assert_failure 'T08 health fails after close' target_anchor_healthy
    assert_success 'T08 second close succeeds' target_close
    unmount_owned "$TEST_ROOT/target"
}

case_t09_spaces_in_mountpoint_round_trip() {
    begin_case T09 'decodes mountinfo escapes for a space-containing mountpoint'
    reset_target_state
    mount_tmpfs "$TEST_ROOT/space target"
    assert_success 'T09 opens a mountpoint containing spaces' \
        target_open "$TEST_ROOT/space target/"
    assert_equal "$TARGET_MOUNT_PATH" "$TEST_ROOT/space target" \
        'T09 retains normalized space-containing path'
    assert_success 'T09 anchored mount with spaces is healthy' target_anchor_healthy
    target_close
    unmount_owned "$TEST_ROOT/space target"
}

case_t10_unmounted_lower_directory_is_rejected() {
    begin_case T10 'does not accept a path whose target mount disappeared before open'
    reset_target_state
    mount_tmpfs "$TEST_ROOT/target"
    unmount_owned "$TEST_ROOT/target"
    assert_failure 'T10 exposed lower directory is not accepted as target' \
        target_open "$TEST_ROOT/target"
    assert_equal "${TARGET_MOUNT_ID:-}" '' 'T10 failed open leaves no target identity'
}

case_t10b_prepare_root_and_directory_stay_under_fd_anchor() {
    begin_case T10b 'root and leaf directories are created only through the live FD anchor'
    reset_target_state
    mount_tmpfs "$TEST_ROOT/target"
    assert_success 'T10b opens target' target_open "$TEST_ROOT/target"
    assert_success 'T10b creates configured root through the FD' \
        target_prepare_root "$TEST_ROOT/target/backups"
    assert_equal "$TARGET_BACKUP_ROOT" "$TARGET_FD_ROOT/backups" \
        'T10b exports only the FD anchored backup root'
    assert_success 'T10b creates UUID directory through the FD' \
        target_prepare_directory 'backups/550e8400-e29b-41d4-a716-446655440000'
    assert_success 'T10b creates logs directory through the FD' \
        target_prepare_directory 'backups/.logs'
    assert_present "$TEST_ROOT/target/backups/.logs" 'T10b creates data on tmpfs'

    rm -rf "$TEST_ROOT/target/backups"
    mkdir -p "$TEST_ROOT/target/elsewhere"
    ln -s "$TEST_ROOT/target/elsewhere" "$TEST_ROOT/target/backups"
    assert_failure 'T10b rejects a symlink configured root' \
        target_prepare_root "$TEST_ROOT/target/backups"
    target_close
    unmount_owned "$TEST_ROOT/target"
}

case_t11_closed_parent_fd_path_is_unusable_by_child() {
    begin_case T11 'child cannot access the former parent proc FD path after close'
    reset_target_state
    mount_tmpfs "$TEST_ROOT/target"
    assert_success 'T11 opens target in parent shell' target_open "$TEST_ROOT/target"
    parent_fd_root=$TARGET_FD_ROOT
    assert_success 'T11 parent close succeeds before child probe' target_close
    # shellcheck disable=SC2016 # The child must expand its own positional parameter.
    assert_failure 'T11 child cannot access a closed parent /proc FD path' \
        /bin/ash -c 'test -e "$1"' target-child "$parent_fd_root"
    unmount_owned "$TEST_ROOT/target"
}


assert_file_hash_unchanged() {
    path=$1
    expected_hash=$2
    message=$3
    assert_equal "$(sha256sum "$path" | awk '{print $1}')" "$expected_hash" "$message"
}

case_t12_submounts_under_backup_root_are_rejected() {
    begin_case T12 'rejects bind mounts over the backup root and every protected descendant'
    for protected_relative in backups \
        backups/550e8400-e29b-41d4-a716-446655440000 \
        backups/.logs \
        backups/550e8400-e29b-41d4-a716-446655440000/deep; do
        reset_target_state
        mount_tmpfs "$TEST_ROOT/target"
        mkdir -p "$TEST_ROOT/target/$protected_relative" "$TEST_ROOT/bind-lower"
        printf 'lower-%s\n' "$protected_relative" > "$TEST_ROOT/target/$protected_relative/lower-sentinel"
        lower_hash=$(sha256sum "$TEST_ROOT/target/$protected_relative/lower-sentinel" | awk '{print $1}')
        assert_success "T12 opens target before bind over [$protected_relative]" \
            target_open "$TEST_ROOT/target"
        assert_success "T12 prepares root before bind over [$protected_relative]" \
            target_prepare_root "$TEST_ROOT/target/backups"
        assert_success "T12 bind mounts test-owned lower over [$protected_relative]" \
            mount --bind "$TEST_ROOT/bind-lower" "$TEST_ROOT/target/$protected_relative"
        assert_failure "T12 rejects bind mount over [$protected_relative]" target_anchor_healthy
        unmount_owned "$TEST_ROOT/target/$protected_relative"
        assert_file_hash_unchanged "$TARGET_FD_ROOT/$protected_relative/lower-sentinel" "$lower_hash" \
            "T12 old anchored lower sentinel is unchanged for [$protected_relative]"
        assert_file_hash_unchanged "$TEST_ROOT/target/$protected_relative/lower-sentinel" "$lower_hash" \
            "T12 naked lower sentinel is unchanged for [$protected_relative]"
        target_close
        unmount_owned "$TEST_ROOT/target"
    done
}

case_t13_target_overmount_and_unrelated_submounts() {
    begin_case T13 'rejects target replacement but permits non-overlapping target children'
    reset_target_state
    mount_tmpfs "$TEST_ROOT/target"
    mkdir -p "$TEST_ROOT/target/backups" "$TEST_ROOT/target/other"
    printf 'target-lower\n' > "$TEST_ROOT/target/target-sentinel"
    target_hash=$(sha256sum "$TEST_ROOT/target/target-sentinel" | awk '{print $1}')
    assert_success 'T13 opens target before same-path overmount' target_open "$TEST_ROOT/target"
    assert_success 'T13 prepares root before same-path overmount' \
        target_prepare_root "$TEST_ROOT/target/backups"
    assert_success 'T13 mounts a second tmpfs at the configured target path' \
        mount -t tmpfs -o rw,size=1m tmpfs "$TEST_ROOT/target"
    assert_failure 'T13 rejects a different mount over the configured target path' target_anchor_healthy
    unmount_owned "$TEST_ROOT/target"
    assert_file_hash_unchanged "$TARGET_FD_ROOT/target-sentinel" "$target_hash" \
        'T13 original target remains unchanged behind the rejected overmount'
    target_close
    unmount_owned "$TEST_ROOT/target"

    reset_target_state
    mount_tmpfs "$TEST_ROOT/target"
    mkdir -p "$TEST_ROOT/target/backups" "$TEST_ROOT/target/unrelated-app"
    assert_success 'T13 opens target before unrelated submount' target_open "$TEST_ROOT/target"
    assert_success 'T13 prepares root before unrelated submount' \
        target_prepare_root "$TEST_ROOT/target/backups"
    assert_success 'T13 mounts tmpfs in unrelated target subtree' \
        mount -t tmpfs -o rw,size=1m tmpfs "$TEST_ROOT/target/unrelated-app"
    assert_success 'T13 allows unrelated target subtree mount' target_anchor_healthy
    unmount_owned "$TEST_ROOT/target/unrelated-app"
    target_close
    unmount_owned "$TEST_ROOT/target"
}

main() {
    trap cleanup_test_data EXIT INT TERM
    if [ ! -r "$TARGET_SCRIPT" ]; then
        printf 'FAIL: target anchor source library is absent: %s\n' "$TARGET_SCRIPT" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$TARGET_SCRIPT"
    mkdir -p "$TEST_ROOT"

    case_t00_source_is_side_effect_free
    case_t01_invalid_parameters_and_absent_paths
    case_t02_non_mount_and_read_only_rejected
    case_t02b_external_fd_is_preserved
    case_t03_open_tracks_exact_mount
    case_t04_normal_unmount_is_busy
    case_t05_lazy_detach_fails_health_and_keeps_old_vfs
    case_t06_replacement_mount_does_not_pass_old_anchor
    case_t07_remount_read_only_fails_health
    case_t08_close_is_idempotent
    case_t09_spaces_in_mountpoint_round_trip
    case_t10_unmounted_lower_directory_is_rejected
    case_t10b_prepare_root_and_directory_stay_under_fd_anchor
    case_t11_closed_parent_fd_path_is_unusable_by_child
    case_t12_submounts_under_backup_root_are_rejected
    case_t13_target_overmount_and_unrelated_submounts

    assert_equal "$CASES" 16 'all required cases executed'
    if [ "$ASSERTIONS" -ne 96 ]; then
        fail "all required assertions executed (expected=96, actual=$ASSERTIONS)"
    fi
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

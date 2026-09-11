#!/bin/sh
#
# BDD tests for source-identity.sh. The host entry uses a pinned OpenWrt
# rootfs and retains per-run stdout, stderr, status, and count evidence.
# Sysfs and `block info` are controlled fixtures; no host block device is used.
#
set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
    REPO_ROOT=$(dirname "$0")
    LOG_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/outdoor-backup-source-identity.XXXXXX") || exit 1
    STAGE=${SOURCE_IDENTITY_STAGE:-green}
    docker run --rm --platform linux/amd64 --network none --read-only \
        --tmpfs /tmp -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-source-identity.sh --inside \
        > "$LOG_ROOT/$STAGE.stdout" 2> "$LOG_ROOT/$STAGE.stderr"
    RUN_STATUS=$?
    printf '%s\n' "$RUN_STATUS" > "$LOG_ROOT/$STAGE.rc"
    if ! grep '^cases=' "$LOG_ROOT/$STAGE.stdout" > "$LOG_ROOT/$STAGE.counts"; then
        printf 'cases=0 assertions=0 failed=unavailable\n' > "$LOG_ROOT/$STAGE.counts"
    fi
    printf 'source-identity %s logs: %s\n' "$STAGE" "$LOG_ROOT"
    exit "$RUN_STATUS"
fi

if [ ! -f /.dockerenv ] || [ ! -r /etc/openwrt_release ] || \
    ! grep -q '^DISTRIB_ID=' /etc/openwrt_release; then
    printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
    exit 1
fi

REPO_ROOT=/src
TARGET_DEVICE_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/target-device.sh"
CARD_IDENTITY_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/card-identity.sh"
SOURCE_IDENTITY_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/source-identity.sh"
TEST_ROOT="/tmp/outdoor-backup-source-identity.$$"
SYSFS="$TEST_ROOT/sys"
NOTICES="$TEST_ROOT/notices"
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
    assert_success_message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! "$@"; then
        fail "$assert_success_message"
    fi
}

assert_failure() {
    assert_failure_message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    if "$@"; then
        fail "$assert_failure_message"
    fi
}

assert_equal() {
    assert_equal_actual=$1
    assert_equal_expected=$2
    assert_equal_message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$assert_equal_actual" != "$assert_equal_expected" ]; then
        fail "$assert_equal_message (expected=[$assert_equal_expected], actual=[$assert_equal_actual])"
    fi
}

assert_failure_empty_output() {
    assert_failure_message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    "$@" > "$TEST_ROOT/actual"
    assert_failure_status=$?
    if [ "$assert_failure_status" -eq 0 ]; then
        fail "$assert_failure_message (unexpected success)"
    elif [ -s "$TEST_ROOT/actual" ]; then
        fail "$assert_failure_message (unexpected stdout)"
    fi
}

assert_snapshot() {
    assert_snapshot_message=$1
    assert_snapshot_expected=$2
    shift 2
    ASSERTIONS=$((ASSERTIONS + 1))
    printf '%s\n' "$assert_snapshot_expected" > "$TEST_ROOT/expected"
    "$@" > "$TEST_ROOT/actual"
    assert_snapshot_status=$?
    if [ "$assert_snapshot_status" -ne 0 ]; then
        fail "$assert_snapshot_message (unexpected failure status=$assert_snapshot_status)"
    elif ! cmp -s "$TEST_ROOT/expected" "$TEST_ROOT/actual"; then
        fail "$assert_snapshot_message (snapshot differs)"
    fi
}

reset_fixture() {
    rm -rf "$TEST_ROOT"
    mkdir -p "$SYSFS/dev/block" "$SYSFS/class/block" "$SYSFS/devices/mock/block"
    : > "$NOTICES"
    TARGET_SYSFS_ROOT=$SYSFS
    SOURCE_UUID=ABCD-1234
    BLOCK_EXPECTED_NODE=/dev/sda1
    SOURCE_IDENTITY_READER_MODE=normal
    export TARGET_SYSFS_ROOT SOURCE_UUID BLOCK_EXPECTED_NODE SOURCE_IDENTITY_READER_MODE
    unset TARGET_BLOCK_NODE TARGET_PHYSICAL_DISK
    block() {
        [ "$#" -eq 2 ] && [ "$1" = info ] && [ "$2" = "$BLOCK_EXPECTED_NODE" ] || return 64
        case "${SOURCE_BLOCK_MODE:-ok}" in
            ok) printf '%s: UUID="%s" TYPE="vfat"\n' "$2" "$SOURCE_UUID" ;;
            no-uuid) printf '%s: TYPE="vfat"\n' "$2" ;;
            bad-record) printf '%s: UUID="%s" UUID="DUP" TYPE="vfat"\n' "$2" "$SOURCE_UUID" ;;
            fail) return 1 ;;
            *) return 65 ;;
        esac
    }
    logger() {
        printf '%s\n' "$*" >> "$NOTICES"
    }
    SOURCE_BLOCK_MODE=ok
    export SOURCE_BLOCK_MODE
}

add_disk() {
    add_disk_name=$1
    add_disk_mm=$2
    add_disk_seq=$3
    add_disk_node="$SYSFS/devices/mock/block/$add_disk_name"
    mkdir -p "$add_disk_node"
    printf '%s\n' "$add_disk_mm" > "$add_disk_node/dev"
    printf '%s\n' "$add_disk_seq" > "$add_disk_node/diskseq"
    printf 'MAJOR=%s\nMINOR=%s\nDEVNAME=%s\nDEVTYPE=disk\n' \
        "${add_disk_mm%%:*}" "${add_disk_mm#*:}" "$add_disk_name" > "$add_disk_node/uevent"
    ln -s "../../devices/mock/block/$add_disk_name" "$SYSFS/dev/block/$add_disk_mm"
    ln -s "../../devices/mock/block/$add_disk_name" "$SYSFS/class/block/$add_disk_name"
}

add_partition() {
    add_partition_parent=$1
    add_partition_name=$2
    add_partition_mm=$3
    add_partition_node="$SYSFS/devices/mock/block/$add_partition_parent/$add_partition_name"
    mkdir -p "$add_partition_node"
    : > "$add_partition_node/partition"
    printf '%s\n' "$add_partition_mm" > "$add_partition_node/dev"
    printf 'MAJOR=%s\nMINOR=%s\nDEVNAME=%s\nDEVTYPE=partition\n' \
        "${add_partition_mm%%:*}" "${add_partition_mm#*:}" "$add_partition_name" > "$add_partition_node/uevent"
    ln -s "../../devices/mock/block/$add_partition_parent/$add_partition_name" \
        "$SYSFS/dev/block/$add_partition_mm"
    ln -s "../../devices/mock/block/$add_partition_parent/$add_partition_name" \
        "$SYSFS/class/block/$add_partition_name"
}

set_default_topology() {
    add_disk sda 8:0 9007199254740992
    add_partition sda sda1 8:1
}

remove_diskseq() {
    rm -f "$SYSFS/devices/mock/block/sda/diskseq"
}

snapshot() {
    source_identity_read "$1"
}

matches() {
    source_identity_matches "$1" "$2"
}

case_s01_source_only_and_stable_shapes() {
    begin_case S01 'sourcing is inert and partition and whole-disk snapshots remain stable'
    reset_fixture
    set_default_topology
    : > "$TEST_ROOT/source.stdout"
    : > "$TEST_ROOT/source.stderr"
    # shellcheck disable=SC1090
    . "$SOURCE_IDENTITY_SCRIPT" > "$TEST_ROOT/source.stdout" 2> "$TEST_ROOT/source.stderr"
    assert_equal "$(wc -c < "$TEST_ROOT/source.stdout")" 0 'S01 source emits no stdout'
    assert_equal "$(wc -c < "$TEST_ROOT/source.stderr")" 0 'S01 source emits no stderr'
    assert_equal "$(wc -c < "$NOTICES")" 0 'S01 source emits no logger record'
    assert_snapshot 'S01 partition snapshot is fixed-order compact JSON' \
        "{\"devname\":\"sda1\",\"node\":\"$SYSFS/devices/mock/block/sda/sda1\",\"major_minor\":\"8:1\",\"filesystem_uuid\":\"abcd-1234\",\"diskseq\":\"9007199254740992\"}" \
        snapshot sda1
    stable_snapshot=$(snapshot sda1) || { fail 'S01 cannot save partition snapshot'; return; }
    assert_success 'S01 identical partition snapshot matches' matches sda1 "$stable_snapshot"

    reset_fixture
    add_disk sda 8:0 18446744073709551615
    BLOCK_EXPECTED_NODE=/dev/sda
    export BLOCK_EXPECTED_NODE
    assert_snapshot 'S01 whole disk remains its own gendisk and preserves max u64 as text' \
        "{\"devname\":\"sda\",\"node\":\"$SYSFS/devices/mock/block/sda\",\"major_minor\":\"8:0\",\"filesystem_uuid\":\"abcd-1234\",\"diskseq\":\"18446744073709551615\"}" \
        snapshot sda
    stable_snapshot=$(snapshot sda) || { fail 'S01 cannot save whole-disk snapshot'; return; }
    assert_success 'S01 identical whole-disk snapshot matches' matches sda "$stable_snapshot"
}

case_s02_uuid_changes_and_normalization() {
    begin_case S02 'UUID case normalizes but a different UUID rejects same DEVNAME'
    reset_fixture
    set_default_topology
    saved_snapshot=$(snapshot sda1) || { fail 'S02 initial snapshot fails'; return; }
    SOURCE_UUID=aBcD-1234
    export SOURCE_UUID
    assert_success 'S02 case-only UUID representation matches' matches sda1 "$saved_snapshot"
    SOURCE_UUID=DIFFERENT-9
    export SOURCE_UUID
    assert_failure_empty_output 'S02 UUID change rejects same name' matches sda1 "$saved_snapshot"
}

case_s03_major_minor_and_node_changes() {
    begin_case S03 'same DEVNAME with changed major:minor or canonical node rejects'
    reset_fixture
    set_default_topology
    saved_snapshot=$(snapshot sda1) || { fail 'S03 initial snapshot fails'; return; }
    rm "$SYSFS/class/block/sda1" "$SYSFS/dev/block/8:1"
    add_partition sda sda1 8:33
    assert_failure_empty_output 'S03 changed major:minor rejects' matches sda1 "$saved_snapshot"

    reset_fixture
    set_default_topology
    saved_snapshot=$(snapshot sda1) || { fail 'S03 second initial snapshot fails'; return; }
    rm "$SYSFS/class/block/sda1" "$SYSFS/dev/block/8:1"
    add_disk sdb 8:16 9007199254740992
    add_partition sdb sda1 8:1
    assert_failure_empty_output 'S03 changed canonical node rejects' matches sda1 "$saved_snapshot"
}

case_s04_diskseq_changes_preserve_u64_text() {
    begin_case S04 'diskseq changes reject without numeric rounding or overflow'
    reset_fixture
    set_default_topology
    saved_snapshot=$(snapshot sda1) || { fail 'S04 initial snapshot fails'; return; }
    printf '%s\n' 9007199254740993 > "$SYSFS/devices/mock/block/sda/diskseq"
    assert_failure_empty_output 'S04 adjacent values beyond 2^53 differ' matches sda1 "$saved_snapshot"
    printf '%s\n' 18446744073709551615 > "$SYSFS/devices/mock/block/sda/diskseq"
    assert_snapshot 'S04 max u64 survives as a JSON string' \
        "{\"devname\":\"sda1\",\"node\":\"$SYSFS/devices/mock/block/sda/sda1\",\"major_minor\":\"8:1\",\"filesystem_uuid\":\"abcd-1234\",\"diskseq\":\"18446744073709551615\"}" \
        snapshot sda1
}

case_s05_diskseq_downgrade_and_invalid_forms() {
    begin_case S05 'absent diskseq is null only when absent, not malformed or unreadable'
    reset_fixture
    set_default_topology
    remove_diskseq
    saved_snapshot=$(snapshot sda1) || { fail 'S05 missing diskseq snapshot fails'; return; }
    assert_success 'S05 missing diskseq remains matchable as null' matches sda1 "$saved_snapshot"
    printf '%s\n' 7 > "$SYSFS/devices/mock/block/sda/diskseq"
    assert_failure_empty_output 'S05 missing-to-present rejects' matches sda1 "$saved_snapshot"

    reset_fixture
    set_default_topology
    saved_snapshot=$(snapshot sda1) || { fail 'S05 present snapshot fails'; return; }
    remove_diskseq
    assert_failure_empty_output 'S05 present-to-missing rejects' matches sda1 "$saved_snapshot"

    for bad_diskseq in '' 0 -1 01 18446744073709551616 '7
8'; do
        reset_fixture
        set_default_topology
        printf '%b\n' "$bad_diskseq" > "$SYSFS/devices/mock/block/sda/diskseq"
        assert_failure_empty_output "S05 invalid diskseq [$bad_diskseq] rejects instead of null" snapshot sda1
    done
    reset_fixture
    set_default_topology
    printf '7\n\n' > "$SYSFS/devices/mock/block/sda/diskseq"
    assert_failure_empty_output 'S05 empty trailing diskseq record rejects instead of null' snapshot sda1
    reset_fixture
    set_default_topology
    printf '7\n\n8\n' > "$SYSFS/devices/mock/block/sda/diskseq"
    assert_failure_empty_output 'S05 nonempty third diskseq record rejects instead of null' snapshot sda1
    reset_fixture
    set_default_topology
    rm "$SYSFS/devices/mock/block/sda/diskseq"
    ln -s /missing/diskseq "$SYSFS/devices/mock/block/sda/diskseq"
    assert_failure_empty_output 'S05 diskseq symlink rejects instead of null' snapshot sda1

    reset_fixture
    set_default_topology
    source_identity_real_read_diskseq() {
        target_device_read_value "$1/diskseq"
    }
    source_identity_read_diskseq() {
        return 1
    }
    assert_failure_empty_output 'S05 explicit reader double proves unreadable is not downgraded to null' snapshot sda1
    unset -f source_identity_read_diskseq source_identity_real_read_diskseq
    # shellcheck disable=SC1090
    . "$SOURCE_IDENTITY_SCRIPT"
    # The explicit reader double models access failure; chmod 000 is not proof under root.
}

case_s06_missing_topology_and_uuid_proof_reject() {
    begin_case S06 'missing source topology and strict block UUID failures reject without snapshots'
    reset_fixture
    set_default_topology
    rm "$SYSFS/class/block/sda1" "$SYSFS/dev/block/8:1"
    assert_failure_empty_output 'S06 missing source node rejects' snapshot sda1

    reset_fixture
    set_default_topology
    rm -rf "$SYSFS/devices/mock/block/sda"
    assert_failure_empty_output 'S06 disappeared parent rejects' snapshot sda1

    reset_fixture
    set_default_topology
    SOURCE_BLOCK_MODE=no-uuid
    export SOURCE_BLOCK_MODE
    assert_failure_empty_output 'S06 block record without UUID rejects' snapshot sda1
    SOURCE_BLOCK_MODE=bad-record
    export SOURCE_BLOCK_MODE
    assert_failure_empty_output 'S06 conflicting block UUID fields reject' snapshot sda1
    SOURCE_BLOCK_MODE=fail
    export SOURCE_BLOCK_MODE
    assert_failure_empty_output 'S06 failed block reader rejects' snapshot sda1
}

case_s07_mixed_sample_rejects_before_output() {
    begin_case S07 'topology or diskseq change during UUID reading rejects a mixed snapshot'
    reset_fixture
    set_default_topology
    source_identity_saved_uuid_reader() {
        card_identity_read_source_uuid "$1"
    }
    source_identity_read_filesystem_uuid() {
        source_identity_test_uuid=$(source_identity_saved_uuid_reader "$1") || return 1
        printf '%s\n' 9007199254740993 > "$SYSFS/devices/mock/block/sda/diskseq"
        printf '%s\n' "$source_identity_test_uuid"
    }
    assert_failure_empty_output 'S07 diskseq mutation between two real topology reads rejects' snapshot sda1
    unset -f source_identity_read_filesystem_uuid source_identity_saved_uuid_reader
    # shellcheck disable=SC1090
    . "$SOURCE_IDENTITY_SCRIPT"
}

case_s08_expected_is_data_and_exports_survive() {
    begin_case S08 'malformed expected data never matches and source reads preserve target exports'
    reset_fixture
    set_default_topology
    TARGET_BLOCK_NODE=/dev/target-sentinel
    TARGET_PHYSICAL_DISK=/dev/target-disk-sentinel
    source_snapshot=$(snapshot sda1) || { fail 'S08 initial snapshot fails'; return; }
    assert_equal "$TARGET_BLOCK_NODE" /dev/target-sentinel 'S08 source read does not alter target node export'
    assert_equal "$TARGET_PHYSICAL_DISK" /dev/target-disk-sentinel 'S08 source read does not alter target disk export'
    assert_failure_empty_output 'S08 malformed expected JSON does not match' matches sda1 '{}'
    assert_failure_empty_output 'S08 schema-incomplete expected JSON does not match' \
        matches sda1 '{"devname":"sda1"}'
    assert_success 'S08 exact saved JSON remains an opaque value and matches' matches sda1 "$source_snapshot"
    assert_equal "$TARGET_BLOCK_NODE" /dev/target-sentinel 'S08 matches does not alter target node export'
    assert_equal "$TARGET_PHYSICAL_DISK" /dev/target-disk-sentinel 'S08 matches does not alter target disk export'
}

main() {
    if [ ! -r "$TARGET_DEVICE_SCRIPT" ] || [ ! -r "$CARD_IDENTITY_SCRIPT" ] || \
        [ ! -r "$SOURCE_IDENTITY_SCRIPT" ]; then
        printf 'FAIL: required source identity libraries are absent\n' >&2
        printf 'cases=0 assertions=0 failed=1\n'
        exit 1
    fi
    trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
    # shellcheck disable=SC1090
    . "$TARGET_DEVICE_SCRIPT"
    # shellcheck disable=SC1090
    . "$CARD_IDENTITY_SCRIPT"
    case_s01_source_only_and_stable_shapes
    # shellcheck disable=SC1090
    . "$SOURCE_IDENTITY_SCRIPT"
    case_s02_uuid_changes_and_normalization
    case_s03_major_minor_and_node_changes
    case_s04_diskseq_changes_preserve_u64_text
    case_s05_diskseq_downgrade_and_invalid_forms
    case_s06_missing_topology_and_uuid_proof_reject
    case_s07_mixed_sample_rejects_before_output
    case_s08_expected_is_data_and_exports_survive
    assert_equal "$CASES" 8 'all required cases executed'
    assert_equal "$ASSERTIONS" 40 'all required assertions executed'
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

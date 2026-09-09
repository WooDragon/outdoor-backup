#!/bin/sh
#
# BDD tests for target-device.sh. The test uses a pinned OpenWrt rootfs but
# never exposes host block devices: sysfs, mountinfo, and block are fixtures.
#

set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 --network none --read-only \
        --tmpfs /tmp -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-target-device.sh --inside
fi

if [ ! -f /.dockerenv ] || [ ! -r /etc/openwrt_release ] || \
    ! grep -q '^DISTRIB_ID=' /etc/openwrt_release; then
    printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
    exit 1
fi

REPO_ROOT=/src
TARGET_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/target-device.sh"
TEST_ROOT="/tmp/outdoor-backup-target-device.$$"
SYSFS="$TEST_ROOT/sys"
MOUNTINFO="$TEST_ROOT/mountinfo"
BIN="$TEST_ROOT/bin"
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

reset_fixture() {
    rm -rf "$TEST_ROOT"
    mkdir -p "$SYSFS/dev/block" "$SYSFS/class/block" "$SYSFS/devices/mock/block" \
        "$BIN"
    : > "$MOUNTINFO"
    : > "$NOTICES"
    BLOCK_OUTPUT_FILE="$TEST_ROOT/block-output"
    : > "$BLOCK_OUTPUT_FILE"
    TARGET_SYSFS_ROOT="$SYSFS"
    TARGET_MOUNTINFO_FILE="$MOUNTINFO"
    TEST_NOTICES="$NOTICES"
    block() {
        sed -n 'p' "$BLOCK_OUTPUT_FILE"
        return "${BLOCK_STATUS:-0}"
    }
    logger() {
        printf '%s\n' "$*" >> "$TEST_NOTICES"
    }
    export TARGET_SYSFS_ROOT TARGET_MOUNTINFO_FILE TEST_NOTICES BLOCK_OUTPUT_FILE
    unset TARGET_BLOCK_NODE TARGET_PHYSICAL_DISK BLOCK_STATUS
}

# Add a sysfs disk with realistic /sys/dev/block and /sys/class/block symlinks.
# Arguments: DEVNAME, major:minor.
add_disk() {
    disk_name=$1
    disk_mm=$2
    disk_node="$SYSFS/devices/mock/block/$disk_name"
    mkdir -p "$disk_node"
    printf '%s\n' "$disk_mm" > "$disk_node/dev"
    printf 'MAJOR=%s\nMINOR=%s\nDEVNAME=%s\nDEVTYPE=disk\n' \
        "${disk_mm%%:*}" "${disk_mm#*:}" "$disk_name" > "$disk_node/uevent"
    ln -s "../../devices/mock/block/$disk_name" "$SYSFS/dev/block/$disk_mm"
    ln -s "../../devices/mock/block/$disk_name" "$SYSFS/class/block/$disk_name"
}

# Add a partition under an existing disk. Arguments: disk, partition, major:minor.
add_partition() {
    parent_name=$1
    part_name=$2
    part_mm=$3
    part_node="$SYSFS/devices/mock/block/$parent_name/$part_name"
    mkdir -p "$part_node"
    : > "$part_node/partition"
    printf '%s\n' "$part_mm" > "$part_node/dev"
    printf 'MAJOR=%s\nMINOR=%s\nDEVNAME=%s\nDEVTYPE=partition\n' \
        "${part_mm%%:*}" "${part_mm#*:}" "$part_name" > "$part_node/uevent"
    ln -s "../../devices/mock/block/$parent_name/$part_name" "$SYSFS/dev/block/$part_mm"
    ln -s "../../devices/mock/block/$parent_name/$part_name" "$SYSFS/class/block/$part_name"
}

# Add loop sysfs state. Argument: major:minor. Backing text is set by callers.
add_loop() {
    loop_mm=$1
    loop_node="$SYSFS/devices/mock/block/loop0"
    mkdir -p "$loop_node/loop"
    printf '%s\n' "$loop_mm" > "$loop_node/dev"
    printf 'MAJOR=%s\nMINOR=%s\nDEVNAME=loop0\nDEVTYPE=disk\n' \
        "${loop_mm%%:*}" "${loop_mm#*:}" > "$loop_node/uevent"
    ln -s '../../devices/mock/block/loop0' "$SYSFS/dev/block/$loop_mm"
    ln -s '../../devices/mock/block/loop0' "$SYSFS/class/block/loop0"
}

# Emit one mountinfo line. Arguments: mount point, major:minor, fstype.
add_mount() {
    mount_path=$1
    mount_mm=$2
    mount_fs=$3
    printf '1 0 %s / %s rw - %s fixture rw\n' \
        "$mount_mm" "$mount_path" "$mount_fs" >> "$MOUNTINFO"
}

set_default_topology() {
    add_disk mmcblk0 179:0
    add_partition mmcblk0 mmcblk0p2 179:2
    add_disk sda 8:0
    add_partition sda sda1 8:1
    add_partition sda sda12 8:12
    add_disk nvme0n1 259:0
    add_partition nvme0n1 nvme0n1p12 259:12
    add_mount / 0:1 overlay
    add_mount /rom 179:2 squashfs
    add_mount /overlay 0:1 overlay
    set_block_output '/dev/nvme0n1p12: UUID="ABCD-1234" LABEL="target" TYPE="vfat"'
}

set_block_output() {
    printf '%s\n' "$1" > "$BLOCK_OUTPUT_FILE"
}

validate() {
    target_device_validate "$@"
}

case_d01_independent_devices_pass() {
    begin_case D01 'independent mmc system, USB source, and NVMe target pass'
    reset_fixture
    set_default_topology
    assert_success 'D01 accepts an independently backed target' \
        validate 259:12 ABCD-1234 sda1
    assert_equal "$TARGET_BLOCK_NODE" /dev/nvme0n1p12 \
        'D01 records target device node from uevent'
    assert_equal "$TARGET_PHYSICAL_DISK" /dev/nvme0n1 \
        'D01 records target parent disk without suffix guessing'
}

case_d02_source_disk_never_targets_itself() {
    begin_case D02 'source partition and sibling partition on same disk reject'
    reset_fixture
    set_default_topology
    set_block_output '/dev/sda12: UUID="ABCD-1234" TYPE="ext4"'
    assert_failure 'D02 rejects target equal to source physical disk' \
        validate 8:12 ABCD-1234 sda1
    set_block_output '/dev/sda1: UUID="ABCD-1234" TYPE="ext4"'
    assert_failure 'D02 rejects target equal to source partition' \
        validate 8:1 ABCD-1234 sda1
}

case_d03_system_backing_disk_never_targets_itself() {
    begin_case D03 'target on any physical system backing disk rejects'
    reset_fixture
    set_default_topology
    set_block_output '/dev/mmcblk0p2: UUID="ABCD-1234" TYPE="ext4"'
    assert_failure 'D03 rejects target on physical /rom parent disk' \
        validate 179:2 ABCD-1234 sda1

    reset_fixture
    set_default_topology
    : > "$MOUNTINFO"
    add_mount / 179:2 ext4
    set_block_output '/dev/mmcblk0p2: UUID="ABCD-1234" TYPE="ext4"'
    assert_failure 'D03 rejects target on physical root parent disk' \
        validate 179:2 ABCD-1234 sda1

    reset_fixture
    set_default_topology
    : > "$MOUNTINFO"
    add_mount / 0:1 overlay
    add_mount /overlay 179:2 ext4
    set_block_output '/dev/mmcblk0p2: UUID="ABCD-1234" TYPE="ext4"'
    assert_failure 'D03 rejects target on physical overlay parent disk' \
        validate 179:2 ABCD-1234 sda1

    reset_fixture
    set_default_topology
    : > "$MOUNTINFO"
    add_mount / 8:1 ext4
    assert_failure 'D03 rejects an otherwise independent target when source is system disk' \
        validate 259:12 ABCD-1234 sda1
}

case_d04_loop_backed_r5s_root_protects_parent() {
    begin_case D04 'loop backed /rom protects mmc parent but permits separate SSD'
    reset_fixture
    set_default_topology
    : > "$MOUNTINFO"
    add_loop 7:0
    printf '%s\n' /dev/mmcblk0p2 > "$SYSFS/devices/mock/block/loop0/loop/backing_file"
    add_mount / 0:1 overlay
    add_mount /rom 7:0 squashfs
    add_mount /overlay 0:1 overlay
    assert_success 'D04 resolves loop backing to mmc and permits NVMe' \
        validate 259:12 ABCD-1234 sda1
    set_block_output '/dev/mmcblk0p2: UUID="ABCD-1234" TYPE="ext4"'
    assert_failure 'D04 rejects resolved loop backing parent disk' \
        validate 179:2 ABCD-1234 sda1
}

case_d05_unprovable_system_and_virtual_backings_reject() {
    begin_case D05 'unknown system, file loop, and dm backing fail closed'
    reset_fixture
    set_default_topology
    : > "$MOUNTINFO"
    add_mount / 0:1 overlay
    add_mount /rom 8:99 squashfs
    assert_failure 'D05 rejects unknown non-pseudo system backing' \
        validate 259:12 ABCD-1234 sda1

    reset_fixture
    set_default_topology
    : > "$MOUNTINFO"
    add_loop 7:0
    printf '%s\n' /tmp/disk-image > "$SYSFS/devices/mock/block/loop0/loop/backing_file"
    add_mount / 0:1 overlay
    add_mount /rom 7:0 squashfs
    assert_failure 'D05 rejects file-backed loop system backing' \
        validate 259:12 ABCD-1234 sda1

    reset_fixture
    set_default_topology
    add_disk dm-0 253:0
    : > "$MOUNTINFO"
    add_mount / 253:0 ext4
    assert_failure 'D05 rejects dm system backing without guessing slaves' \
        validate 259:12 ABCD-1234 sda1
}

case_d06_pseudo_only_system_is_not_proven() {
    begin_case D06 'pseudo-only root has no proven physical system backing'
    reset_fixture
    set_default_topology
    : > "$MOUNTINFO"
    add_mount / 0:1 overlay
    add_mount /overlay 0:1 overlay
    assert_failure 'D06 rejects when /, /rom, /overlay prove no physical disk' \
        validate 259:12 ABCD-1234 sda1
}

case_d07_uuid_contract_rejects_all_nonproof() {
    begin_case D07 'empty invalid wrong and non-UUID block output reject'
    reset_fixture
    set_default_topology
    assert_failure 'D07 rejects unconfigured empty UUID' validate 259:12 '' sda1
    assert_failure 'D07 rejects unsafe expected UUID' validate 259:12 'bad value' sda1
    assert_failure 'D07 rejects mismatched UUID' validate 259:12 WRONG-UUID sda1
    set_block_output '/dev/nvme0n1p12: LABEL="ABCD-1234" TYPE="vfat"'
    assert_failure 'D07 does not treat LABEL as UUID' validate 259:12 ABCD-1234 sda1
    set_block_output '/dev/nvme0n1p12: LABEL="camera UUID="ABCD-1234" TYPE="vfat"'
    assert_failure 'D07 rejects UUID-shaped text in malformed nested LABEL quotes' \
        validate 259:12 ABCD-1234 sda1
    set_block_output '/dev/nvme0n1p12: LABEL="camera UUID=ABCD-1234" TYPE="vfat"'
    assert_failure 'D07 rejects UUID-shaped text inside a spaced LABEL' \
        validate 259:12 ABCD-1234 sda1
    set_block_output '/dev/nvme0n1p12: UUID="ABCD-1234" LABEL="camera angle" TYPE="vfat"'
    assert_success 'D07 accepts UUID with a spaced LABEL' \
        validate 259:12 ABCD-1234 sda1
    set_block_output '/dev/nvme0n1p12: LABEL="camera angle" UUID="ABCD-1234" TYPE="vfat"'
    assert_success 'D07 accepts UUID after a spaced LABEL' \
        validate 259:12 ABCD-1234 sda1
    set_block_output '/dev/nvme0n1p12: UUID="ABCD-1234" LABEL="camera angle'
    assert_failure 'D07 rejects an unclosed LABEL value' \
        validate 259:12 ABCD-1234 sda1
    set_block_output '/dev/nvme0n1p12: UUID="ABCD-1234" LABEL="camera angle" stray TYPE="vfat"'
    assert_failure 'D07 rejects extra bare record characters' \
        validate 259:12 ABCD-1234 sda1
    set_block_output ''
    assert_failure 'D07 rejects empty block output' validate 259:12 ABCD-1234 sda1
    set_block_output '/dev/other: UUID="ABCD-1234" TYPE="vfat"'
    assert_failure 'D07 rejects output for a different device' validate 259:12 ABCD-1234 sda1
    set_block_output '/dev/nvme0n1p12: UUID="ABCD-1234" UUID="DUP" TYPE="vfat"'
    assert_failure 'D07 rejects multiple UUID fields' validate 259:12 ABCD-1234 sda1
}

case_d08_block_absence_and_target_virtual_devices_reject() {
    begin_case D08 'missing block CLI and loop target reject'
    reset_fixture
    set_default_topology
    unset -f block
    assert_failure 'D08 rejects missing official block CLI' \
        validate 259:12 ABCD-1234 sda1

    reset_fixture
    set_default_topology
    add_loop 7:0
    printf '%s\n' /dev/nvme0n1p12 > "$SYSFS/devices/mock/block/loop0/loop/backing_file"
    set_block_output '/dev/loop0: UUID="ABCD-1234" TYPE="ext4"'
    assert_failure 'D08 rejects loop target even with block UUID' \
        validate 7:0 ABCD-1234 sda1
}

case_d09_parent_resolution_handles_multidigit_partitions() {
    begin_case D09 'nvme mmc and multi-letter sd partitions retain true parents'
    reset_fixture
    set_default_topology
    assert_equal "$(target_device_physical_disk_for_major_minor "$SYSFS" 179:2 '')" \
        /dev/mmcblk0 'D09 mmcblk0p2 physical parent is mmcblk0'
    assert_success 'D09 resolves nvme0n1p12 parent from partition node' \
        validate 259:12 ABCD-1234 sda1
    assert_equal "$TARGET_PHYSICAL_DISK" /dev/nvme0n1 \
        'D09 nvme p12 physical parent is nvme0n1'

    reset_fixture
    set_default_topology
    add_disk sdaa 65:0
    add_partition sdaa sdaa12 65:12
    set_block_output '/dev/sdaa12: UUID="ABCD-1234" TYPE="ext4"'
    assert_success 'D09 accepts a multi-letter sd partition on another disk' \
        validate 65:12 ABCD-1234 sda1
    assert_equal "$TARGET_PHYSICAL_DISK" /dev/sdaa \
        'D09 does not truncate multi-letter sd disk name'
}

case_d10_source_name_is_a_safe_basename() {
    begin_case D10 'source DEVNAME traversal and controls reject before sysfs lookup'
    reset_fixture
    set_default_topology
    assert_failure 'D10 rejects source traversal' \
        validate 259:12 ABCD-1234 '../sda1'
    assert_failure 'D10 rejects source control character' \
        validate 259:12 ABCD-1234 "sda1$(printf '\t')"
}

main() {
    if [ ! -r "$TARGET_SCRIPT" ]; then
        printf 'FAIL: target device library is absent: %s\n' "$TARGET_SCRIPT" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$TARGET_SCRIPT"
    trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

    case_d01_independent_devices_pass
    case_d02_source_disk_never_targets_itself
    case_d03_system_backing_disk_never_targets_itself
    case_d04_loop_backed_r5s_root_protects_parent
    case_d05_unprovable_system_and_virtual_backings_reject
    case_d06_pseudo_only_system_is_not_proven
    case_d07_uuid_contract_rejects_all_nonproof
    case_d08_block_absence_and_target_virtual_devices_reject
    case_d09_parent_resolution_handles_multidigit_partitions
    case_d10_source_name_is_a_safe_basename

    assert_equal "$CASES" 10 'all required cases executed'
    assert_equal "$ASSERTIONS" 38 'all required assertions executed'
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

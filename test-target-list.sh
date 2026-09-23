#!/bin/sh
#
# BDD tests for the read-only target storage enumerator. The test runs inside
# the pinned OpenWrt rootfs and supplies topology evidence through existing
# script seams; it never exposes host block devices.
#

set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 --network bridge \
        --tmpfs /tmp -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-target-list.sh --inside
fi

if [ ! -f /.dockerenv ] || [ ! -r /etc/openwrt_release ]; then
    printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    mkdir -p /var/lock
    if ! opkg update >/dev/null || ! opkg install jq >/dev/null; then
        printf '%s\n' 'FAIL: cannot install jq required for JSON assertions' >&2
        exit 1
    fi
fi

REPO_ROOT=/src
TARGET_LIST_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/target-list.sh"
TEST_ROOT="/tmp/outdoor-backup-target-list.$$"
MOUNTINFO="$TEST_ROOT/mountinfo"
EFFECTS="$TEST_ROOT/effects"
LEGACY_CONFIG=/opt/outdoor-backup/conf/backup.conf
UCI_CONFIG_DIR="$TEST_ROOT/uci"
UCI_CONFIG_FILE="$UCI_CONFIG_DIR/outdoor-backup"
CASES=0
ASSERTIONS=0
FAILED=0

# Load the delivered implementation before installing fixture evidence providers.
TARGET_LIST_SCRIPT_DIR="$REPO_ROOT/files/opt/outdoor-backup/scripts"
TARGET_LIST_LIBRARY_ONLY=1
export TARGET_LIST_SCRIPT_DIR TARGET_LIST_LIBRARY_ONLY
# shellcheck disable=SC1090
. "$TARGET_LIST_SCRIPT"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILED=$((FAILED + 1))
}

begin_case() {
    CASES=$((CASES + 1))
    printf 'CASE %s: %s\n' "$1" "$2"
}

assert_equal() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$1" != "$2" ]; then
        fail "$3 (expected=[$2], actual=[$1])"
    fi
}

assert_success() {
    message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! "$@"; then
        fail "$message should succeed"
    fi
}

assert_failure() {
    message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    if "$@"; then
        fail "$message should fail"
    fi
}

assert_file_absent() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ -e "$1" ] || [ -L "$1" ]; then
        fail "$2 (path exists: $1)"
    fi
}

assert_json_targets() {
    expected=$1
    actual=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    actual_targets=$(printf '%s' "$actual" | jq -cS '.targets' 2>/dev/null) || {
        fail "$message (invalid JSON)"
        return
    }
    if [ "$actual_targets" != "$expected" ]; then
        fail "$message (expected=[$expected], actual=[$actual_targets])"
    fi
}

assert_json_current() {
    expected=$1
    actual=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    actual_current=$(printf '%s' "$actual" | jq -cS '.current' 2>/dev/null) || {
        fail "$message (invalid JSON)"
        return
    }
    if [ "$actual_current" != "$expected" ]; then
        fail "$message (expected=[$expected], actual=[$actual_current])"
    fi
}

reset_fixture() {
    rm -rf "$TEST_ROOT"
    mkdir -p "$TEST_ROOT"
    : > "$MOUNTINFO"
    mkdir -p "$EFFECTS" "$UCI_CONFIG_DIR" "$(dirname "$LEGACY_CONFIG")"
    rm -f "$LEGACY_CONFIG" "$UCI_CONFIG_FILE"
    TARGET_MOUNTINFO_FILE="$MOUNTINFO"
    BLOCK_OUTPUT_FILE="$TEST_ROOT/block-output"
    : > "$BLOCK_OUTPUT_FILE"
    export TARGET_MOUNTINFO_FILE BLOCK_OUTPUT_FILE UCI_CONFIG_DIR
}

write_legacy_config() {
    cat > "$LEGACY_CONFIG" <<'EOF'
BACKUP_ROOT='/legacy/backups/'
TARGET_MOUNT='/legacy/target/'
EOF
}

write_uci_config() {
    cat > "$UCI_CONFIG_FILE" <<'EOF'
config outdoor-backup 'config'
	option backup_root '/uci/backups/'
	option target_mount '/uci/target/'
EOF
}

write_invalid_optional_led_uci_config() {
    write_uci_config
    cat >> "$UCI_CONFIG_FILE" <<'EOF'
	option led_green 'relative-led'
EOF
}

write_invalid_legacy_config() {
    cat > "$LEGACY_CONFIG" <<'EOF'
BACKUP_ROOT='relative-root'
EOF
}

block() {
    [ "$#" -eq 2 ] && [ "$1" = info ] && [ "$2" = /dev/nvme0n1p12 ] || return 64
    sed -n 'p' "$BLOCK_OUTPUT_FILE"
}

add_mount() {
    # Arguments: mount ID, major:minor, mount path, fstype, source, vfs opts, super opts.
    printf '%s 0 %s / %s %s - %s %s %s\n' \
        "$1" "$2" "$3" "$6" "$4" "$5" "$7" >> "$MOUNTINFO"
}

target_open() {
    target_list_test_mount=$1
    case "$target_list_test_mount" in
        /mnt/good|'/mnt/target space'|/mnt/clone-a|/mnt/clone-b|/mnt/btrfs)
            TARGET_DEVICE=259:12
            TARGET_FS_TYPE=ext4
            TARGET_MOUNT_PATH=$target_list_test_mount
            return 0
            ;;
        /mnt/ro|/mnt/unknown|/mnt/virtual|/mnt/system|/mnt/sibling|/mnt/unmounted)
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

target_close() {
    unset TARGET_DEVICE TARGET_FS_TYPE TARGET_MOUNT_PATH
}

target_device_target_only() {
    case "$TARGET_MOUNT_PATH" in
        /mnt/good) TARGET_BLOCK_NODE=/dev/nvme0n1p12; TARGET_PHYSICAL_DISK=/dev/nvme0n1; TARGET_BLOCK_UUID=GOOD-1234 ;;
        '/mnt/target space') TARGET_BLOCK_NODE=/dev/nvme0n1p12; TARGET_PHYSICAL_DISK=/dev/nvme0n1; TARGET_BLOCK_UUID=SPACE-1234 ;;
        /mnt/clone-a|/mnt/clone-b) TARGET_BLOCK_NODE=/dev/nvme0n1p12; TARGET_PHYSICAL_DISK=/dev/nvme0n1; TARGET_BLOCK_UUID=CLONE-1234 ;;
        /mnt/btrfs) TARGET_BLOCK_NODE=/dev/nvme0n1p12; TARGET_PHYSICAL_DISK=/dev/nvme0n1; TARGET_BLOCK_UUID=BTRFS-1234 ;;
        *) return 1 ;;
    esac
    return 0
}

logger() {
    : > "$EFFECTS/logger-called"
}

run_list() {
    target_list_main "$@"
}

case_l01_normal_candidates_are_one_complete_object() {
    begin_case L01 'mounted writable direct physical candidates form one JSON object'
    reset_fixture
    write_legacy_config
    write_uci_config
    add_mount 11 259:12 /mnt/good ext4 /dev/nvme0n1p12 rw rw
    list_output=$(run_list)
    assert_json_targets '[{"device":"/dev/nvme0n1p12","fstype":"ext4","mount":"/mnt/good","uuid":"GOOD-1234"}]' \
        "$list_output" 'L01 returns the direct physical target'
    assert_json_current '{"backup_root":"/uci/backups","target_mount":"/uci/target"}' \
        "$list_output" 'L01 returns effective current configuration'
    assert_file_absent "$EFFECTS/logger-called" 'L01 enumeration wrote syslog'
}

case_l02_empty_collection_is_success() {
    begin_case L02 'no eligible mounts is a successful empty collection'
    reset_fixture
    list_output=$(run_list)
    assert_json_targets '[]' "$list_output" 'L02 emits a complete empty targets array'
}

case_l03_global_configuration_failure_has_no_json() {
    begin_case L03 'configuration failure emits no consumable JSON'
    reset_fixture
    write_invalid_legacy_config
    list_output=$(run_list 2>"$TEST_ROOT/l03.err")
    list_status=$?
    assert_equal "$list_status" 1 'L03 fails on invalid effective configuration'
    assert_equal "$list_output" '' 'L03 emits no partial JSON on configuration failure'
    assert_file_absent "$EFFECTS/logger-called" 'L03 invalid configuration wrote syslog'
}

case_l04_collection_then_encoding_failure_has_no_partial_output() {
    begin_case L04 'final encoding failure after collection emits no partial output'
    reset_fixture
    add_mount 11 259:12 /mnt/good ext4 /dev/nvme0n1p12 rw rw
    # This is deliberately last in main: replace only the final serializer,
    # after a candidate has been collected, to prove stdout is still empty.
    jq() { return 1; }
    list_output=$(run_list 2>"$TEST_ROOT/l04.err")
    list_status=$?
    assert_equal "$list_status" 1 'L04 fails after a collected candidate cannot be encoded'
    assert_equal "$list_output" '' 'L04 does not stream a candidate before final encoding'
}

case_l05_rejects_noneligible_mount_states() {
    begin_case L05 'system sibling read-only unknown virtual and unmounted entries skip'
    reset_fixture
    add_mount 11 259:12 /mnt/good ext4 /dev/nvme0n1p12 rw rw
    add_mount 12 259:12 /mnt/ro ext4 /dev/nvme0n1p12 ro ro
    add_mount 13 8:1 /mnt/sibling ext4 /dev/sda1 rw rw
    add_mount 14 0:28 /mnt/virtual tmpfs tmpfs rw rw
    add_mount 15 179:2 /mnt/system ext4 /dev/mmcblk0p2 rw rw
    add_mount 16 8:2 /mnt/unknown ext4 /dev/sdb2 rw rw
    list_output=$(run_list)
    assert_json_targets '[{"device":"/dev/nvme0n1p12","fstype":"ext4","mount":"/mnt/good","uuid":"GOOD-1234"}]' \
        "$list_output" 'L05 skips every ineligible mount independently'
}

case_l06_btrfs_anonymous_source_is_a_candidate() {
    begin_case L06 'anonymous btrfs 0:N source remains eligible through target proof'
    reset_fixture
    add_mount 11 0:28 /mnt/btrfs btrfs /dev/nvme0n1p12 rw rw
    list_output=$(run_list)
    assert_json_targets '[{"device":"/dev/nvme0n1p12","fstype":"ext4","mount":"/mnt/btrfs","uuid":"BTRFS-1234"}]' \
        "$list_output" 'L06 retains the btrfs physical target'
}

case_l07_mount_space_and_clone_identity_are_preserved() {
    begin_case L07 'escaped mount spaces and cloned UUID mounts remain distinct selections'
    reset_fixture
    add_mount 11 259:12 '/mnt/target\040space' ext4 /dev/nvme0n1p12 rw rw
    add_mount 12 259:12 /mnt/clone-a ext4 /dev/nvme0n1p12 rw rw
    add_mount 13 259:12 /mnt/clone-b ext4 /dev/nvme0n1p12 rw rw
    list_output=$(run_list)
    assert_json_targets '[{"device":"/dev/nvme0n1p12","fstype":"ext4","mount":"/mnt/target space","uuid":"SPACE-1234"},{"device":"/dev/nvme0n1p12","fstype":"ext4","mount":"/mnt/clone-a","uuid":"CLONE-1234"},{"device":"/dev/nvme0n1p12","fstype":"ext4","mount":"/mnt/clone-b","uuid":"CLONE-1234"}]' \
        "$list_output" 'L07 retains mount as part of the selection identity'
}

case_l08_loader_precedence_and_path_normalization_are_reported() {
    begin_case L08 'real loader reports defaults then legacy then explicit UCI precedence'
    reset_fixture
    list_output=$(run_list)
    assert_json_current '{"backup_root":"/mnt/ssd/SDMirrors","target_mount":"/mnt/ssd"}' \
        "$list_output" 'L08 defaults apply without legacy or UCI configuration'

    write_legacy_config
    list_output=$(run_list)
    assert_json_current '{"backup_root":"/legacy/backups","target_mount":"/legacy/target"}' \
        "$list_output" 'L08 legacy overrides defaults and normalizes trailing slashes'

    write_uci_config
    list_output=$(run_list)
    assert_json_current '{"backup_root":"/uci/backups","target_mount":"/uci/target"}' \
        "$list_output" 'L08 explicit UCI overrides legacy and normalizes trailing slashes'
}

case_l09_invalid_optional_led_is_silent_and_nonfatal() {
    begin_case L09 'invalid optional LED keeps enumeration successful without syslog'
    reset_fixture
    write_legacy_config
    write_invalid_optional_led_uci_config
    list_output=$(run_list 2>"$TEST_ROOT/l09.err")
    list_status=$?
    assert_equal "$list_status" 0 'L09 invalid optional LED remains nonfatal'
    assert_json_current '{"backup_root":"/uci/backups","target_mount":"/uci/target"}' \
        "$list_output" 'L09 keeps the effective target configuration'
    assert_file_absent "$EFFECTS/logger-called" 'L09 invalid optional LED wrote syslog'
}

case_l10_rejects_arguments() {
    begin_case L10 'public entry accepts no user parameters'
    reset_fixture
    list_output=$(run_list unexpected 2>"$TEST_ROOT/l10.err")
    list_status=$?
    assert_equal "$list_status" 1 'L10 rejects a user argument'
    assert_equal "$list_output" '' 'L10 returns no JSON for invalid invocation'
}

case_l11_strict_block_reader_rejects_malicious_records() {
    begin_case L11 'candidate UUID evidence uses the shared strict block parser'
    reset_fixture
    printf '%s\n' '/dev/nvme0n1p12: UUID="GOOD-1234" TYPE="ext4"' > "$BLOCK_OUTPUT_FILE"
    assert_equal "$(target_device_read_block_uuid /dev/nvme0n1p12)" GOOD-1234 \
        'L11 reads one exact UUID field'
    printf '%s\n' '/dev/nvme0n1p12: LABEL="camera UUID=GOOD-1234" TYPE="ext4"' > "$BLOCK_OUTPUT_FILE"
    assert_failure 'L11 rejects UUID-shaped text inside LABEL' \
        target_device_read_block_uuid /dev/nvme0n1p12
    printf '%s\n' '/dev/nvme0n1p12: UUID="GOOD-1234" TYPE="ext4"' \
        '/dev/nvme0n1p12: UUID="GOOD-1234" TYPE="ext4"' > "$BLOCK_OUTPUT_FILE"
    assert_failure 'L11 rejects multiple block output records' \
        target_device_read_block_uuid /dev/nvme0n1p12
}

main() {
    trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
    if [ ! -r "$TARGET_LIST_SCRIPT" ]; then
        printf 'FAIL: target list script is absent: %s\n' "$TARGET_LIST_SCRIPT" >&2
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        printf '%s\n' 'FAIL: pinned OpenWrt rootfs lacks jq required for JSON assertions' >&2
        exit 1
    fi

    # Fixture functions installed above replace only external evidence. The
    # delivered parser, aggregation, and final JSON encoder remain in use.

    case_l01_normal_candidates_are_one_complete_object
    case_l02_empty_collection_is_success
    case_l03_global_configuration_failure_has_no_json
    case_l05_rejects_noneligible_mount_states
    case_l06_btrfs_anonymous_source_is_a_candidate
    case_l07_mount_space_and_clone_identity_are_preserved
    case_l08_loader_precedence_and_path_normalization_are_reported
    case_l09_invalid_optional_led_is_silent_and_nonfatal
    case_l10_rejects_arguments
    case_l11_strict_block_reader_rejects_malicious_records
    case_l04_collection_then_encoding_failure_has_no_partial_output

    assert_equal "$CASES" 11 'all required cases executed'
    assert_equal "$ASSERTIONS" 24 'all required assertions executed'
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

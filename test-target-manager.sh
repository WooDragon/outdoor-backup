#!/bin/sh
#
# BDD integration tests for manager wiring of the target FD anchor and device
# guard. target tmpfs and /proc/$$/fd/9 are real; sysfs/block, source mount,
# and rsync are explicit fixtures and never represent a real SSD.
#
set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 --network bridge \
        --cap-add SYS_ADMIN --security-opt seccomp=unconfined --tmpfs /tmp:rw,exec --tmpfs /opt:rw,exec \
        -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-target-manager.sh --inside
fi

if [ ! -f /.dockerenv ] || [ ! -r /etc/openwrt_release ]; then
    printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
    exit 1
fi

ASYNC_STDERR="${TEST_ASYNC_STDERR:-/tmp/outdoor-backup-target-manager-stderr.$$}"

# Preserve the caller's diagnostic sink before the normal child redirects fd 2
# into ASYNC_STDERR. Failure replay must never write into its own input file.
if [ "${TEST_CAPTURED_STDERR:-0}" != 1 ]; then
    exec 3>&2
    : > "$ASYNC_STDERR"
    TEST_CAPTURED_STDERR=1 TEST_ASYNC_STDERR="$ASYNC_STDERR"         exec /bin/ash "$0" "$@" 2> "$ASYNC_STDERR"
fi

replay_async_stderr() {
    while IFS= read -r captured_line || [ -n "$captured_line" ]; do
        printf '%s\n' "$captured_line" >&3
    done < "$ASYNC_STDERR"
}

# This test-only probe exercises the normal replay helper without running the
# suite again. Its caller supplies fd 3 as an independent, bounded sink.
if [ "${2:-}" = "--stderr-replay-probe" ]; then
    printf '%s\n' 'ASYNC-REPLAY-SENTINEL-7f1c6d9e' > "$ASYNC_STDERR"
    replay_async_stderr
    printf 'cases=0 assertions=0 failed=1\n' >&3
    exit 1
fi

mkdir -p /var/lock
opkg update >/dev/null
opkg install jq >/dev/null

REPO_ROOT=/src
# Every case gets its own directory tree under SUITE_ROOT and cases never
# delete each other's tree (only the EXIT trap removes SUITE_ROOT wholesale).
# The LED helper (common.sh) forks a child that itself loops and re-spawns
# stub sleep processes; settle_led_fixture only joins the one child it has a
# pid for, so a straggling grandchild can still be alive after a case ends.
# Giving each case an isolated, never-deleted-until-suite-exit directory
# means that straggler simply keeps writing into a tree that still exists
# instead of racing the next case's teardown.
SUITE_ROOT="/tmp/outdoor-backup-target-manager.$$"
FIXTURE_SEQ=0
TEST_ROOT="$SUITE_ROOT/case-0"

# Derive every fixture path from the current TEST_ROOT. Called once at
# startup and again by reset_case() each time TEST_ROOT advances to a new
# per-case directory.
derive_fixture_paths() {
    RUNTIME="$TEST_ROOT/runtime/opt/outdoor-backup"
    SCRIPTS="$RUNTIME/scripts"
    TARGET_MOUNT="$TEST_ROOT/target mount"
    SOURCE_MOUNT="$TEST_ROOT/source mount"
    SYSFS="$TEST_ROOT/sys"
    MOUNTINFO="$TEST_ROOT/mountinfo"
    BIN="$TEST_ROOT/bin"
    EFFECTS="$TEST_ROOT/effects"
    NOTICES="$TEST_ROOT/notices"
    RSYNC_ARGC="$TEST_ROOT/rsync-argc"
    RSYNC_SOURCE="$TEST_ROOT/rsync-source"
    RSYNC_TARGET="$TEST_ROOT/rsync-target"
}
derive_fixture_paths
TARGET_UUID="A1B2-C3D4"
CARD_UUID="550e8400-e29b-41d4-a716-446655440000"
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

# Execute the production manager once and retain its real exit status. Args are
# the manager event arguments; this wrapper always succeeds for test control.
run_manager_capture_exit() {
    if run_manager "$@"; then
        MANAGER_EXIT=0
    else
        MANAGER_EXIT=$?
    fi
    return 0
}

assert_manager_exit() {
    expected_exit=$1
    message=$2
    shift 2
    run_manager_capture_exit "$@"
    assert_equal "$MANAGER_EXIT" "$expected_exit" "$message"
}

assert_manager_nonzero() {
    message=$1
    shift
    run_manager_capture_exit "$@"
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$MANAGER_EXIT" -eq 0 ]; then
        fail "$message (actual exit=0)"
    fi
}

# Prove the precise exit assertion is a real guard: a deliberately mutated
# manager must not satisfy the production exit code expectation.
assert_manager_exit_rejected() {
    expected_exit=$1
    message=$2
    shift 2
    run_manager_capture_exit "$@"
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$MANAGER_EXIT" -eq "$expected_exit" ]; then
        fail "$message (unexpected exit=$MANAGER_EXIT)"
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

assert_contains() {
    needle=$1
    file=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! grep -F -q -- "$needle" "$file"; then
        fail "$message (missing=[$needle])"
    fi
}

assert_absent() {
    path=$1
    message=$2
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ -e "$path" ] || [ -L "$path" ]; then
        fail "$message (exists=[$path])"
    fi
}

file_hash_or_absent() {
    if [ -f "$1" ] && [ ! -L "$1" ]; then
        sha256sum "$1" | awk '{print $1}'
    else
        printf '%s\n' absent
    fi
}

assert_not_contains() {
    needle=$1
    file=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if grep -F -q -- "$needle" "$file"; then
        fail "$message (unexpected=[$needle])"
    fi
}

assert_matches() {
    pattern=$1
    file=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! grep -E -q -- "$pattern" "$file"; then
        fail "$message (pattern=[$pattern])"
    fi
}

assert_no_async_led_stderr() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if grep -E -q 'sleep: invalid number|nonexistent directory' "$ASYNC_STDERR"; then
        fail "LED helper emitted invalid asynchronous stderr: $(tr '\n' ' ' < "$ASYNC_STDERR")"
    fi
}

# A target guard failure may emit syslog and the red LED only. The fixture sleep
# stub records the production duration, then waits on a fixture-owned release file.
# reset_case releases and joins that exact child before replacing its LED directory.
assert_guard_failure_effects() {
    case_id=$1
    assert_contains '-t outdoor-backup -p err' "$NOTICES" \
        "$case_id guard syslog uses error severity"
    assert_equal "$(cat "$TEST_ROOT/red/trigger")" timer \
        "$case_id guard sets red LED timer trigger"
    assert_equal "$(cat "$TEST_ROOT/red/delay_on")" 500 \
        "$case_id guard sets red LED on delay"
    assert_equal "$(cat "$TEST_ROOT/red/delay_off")" 500 \
        "$case_id guard sets red LED off delay"
    assert_contains 'sleep duration=60' "$EFFECTS" \
        "$case_id LED auto-off requests its production duration through the stub"
    assert_not_contains 'mount argc=' "$EFFECTS" \
        "$case_id guard did not mount source media"
    assert_not_contains rsync "$EFFECTS" \
        "$case_id guard did not start a backup"
    assert_absent "$RUNTIME/log/backup.log" \
        "$case_id guard did not create an application log"
    assert_absent /opt/outdoor-backup/conf/aliases.json \
        "$case_id guard did not create aliases"
    assert_absent "$TEST_ROOT/green/trigger" \
        "$case_id guard did not signal backup completion"
}

assert_guard_failure_observable() {
    assert_guard_failure_effects "$1"
    /bin/sleep 1
}

wait_for_path() {
    path=$1
    attempts=0
    while [ ! -e "$path" ] && [ "$attempts" -lt 5 ]; do
        /bin/sleep 1
        attempts=$((attempts + 1))
    done
    [ -e "$path" ]
}

wait_for_timer_exit() {
    timer_pid=$(cat "$TEST_ROOT/timer-pid" 2>/dev/null) || return 1
    attempts=0
    while kill -0 "$timer_pid" 2>/dev/null && [ "$attempts" -lt 5 ]; do
        /bin/sleep 1
        attempts=$((attempts + 1))
    done
    ! kill -0 "$timer_pid" 2>/dev/null
}

mount_target() {
    mkdir -p "$TARGET_MOUNT"
    mount -t tmpfs -o rw,size=2m tmpfs "$TARGET_MOUNT"
}

unmount_target() {
    umount "$TARGET_MOUNT" 2>/dev/null || :
}

mount_major_minor() {
    awk -v expected="$TARGET_MOUNT" '
        function decode(value) { gsub(/\\040/, " ", value); return value }
        decode($5) == expected { print $3; exit }
    ' /proc/self/mountinfo
}

add_node() {
    name=$1
    major_minor=$2
    node="$SYSFS/devices/mock/block/$name"
    mkdir -p "$node"
    printf '%s\n' "$major_minor" > "$node/dev"
    printf 'DEVNAME=%s\n' "$name" > "$node/uevent"
    ln -s "../../devices/mock/block/$name" "$SYSFS/dev/block/$major_minor"
    ln -s "../../devices/mock/block/$name" "$SYSFS/class/block/$name"
}

add_partition() {
    parent=$1
    name=$2
    major_minor=$3
    node="$SYSFS/devices/mock/block/$parent/$name"
    mkdir -p "$node"
    : > "$node/partition"
    printf '%s\n' "$major_minor" > "$node/dev"
    printf 'DEVNAME=%s\n' "$name" > "$node/uevent"
    ln -s "../../devices/mock/block/$parent/$name" "$SYSFS/dev/block/$major_minor"
    ln -s "../../devices/mock/block/$parent/$name" "$SYSFS/class/block/$name"
}

prepare_fixture_topology() {
    target_mm=$(mount_major_minor)
    [ -n "$target_mm" ] || return 1
    mkdir -p "$SYSFS/dev/block" "$SYSFS/class/block" "$SYSFS/devices/mock/block"
    add_node mmcblk0 179:0
    add_partition mmcblk0 mmcblk0p2 179:2
    add_node sda 8:0
    add_partition sda sda1 8:1
    add_node nvme0n1 259:0
    add_partition nvme0n1 nvme0n1p1 "$target_mm"
    TARGET_TEST_BLOCK_NODE=/dev/nvme0n1p1
    printf '1 0 179:2 / /rom ro - squashfs fixture ro\n' > "$MOUNTINFO"
    printf '%s\n' "$target_mm" > "$TEST_ROOT/target-mm"
}

# Re-map the real target mount major:minor to a fixture partition on one parent.
# Arguments: physical parent disk name, safe target partition fixture name.
map_target_to_physical_disk() {
    parent_name=$1
    target_name=$2
    target_mm=$(cat "$TEST_ROOT/target-mm")
    rm -f "$SYSFS/dev/block/$target_mm"
    target_node="$SYSFS/devices/mock/block/$parent_name/$target_name"
    mkdir -p "$target_node"
    : > "$target_node/partition"
    printf '%s\n' "$target_mm" > "$target_node/dev"
    printf 'DEVNAME=%s\n' "$target_name" > "$target_node/uevent"
    ln -s "../../devices/mock/block/$parent_name/$target_name" \
        "$SYSFS/dev/block/$target_mm"
    TARGET_TEST_BLOCK_NODE=/dev/$target_name
}

prepare_runtime() {
    rm -rf "$RUNTIME" "$SOURCE_MOUNT" "$BIN" "$EFFECTS" "$NOTICES" \
        /opt/outdoor-backup/conf
    mkdir -p "$SCRIPTS" "$RUNTIME/conf" "$RUNTIME/var/lock" \
        "$RUNTIME/log" "$BIN" "$SOURCE_MOUNT" /opt/outdoor-backup/conf
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/backup-manager.sh" "$SCRIPTS/backup-manager.sh"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/config.sh" "$SCRIPTS/config.sh"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/common.sh" "$SCRIPTS/common.sh"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/status.sh" "$SCRIPTS/status.sh"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/backup-transfer.sh" "$SCRIPTS/backup-transfer.sh"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/card-config.sh" "$SCRIPTS/card-config.sh"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/card-identity.sh" "$SCRIPTS/card-identity.sh"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/target.sh" "$SCRIPTS/target.sh"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/target-device.sh" "$SCRIPTS/target-device.sh"
    : > "$EFFECTS"
    : > "$NOTICES"
    cat > "$RUNTIME/conf/backup.conf" <<EOF
BACKUP_ROOT="$TARGET_MOUNT/backups"
TARGET_MOUNT="$TARGET_MOUNT"
TARGET_UUID="$TARGET_UUID"
MOUNT_POINT="$SOURCE_MOUNT"
MIN_FREE_SPACE=0
LED_GREEN="$TEST_ROOT/green"
LED_RED="$TEST_ROOT/red"
EOF
    mkdir -p "$TEST_ROOT/green" "$TEST_ROOT/red"
    cat > "$BIN/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_NOTICES"
EOF
    cat > "$BIN/block" <<'EOF'
#!/bin/sh
case "${1:-}:$2" in
    info:"$TARGET_TEST_BLOCK_NODE")
        printf '%s: UUID="A1B2-C3D4" TYPE="tmpfs"\n' "$TARGET_TEST_BLOCK_NODE"
        ;;
    info:/dev/sda1)
        [ "${TEST_SOURCE_BLOCK_FAIL:-0}" = 1 ] && exit 1
        printf '%s: UUID="%s" TYPE="vfat"\n' /dev/sda1 "$TEST_SOURCE_FS_UUID"
        ;;
    *)
        printf '%s: UUID="A1B2-C3D4" TYPE="tmpfs"\n' /dev/unexpected
        ;;
esac
EOF
    cat > "$BIN/mount" <<'EOF'
#!/bin/sh
# The mountpoint is always the final positional operand no matter how many
# -t/-o option pairs precede it, so scan for it instead of hardcoding a
# position (mirrors the rsync stub's own source/target extraction below) --
# this stays correct across argv shape changes such as adding "-o <mode>".
mount_prev=''
mount_target=''
mount_mode='none'
mount_fstype='none'
for value in "$@"; do
    if [ "$mount_prev" = '-o' ]; then
        mount_mode=$value
    fi
    if [ "$mount_prev" = '-t' ]; then
        mount_fstype=$value
    fi
    mount_target=$value
    mount_prev=$value
done
printf 'mount mode=%s target=[%s]\n' "$mount_mode" "$mount_target" >> "$TEST_EFFECTS"
mkdir -p "$mount_target"
# Auto-creating a card config file is opt-in only: a case that wants a
# pre-existing config must ask for it explicitly (or write it directly, as
# the replica/invalid-card cases do), so a case that says nothing sees a
# genuinely blank card and exercises the manager's own first-write path.
if [ -n "${TEST_MOUNT_AUTO_CARD:-}" ] && [ ! -e "$mount_target/FieldBackup.conf" ]; then
    if [ -n "${TEST_CARD_CONFIG:-}" ]; then
        printf '%s\n' "$TEST_CARD_CONFIG" > "$mount_target/FieldBackup.conf"
    else
        cat > "$mount_target/FieldBackup.conf" <<'CARD'
SD_UUID="550e8400-e29b-41d4-a716-446655440000"
BACKUP_MODE="PRIMARY"
BACKUP_ROOT="/escaped-by-card-config"
TARGET_FD_ROOT="/escaped-by-card-config/fd"
TARGET_BACKUP_ROOT="/escaped-by-card-config/backups"
TARGET_UUID="ATTACKER-UUID"
TARGET_SYSFS_ROOT="/escaped-by-card-config/sys"
PATH="/escaped-by-card-config/bin"
IFS="attacker"
CARD
    fi
fi
if [ -n "${TEST_SOURCE_SENTINEL:-}" ] && [ ! -e "$mount_target/source-sentinel" ]; then
    printf '%s\n' "$TEST_SOURCE_SENTINEL" > "$mount_target/source-sentinel"
fi
if [ "$mount_mode" = rw ] && [ "${TEST_MOUNT_RW_FAILS:-0}" = 1 ]; then
    exit 1
fi
if [ "$mount_mode" = ro ] && [ -n "${TEST_MOUNT_RO_COUNT:-}" ]; then
    # mount_sdcard() retries multiple fs types on failure, so a naive "count
    # every stub call" counter double-counts a deliberately failing logical
    # invocation as soon as production retries the next fs type. "-t auto" is
    # always the first fs type mount_sdcard() tries for any one invocation, so
    # only it advances the counter and decides pass/fail; every later fs-type
    # retry within that same invocation (fstype != auto) replays that same
    # decision from a sidecar file instead of drawing a fresh one.
    decision_file="$TEST_MOUNT_RO_COUNT.decision"
    if [ "$mount_fstype" = auto ]; then
        ro_count=0
        [ -r "$TEST_MOUNT_RO_COUNT" ] && ro_count=$(cat "$TEST_MOUNT_RO_COUNT")
        ro_count=$((ro_count + 1))
        printf '%s\n' "$ro_count" > "$TEST_MOUNT_RO_COUNT"
        if [ "$ro_count" = "${TEST_MOUNT_RO_FAIL_ON:-0}" ]; then
            printf '1\n' > "$decision_file"
        else
            printf '0\n' > "$decision_file"
        fi
    fi
    if [ -r "$decision_file" ] && [ "$(cat "$decision_file")" = 1 ]; then
        exit 1
    fi
fi
exit 0
EOF
    cat > "$BIN/umount" <<'EOF'
#!/bin/sh
# Only source-media calls through the manager's PATH are injectable. Test setup
# unmounts the target with /bin/umount, so this cannot block the real tmpfs.
umount_target=''
for value in "$@"; do
    case $value in
        -*) ;;
        *) umount_target=$value ;;
    esac
done
printf 'umount target=[%s]\n' "$umount_target" >> "$TEST_EFFECTS"
if [ "$umount_target" = "$TEST_SOURCE_MOUNT" ]; then
    umount_count=0
    [ -r "$TEST_SOURCE_UMOUNT_COUNT" ] && umount_count=$(cat "$TEST_SOURCE_UMOUNT_COUNT")
    umount_count=$((umount_count + 1))
    printf '%s\n' "$umount_count" > "$TEST_SOURCE_UMOUNT_COUNT"
    printf 'source-umount count=%s\n' "$umount_count" >> "$TEST_EFFECTS"
    if [ "$umount_count" = "${TEST_SOURCE_UMOUNT_FAIL_ON:-0}" ]; then
        exit 1
    fi
fi
exit 0
EOF

    cat > "$BIN/mktemp" <<'EOF'
#!/bin/sh
case "$1" in
    "$TEST_SOURCE_MOUNT"/.FieldBackup.conf.*)
        [ "${TEST_CONFIG_MKTEMP_FAIL:-0}" = 1 ] && exit 1
        ;;
    */.card-identities/.*.json.*)
        [ "${TEST_IDENTITY_MKTEMP_FAIL:-0}" = 1 ] && exit 1
        ;;
esac
exec /bin/mktemp "$@"
EOF

    cat > "$BIN/mv" <<'EOF'
#!/bin/sh
mv_target=''
for value in "$@"; do mv_target=$value; done
if [ "$mv_target" = "$TEST_SOURCE_MOUNT/FieldBackup.conf" ]; then
    if [ "${TEST_CONFIG_MV_FAIL:-0}" = 1 ]; then
        exit 1
    fi
    printf 'config-publish target=[%s]\n' "$mv_target" >> "$TEST_EFFECTS"
fi
case "$mv_target" in
    */.card-identities/*.json)
        [ "${TEST_IDENTITY_MV_FAIL:-0}" = 1 ] && exit 1
        ;;
esac
exec /bin/mv "$@"
EOF
    cat > "$BIN/mountpoint" <<'EOF'
#!/bin/sh
exit 1
EOF
    cat > "$BIN/rsync" <<'EOF'
#!/bin/sh
printf 'rsync' >> "$TEST_EFFECTS"
for value in "$@"; do printf ' arg=[%s]' "$value" >> "$TEST_EFFECTS"; done
printf '\n' >> "$TEST_EFFECTS"
printf '%s\n' "$#" > "$TEST_RSYNC_ARGC"
rsync_source=''
rsync_target=''
for value in "$@"; do
    rsync_source=$rsync_target
    rsync_target=$value
done
printf '%s' "$rsync_source" > "$TEST_RSYNC_SOURCE"
printf '%s' "$rsync_target" > "$TEST_RSYNC_TARGET"
if [ -n "${TEST_RSYNC_DIAGNOSTIC:-}" ]; then
    printf '%s\n' "$TEST_RSYNC_DIAGNOSTIC" >&2
fi
if [ -n "${TEST_RSYNC_STATS:-}" ]; then
    printf '%s\n' 'Number of regular files transferred: 7'
    printf '%s\n' 'Total transferred file size: 1,234 bytes'
fi
if [ "${TEST_RSYNC_INJECT:-}" = detach ]; then
    /bin/umount -l "$TEST_TARGET_MOUNT"
elif [ "${TEST_RSYNC_INJECT:-}" = ro ]; then
    /bin/mount -o remount,ro "$TEST_TARGET_MOUNT"
fi
exit "${TEST_RSYNC_EXIT:-0}"
EOF
    cat > "$BIN/cat" <<'EOF'
#!/bin/sh
output_target=$(readlink "/proc/$$/fd/1" 2>/dev/null || :)
if [ "$#" -eq 0 ]; then
    case "$output_target" in
        "$TEST_SOURCE_MOUNT"/.FieldBackup.conf.*)
            if [ "${TEST_CAT_INJECT:-}" = config-write-fail ]; then
                printf '%s\n' 'partial FieldBackup.conf data'
                exit 1
            fi
            exec /bin/cat
            ;;
    esac
fi
if [ "$#" -eq 0 ] && [ "${output_target##*/}" != FieldBackup.conf ]; then
    case "${TEST_CAT_INJECT:-}" in
        summary-fail)
            exit 1
            ;;
        summary-detach)
            /bin/cat
            /bin/umount -l "$TEST_TARGET_MOUNT"
            exit 0
            ;;
        summary-verify-fail)
            /bin/cat
            /bin/rm -f "$TEST_SYSFS/dev/block/$(/bin/cat "$TEST_TARGET_MM")"
            exit 0
            ;;
    esac
fi
exec /bin/cat "$@"
EOF
    cat > "$BIN/df" <<'EOF'
#!/bin/sh
printf 'df %s\n' "$*" >> "$TEST_EFFECTS"
if [ "${1:-}" = -m ]; then
    printf '%s\n' 'Filesystem 1M-blocks Used Available Use% Mounted on'
    printf '%s\n' "/dev/fixture 100 0 ${TEST_DF_MB:-2} 0% /fixture"
else
    printf '%s\n' 'Filesystem 1K-blocks Used Available Use% Mounted on'
    printf '%s\n' "/dev/fixture 102400 0 $(( ${TEST_DF_MB:-2} * 1024 )) 0% /fixture"
fi
EOF
    cat > "$BIN/du" <<'EOF'
#!/bin/sh
printf 'du %s\n' "$*" >> "$TEST_EFFECTS"
exit 99
EOF
    cat > "$BIN/status-mv" <<'EOF'
#!/bin/sh
count_file=$TEST_STATUS_MV_COUNT
count=0
[ -r "$count_file" ] && count=$(cat "$count_file")
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ "${TEST_STATUS_MV_FAIL:-0}" = 1 ] || [ "${TEST_STATUS_MV_FAIL_ON:-0}" = "$count" ]; then
    exit 1
fi
exec /bin/mv "$@"
EOF
    cat > "$BIN/pkill" <<'EOF'
#!/bin/sh
printf 'pkill\n' >> "$TEST_EFFECTS"
EOF
    cat > "$BIN/sync" <<'EOF'
#!/bin/sh
sync_count=0
[ -r "$TEST_CONFIG_SYNC_COUNT" ] && sync_count=$(cat "$TEST_CONFIG_SYNC_COUNT")
sync_count=$((sync_count + 1))
printf '%s\n' "$sync_count" > "$TEST_CONFIG_SYNC_COUNT"
printf 'sync count=%s\n' "$sync_count" >> "$TEST_EFFECTS"
if [ "$sync_count" = "${TEST_CONFIG_SYNC_FAIL_ON:-0}" ]; then
    exit 1
fi
EOF
    cat > "$BIN/sleep" <<'EOF'
#!/bin/sh
# The fixture accepts only production-valid, integer delays. It then blocks on a
# case-owned release file: reset_case can join this exact child before deleting
# BIN or fake LED paths, while M02d/M11 can prove the timer stays alive.
case "${1:-}" in
    ''|*[!0-9]*)
        printf 'sleep fixture rejected non-integer=[%s]\n' "${1:-}" >&2
        exit 64
        ;;
esac
printf 'sleep duration=%s\n' "$1" >> "$TEST_EFFECTS"
printf '%s\n' "$$" > "$TEST_TIMER_PID"
: > "$TEST_TIMER_READY"
while [ ! -e "$TEST_TIMER_RELEASE" ]; do
    /bin/sleep 1
done
EOF
    chmod 755 "$BIN"/*
}

set_config_target_uuid() {
    sed -i "s/^TARGET_UUID=.*/TARGET_UUID=\"$1\"/" "$RUNTIME/conf/backup.conf"
}

run_manager() {
    TEST_EFFECTS="$EFFECTS" TEST_NOTICES="$NOTICES" \
        TARGET_TEST_BLOCK_NODE="$TARGET_TEST_BLOCK_NODE" \
        TARGET_SYSFS_ROOT="$SYSFS" TARGET_MOUNTINFO_FILE="$MOUNTINFO" \
        TEST_SYSFS="$SYSFS" TEST_TARGET_MM="$TEST_ROOT/target-mm" \
        TEST_TARGET_MOUNT="$TARGET_MOUNT" TEST_CAT_INJECT="${TEST_CAT_INJECT:-}" \
        TEST_RSYNC_ARGC="$RSYNC_ARGC" TEST_RSYNC_SOURCE="$RSYNC_SOURCE" \
        TEST_RSYNC_TARGET="$RSYNC_TARGET" \
        TEST_TIMER_CONTROLLED="${TEST_TIMER_CONTROLLED:-0}" \
        TEST_TIMER_READY="$TEST_ROOT/timer-ready" \
        TEST_TIMER_RELEASE="$TEST_ROOT/timer-release" \
        TEST_TIMER_PID="$TEST_ROOT/timer-pid" \
        TEST_TIMER_DURATION="${TEST_TIMER_DURATION:-60}" \
        TEST_DF_MB="${TEST_DF_MB:-2}" TEST_RSYNC_EXIT="${TEST_RSYNC_EXIT:-0}" \
        TEST_RSYNC_DIAGNOSTIC="${TEST_RSYNC_DIAGNOSTIC:-}" TEST_RSYNC_STATS="${TEST_RSYNC_STATS:-}" \
        STATUS_FILE="$RUNTIME/var/status.json" STATUS_MV="$BIN/status-mv" \
        TEST_STATUS_MV_COUNT="$TEST_ROOT/status-mv-count" \
        TEST_STATUS_MV_FAIL="${TEST_STATUS_MV_FAIL:-0}" \
        TEST_STATUS_MV_FAIL_ON="${TEST_STATUS_MV_FAIL_ON:-0}" \
        TEST_MOUNT_AUTO_CARD="${TEST_MOUNT_AUTO_CARD:-}" \
        TEST_MOUNT_RW_FAILS="${TEST_MOUNT_RW_FAILS:-0}" \
        TEST_MOUNT_RO_FAIL_ON="${TEST_MOUNT_RO_FAIL_ON:-0}" \
        TEST_MOUNT_RO_COUNT="$TEST_ROOT/mount-ro-count" \
        TEST_SOURCE_MOUNT="$SOURCE_MOUNT" \
        TEST_SOURCE_UMOUNT_FAIL_ON="${TEST_SOURCE_UMOUNT_FAIL_ON:-0}" \
        TEST_SOURCE_UMOUNT_COUNT="$TEST_ROOT/source-umount-count" \
        TEST_SOURCE_FS_UUID="${TEST_SOURCE_FS_UUID:-ABCD-1234}" \
        TEST_SOURCE_BLOCK_FAIL="${TEST_SOURCE_BLOCK_FAIL:-0}" \
        TEST_CONFIG_MKTEMP_FAIL="${TEST_CONFIG_MKTEMP_FAIL:-0}" \
        TEST_CONFIG_MV_FAIL="${TEST_CONFIG_MV_FAIL:-0}" \
        TEST_IDENTITY_MKTEMP_FAIL="${TEST_IDENTITY_MKTEMP_FAIL:-0}" \
        TEST_IDENTITY_MV_FAIL="${TEST_IDENTITY_MV_FAIL:-0}" \
        TEST_CONFIG_SYNC_FAIL_ON="${TEST_CONFIG_SYNC_FAIL_ON:-0}" \
        TEST_CONFIG_SYNC_COUNT="$TEST_ROOT/config-sync-count" \
        DEBUG="${DEBUG:-0}" PATH="$BIN:$PATH" \
        /bin/ash "${MANAGER_SCRIPT:-$SCRIPTS/backup-manager.sh}" "$@"
}

settle_led_fixture() {
    [ -d "$TEST_ROOT" ] || return 0
    timer_pid=$(cat "$TEST_ROOT/timer-pid" 2>/dev/null || :)
    [ -n "$timer_pid" ] || return 0

    if kill -0 "$timer_pid" 2>/dev/null; then
        : > "$TEST_ROOT/timer-release"
        wait_for_timer_exit || return 1
    fi

    attempts=0
    while [ "$attempts" -lt 5 ]; do
        red_active=0
        green_active=0
        [ -s "$TEST_ROOT/red/trigger" ] && red_active=1
        [ -s "$TEST_ROOT/green/trigger" ] && green_active=1
        if { [ "$red_active" -eq 0 ] || [ "$(cat "$TEST_ROOT/red/brightness")" = 0 ]; } && \
            { [ "$green_active" -eq 0 ] || [ "$(cat "$TEST_ROOT/green/brightness")" = 0 ]; }; then
            return 0
        fi
        /bin/sleep 1
        attempts=$((attempts + 1))
    done
    return 1
}

reset_case() {
    settle_led_fixture || return 1
    unmount_target
    FIXTURE_SEQ=$((FIXTURE_SEQ + 1))
    TEST_ROOT="$SUITE_ROOT/case-$FIXTURE_SEQ"
    derive_fixture_paths
    TARGET_UUID="A1B2-C3D4"
    mkdir -p "$TEST_ROOT"
    mount_target || return 1
    prepare_fixture_topology || return 1
    prepare_runtime
}

case_m01_unconfigured_uuid_stops_before_common_side_effects() {
    begin_case M01 'empty UUID stops add before common logging alias lock or source mount'
    reset_case || { fail 'M01 fixture setup failed'; return; }
    set_config_target_uuid ''
    if run_manager add sda1 /devices/mock > /dev/null 2> "$TEST_ROOT/error"; then
        fail 'M01 empty target UUID unexpectedly succeeded'
    fi
    assert_contains 'target UUID is unconfigured' "$TEST_ROOT/error" 'M01 reports UUID decision'
    assert_equal "$(wc -l < "$NOTICES")" 1 'M01 only emitted guard observability'
    assert_guard_failure_observable M01
}

case_m01b_missing_led_keeps_guard_failure_and_error_syslog() {
    begin_case M01b 'missing optional red LED cannot hide unconfigured target failure'
    reset_case || { fail 'M01b fixture setup failed'; return; }
    set_config_target_uuid ''
    rm -rf "$TEST_ROOT/red"
    assert_failure 'M01b missing LED still leaves manager failure nonzero' run_manager add sda1 /devices/mock
    assert_contains '-t outdoor-backup -p err' "$NOTICES" \
        'M01b missing LED still reports error-severity syslog'
    assert_equal "$(wc -l < "$EFFECTS")" 1 \
        'M01b missing LED emitted only its controlled auto-off sleep effect'
    assert_contains 'sleep duration=60' "$EFFECTS" \
        'M01b missing LED retained the production auto-off request'
    assert_absent "$RUNTIME/log/backup.log" 'M01b missing LED did not create application log'
    assert_absent /opt/outdoor-backup/conf/aliases.json 'M01b missing LED did not create aliases'
    assert_absent "$TEST_ROOT/green/trigger" 'M01b missing LED did not signal completion'
    /bin/sleep 1
}

case_m01c_debug_guard_failure_does_not_create_application_log() {
    begin_case M01c 'DEBUG guard failure signals externally without application logging'
    reset_case || { fail 'M01c fixture setup failed'; return; }
    set_config_target_uuid ''
    DEBUG=1 assert_failure 'M01c DEBUG fixture manager still fails' run_manager add sda1 /devices/mock
    assert_guard_failure_observable M01c
}

case_m02_target_device_mismatch_stops_before_source_mount() {
    begin_case M02 'wrong configured UUID stops after target open but before application effects'
    reset_case || { fail 'M02 fixture setup failed'; return; }
    set_config_target_uuid 'WRONG-UUID'
    assert_failure 'M02 mismatched target UUID fails manager' run_manager add sda1 /devices/mock
    assert_guard_failure_observable M02
}

case_m02d_uuid_mismatch_releases_anchor_before_led_timer() {
    begin_case M02d 'UUID mismatch closes the target anchor before its red LED timer waits'
    reset_case || { fail 'M02d fixture setup failed'; return; }
    set_config_target_uuid 'WRONG-UUID'
    TEST_TIMER_CONTROLLED=1
    export TEST_TIMER_CONTROLLED
    assert_failure 'M02d mismatched target UUID fails manager' run_manager add sda1 /devices/mock
    assert_success 'M02d LED timer reached its controlled wait' \
        wait_for_path "$TEST_ROOT/timer-ready"
    assert_success 'M02d LED timer remains alive before target unmount' \
        kill -0 "$(cat "$TEST_ROOT/timer-pid")"
    assert_guard_failure_effects M02d
    assert_success 'M02d regular umount succeeds while LED timer is waiting' \
        /bin/umount "$TARGET_MOUNT"
    : > "$TEST_ROOT/timer-release"
    assert_success 'M02d LED timer exits after fixture release' wait_for_timer_exit
    unset TEST_TIMER_CONTROLLED
}

case_m02a_read_only_target_stops_before_common_side_effects() {
    begin_case M02a 'read-only target rejects add before common lifecycle effects'
    reset_case || { fail 'M02a fixture setup failed'; return; }
    assert_success 'M02a remounted target read-only' /bin/mount -o remount,ro "$TARGET_MOUNT"
    assert_failure 'M02a read-only target fails manager' run_manager add sda1 /devices/mock
    assert_guard_failure_observable M02a
}

case_m02b_missing_mount_stops_before_common_side_effects() {
    begin_case M02b 'missing target mount rejects add before common source mount or logging'
    reset_case || { fail 'M02b fixture setup failed'; return; }
    unmount_target
    assert_failure 'M02b missing target mount fails manager' run_manager add sda1 /devices/mock
    assert_guard_failure_observable M02b
}

case_m02c_same_source_or_system_disk_stops_before_common() {
    begin_case M02c 'source and system physical target mappings reject before common effects'
    reset_case || { fail 'M02c source fixture setup failed'; return; }
    map_target_to_physical_disk sda sda12
    assert_failure 'M02c source physical disk target fails manager' run_manager add sda1 /devices/mock
    assert_guard_failure_observable M02c-source

    reset_case || { fail 'M02c system fixture setup failed'; return; }
    map_target_to_physical_disk mmcblk0 mmcblk0p3
    assert_failure 'M02c system physical disk target fails manager' run_manager add sda1 /devices/mock
    assert_guard_failure_observable M02c-system
}

case_m03_healthy_path_uses_only_fd_anchored_target() {
    begin_case M03 'successful primary backup ignores card BACKUP_ROOT and TARGET overrides'
    reset_case || { fail 'M03 fixture setup failed'; return; }
    # This case is about rsync/backup mechanics on an already-provisioned card,
    # not about setup_sdcard_config's first-write path (covered by dedicated
    # cases below), so it opts the fixture back into a pre-existing, fixed-UUID
    # card config -- matching what the manager sees in the field on every run
    # after the very first.
    TEST_MOUNT_AUTO_CARD=1
    export TEST_MOUNT_AUTO_CARD
    ASSERTIONS=$((ASSERTIONS + 1))
    if run_manager add sda1 /devices/mock > "$TEST_ROOT/m03.stdout" 2> "$TEST_ROOT/m03.stderr"; then
        :
    else
        fail "M03 healthy guarded backup succeeds: stderr=$(tr '\n' ' ' < "$TEST_ROOT/m03.stderr"); log=$(tr '\n' ' ' < "$RUNTIME/log/backup.log")"
    fi
    unset TEST_MOUNT_AUTO_CARD
    target_root=$(cat "$TEST_ROOT/target-mm")
    assert_contains "mount mode=ro target=[$SOURCE_MOUNT]" "$EFFECTS" 'M03 source mount stayed read-only'
    assert_equal "$(cat "$RSYNC_ARGC")" 15 'M03 rsync received the transfer helper option and operand count'
    assert_equal "$(cat "$RSYNC_SOURCE")" "$SOURCE_MOUNT/" \
        'M03 rsync penultimate argv is the complete source-card path'
    assert_matches "^/proc/[0-9]+/fd/9/backups/$CARD_UUID/$" "$RSYNC_TARGET" \
        'M03 rsync final argv is the complete anchored UUID target path'
    assert_contains 'Backup completed successfully' "$RUNTIME/log/backup.log" \
        'M03 successful completed status retains the final cleanup success log'
    assert_absent /escaped-by-card-config 'M03 card configuration did not create an escaped root'
    assert_not_contains /escaped-by-card-config "$EFFECTS" 'M03 ignored card BACKUP_ROOT and TARGET overrides'
    assert_equal "$(find "$TARGET_MOUNT/backups" -type d | wc -l)" 4 \
        'M03 created root UUID logs and identity directories only on tmpfs'
    assert_equal "$(find "$TEST_ROOT" -path "$TARGET_MOUNT" -prune -o -name "$CARD_UUID" -print | wc -l)" 0 \
        'M03 UUID directory did not leak outside target tmpfs'
    rm -f "$TEST_ROOT/target-mm" # keeps the real value read above explicit for fixture audit.
    : "$target_root"
}

case_m03a_existing_replica_card_rejects_reverse_rsync_and_preserves_card_files() {
    begin_case M03a 'existing replica card rejects reverse rsync and preserves existing card files'
    reset_case || { fail 'M03a fixture setup failed'; return; }
    TEST_CARD_CONFIG="SD_UUID=\"$CARD_UUID\"
BACKUP_MODE=\"REPLICA\""
    TEST_SOURCE_SENTINEL='original source data sentinel'
    export TEST_CARD_CONFIG TEST_SOURCE_SENTINEL
    printf '%s\n' "$TEST_CARD_CONFIG" > "$SOURCE_MOUNT/FieldBackup.conf"
    printf '%s\n' "$TEST_SOURCE_SENTINEL" > "$SOURCE_MOUNT/source-sentinel"
    card_config_hash=$(sha256sum "$SOURCE_MOUNT/FieldBackup.conf" | awk '{print $1}')
    sentinel_hash=$(sha256sum "$SOURCE_MOUNT/source-sentinel" | awk '{print $1}')
    assert_failure 'M03a existing REPLICA card fails manager' run_manager add sda1 /devices/mock
    unset TEST_CARD_CONFIG TEST_SOURCE_SENTINEL
    assert_contains 'REPLICA mode is not supported by automatic backup; refusing reverse synchronization' \
        "$RUNTIME/log/backup.log" 'M03a explains automatic backup refusal'
    assert_not_contains rsync "$EFFECTS" 'M03a replica card never reaches rsync'
    assert_absent /opt/outdoor-backup/conf/aliases.json 'M03a does not update aliases'
    assert_absent "$TARGET_MOUNT/backups/$CARD_UUID" 'M03a does not create a target UUID leaf'
    assert_absent "$TARGET_MOUNT/backups/.logs" 'M03a does not create a backup log directory'
    assert_equal "$(sha256sum "$SOURCE_MOUNT/FieldBackup.conf" | awk '{print $1}')" "$card_config_hash" \
        'M03a preserves the existing card configuration bytes'
    assert_equal "$(sha256sum "$SOURCE_MOUNT/source-sentinel" | awk '{print $1}')" "$sentinel_hash" \
        'M03a preserves source data bytes'
    assert_success 'M03a target FD closes before the fixture unmount' /bin/umount "$TARGET_MOUNT"
}

case_m03b_invalid_existing_card_fails_without_rewriting_identity() {
    begin_case M03b 'invalid existing card config fails without rsync or replacement identity'
    reset_case || { fail 'M03b fixture setup failed'; return; }
    TEST_CARD_CONFIG='BACKUP_MODE=PRIMARY'
    TEST_MOUNT_AUTO_CARD=1
    export TEST_CARD_CONFIG TEST_MOUNT_AUTO_CARD
    assert_failure 'M03b missing card UUID fails manager' run_manager add sda1 /devices/mock
    unset TEST_CARD_CONFIG TEST_MOUNT_AUTO_CARD
    assert_not_contains rsync "$EFFECTS" 'M03b invalid card never reaches rsync'
    assert_equal "$(cat "$SOURCE_MOUNT/FieldBackup.conf")" 'BACKUP_MODE=PRIMARY' \
        'M03b preserves the invalid existing card file'
}

case_m03c_existing_replica_card_classifies_card_config_not_rsync() {
    begin_case M03c 'existing replica card classifies ERROR_TYPE as card_config, not the generic rsync failure'
    reset_case || { fail 'M03c fixture setup failed'; return; }
    TEST_CARD_CONFIG="SD_UUID=\"$CARD_UUID\"
BACKUP_MODE=\"REPLICA\""
    export TEST_CARD_CONFIG
    printf '%s\n' "$TEST_CARD_CONFIG" > "$SOURCE_MOUNT/FieldBackup.conf"
    assert_failure 'M03c existing REPLICA card fails manager' run_manager add sda1 /devices/mock
    unset TEST_CARD_CONFIG
    assert_equal "$(cat "$TEST_ROOT/red/trigger")" none \
        'M03c card_config uses the manual-toggle flash pattern, not the generic rsync timer trigger'
    assert_absent "$RUNTIME/var/status.json" \
        'M03c guard-stage rejection precedes STATUS_STARTED, so no status.json terminal write occurs'
    /bin/sleep 1
}

case_m04_symlink_components_reject_before_target_update() {
    begin_case M04 'root UUID and logs symlink components reject without writes'
    reset_case || { fail 'M04 root fixture setup failed'; return; }
    mkdir -p "$TARGET_MOUNT/outside"
    ln -s "$TARGET_MOUNT/outside" "$TARGET_MOUNT/backups"
    assert_failure 'M04 root symlink rejects' run_manager add sda1 /devices/mock
    assert_not_contains 'mount mode=' "$EFFECTS" 'M04 root symlink did not source mount'
    # Let the fixture's capped LED auto-off finish before the next reset.
    /bin/sleep 1

    reset_case || { fail 'M04 UUID fixture setup failed'; return; }
    mkdir -p "$TARGET_MOUNT/backups/outside"
    ln -s "$TARGET_MOUNT/backups/outside" "$TARGET_MOUNT/backups/$CARD_UUID"
    # The planted symlink's name is the fixed CARD_UUID, so the card config
    # must resolve to that same UUID for the escape attempt to actually be
    # exercised -- otherwise a freshly generated random UUID sails past it.
    TEST_MOUNT_AUTO_CARD=1
    export TEST_MOUNT_AUTO_CARD
    assert_failure 'M04 UUID symlink rejects' run_manager add sda1 /devices/mock
    unset TEST_MOUNT_AUTO_CARD
    assert_contains "mount mode=ro target=[$SOURCE_MOUNT]" "$EFFECTS" \
        'M04 UUID rejection did not reach the controlled source mount'
    ASSERTIONS=$((ASSERTIONS + 1))
    if grep -F -q rsync "$EFFECTS"; then
        fail 'M04 UUID symlink reached rsync'
    fi

    reset_case || { fail 'M04 logs fixture setup failed'; return; }
    mkdir -p "$TARGET_MOUNT/backups/outside"
    ln -s "$TARGET_MOUNT/backups/outside" "$TARGET_MOUNT/backups/.logs"
    assert_failure 'M04 logs symlink rejects' run_manager add sda1 /devices/mock
    assert_contains "mount mode=ro target=[$SOURCE_MOUNT]" "$EFFECTS" \
        'M04 logs rejection did not reach the controlled source mount'
    ASSERTIONS=$((ASSERTIONS + 1))
    if grep -F -q rsync "$EFFECTS"; then
        fail 'M04 logs symlink reached rsync'
    fi
}

# Reduce $EFFECTS to just its ordered mount/umount events, e.g. "ro,umount,rw".
mount_effect_sequence() {
    grep -E '^(mount mode=|umount target=)' "$EFFECTS" \
        | sed -E 's/^mount mode=([a-z]+).*/\1/; s/^umount target=.*/umount/' \
        | tr '\n' ',' \
        | sed 's/,$//'
}

assert_card_config_temp_absent() {
    message=$1
    ASSERTIONS=$((ASSERTIONS + 1))
    if find "$SOURCE_MOUNT" -maxdepth 1 -name '.FieldBackup.conf.*' -print | grep -q .; then
        fail "$message"
    fi
}

assert_first_write_restore_order() {
    case_id=$1
    rw_line=$(grep -n -F "mount mode=rw target=[$SOURCE_MOUNT]" "$EFFECTS" | sed -n '1s/:.*//p')
    publish_line=$(grep -n -F "config-publish target=[$SOURCE_MOUNT/FieldBackup.conf]" "$EFFECTS" | sed -n '1s/:.*//p')
    restore_line=$(grep -n -F "mount mode=ro target=[$SOURCE_MOUNT]" "$EFFECTS" | sed -n '2s/:.*//p')
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ -z "$rw_line" ] || [ -z "$publish_line" ] || [ -z "$restore_line" ] || \
        [ "$rw_line" -ge "$publish_line" ] || [ "$publish_line" -ge "$restore_line" ]; then
        fail "$case_id effects order must be rw mount, config publish, then read-only restore attempt"
    fi
}

case_m13_steady_state_source_stays_read_only() {
    begin_case M13 'a card with an existing config is mounted read-only and never remounted read-write'
    reset_case || { fail 'M13 fixture setup failed'; return; }
    printf 'SD_UUID="%s"\nBACKUP_MODE="PRIMARY"\n' "$CARD_UUID" > "$SOURCE_MOUNT/FieldBackup.conf"
    config_hash_before=$(sha256sum "$SOURCE_MOUNT/FieldBackup.conf" | awk '{print $1}')
    assert_success 'M13 steady-state backup with a pre-existing card config succeeds' \
        run_manager add sda1 /devices/mock
    assert_equal "$(mount_effect_sequence)" ro 'M13 steady state performs exactly one read-only source mount'
    assert_not_contains 'mount mode=rw' "$EFFECTS" 'M13 steady state never opens a read-write source mount'
    assert_equal "$(sha256sum "$SOURCE_MOUNT/FieldBackup.conf" | awk '{print $1}')" "$config_hash_before" \
        'M13 steady state never rewrites the existing card configuration bytes'
}

case_m14_first_write_bounded_mount_sequence() {
    begin_case M14 'a blank card opens exactly one bounded read-write window bracketed by read-only mounts'
    reset_case || { fail 'M14 fixture setup failed'; return; }
    assert_absent "$SOURCE_MOUNT/FieldBackup.conf" 'M14 fixture starts with a genuinely blank card'
    assert_success 'M14 first-write provisioning succeeds' run_manager add sda1 /devices/mock
    assert_equal "$(mount_effect_sequence)" ro,umount,rw,umount,ro \
        'M14 mount sequence is exactly ro-mount, umount, rw-mount, umount, ro-mount'
    assert_success 'M14 card configuration exists after provisioning' test -f "$SOURCE_MOUNT/FieldBackup.conf"
    last_mount_mode=$(grep '^mount mode=' "$EFFECTS" | tail -n 1 | sed -E 's/^mount mode=([a-z]+).*/\1/')
    assert_equal "$last_mount_mode" ro 'M14 the final source mount is read-only before rsync runs'
}

case_m15_write_protected_card_rejects_without_config() {
    begin_case M15 'a write-protected card fails cleanly without creating a config or starting rsync'
    reset_case || { fail 'M15 fixture setup failed'; return; }
    TEST_MOUNT_RW_FAILS=1
    export TEST_MOUNT_RW_FAILS
    assert_failure 'M15 write-protected card fails the manager' run_manager add sda1 /devices/mock
    unset TEST_MOUNT_RW_FAILS
    # write_failed_status is gated on STATUS_STARTED, which perform_backup sets
    # only after a card config already validated; a card_config rejection here
    # happens strictly before that point, so (as M03c already establishes for
    # the REPLICA case) no status.json is ever written -- the manual-toggle red
    # LED trigger is this failure class's real, already-established signature.
    assert_absent "$RUNTIME/var/status.json" \
        'M15 card_config rejection precedes STATUS_STARTED, so no status.json terminal write occurs'
    assert_equal "$(cat "$TEST_ROOT/red/trigger")" none \
        'M15 write-protected card uses the card_config manual-toggle LED pattern (4 flashes), not the rsync timer pattern'
    assert_absent "$SOURCE_MOUNT/FieldBackup.conf" 'M15 write-protected card never gets a config file'
    assert_not_contains rsync "$EFFECTS" 'M15 write-protected card never reaches rsync'
    # The LED trigger above only proves the failure landed in the manual-toggle
    # class, which card_config shares with no_space and verify_failed. Pin the
    # actual reason so this case cannot go green on a different failure.
    assert_contains 'may be write-protected' "$NOTICES" \
        'M15 the failure is reported as the write-protected-card reason specifically'
    /bin/sleep 1
}

case_m16_readonly_restore_failure_blocks_transfer() {
    begin_case M16 'failure to restore the read-only mount after publishing config blocks the transfer'
    reset_case || { fail 'M16 fixture setup failed'; return; }
    # ro-mount #1 (initial source mount) must succeed; ro-mount #2 (the
    # restore-to-read-only step after the config write) must fail.
    TEST_MOUNT_RO_FAIL_ON=2
    export TEST_MOUNT_RO_FAIL_ON
    assert_failure 'M16 failed read-only restore fails the manager' run_manager add sda1 /devices/mock
    unset TEST_MOUNT_RO_FAIL_ON
    assert_not_contains rsync "$EFFECTS" \
        'M16 a source that could not be proven read-only again never reaches rsync'
    # This is a control-flow fixture, not a physical-media persistence check.
    # It proves the rw window and publish precede the second ro-mount attempt.
    assert_first_write_restore_order M16
    assert_contains 'Failed to restore read-only source mount' "$NOTICES" \
        'M16 the failure is reported as the read-only restore reason specifically'
    /bin/sleep 1
}

case_m17_initial_source_unmount_failure_blocks_rw_window() {
    begin_case M17 'first source unmount failure prevents the read-write window and transfer'
    reset_case || { fail 'M17 fixture setup failed'; return; }
    TEST_SOURCE_UMOUNT_FAIL_ON=1
    export TEST_SOURCE_UMOUNT_FAIL_ON
    assert_failure 'M17 initial source unmount failure fails manager' run_manager add sda1 /devices/mock
    unset TEST_SOURCE_UMOUNT_FAIL_ON
    assert_contains 'Failed to release read-only source mount to create card configuration' "$NOTICES" \
        'M17 reports the initial source-unmount reason specifically'
    assert_not_contains 'mount mode=rw' "$EFFECTS" 'M17 does not open a read-write source mount'
    assert_not_contains rsync "$EFFECTS" 'M17 does not start rsync'
    assert_equal "$(cat "$TEST_ROOT/source-umount-count")" 1 'M17 injects only the first source unmount'
    /bin/sleep 1
}

case_m18_post_write_source_unmount_failure_blocks_restore_and_transfer() {
    begin_case M18 'second source unmount failure prevents read-only restore and transfer'
    reset_case || { fail 'M18 fixture setup failed'; return; }
    TEST_SOURCE_UMOUNT_FAIL_ON=2
    export TEST_SOURCE_UMOUNT_FAIL_ON
    assert_failure 'M18 post-write source unmount failure fails manager' run_manager add sda1 /devices/mock
    unset TEST_SOURCE_UMOUNT_FAIL_ON
    assert_contains 'Failed to unmount source card after writing card configuration' "$NOTICES" \
        'M18 reports the post-write source-unmount reason specifically'
    assert_contains 'mount mode=rw' "$EFFECTS" 'M18 opened its bounded read-write source mount'
    assert_not_contains rsync "$EFFECTS" 'M18 does not start rsync'
    assert_equal "$(cat "$TEST_ROOT/source-umount-count")" 2 'M18 injects only the second source unmount'
    assert_equal "$(mount_effect_sequence)" ro,umount,rw,umount \
        'M18 does not attempt to restore read-only after the second unmount fails'
    /bin/sleep 1
}

case_m19_temporary_config_write_failure_cleans_up_and_allows_retry() {
    begin_case M19 'partial temporary config write fails without a published config and later retry succeeds'
    reset_case || { fail 'M19 fixture setup failed'; return; }
    TEST_CAT_INJECT=config-write-fail
    export TEST_CAT_INJECT
    assert_failure 'M19 partial temporary config write fails manager' run_manager add sda1 /devices/mock
    unset TEST_CAT_INJECT
    assert_contains 'Failed to write new card configuration' "$NOTICES" \
        'M19 reports the temporary-write failure specifically'
    assert_absent "$SOURCE_MOUNT/FieldBackup.conf" 'M19 never publishes a partial formal card configuration'
    assert_card_config_temp_absent 'M19 cleans up its failed temporary config file'
    assert_not_contains rsync "$EFFECTS" 'M19 does not start rsync after the write failure'
    assert_success 'M19 retry without the write injection provisions the blank card' \
        run_manager add sda1 /devices/mock
    assert_success 'M19 retry publishes the formal card configuration' \
        test -f "$SOURCE_MOUNT/FieldBackup.conf"
}

case_m20_temporary_config_creation_failure_blocks_transfer() {
    begin_case M20 'temporary config creation failure leaves no formal or temporary config'
    reset_case || { fail 'M20 fixture setup failed'; return; }
    TEST_CONFIG_MKTEMP_FAIL=1
    export TEST_CONFIG_MKTEMP_FAIL
    assert_failure 'M20 temporary config creation failure fails manager' run_manager add sda1 /devices/mock
    unset TEST_CONFIG_MKTEMP_FAIL
    assert_contains 'Failed to create temporary card configuration' "$NOTICES" \
        'M20 reports the temporary-file creation failure specifically'
    assert_absent "$SOURCE_MOUNT/FieldBackup.conf" 'M20 does not publish a formal card configuration'
    assert_card_config_temp_absent 'M20 leaves no owned temporary config file'
    assert_not_contains rsync "$EFFECTS" 'M20 does not start rsync'
    /bin/sleep 1
}

case_m21_config_publish_failure_cleans_up_and_blocks_transfer() {
    begin_case M21 'rename publication failure leaves no formal or temporary config'
    reset_case || { fail 'M21 fixture setup failed'; return; }
    TEST_CONFIG_MV_FAIL=1
    export TEST_CONFIG_MV_FAIL
    assert_failure 'M21 config publish failure fails manager' run_manager add sda1 /devices/mock
    unset TEST_CONFIG_MV_FAIL
    assert_contains 'Failed to publish new card configuration' "$NOTICES" \
        'M21 reports the config-publication failure specifically'
    assert_absent "$SOURCE_MOUNT/FieldBackup.conf" 'M21 does not publish a formal card configuration'
    assert_card_config_temp_absent 'M21 cleans up the unpublished temporary config file'
    assert_not_contains rsync "$EFFECTS" 'M21 does not start rsync'
    /bin/sleep 1
}

case_m22_nonregular_or_linked_config_rejects_without_transfer() {
    begin_case M22 'a dangling link or a directory at the formal config name rejects without transfer'
    reset_case || { fail 'M22 link fixture setup failed'; return; }
    ln -s "$SOURCE_MOUNT/missing-config" "$SOURCE_MOUNT/FieldBackup.conf"
    assert_failure 'M22 dangling config link fails manager' run_manager add sda1 /devices/mock
    assert_contains 'Card configuration is not a regular file' "$NOTICES" \
        'M22 reports the dangling-link rejection specifically'
    assert_not_contains rsync "$EFFECTS" 'M22 dangling config link does not start rsync'

    reset_case || { fail 'M22 directory fixture setup failed'; return; }
    mkdir "$SOURCE_MOUNT/FieldBackup.conf"
    assert_failure 'M22 config directory fails manager' run_manager add sda1 /devices/mock
    assert_contains 'Card configuration is not a regular file' "$NOTICES" \
        'M22 reports the non-regular-object rejection specifically'
    assert_not_contains rsync "$EFFECTS" 'M22 config directory does not start rsync'
    /bin/sleep 1
}

case_m23_published_config_sync_failure_blocks_transfer() {
    begin_case M23 'sync failure after config publication reports failure and blocks transfer'
    reset_case || { fail 'M23 fixture setup failed'; return; }
    TEST_CONFIG_SYNC_FAIL_ON=1
    export TEST_CONFIG_SYNC_FAIL_ON
    assert_failure 'M23 published config sync failure fails manager' run_manager add sda1 /devices/mock
    unset TEST_CONFIG_SYNC_FAIL_ON
    assert_contains 'Failed to synchronize published card configuration' "$NOTICES" \
        'M23 reports the configuration sync failure specifically'
    assert_success 'M23 publish happened before the sync failure' \
        test -f "$SOURCE_MOUNT/FieldBackup.conf"
    assert_not_contains rsync "$EFFECTS" 'M23 sync failure does not start rsync'
    /bin/sleep 1
}

case_m24_source_identity_conflict_stops_before_alias_or_transfer() {
    begin_case M24 'same source repeats normally and a conflicting source cannot update alias or transfer'
    reset_case || { fail 'M24 fixture setup failed'; return; }
    printf 'SD_UUID="%s"\nBACKUP_MODE="PRIMARY"\n' "$CARD_UUID" > "$SOURCE_MOUNT/FieldBackup.conf"
    assert_success 'M24 first source binding and backup succeeds' run_manager add sda1 /devices/mock
    identity_record="$TARGET_MOUNT/backups/.card-identities/$CARD_UUID.json"
    assert_success 'M24 first backup published source identity record' test -f "$identity_record"
    assert_success 'M24 same source backup succeeds again' run_manager add sda1 /devices/mock
    alias_before=$(sha256sum /opt/outdoor-backup/conf/aliases.json | awk '{print $1}')
    record_before=$(sha256sum "$identity_record" | awk '{print $1}')
    rsync_before=$(grep -c '^rsync' "$EFFECTS")
    TEST_SOURCE_FS_UUID=CONFLICT-99
    export TEST_SOURCE_FS_UUID
    assert_failure 'M24 conflicting source fails manager' run_manager add sda1 /devices/mock
    unset TEST_SOURCE_FS_UUID
    assert_equal "$(grep -c '^rsync' "$EFFECTS")" "$rsync_before" \
        'M24 conflict starts no additional rsync'
    assert_equal "$(sha256sum /opt/outdoor-backup/conf/aliases.json | awk '{print $1}')" "$alias_before" \
        'M24 conflict preserves alias bytes'
    assert_equal "$(sha256sum "$identity_record" | awk '{print $1}')" "$record_before" \
        'M24 conflict preserves identity record bytes'
}

case_m25_unknown_source_stops_before_rw_configuration_window() {
    begin_case M25 'unknown source UUID fails before a blank card receives a writable configuration window'
    reset_case || { fail 'M25 fixture setup failed'; return; }
    TEST_SOURCE_BLOCK_FAIL=1
    export TEST_SOURCE_BLOCK_FAIL
    assert_failure 'M25 failed source UUID read rejects manager' run_manager add sda1 /devices/mock
    unset TEST_SOURCE_BLOCK_FAIL
    assert_contains "mount mode=ro target=[$SOURCE_MOUNT]" "$EFFECTS" \
        'M25 source was initially mounted read-only'
    assert_not_contains 'mount mode=rw' "$EFFECTS" \
        'M25 source UUID failure never opens a writable mount'
    assert_absent "$SOURCE_MOUNT/FieldBackup.conf" \
        'M25 source UUID failure never writes blank-card configuration'
    assert_not_contains rsync "$EFFECTS" 'M25 source UUID failure never starts rsync'
}

case_m26_newline_identity_record_rejects_before_alias_or_transfer() {
    begin_case M26 'an identity record with a JSON newline cannot authorize a backup'
    reset_case || { fail 'M26 fixture setup failed'; return; }
    printf 'SD_UUID="%s"\nBACKUP_MODE="PRIMARY"\n' "$CARD_UUID" > "$SOURCE_MOUNT/FieldBackup.conf"
    identity_record="$TARGET_MOUNT/backups/.card-identities/$CARD_UUID.json"
    mkdir -p "${identity_record%/*}" "$TARGET_MOUNT/backups/$CARD_UUID"
    printf '%s\n' \
        '{"version":1,"sd_uuid":"550e8400-e29b-41d4-a716-446655440000","fs_uuid":"abcd-1234\n"}' \
        > "$identity_record"
    printf '%s\n' original-backup-data > "$TARGET_MOUNT/backups/$CARD_UUID/data"
    alias_before=$(file_hash_or_absent /opt/outdoor-backup/conf/aliases.json)
    record_before=$(sha256sum "$identity_record" | awk '{print $1}')
    data_before=$(sha256sum "$TARGET_MOUNT/backups/$CARD_UUID/data" | awk '{print $1}')
    rsync_before=$(grep -c '^rsync' "$EFFECTS")
    ASSERTIONS=$((ASSERTIONS + 1))
    if run_manager add sda1 /devices/mock > "$TEST_ROOT/m26.stdout" 2> "$TEST_ROOT/m26.stderr"; then
        fail 'M26 newline identity record unexpectedly succeeds'
    fi
    assert_contains 'card identity error: card identity conflict' "$TEST_ROOT/m26.stderr" \
        'M26 reports the identity-layer conflict reason'
    assert_equal "$(grep -c '^rsync' "$EFFECTS")" "$rsync_before" \
        'M26 malformed record starts no rsync'
    assert_equal "$(file_hash_or_absent /opt/outdoor-backup/conf/aliases.json)" "$alias_before" \
        'M26 malformed record preserves alias bytes or absence'
    assert_equal "$(sha256sum "$identity_record" | awk '{print $1}')" "$record_before" \
        'M26 malformed record preserves identity record bytes'
    assert_equal "$(sha256sum "$TARGET_MOUNT/backups/$CARD_UUID/data" | awk '{print $1}')" "$data_before" \
        'M26 malformed record preserves backup data bytes'
}

case_m27_identity_publish_failure_follows_initial_card_configuration() {
    begin_case M27 'identity publication failure follows successful first-card configuration without alias or transfer'
    reset_case || { fail 'M27 fixture setup failed'; return; }
    alias_before=$(file_hash_or_absent /opt/outdoor-backup/conf/aliases.json)
    TEST_IDENTITY_MV_FAIL=1
    export TEST_IDENTITY_MV_FAIL
    assert_failure 'M27 identity publication failure fails manager' run_manager add sda1 /devices/mock
    unset TEST_IDENTITY_MV_FAIL
    assert_contains 'cannot publish card identity record' "$NOTICES" \
        'M27 reports the identity publication reason specifically'
    assert_success 'M27 first-card configuration was published before identity failure' \
        test -f "$SOURCE_MOUNT/FieldBackup.conf"
    assert_success 'M27 published first-card configuration has a UUID assignment' \
        grep -E -q '^SD_UUID="[0-9a-f-]+"$' "$SOURCE_MOUNT/FieldBackup.conf"
    assert_success 'M27 published first-card configuration remains PRIMARY' \
        grep -F -q 'BACKUP_MODE="PRIMARY"' "$SOURCE_MOUNT/FieldBackup.conf"
    assert_equal "$(file_hash_or_absent /opt/outdoor-backup/conf/aliases.json)" "$alias_before" \
        'M27 identity failure preserves alias bytes or absence'
    assert_not_contains rsync "$EFFECTS" 'M27 identity publication failure never reaches rsync'
    # The new-card UUID is dynamic, so inspect the whole root for data entries.
    assert_equal "$(find "$TARGET_MOUNT/backups" -mindepth 1 -maxdepth 1 ! -name .card-identities -print)" '' \
        'M27 identity publication failure creates no backup-root data entries'
}

case_m05_detach_or_readonly_during_rsync_fails_without_naked_writes() {
    begin_case M05 'detach and read-only injections after rsync start cannot report success or leak'
    reset_case || { fail 'M05 detach fixture setup failed'; return; }
    TEST_RSYNC_INJECT=detach
    export TEST_RSYNC_INJECT
    assert_failure 'M05 detach after rsync must fail manager' run_manager add sda1 /devices/mock
    unset TEST_RSYNC_INJECT
    assert_absent "$TARGET_MOUNT/backups" 'M05 detach wrote through naked mount path'

    reset_case || { fail 'M05 read-only fixture setup failed'; return; }
    TEST_RSYNC_INJECT=ro
    export TEST_RSYNC_INJECT
    assert_failure 'M05 read-only after rsync must fail manager' run_manager add sda1 /devices/mock
    unset TEST_RSYNC_INJECT
    ASSERTIONS=$((ASSERTIONS + 1))
    if find "$TARGET_MOUNT/backups/.logs" -type f | grep -q .; then
        fail 'M05 read-only target received a post-rsync summary write'
    fi
}

case_m05b_summary_failure_and_post_summary_detach_fail() {
    begin_case M05b 'summary failure and post-summary detach both fail before completion logging'
    reset_case || { fail 'M05b summary failure fixture setup failed'; return; }
    TEST_CAT_INJECT=summary-fail
    export TEST_CAT_INJECT
    assert_failure 'M05b summary write failure fails manager despite perform_backup conditional' \
        run_manager add sda1 /devices/mock
    unset TEST_CAT_INJECT
    assert_not_contains 'Backup completed successfully' "$RUNTIME/log/backup.log" \
        'M05b summary failure does not log completed successfully'

    reset_case || { fail 'M05b detach fixture setup failed'; return; }
    TEST_CAT_INJECT=summary-detach
    export TEST_CAT_INJECT
    assert_failure 'M05b detach immediately after summary fails final target validation' \
        run_manager add sda1 /devices/mock
    unset TEST_CAT_INJECT
    assert_not_contains 'Backup completed successfully' "$RUNTIME/log/backup.log" \
        'M05b post-summary detach does not log completed successfully'
}

assert_status_jq() {
    filter=$1
    message=$2
    ASSERTIONS=$((ASSERTIONS + 1))
    jq -e "$filter" "$RUNTIME/var/status.json" >/dev/null 2>&1 || fail "$message"
}

set_config_value() {
    name=$1
    value=$2
    sed -i "s|^${name}=.*|${name}=${value}|" "$RUNTIME/conf/backup.conf"
}

case_m07_transfer_failures_preserve_exit_and_classify_evidence() {
    begin_case M07 'rsync exit and diagnostics drive failed history and evidence-based error LEDs'
    reset_case || { fail 'M07 fixture setup failed'; return; }
    TEST_RSYNC_EXIT=23
    export TEST_RSYNC_EXIT
    assert_manager_exit 23 'M07 exit 23 survives the manager unchanged' add sda1 /devices/mock
    unset TEST_RSYNC_EXIT
    assert_status_jq '.history[0].status == "error" and .history[0].error_message == "rsync"' \
        'M07 exit 23 without ENOSPC records generic rsync failure'
    assert_equal "$(cat "$TEST_ROOT/red/trigger")" timer 'M07 generic transfer failure uses generic red LED'
    assert_equal "$(cat "$TEST_ROOT/green/brightness")" 0 'M07 failed transfer leaves completion LED off'

    reset_case || { fail 'M07 exit12 fixture setup failed'; return; }
    TEST_RSYNC_EXIT=12
    export TEST_RSYNC_EXIT
    assert_manager_exit 12 'M07 exit 12 survives the manager unchanged' add sda1 /devices/mock
    unset TEST_RSYNC_EXIT
    assert_status_jq '.history[0].error_message == "rsync"' \
        'M07 exit 12 without ENOSPC is not mislabeled no_space'
    assert_equal "$(cat "$TEST_ROOT/red/trigger")" timer 'M07 exit 12 retains generic LED'

    reset_case || { fail 'M07 ENOSPC fixture setup failed'; return; }
    TEST_RSYNC_EXIT=23
    TEST_RSYNC_DIAGNOSTIC=ENOSPC
    export TEST_RSYNC_EXIT TEST_RSYNC_DIAGNOSTIC
    assert_manager_exit 23 'M07 ENOSPC retains rsync exit 23' add sda1 /devices/mock
    unset TEST_RSYNC_EXIT TEST_RSYNC_DIAGNOSTIC
    assert_status_jq '.history[0].error_message == "no_space"' \
        'M07 ENOSPC produces no_space history classification'
    assert_equal "$(cat "$TEST_ROOT/red/trigger")" none 'M07 ENOSPC uses no-space LED pattern'
    assert_equal "$(cat "$TEST_ROOT/green/brightness")" 0 'M07 ENOSPC leaves completion LED off'

    reset_case || { fail 'M07 mutation fixture setup failed'; return; }
    cp "$SCRIPTS/backup-manager.sh" "$SCRIPTS/backup-manager-mutated.sh"
    sed -i 's/return "\$transfer_exit"/return 1/' "$SCRIPTS/backup-manager-mutated.sh"
    MANAGER_SCRIPT="$SCRIPTS/backup-manager-mutated.sh"
    TEST_RSYNC_EXIT=23
    export TEST_RSYNC_EXIT
    assert_manager_exit_rejected 23 \
        'M07 controlled return-1 mutation would turn the exact exit-23 gate red' \
        add sda1 /devices/mock
    unset TEST_RSYNC_EXIT MANAGER_SCRIPT
}

case_m08_free_space_boundaries_are_strict_and_credible() {
    begin_case M08 'minimum free-space accepts equality and zero but rejects insufficient or untrustworthy df'
    reset_case || { fail 'M08 low-space fixture setup failed'; return; }
    set_config_value MIN_FREE_SPACE 3
    TEST_DF_MB=2
    export TEST_DF_MB
    assert_failure 'M08 free space below configured minimum fails' run_manager add sda1 /devices/mock
    unset TEST_DF_MB
    assert_not_contains rsync "$EFFECTS" 'M08 insufficient preflight does not start rsync'
    assert_equal "$(cat "$TEST_ROOT/red/trigger")" none 'M08 insufficient space uses no-space LED'

    reset_case || { fail 'M08 equality fixture setup failed'; return; }
    set_config_value MIN_FREE_SPACE 2
    TEST_DF_MB=2
    export TEST_DF_MB
    assert_success 'M08 free space equal to minimum succeeds' run_manager add sda1 /devices/mock
    unset TEST_DF_MB

    reset_case || { fail 'M08 zero minimum fixture setup failed'; return; }
    set_config_value MIN_FREE_SPACE 0
    TEST_DF_MB=0
    export TEST_DF_MB
    assert_success 'M08 zero disables only headroom, not df validation' run_manager add sda1 /devices/mock
    unset TEST_DF_MB

    reset_case || { fail 'M08 invalid minimum fixture setup failed'; return; }
    set_config_value MIN_FREE_SPACE invalid
    assert_failure 'M08 invalid minimum is rejected' run_manager add sda1 /devices/mock
    assert_not_contains rsync "$EFFECTS" 'M08 invalid minimum does not start rsync'

    reset_case || { fail 'M08 overflow minimum fixture setup failed'; return; }
    set_config_value MIN_FREE_SPACE 2147483648
    assert_failure 'M08 out-of-range minimum is rejected before shell comparison' run_manager add sda1 /devices/mock
    assert_not_contains rsync "$EFFECTS" 'M08 out-of-range minimum does not start rsync'

    reset_case || { fail 'M08 unknown df fixture setup failed'; return; }
    TEST_DF_MB=unknown
    export TEST_DF_MB
    assert_failure 'M08 nonnumeric df result is rejected' run_manager add sda1 /devices/mock
    unset TEST_DF_MB
    assert_not_contains rsync "$EFFECTS" 'M08 unknown df does not start rsync'
}

case_m09_terminal_state_never_precedes_final_target_writes() {
    begin_case M09 'summary and final-target failures cannot publish completed status'
    reset_case || { fail 'M09 summary fixture setup failed'; return; }
    TEST_CAT_INJECT=summary-fail
    export TEST_CAT_INJECT
    assert_failure 'M09 summary write failure fails manager' run_manager add sda1 /devices/mock
    unset TEST_CAT_INJECT
    assert_status_jq '.history[0].status == "error" and .history[0].error_message == "rsync"' \
        'M09 summary failure records failed status rather than completed'
    assert_not_contains 'Backup completed successfully' "$RUNTIME/log/backup.log" \
        'M09 summary failure never signals backup completion'

    reset_case || { fail 'M09 detach fixture setup failed'; return; }
    TEST_RSYNC_INJECT=detach
    export TEST_RSYNC_INJECT
    assert_failure 'M09 target detach after transfer fails manager' run_manager add sda1 /devices/mock
    unset TEST_RSYNC_INJECT
    assert_status_jq '.history | all(.status != "completed")' \
        'M09 detached target never publishes completed history'
    assert_not_contains 'Backup completed successfully' "$RUNTIME/log/backup.log" \
        'M09 detached target never signals backup completion'

    reset_case || { fail 'M09 readonly fixture setup failed'; return; }
    TEST_RSYNC_INJECT=ro
    export TEST_RSYNC_INJECT
    assert_failure 'M09 read-only target after transfer fails manager' run_manager add sda1 /devices/mock
    unset TEST_RSYNC_INJECT
    assert_status_jq '.history | all(.status != "completed")' \
        'M09 read-only target never publishes completed history'
    assert_not_contains 'Backup completed successfully' "$RUNTIME/log/backup.log" \
        'M09 read-only target never signals backup completion'
}

case_m10_status_terminal_write_failure_never_signals_success() {
    begin_case M10 'durable-finalization failures remain failures and never claim backup completion'

    reset_case || { fail 'M10 rename fixture setup failed'; return; }
    TEST_STATUS_MV_FAIL_ON=2
    export TEST_STATUS_MV_FAIL_ON
    assert_manager_nonzero 'M10 second atomic status rename fails manager' add sda1 /devices/mock
    unset TEST_STATUS_MV_FAIL_ON
    assert_contains rsync "$EFFECTS" 'M10 rename failure reaches terminal status publication'
    assert_status_jq '.history[0].status == "error" and .history[0].error_message == "rsync"' \
        'M10 rename cleanup records failed terminal state'
    assert_equal "$(cat "$TEST_ROOT/green/brightness")" 0 'M10 rename failure leaves completion LED off'
    assert_equal "$(cat "$TEST_ROOT/red/trigger")" timer 'M10 rename failure signals error LED'
    assert_not_contains 'Backup completed' "$RUNTIME/log/backup.log" \
        'M10 rename failure has no application completion claim'
    target_log=''
    for candidate_log in "$TARGET_MOUNT/backups/.logs/"*; do
        if [ -f "$candidate_log" ]; then
            target_log=$candidate_log
            break
        fi
    done
    assert_success 'M10 rename failure leaves transfer log for inspection' test -n "$target_log"
    assert_not_contains 'Completed:' "$target_log" 'M10 rename failure target log has no overall completion marker'

    reset_case || { fail 'M10 summary fixture setup failed'; return; }
    TEST_CAT_INJECT=summary-fail
    export TEST_CAT_INJECT
    assert_manager_nonzero 'M10 summary write failure fails manager' add sda1 /devices/mock
    unset TEST_CAT_INJECT
    assert_status_jq '.history[0].status == "error" and .history[0].error_message == "rsync"' \
        'M10 summary failure records failed terminal state'
    assert_equal "$(cat "$TEST_ROOT/green/brightness")" 0 'M10 summary failure leaves completion LED off'
    assert_equal "$(cat "$TEST_ROOT/red/trigger")" timer 'M10 summary failure signals error LED'
    assert_not_contains 'Backup completed' "$RUNTIME/log/backup.log" \
        'M10 summary failure has no application completion claim'
    target_log=''
    for candidate_log in "$TARGET_MOUNT/backups/.logs/"*; do
        if [ -f "$candidate_log" ]; then
            target_log=$candidate_log
            break
        fi
    done
    assert_success 'M10 summary failure leaves target log for inspection' test -n "$target_log"
    assert_not_contains 'Completed:' "$target_log" 'M10 summary failure target log has no overall completion marker'

    reset_case || { fail 'M10 final verification fixture setup failed'; return; }
    TEST_CAT_INJECT=summary-verify-fail
    export TEST_CAT_INJECT
    assert_manager_nonzero 'M10 final target verification failure fails manager' add sda1 /devices/mock
    unset TEST_CAT_INJECT
    assert_status_jq '.history[0].status == "error" and .history[0].error_message == "verify_failed"' \
        'M10 final target verification records failed terminal state'
    assert_equal "$(cat "$TEST_ROOT/green/brightness")" 0 'M10 final verification failure leaves completion LED off'
    assert_equal "$(cat "$TEST_ROOT/red/trigger")" none 'M10 final verification failure uses its configured error LED pattern'
    assert_not_contains 'Backup completed' "$RUNTIME/log/backup.log" \
        'M10 final verification failure has no application completion claim'
    target_log=''
    for candidate_log in "$TARGET_MOUNT/backups/.logs/"*; do
        if [ -f "$candidate_log" ]; then
            target_log=$candidate_log
            break
        fi
    done
    assert_success 'M10 final verification failure leaves transfer log for inspection' test -n "$target_log"
    assert_not_contains 'Completed:' "$target_log" 'M10 final verification target log has no overall completion marker'
}

case_m11_status_stats_are_real_and_paths_are_stable() {
    begin_case M11 'successful transfer uses helper statistics and never serializes an FD path'
    reset_case || { fail 'M11 fixture setup failed'; return; }
    TEST_RSYNC_STATS=1
    TEST_TIMER_CONTROLLED=1
    TEST_TIMER_DURATION=30
    export TEST_RSYNC_STATS TEST_TIMER_CONTROLLED TEST_TIMER_DURATION
    assert_success 'M11 transfer with helper stats succeeds' run_manager add sda1 /devices/mock
    unset TEST_RSYNC_STATS
    assert_status_jq '.history[0].status == "completed" and .history[0].files_count == 7 and
        .history[0].bytes_total == 1234 and (.history[0].backup_path | startswith("/proc/") | not) and
        (.storage.root | startswith("/proc/") | not)' \
        'M11 JSON reports helper stats and stable user-visible paths'
    assert_contains 'df -m /proc/' "$EFFECTS" 'M11 free-space check probes anchored FD path'
    assert_not_contains 'du ' "$EFFECTS" 'M11 manager never scans source with du'
    assert_success 'M11 completion timer reaches controlled wait' wait_for_path "$TEST_ROOT/timer-ready"
    assert_success 'M11 completion timer remains alive until release' kill -0 "$(cat "$TEST_ROOT/timer-pid")"
    assert_success 'M11 completed LED timer cannot retain target FD' /bin/umount "$TARGET_MOUNT"
    : > "$TEST_ROOT/timer-release"
    assert_success 'M11 completion timer exits after fixture release' wait_for_timer_exit
    unset TEST_TIMER_CONTROLLED TEST_TIMER_DURATION
}

run_replay_probe_with_timeout() {
    probe_stderr=$1
    probe_output=$2
    (
        exec env TEST_CAPTURED_STDERR=1 TEST_ASYNC_STDERR="$probe_stderr" \
            /bin/ash "$0" --inside --stderr-replay-probe
    ) 3> "$probe_output" &
    probe_pid=$!
    probe_seconds=0
    while kill -0 "$probe_pid" 2>/dev/null; do
        if [ "$probe_seconds" -eq 3 ]; then
            # This PID is the exec'd test-only ash process in this container.
            # Never use name-based process control for this safety boundary.
            kill "$probe_pid" 2>/dev/null || :
            wait "$probe_pid" 2>/dev/null || :
            return 124
        fi
        /bin/sleep 1
        probe_seconds=$((probe_seconds + 1))
    done
    wait "$probe_pid"
    probe_wait_exit=$?
    return "$probe_wait_exit"
}

case_stderr_replay_self_check() {
    begin_case M12 'test stderr replay preserves the failure sentinel without self-copying'
    probe_stderr="$TEST_ROOT/replay-probe.stderr"
    probe_output="$TEST_ROOT/replay-probe.output"

    # The dedicated helper bounds only its exec'd test child in the existing
    # pinned OpenWrt container; it cannot kill unrelated fixture processes.
    if run_replay_probe_with_timeout "$probe_stderr" "$probe_output"; then
        probe_exit=0
    else
        probe_exit=$?
    fi
    assert_equal "$probe_exit" 1 'M12 injected replay failure ends with its expected nonzero status'
    assert_contains 'ASYNC-REPLAY-SENTINEL-7f1c6d9e' "$probe_output" \
        'M12 replay forwards the unique stderr sentinel to the original sink'
    assert_equal "$(wc -l < "$probe_output")" 2 \
        'M12 replay output remains bounded instead of self-copying'
}

case_m06_remove_ignores_unmounted_target() {
    begin_case M06 'remove retains cleanup path without opening or requiring target mount'
    reset_case || { fail 'M06 fixture setup failed'; return; }
    unmount_target
    assert_success 'M06 remove succeeds without target mount' run_manager remove sda1 /devices/mock
    assert_contains pkill "$EFFECTS" 'M06 retained remove cleanup process control'
}

main() {
    trap 'settle_led_fixture; unmount_target; rm -rf "$SUITE_ROOT" /opt/outdoor-backup/conf "$ASYNC_STDERR"' EXIT INT TERM
    case_m01_unconfigured_uuid_stops_before_common_side_effects
    case_m01b_missing_led_keeps_guard_failure_and_error_syslog
    case_m01c_debug_guard_failure_does_not_create_application_log
    case_m02_target_device_mismatch_stops_before_source_mount
    case_m02d_uuid_mismatch_releases_anchor_before_led_timer
    case_m02a_read_only_target_stops_before_common_side_effects
    case_m02b_missing_mount_stops_before_common_side_effects
    case_m02c_same_source_or_system_disk_stops_before_common
    case_m03_healthy_path_uses_only_fd_anchored_target
    case_m03a_existing_replica_card_rejects_reverse_rsync_and_preserves_card_files
    case_m03b_invalid_existing_card_fails_without_rewriting_identity
    case_m03c_existing_replica_card_classifies_card_config_not_rsync
    case_m04_symlink_components_reject_before_target_update
    case_m13_steady_state_source_stays_read_only
    case_m14_first_write_bounded_mount_sequence
    case_m15_write_protected_card_rejects_without_config
    case_m16_readonly_restore_failure_blocks_transfer
    case_m17_initial_source_unmount_failure_blocks_rw_window
    case_m18_post_write_source_unmount_failure_blocks_restore_and_transfer
    case_m19_temporary_config_write_failure_cleans_up_and_allows_retry
    case_m20_temporary_config_creation_failure_blocks_transfer
    case_m21_config_publish_failure_cleans_up_and_blocks_transfer
    case_m22_nonregular_or_linked_config_rejects_without_transfer
    case_m23_published_config_sync_failure_blocks_transfer
    case_m24_source_identity_conflict_stops_before_alias_or_transfer
    case_m25_unknown_source_stops_before_rw_configuration_window
    case_m26_newline_identity_record_rejects_before_alias_or_transfer
    case_m27_identity_publish_failure_follows_initial_card_configuration
    case_m05_detach_or_readonly_during_rsync_fails_without_naked_writes
    case_m05b_summary_failure_and_post_summary_detach_fail
    case_m07_transfer_failures_preserve_exit_and_classify_evidence
    case_m08_free_space_boundaries_are_strict_and_credible
    case_m09_terminal_state_never_precedes_final_target_writes
    case_m10_status_terminal_write_failure_never_signals_success
    case_m11_status_stats_are_real_and_paths_are_stable
    case_stderr_replay_self_check
    case_m06_remove_ignores_unmounted_target
    assert_success 'M06 completion timer releases before test exit' settle_led_fixture
    assert_no_async_led_stderr
    assert_equal "$CASES" 37 'all required cases executed'
    if [ "$ASSERTIONS" -ne 295 ]; then
        fail "all required assertions executed (expected=295, actual=$ASSERTIONS)"
    fi
    if [ "$FAILED" -ne 0 ]; then
        replay_async_stderr
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED" >&3
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

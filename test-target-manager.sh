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
    exec docker run --rm --platform linux/amd64 --network none --read-only \
        --cap-add SYS_ADMIN --security-opt seccomp=unconfined --tmpfs /tmp:rw,exec --tmpfs /opt:rw,exec \
        -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-target-manager.sh --inside
fi

if [ ! -f /.dockerenv ] || [ ! -r /etc/openwrt_release ]; then
    printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
    exit 1
fi

REPO_ROOT=/src
TEST_ROOT="/tmp/outdoor-backup-target-manager.$$"
RUNTIME="$TEST_ROOT/runtime/opt/outdoor-backup"
SCRIPTS="$RUNTIME/scripts"
TARGET_MOUNT="$TEST_ROOT/target mount"
SOURCE_MOUNT="$TEST_ROOT/source mount"
SYSFS="$TEST_ROOT/sys"
MOUNTINFO="$TEST_ROOT/mountinfo"
BIN="$TEST_ROOT/bin"
EFFECTS="$TEST_ROOT/effects"
NOTICES="$TEST_ROOT/notices"
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

assert_not_contains() {
    needle=$1
    file=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if grep -F -q -- "$needle" "$file"; then
        fail "$message (unexpected=[$needle])"
    fi
}

# A target guard failure may emit syslog and the red LED only. The fixture sleep
# stub records the production 60-second auto-off request. Individual cases choose
# either a capped wait or a release-controlled wait to make timer lifetime explicit.
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
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/card-config.sh" "$SCRIPTS/card-config.sh"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/target.sh" "$SCRIPTS/target.sh"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/target-device.sh" "$SCRIPTS/target-device.sh"
    : > "$EFFECTS"
    : > "$NOTICES"
    cat > "$RUNTIME/conf/backup.conf" <<EOF
BACKUP_ROOT="$TARGET_MOUNT/backups"
TARGET_MOUNT="$TARGET_MOUNT"
TARGET_UUID="$TARGET_UUID"
MOUNT_POINT="$SOURCE_MOUNT"
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
printf '%s: UUID="A1B2-C3D4" TYPE="tmpfs"\n' "$TARGET_TEST_BLOCK_NODE"
EOF
    cat > "$BIN/mount" <<'EOF'
#!/bin/sh
printf 'mount argc=%s target=[%s]\n' "$#" "$4" >> "$TEST_EFFECTS"
mkdir -p "$4"
if [ -n "${TEST_CARD_CONFIG:-}" ]; then
    printf '%s\n' "$TEST_CARD_CONFIG" > "$4/FieldBackup.conf"
else
    cat > "$4/FieldBackup.conf" <<'CARD'
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
if [ "${TEST_RSYNC_INJECT:-}" = detach ]; then
    /bin/umount -l "$TEST_TARGET_MOUNT"
elif [ "${TEST_RSYNC_INJECT:-}" = ro ]; then
    /bin/mount -o remount,ro "$TEST_TARGET_MOUNT"
fi
exit 0
EOF
    cat > "$BIN/cat" <<'EOF'
#!/bin/sh
if [ "$#" -eq 0 ]; then
    case "${TEST_CAT_INJECT:-}" in
        summary-fail)
            exit 1
            ;;
        summary-detach)
            /bin/cat
            /bin/umount -l "$TEST_TARGET_MOUNT"
            exit 0
            ;;
    esac
fi
exec /bin/cat "$@"
EOF
    cat > "$BIN/pkill" <<'EOF'
#!/bin/sh
printf 'pkill\n' >> "$TEST_EFFECTS"
EOF
    cat > "$BIN/sync" <<'EOF'
#!/bin/sh
printf 'sync\n' >> "$TEST_EFFECTS"
EOF
    cat > "$BIN/sleep" <<'EOF'
#!/bin/sh
# The production helper still requests 60 seconds. M02d switches to a controlled
# wait so the test can prove the timer is alive while it tries a normal umount.
printf 'sleep duration=%s\n' "$1" >> "$TEST_EFFECTS"
if [ "${TEST_TIMER_CONTROLLED:-0}" = 1 ] && [ "$1" = 60 ]; then
    printf '%s\n' "$$" > "$TEST_TIMER_PID"
    : > "$TEST_TIMER_READY"
    while [ ! -e "$TEST_TIMER_RELEASE" ]; do
        /bin/sleep 1
    done
    exit 0
fi
/bin/sleep 1
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
        TEST_TARGET_MOUNT="$TARGET_MOUNT" TEST_CAT_INJECT="${TEST_CAT_INJECT:-}" \
        TEST_TIMER_CONTROLLED="${TEST_TIMER_CONTROLLED:-0}" \
        TEST_TIMER_READY="$TEST_ROOT/timer-ready" \
        TEST_TIMER_RELEASE="$TEST_ROOT/timer-release" \
        TEST_TIMER_PID="$TEST_ROOT/timer-pid" \
        DEBUG="${DEBUG:-0}" PATH="$BIN:$PATH" \
        /bin/ash "$SCRIPTS/backup-manager.sh" "$@"
}

reset_case() {
    unmount_target
    rm -rf "$TEST_ROOT"
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
    assert_success 'M03 healthy guarded backup succeeds' run_manager add sda1 /devices/mock
    target_root=$(cat "$TEST_ROOT/target-mm")
    assert_contains "mount argc=4 target=[$SOURCE_MOUNT]" "$EFFECTS" 'M03 space mount remained one argument'
    assert_contains "arg=[/proc/" "$EFFECTS" 'M03 rsync used a proc FD target path'
    assert_contains "/fd/9/backups/$CARD_UUID/]" "$EFFECTS" 'M03 rsync target used anchored UUID leaf'
    assert_absent /escaped-by-card-config 'M03 card configuration did not create an escaped root'
    assert_not_contains /escaped-by-card-config "$EFFECTS" 'M03 ignored card BACKUP_ROOT and TARGET overrides'
    assert_equal "$(find "$TARGET_MOUNT/backups" -type d | wc -l)" 3 'M03 created root UUID and logs only on tmpfs'
    assert_equal "$(find "$TEST_ROOT" -path "$TARGET_MOUNT" -prune -o -name "$CARD_UUID" -print | wc -l)" 0 \
        'M03 UUID directory did not leak outside target tmpfs'
    rm -f "$TEST_ROOT/target-mm" # keeps the real value read above explicit for fixture audit.
    : "$target_root"
}

case_m03b_invalid_existing_card_fails_without_rewriting_identity() {
    begin_case M03b 'invalid existing card config fails without rsync or replacement identity'
    reset_case || { fail 'M03b fixture setup failed'; return; }
    TEST_CARD_CONFIG='BACKUP_MODE=PRIMARY'
    export TEST_CARD_CONFIG
    assert_failure 'M03b missing card UUID fails manager' run_manager add sda1 /devices/mock
    unset TEST_CARD_CONFIG
    assert_not_contains rsync "$EFFECTS" 'M03b invalid card never reaches rsync'
    assert_equal "$(cat "$SOURCE_MOUNT/FieldBackup.conf")" 'BACKUP_MODE=PRIMARY' \
        'M03b preserves the invalid existing card file'
}

case_m04_symlink_components_reject_before_target_update() {
    begin_case M04 'root UUID and logs symlink components reject without writes'
    reset_case || { fail 'M04 root fixture setup failed'; return; }
    mkdir -p "$TARGET_MOUNT/outside"
    ln -s "$TARGET_MOUNT/outside" "$TARGET_MOUNT/backups"
    assert_failure 'M04 root symlink rejects' run_manager add sda1 /devices/mock
    assert_not_contains 'mount argc=' "$EFFECTS" 'M04 root symlink did not source mount'
    # Let the fixture's capped LED auto-off finish before the next reset.
    /bin/sleep 1

    reset_case || { fail 'M04 UUID fixture setup failed'; return; }
    mkdir -p "$TARGET_MOUNT/backups/outside"
    ln -s "$TARGET_MOUNT/backups/outside" "$TARGET_MOUNT/backups/$CARD_UUID"
    assert_failure 'M04 UUID symlink rejects' run_manager add sda1 /devices/mock
    assert_contains "mount argc=4 target=[$SOURCE_MOUNT]" "$EFFECTS" \
        'M04 UUID rejection did not reach the controlled source mount'
    ASSERTIONS=$((ASSERTIONS + 1))
    if grep -F -q rsync "$EFFECTS"; then
        fail 'M04 UUID symlink reached rsync'
    fi

    reset_case || { fail 'M04 logs fixture setup failed'; return; }
    mkdir -p "$TARGET_MOUNT/backups/outside"
    ln -s "$TARGET_MOUNT/backups/outside" "$TARGET_MOUNT/backups/.logs"
    assert_failure 'M04 logs symlink rejects' run_manager add sda1 /devices/mock
    assert_contains "mount argc=4 target=[$SOURCE_MOUNT]" "$EFFECTS" \
        'M04 logs rejection did not reach the controlled source mount'
    ASSERTIONS=$((ASSERTIONS + 1))
    if grep -F -q rsync "$EFFECTS"; then
        fail 'M04 logs symlink reached rsync'
    fi
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

case_m06_remove_ignores_unmounted_target() {
    begin_case M06 'remove retains cleanup path without opening or requiring target mount'
    reset_case || { fail 'M06 fixture setup failed'; return; }
    unmount_target
    assert_success 'M06 remove succeeds without target mount' run_manager remove sda1 /devices/mock
    assert_contains pkill "$EFFECTS" 'M06 retained remove cleanup process control'
}

main() {
    trap 'unmount_target; rm -rf "$TEST_ROOT" /opt/outdoor-backup/conf' EXIT INT TERM
    case_m01_unconfigured_uuid_stops_before_common_side_effects
    case_m01b_missing_led_keeps_guard_failure_and_error_syslog
    case_m01c_debug_guard_failure_does_not_create_application_log
    case_m02_target_device_mismatch_stops_before_source_mount
    case_m02d_uuid_mismatch_releases_anchor_before_led_timer
    case_m02a_read_only_target_stops_before_common_side_effects
    case_m02b_missing_mount_stops_before_common_side_effects
    case_m02c_same_source_or_system_disk_stops_before_common
    case_m03_healthy_path_uses_only_fd_anchored_target
    case_m03b_invalid_existing_card_fails_without_rewriting_identity
    case_m04_symlink_components_reject_before_target_update
    case_m05_detach_or_readonly_during_rsync_fails_without_naked_writes
    case_m05b_summary_failure_and_post_summary_detach_fail
    case_m06_remove_ignores_unmounted_target
    assert_equal "$CASES" 14 'all required cases executed'
    if [ "$ASSERTIONS" -ne 131 ]; then
        fail "all required assertions executed (expected=131, actual=$ASSERTIONS)"
    fi
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

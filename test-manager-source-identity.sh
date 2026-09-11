#!/bin/sh
#
# BDD integration tests for backup-manager source snapshot and cancellation
# boundaries. The manager and helpers are delivered runtime files; sysfs, UUID,
# lock timing and signals are controlled fixtures in the pinned OpenWrt image.
#
set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
    REPO_ROOT=$(dirname "$0")
    LOG_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/outdoor-backup-manager-source-identity.XXXXXX") || exit 1
    docker run --rm --platform linux/amd64 --network bridge \
        --cap-add SYS_ADMIN --security-opt seccomp=unconfined --tmpfs /tmp:rw,exec --tmpfs /opt:rw,exec \
        -v "$REPO_ROOT:/src:ro" "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-manager-source-identity.sh --inside \
        > "$LOG_ROOT/green.stdout" 2> "$LOG_ROOT/green.stderr"
    RUN_STATUS=$?
    printf '%s\n' "$RUN_STATUS" > "$LOG_ROOT/green.rc"
    grep '^RESULT ' "$LOG_ROOT/green.stdout" > "$LOG_ROOT/green.counts" 2>/dev/null || \
        printf 'RESULT cases=0 assertions=0 failed=unavailable\n' > "$LOG_ROOT/green.counts"
    printf 'manager-source-identity logs: %s\n' "$LOG_ROOT"
    exit "$RUN_STATUS"
fi

[ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || {
    printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
    exit 1
}

TEST_CAPTURED_STDERR=1
TEST_ASYNC_STDERR=/tmp/outdoor-backup-manager-source-identity.stderr
TEST_TARGET_MANAGER_LIBRARY_ONLY=1
. /src/test-target-manager.sh

MS_CASES=0
MS_ASSERTIONS=0
MS_FAILED=0

ms_fail() { printf 'FAIL: %s\n' "$1" >&2; MS_FAILED=$((MS_FAILED + 1)); }
ms_case() { MS_CASES=$((MS_CASES + 1)); printf 'CASE %s: %s\n' "$1" "$2"; }
ms_equal() {
    actual=$1 expected=$2 message=$3
    MS_ASSERTIONS=$((MS_ASSERTIONS + 1))
    [ "$actual" = "$expected" ] || ms_fail "$message (expected=[$expected], actual=[$actual])"
}
ms_success() { message=$1; shift; MS_ASSERTIONS=$((MS_ASSERTIONS + 1)); "$@" || ms_fail "$message"; }
ms_failure() { message=$1; shift; MS_ASSERTIONS=$((MS_ASSERTIONS + 1)); "$@" && ms_fail "$message"; }
ms_absent() {
    path=$1 message=$2; MS_ASSERTIONS=$((MS_ASSERTIONS + 1))
    [ ! -e "$path" ] && [ ! -L "$path" ] || ms_fail "$message (path=[$path])"
}
ms_wait_path() {
    path=$1 attempts=0
    while [ ! -e "$path" ] && [ "$attempts" -lt 10 ]; do /bin/sleep 1; attempts=$((attempts + 1)); done
    [ -e "$path" ]
}
ms_wait_exit() {
    pid=$1 attempts=0
    while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 15 ]; do /bin/sleep 1; attempts=$((attempts + 1)); done
    ! kill -0 "$pid" 2>/dev/null
}
ms_manager_exit() {
    if run_manager "$@"; then MS_MANAGER_RC=0; else MS_MANAGER_RC=$?; fi
}
ms_manager_nonzero() { ms_manager_exit "$@"; [ "$MS_MANAGER_RC" -ne 0 ]; }

prepare_existing_card() {
    printf 'SD_UUID="%s"\nBACKUP_MODE="PRIMARY"\n' "$CARD_UUID" > "$SOURCE_MOUNT/FieldBackup.conf"
}

start_lock_holder() {
    HOLDER_RELEASE="$TEST_ROOT/holder-release"
    HOLDER_READY="$TEST_ROOT/holder-ready"
    cat > "$BIN/backup-manager.sh" <<'EOF'
#!/bin/ash
ln -s "/proc/$$" "$TEST_HOLDER_LOCK" || exit 1
: > "$TEST_HOLDER_READY"
while [ ! -e "$TEST_HOLDER_RELEASE" ]; do /bin/sleep 1; done
EOF
    chmod 700 "$BIN/backup-manager.sh"
    TEST_HOLDER_LOCK="$RUNTIME/var/lock/backup.lock" TEST_HOLDER_READY="$HOLDER_READY" \
        TEST_HOLDER_RELEASE="$HOLDER_RELEASE" "$BIN/backup-manager.sh" &
    HOLDER_PID=$!
    ms_success 'A published its live matching lock before B starts' ms_wait_path "$HOLDER_READY"
    ms_equal "$(readlink "$RUNTIME/var/lock/backup.lock")" "/proc/$HOLDER_PID" \
        'A holder owns the published lock before B starts'
}

release_lock_holder() {
    : > "$HOLDER_RELEASE"
    ms_success 'A holder exits after B test releases it' ms_wait_exit "$HOLDER_PID"
    wait "$HOLDER_PID" 2>/dev/null || :
}

ms_hash_or_absent() {
    [ -f "$1" ] && [ ! -L "$1" ] && sha256sum "$1" | awk '{print $1}' || printf '%s\n' absent
}

ms_count() {
    [ -r "$2" ] || { printf '%s\n' 0; return; }
    grep -F -c "$1" "$2" || :
}

save_b_baseline() {
    B_CONFIG_HASH=$(ms_hash_or_absent "$SOURCE_MOUNT/FieldBackup.conf")
    B_IDENTITIES_HASH=$(find "$TARGET_MOUNT/backups/.card-identities" -type f -exec sha256sum {} \; 2>/dev/null | sort || :)
    B_ALIAS_HASH=$(ms_hash_or_absent /opt/outdoor-backup/conf/aliases.json)
    B_RSYNC_COUNT=$(ms_count '^rsync' "$EFFECTS")
    B_COMPLETION_COUNT=$(ms_count 'Backup completed successfully' "$RUNTIME/log/backup.log")
    B_GREEN_HASH=$(ms_hash_or_absent "$TEST_ROOT/green/trigger")
}

assert_rejected_before_source_effects() {
    label=$1
    ms_absent "$SOURCE_MOUNT_STATE" "$label does not mount B source"
    ms_equal "$(ms_hash_or_absent "$SOURCE_MOUNT/FieldBackup.conf")" "$B_CONFIG_HASH" "$label does not write B config"
    ms_equal "$(find "$TARGET_MOUNT/backups/.card-identities" -type f -exec sha256sum {} \; 2>/dev/null | sort || :)" "$B_IDENTITIES_HASH" "$label does not write B identity"
    ms_equal "$(ms_hash_or_absent /opt/outdoor-backup/conf/aliases.json)" "$B_ALIAS_HASH" "$label does not write B alias"
    ms_equal "$(ms_count '^rsync' "$EFFECTS")" "$B_RSYNC_COUNT" "$label does not start B rsync"
    ms_equal "$(ms_count 'Backup completed successfully' "$RUNTIME/log/backup.log")" "$B_COMPLETION_COUNT" "$label does not report B completion"
}

make_waiting_manager() {
    waiting_source=${1:-$SCRIPTS/backup-manager.sh}
    B_WAIT_MANAGER="$SCRIPTS/backup-manager-waiter.sh"
    awk '
        /if ! acquire_lock; then/ {
            acquire_anchors++
            after_acquire_anchor=1
            print "\tprintf \"%s\\n\" \"$LOCK_IDENTITY\" > \"$TEST_B_LOCK_IDENTITY_MARKER\""
        }
        after_acquire_anchor && !inserted && /check_cancel_request \|\| exit "\$\?"/ {
            print "\t: > \"$TEST_WAIT_AFTER_LOCK_MARKER\""
            print "\twhile [ ! -e \"$TEST_WAIT_AFTER_LOCK_RELEASE\" ]; do /bin/sleep 1; done"
            inserted=1
        }
        { print }
        END { exit(acquire_anchors == 1 && inserted == 1 ? 0 : 1) }
    ' "$waiting_source" > "$B_WAIT_MANAGER" || return 1
    chmod 700 "$B_WAIT_MANAGER"
}

start_waiting_b() {
    B_PID=''
    B_MANAGER_PID=''
    B_CAPTURE_MARKER="$TEST_ROOT/b-capture"
    B_LOCK_ATTEMPT="$TEST_ROOT/b-lock-attempt"
    B_LOCK_IDENTITY_FILE="$TEST_ROOT/b-lock-identity"
    B_AFTER_LOCK="$TEST_ROOT/b-after-lock"
    B_AFTER_LOCK_RELEASE="$TEST_ROOT/b-after-lock-release"
    B_LOGGER_TRACE="$TEST_ROOT/b-logger-trace"
    B_STDERR="$TEST_ROOT/b-manager.stderr"
    printf 'DEBUG=1\n' >> "$RUNTIME/conf/backup.conf"
    save_b_baseline
    printf '%s\n' ABCD-1234 > "$TEST_ROOT/source-uuid"
    make_waiting_manager "${WAITING_SOURCE_MANAGER:-$SCRIPTS/backup-manager.sh}" || {
        ms_fail 'B waiter manager fixture could not be generated'
        return 1
    }
    TEST_SOURCE_READ_MARKER="$B_CAPTURE_MARKER" TEST_SOURCE_UUID_FILE="$TEST_ROOT/source-uuid" \
        TEST_LOCK_ATTEMPT_MARKER="$B_LOCK_ATTEMPT" \
        TEST_B_LOCK_IDENTITY_MARKER="$B_LOCK_IDENTITY_FILE" \
        TEST_WAIT_AFTER_LOCK_MARKER="$B_AFTER_LOCK" TEST_WAIT_AFTER_LOCK_RELEASE="$B_AFTER_LOCK_RELEASE" \
        TEST_LOGGER_TRACE="$B_LOGGER_TRACE" \
        LOCK_IDENTITY=backup-manager.sh TEST_SLEEP_PASSTHROUGH=1 LOCK_TIMEOUT=10 LOCK_INTERVAL=1 TEST_RUN_MANAGER_EXEC=1 \
        MANAGER_SCRIPT="$B_WAIT_MANAGER" run_manager add sda1 /devices/mock/sda/sda1 20 > "$TEST_ROOT/b-manager.stdout" 2> "$B_STDERR" &
    B_PID=$!
    ms_success 'B captured a source baseline before lock release' ms_wait_path "$B_CAPTURE_MARKER"
    ms_success 'B reports its literal lock-holder identity before acquisition' ms_wait_path "$B_LOCK_IDENTITY_FILE"
    ms_success 'B attempted the real lock publish while A still owned it' ms_wait_path "$B_LOCK_ATTEMPT"
    B_MANAGER_PID=$(sed -n 's/^manager=\([0-9][0-9]*\).*/\1/p' "$B_LOCK_ATTEMPT")
    ms_success 'B lock-attempt marker identifies its actual manager process' test -n "$B_MANAGER_PID"
    ms_equal "$(readlink "$RUNTIME/var/lock/backup.lock")" "/proc/$HOLDER_PID" \
        'B failed acquisition left A lock published, proving a wait iteration'
    ms_success 'B can read the live A lock command line' test -r "$RUNTIME/var/lock/backup.lock/cmdline"
    ms_success 'B remains alive while A owns the lock' kill -0 "$B_PID"
    ms_absent "$B_AFTER_LOCK" 'B has not acquired the lock before A releases it'
}

wait_b_failure_after_acquire() {
    ms_success 'B reaches its post-acquire boundary after A releases it' ms_wait_path "$B_AFTER_LOCK"
    B_OWNER_LINK=$(readlink "$RUNTIME/var/lock/backup.lock")
    ms_success 'B post-acquire boundary exposes a live process lock owner' \
        grep -E -q '^/proc/[0-9]+$' <<EOF
$B_OWNER_LINK
EOF
    ms_failure 'B post-acquire lock is not A holder lock' test "$B_OWNER_LINK" = "/proc/$HOLDER_PID"
    : > "$B_AFTER_LOCK_RELEASE"
    ms_success 'B exits after its post-acquire source rejection' ms_wait_exit "$B_PID"
    B_RC=0
    wait "$B_PID" 2>/dev/null || B_RC=$?
    ms_equal "$B_RC" 1 'B source replacement has the ordinary device rejection exit'
    ms_success 'B stderr contains the source-identity mismatch classification' \
        grep -F -q 'outdoor-backup: source identity error:' "$B_STDERR"
    ms_failure 'B rejection never starts the backup LED after its source mismatch' \
        grep -F -q 'LED set to fast blink' "$B_LOGGER_TRACE"
    ms_absent "$RUNTIME/var/lock/backup.lock" 'B cleanup removes only B lock after it owned it'
    unset LOCK_IDENTITY
}

# Create a runtime-only manager variant which marks one existing probe boundary.
# It locates the production call by its unique source line and does not copy logic.
make_probe_manager() {
    phase=$1
    PROBE_MANAGER="$SCRIPTS/backup-manager-$phase.sh"
    cp "$SCRIPTS/backup-manager.sh" "$PROBE_MANAGER" || return 1
    case "$phase" in
        prelock)
            awk '
                /if ! SOURCE_IDENTITY_SNAPSHOT=\$\(source_identity_read "\$DEVNAME"\); then/ {
                    print "\t: > \"$TEST_SOURCE_PROBE_STAGE_FILE\""
                }
                { print }
            ' "$PROBE_MANAGER" > "$PROBE_MANAGER.tmp" || return 1
            ;;
        afterlock)
            awk '
                /if ! source_identity_matches "\$DEVNAME" "\$SOURCE_IDENTITY_SNAPSHOT"; then/ { matches++ }
                matches == 2 && !marked {
                    print "\t: > \"$TEST_SOURCE_PROBE_STAGE_FILE\""
                    marked=1
                }
                { print }
                END { exit(marked ? 0 : 1) }
            ' "$PROBE_MANAGER" > "$PROBE_MANAGER.tmp" || return 1
            ;;
        premount)
            awk '
                /if ! mount_sdcard rw; then/ && !marked {
                    print "\t: > \"$TEST_SOURCE_PROBE_STAGE_FILE\""
                    marked=1
                }
                { print }
                END { exit(marked ? 0 : 1) }
            ' "$PROBE_MANAGER" > "$PROBE_MANAGER.tmp" || return 1
            ;;
        *) return 1 ;;
    esac
    mv "$PROBE_MANAGER.tmp" "$PROBE_MANAGER" || return 1
    chmod 700 "$PROBE_MANAGER"
}

run_cancelled_probe() {
    phase=$1
    SIGNAL_FILE="$TEST_ROOT/$phase-manager-pid"
    STAGE_FILE="$TEST_ROOT/$phase-stage"
    SIGNAL_TRACE="$TEST_ROOT/$phase-signal-trace"
    CANCEL_LED_START="$TEST_ROOT/$phase-led-start"
    CANCEL_LOCK_ACQUIRED="$TEST_ROOT/$phase-lock-acquired"
    make_probe_manager "$phase" || return 1
    TEST_SOURCE_PROBE_STAGE_FILE="$STAGE_FILE" TEST_SOURCE_PROBE_SIGNAL_PID_FILE="$SIGNAL_FILE" \
        TEST_SOURCE_PROBE_SIGNAL_TRACE="$SIGNAL_TRACE" TEST_RUN_MANAGER_EXEC=1 DEBUG=1 \
        TEST_LOCK_ACQUIRED_MARKER="$CANCEL_LOCK_ACQUIRED" \
        TEST_LOGGER_STAGE_MATCH='LED set to fast blink' TEST_LOGGER_STAGE_FILE="$CANCEL_LED_START" \
        MANAGER_SCRIPT="$PROBE_MANAGER" run_manager add sda1 /devices/mock/sda/sda1 30 &
    CANCEL_PID=$!
    printf '%s\n' "$CANCEL_PID" > "$SIGNAL_FILE"
    ms_success "$phase probe sent TERM to this manager only" ms_wait_path "$SIGNAL_TRACE"
    ms_success "$phase manager exits after sticky TERM" ms_wait_exit "$CANCEL_PID"
    CANCEL_RC=0
    wait "$CANCEL_PID" 2>/dev/null || CANCEL_RC=$?
    ms_equal "$CANCEL_RC" 143 "$phase preserves TERM exit code 143"
    ms_success "$phase fixture signal succeeded" grep -F -q 'signal-rc=0' "$SIGNAL_TRACE"
}

make_afterlock_gate_mutant() {
    MUTANT_MANAGER="$SCRIPTS/backup-manager-afterlock-mutant.sh"
    awk '
        /if ! source_identity_matches "\$DEVNAME" "\$SOURCE_IDENTITY_SNAPSHOT"; then/ {
            gates++
            if (gates == 2) deleting=1
        }
        deleting { if ($0 == "\tfi") { deleting=0 }; next }
        { print }
        END { exit(gates == 2 ? 0 : 1) }
    ' "$SCRIPTS/backup-manager.sh" > "$MUTANT_MANAGER" || return 1
    chmod 700 "$MUTANT_MANAGER"
}

make_premount_gate_mutant() {
    MUTANT_MANAGER="$SCRIPTS/backup-manager-premount-mutant.sh"
    awk '
        /if ! source_identity_matches "\$DEVNAME" "\$SOURCE_IDENTITY_SNAPSHOT"; then/ {
            gates++
            if (gates == 1) deleting=1
        }
        deleting { if ($0 == "\tfi") { deleting=0 }; next }
        { print }
        END { exit(gates == 2 ? 0 : 1) }
    ' "$SCRIPTS/backup-manager.sh" > "$MUTANT_MANAGER" || return 1
    chmod 700 "$MUTANT_MANAGER"
}

case_s01_normal_three_four_and_diskseq_absence() {
    ms_case S01 'normal legacy and identity-bearing adds preserve snapshot semantics including old kernels'
    reset_case || { ms_fail 'S01 fixture setup failed'; return; }
    prepare_existing_card
    ms_success 'S01 legacy three-argument add succeeds with diskseq' run_manager add sda1 /devices/mock
    ms_success 'S01 four-argument add succeeds with same identity' run_manager add sda1 /devices/mock/sda/sda1 1
    reset_case || { ms_fail 'S01 old-kernel fixture setup failed'; return; }
    prepare_existing_card
    rm -f "$SYSFS/devices/mock/block/sda/diskseq"
    ms_success 'S01 absence on both observations is accepted as documented weak semantics' run_manager add sda1 /devices/mock
}

case_s02_waiter_uuid_change_has_own_acquisition_and_device_rejection() {
    ms_case S02 'B waits on A, acquires itself, then rejects UUID replacement before LED or source effects'
    reset_case || { ms_fail 'S02 fixture setup failed'; return; }
    prepare_existing_card
    ms_success 'S02 A completes a record before its later lock hold' run_manager add sda1 /devices/mock
    a_status_hash=$(sha256sum "$RUNTIME/var/status.json" | awk '{print $1}')
    start_lock_holder
    start_waiting_b || {
        ms_fail 'S02 B waiter setup failed'
        release_lock_holder
        return
    }
    printf '%s\n' REPLACED-UUID > "$TEST_ROOT/source-uuid"
    release_lock_holder
    wait_b_failure_after_acquire
    ms_equal "$(sha256sum "$RUNTIME/var/status.json" | awk '{print $1}')" "$a_status_hash" 'S02 B does not alter A completed status'
    assert_rejected_before_source_effects S02
}

case_s03_waiter_topology_changes_have_own_acquisition_and_rejection() {
    ms_case S03 'B waits and rejects canonical node, major-minor, and diskseq source replacements'
    for change in node major_minor diskseq; do
        reset_case || { ms_fail "S03 $change fixture setup failed"; continue; }
        prepare_existing_card
        start_lock_holder
        start_waiting_b || {
            ms_fail "S03 $change B waiter setup failed"
            release_lock_holder
            return
        }
        case "$change" in
            node)
                rm -f "$SYSFS/class/block/sda1" "$SYSFS/dev/block/8:1"
                add_node sdb 8:16
                add_partition sdb sda1 8:1
                ;;
            major_minor)
                rm -f "$SYSFS/class/block/sda1" "$SYSFS/dev/block/8:1"
                add_partition sda sda1 8:33
                ;;
            diskseq) printf '%s\n' 2 > "$SYSFS/devices/mock/block/sda/diskseq" ;;
        esac
        release_lock_holder
        wait_b_failure_after_acquire
        assert_rejected_before_source_effects "S03-$change"
    done
}

case_s04_waiter_disappearance_and_downgrade_have_own_acquisition_and_rejection() {
    ms_case S04 'B waits and rejects source disappearance or diskseq downgrade after it acquires'
    for change in disappeared diskseq_missing; do
        reset_case || { ms_fail "S04 $change fixture setup failed"; continue; }
        prepare_existing_card
        start_lock_holder
        start_waiting_b || {
            ms_fail "S04 $change B waiter setup failed"
            release_lock_holder
            return
        }
        case "$change" in
            disappeared) rm -rf "$SYSFS/devices/mock/block/sda" ;;
            diskseq_missing) rm -f "$SYSFS/devices/mock/block/sda/diskseq" ;;
        esac
        release_lock_holder
        wait_b_failure_after_acquire
        assert_rejected_before_source_effects "S04-$change"
    done
}

case_s05_capture_failure_disabled_and_remove_do_not_touch_source() {
    ms_case S05 'pre-lock failure has no lock or source action while disabled and remove do not read source'
    reset_case || { ms_fail 'S05 failure fixture setup failed'; return; }
    TEST_SOURCE_BLOCK_FAIL=1
    export TEST_SOURCE_BLOCK_FAIL
    ms_success 'S05 failed pre-lock capture returns nonzero' ms_manager_nonzero add sda1 /devices/mock
    unset TEST_SOURCE_BLOCK_FAIL
    ms_absent "$RUNTIME/var/lock/backup.lock" 'S05 failed capture does not acquire lock'
    ms_absent "$SOURCE_MOUNT_STATE" 'S05 failed capture does not mount source'

    reset_case || { ms_fail 'S05 disabled fixture setup failed'; return; }
    printf 'ENABLED=0\n' >> "$RUNTIME/conf/backup.conf"
    rm -f "$SCRIPTS/source-identity.sh"
    ms_success 'S05 disabled add does not load source identity library' run_manager add sda1 /devices/mock

    reset_case || { ms_fail 'S05 remove fixture setup failed'; return; }
    rm -f "$SCRIPTS/source-identity.sh"
    ms_success 'S05 four-argument remove does not load source identity library' run_manager remove sda1 /devices/mock/sda/sda1 20
    ms_success 'S05 legacy remove does not load source identity library' run_manager remove sda1 /devices/mock
}

case_s06_afterlock_gate_rejects_before_led_and_afterlock_mutant_is_red() {
    ms_case S06 'after-lock gate rejects before LED; deleting only that gate starts LED before mount gate rejects'
    reset_case || { ms_fail 'S06 production fixture setup failed'; return; }
    prepare_existing_card
    start_lock_holder
    start_waiting_b || {
        ms_fail 'S06 production B waiter setup failed'
        release_lock_holder
        return
    }
    printf '%s\n' REPLACED-UUID > "$TEST_ROOT/source-uuid"
    release_lock_holder
    wait_b_failure_after_acquire

    reset_case || { ms_fail 'S06 mutant fixture setup failed'; return; }
    prepare_existing_card
    make_afterlock_gate_mutant || { ms_fail 'S06 could not create after-lock-only mutant'; return; }
    WAITING_SOURCE_MANAGER="$MUTANT_MANAGER"
    export WAITING_SOURCE_MANAGER
    start_lock_holder
    start_waiting_b || {
        ms_fail 'S06 mutant B waiter setup failed'
        release_lock_holder
        unset WAITING_SOURCE_MANAGER
        return
    }
    printf '%s\n' REPLACED-UUID > "$TEST_ROOT/source-uuid"
    release_lock_holder
    : > "$B_AFTER_LOCK_RELEASE"
    ms_success 'S06 after-lock mutant exits after later mount gate rejection' ms_wait_exit "$B_PID"
    wait "$B_PID" 2>/dev/null || :
    ms_success 'S06 deleting only after-lock gate starts LED before the later mount gate' \
        grep -F -q 'LED set to fast blink' "$B_LOGGER_TRACE"
    unset WAITING_SOURCE_MANAGER
    ms_absent "$SOURCE_MOUNT_STATE" 'S06 remaining per-mount gate still rejects before a source mount'
}

case_s07_prerw_gate_rejects_and_single_gate_mutant_opens_rw() {
    ms_case S07 'source replacement after first unmount is rejected before RW; deleting per-mount gate opens RW'
    reset_case || { ms_fail 'S07 production fixture setup failed'; return; }
    printf '%s\n' ABCD-1234 > "$TEST_ROOT/source-uuid"
    TEST_SOURCE_CHANGE_AFTER_UMOUNT=1 TEST_SOURCE_UUID_FILE="$TEST_ROOT/source-uuid"
    export TEST_SOURCE_CHANGE_AFTER_UMOUNT TEST_SOURCE_UUID_FILE
    ms_success 'S07 production pre-RW replacement fails' ms_manager_nonzero add sda1 /devices/mock
    unset TEST_SOURCE_CHANGE_AFTER_UMOUNT TEST_SOURCE_UUID_FILE
    ms_success 'S07 initial read-only mount occurred' grep -F -q 'mount mode=ro' "$EFFECTS"
    ms_failure 'S07 pre-RW gate prevents the writable mount' grep -F -q 'mount mode=rw' "$EFFECTS"
    ms_absent "$SOURCE_MOUNT/FieldBackup.conf" 'S07 pre-RW rejection has no config write'
    ms_equal "$(cat "$TEST_ROOT/red/trigger")" none 'S07 pre-RW rejection retains device_unknown LED classification'
    ms_failure 'S07 pre-RW rejection has no transfer' grep -F -q '^rsync' "$EFFECTS"

    reset_case || { ms_fail 'S07 mutant fixture setup failed'; return; }
    make_premount_gate_mutant || { ms_fail 'S07 could not create per-mount-only mutant'; return; }
    printf '%s\n' ABCD-1234 > "$TEST_ROOT/source-uuid"
    TEST_SOURCE_CHANGE_AFTER_UMOUNT=1 TEST_SOURCE_UUID_FILE="$TEST_ROOT/source-uuid" MANAGER_SCRIPT="$MUTANT_MANAGER"
    export TEST_SOURCE_CHANGE_AFTER_UMOUNT TEST_SOURCE_UUID_FILE MANAGER_SCRIPT
    ms_success 'S07 per-mount mutant permits completion after replacement' run_manager add sda1 /devices/mock
    unset TEST_SOURCE_CHANGE_AFTER_UMOUNT TEST_SOURCE_UUID_FILE MANAGER_SCRIPT
    ms_success 'S07 deleting only pre-mount gate opens a dangerous RW mount' grep -F -q 'mount mode=rw' "$EFFECTS"
    ms_success 'S07 mutant publishes configuration to the replacement fixture' test -f "$SOURCE_MOUNT/FieldBackup.conf"
}

case_s08_prero_gate_rejects_after_rw_and_single_gate_mutant_restores_ro() {
    ms_case S08 'source replacement after second unmount rejects before RO restore; deleting gate attempts RO restore'
    reset_case || { ms_fail 'S08 production fixture setup failed'; return; }
    printf '%s\n' ABCD-1234 > "$TEST_ROOT/source-uuid"
    TEST_SOURCE_CHANGE_AFTER_SECOND_UMOUNT=1 TEST_SOURCE_UUID_FILE="$TEST_ROOT/source-uuid"
    export TEST_SOURCE_CHANGE_AFTER_SECOND_UMOUNT TEST_SOURCE_UUID_FILE
    ms_success 'S08 production pre-RO replacement fails' ms_manager_nonzero add sda1 /devices/mock
    unset TEST_SOURCE_CHANGE_AFTER_SECOND_UMOUNT TEST_SOURCE_UUID_FILE
    ms_equal "$(mount_effect_sequence)" ro,umount,rw,umount 'S08 gate blocks RO restore before mount syscall'
    ms_success 'S08 RW configuration had already been published before the later replacement' test -f "$SOURCE_MOUNT/FieldBackup.conf"
    ms_equal "$(cat "$TEST_ROOT/red/trigger")" none 'S08 pre-RO rejection retains device_unknown LED classification'
    ms_failure 'S08 pre-RO rejection has no transfer' grep -F -q '^rsync' "$EFFECTS"
    ms_failure 'S08 pre-RO rejection has no completion log' grep -F -q 'Backup completed successfully' "$RUNTIME/log/backup.log"

    reset_case || { ms_fail 'S08 mutant fixture setup failed'; return; }
    make_premount_gate_mutant || { ms_fail 'S08 could not create per-mount-only mutant'; return; }
    printf '%s\n' ABCD-1234 > "$TEST_ROOT/source-uuid"
    TEST_SOURCE_CHANGE_AFTER_SECOND_UMOUNT=1 TEST_SOURCE_UUID_FILE="$TEST_ROOT/source-uuid" MANAGER_SCRIPT="$MUTANT_MANAGER"
    export TEST_SOURCE_CHANGE_AFTER_SECOND_UMOUNT TEST_SOURCE_UUID_FILE MANAGER_SCRIPT
    ms_success 'S08 per-mount mutant permits completion after second replacement' run_manager add sda1 /devices/mock
    unset TEST_SOURCE_CHANGE_AFTER_SECOND_UMOUNT TEST_SOURCE_UUID_FILE MANAGER_SCRIPT
    ms_equal "$(mount_effect_sequence)" ro,umount,rw,umount,ro,umount 'S08 deleting only per-mount gate attempts unsafe RO restoration'
}

case_s09_prelock_probe_term_stops_before_lock() {
    ms_case S09 'TERM delivered inside pre-lock capture returns 143 before lock acquisition'
    reset_case || { ms_fail 'S09 fixture setup failed'; return; }
    prepare_existing_card
    run_cancelled_probe prelock
    ms_absent "$RUNTIME/var/lock/backup.lock" 'S09 pre-lock cancellation leaves no published lock'
    ms_failure 'S09 pre-lock cancellation never acquires a lock' grep -F -q 'Lock acquired' "$RUNTIME/log/backup.log"
    ms_absent "$TEST_ROOT/green/trigger" 'S09 pre-lock cancellation never starts backup LED'
    ms_absent "$SOURCE_MOUNT_STATE" 'S09 pre-lock cancellation never mounts source'
}

case_s10_afterlock_probe_term_stops_before_led() {
    ms_case S10 'TERM delivered inside after-lock identity probe returns 143 before start LED'
    reset_case || { ms_fail 'S10 fixture setup failed'; return; }
    prepare_existing_card
    run_cancelled_probe afterlock
    ms_success 'S10 after-lock probe acquired its own lock before cancellation' ms_wait_path "$CANCEL_LOCK_ACQUIRED"
    ms_absent "$RUNTIME/var/lock/backup.lock" 'S10 after-lock cancellation releases its lock'
    ms_absent "$CANCEL_LED_START" 'S10 after-lock cancellation does not start the LED after probe success'
    ms_absent "$SOURCE_MOUNT_STATE" 'S10 after-lock cancellation never mounts source'
}

case_s11_premount_probe_term_stops_before_rw() {
    ms_case S11 'TERM delivered inside RW pre-mount probe returns 143 without a writable source mount'
    reset_case || { ms_fail 'S11 fixture setup failed'; return; }
    printf '%s\n' ABCD-1234 > "$TEST_ROOT/source-uuid"
    TEST_SOURCE_UUID_FILE="$TEST_ROOT/source-uuid"
    export TEST_SOURCE_UUID_FILE
    run_cancelled_probe premount
    unset TEST_SOURCE_UUID_FILE
    ms_success 'S11 initial read-only mount completed before the RW-sensitive probe' grep -F -q 'mount mode=ro' "$EFFECTS"
    ms_failure 'S11 cancellation after pre-mount probe prevents RW mount' grep -F -q 'mount mode=rw' "$EFFECTS"
    ms_absent "$SOURCE_MOUNT/FieldBackup.conf" 'S11 cancellation before RW leaves blank card unconfigured'
    ms_failure 'S11 cancellation before RW never transfers' grep -F -q '^rsync' "$EFFECTS"
}

make_postmount_uuid_consumer_mutant() {
    MUTANT_MANAGER="$SCRIPTS/backup-manager-postmount-uuid-mutant.sh"
    cp "$SCRIPTS/backup-manager.sh" "$MUTANT_MANAGER" || return 1
    sed -i '/if \[ "\$SOURCE_FS_UUID" != "\$source_identity_snapshot_uuid" \]; then/,/^\tfi$/d' "$MUTANT_MANAGER" || return 1
    grep -F -q 'source filesystem UUID differs from source snapshot' "$MUTANT_MANAGER" && return 1
    chmod 700 "$MUTANT_MANAGER"
}

case_s12_postmount_uuid_mismatch_and_read_failure_are_source_rejections() {
    ms_case S12 'post-mount UUID consumption must match its snapshot and unreadable UUID is device_unknown'
    reset_case || { ms_fail 'S12 mismatch fixture setup failed'; return; }
    prepare_existing_card
    printf '%s\n' ABCD-1234 > "$TEST_ROOT/source-uuid"
    TEST_SOURCE_UUID_FILE="$TEST_ROOT/source-uuid" TEST_SOURCE_UUID_CHANGE_AFTER_RO=1 \
        TEST_SOURCE_UUID_AFTER_RO=REPLACED-UUID
    export TEST_SOURCE_UUID_FILE TEST_SOURCE_UUID_CHANGE_AFTER_RO TEST_SOURCE_UUID_AFTER_RO
    ms_manager_nonzero add sda1 /devices/mock
    unset TEST_SOURCE_UUID_FILE TEST_SOURCE_UUID_CHANGE_AFTER_RO TEST_SOURCE_UUID_AFTER_RO
    ms_success 'S12 mismatch emits the static source-identity diagnostic' \
        grep -F -q 'source filesystem UUID differs from source snapshot' "$NOTICES"
    ms_equal "$(cat "$TEST_ROOT/red/trigger")" none \
        'S12 mismatch uses the device_unknown LED classification'
    ms_absent "$TARGET_MOUNT/backups/.card-identities" 'S12 mismatch creates no identity record'
    ms_absent /opt/outdoor-backup/conf/aliases.json 'S12 mismatch creates no alias'
    ms_failure 'S12 mismatch starts no rsync' grep -F -q '^rsync' "$EFFECTS"
    ms_failure 'S12 mismatch reports no completion' grep -F -q 'Backup completed successfully' "$RUNTIME/log/backup.log"

    reset_case || { ms_fail 'S12 mutant fixture setup failed'; return; }
    prepare_existing_card
    make_postmount_uuid_consumer_mutant || { ms_fail 'S12 consumer-only mutant generation failed'; return; }
    printf '%s\n' ABCD-1234 > "$TEST_ROOT/source-uuid"
    MANAGER_SCRIPT="$MUTANT_MANAGER" TEST_SOURCE_UUID_FILE="$TEST_ROOT/source-uuid" \
        TEST_SOURCE_UUID_CHANGE_AFTER_RO=1 TEST_SOURCE_UUID_AFTER_RO=REPLACED-UUID
    export MANAGER_SCRIPT TEST_SOURCE_UUID_FILE TEST_SOURCE_UUID_CHANGE_AFTER_RO TEST_SOURCE_UUID_AFTER_RO
    ms_success 'S12 consumer-only mutant reaches the formerly unsafe binding path' \
        run_manager add sda1 /devices/mock
    unset MANAGER_SCRIPT TEST_SOURCE_UUID_FILE TEST_SOURCE_UUID_CHANGE_AFTER_RO TEST_SOURCE_UUID_AFTER_RO
    ms_success 'S12 mutant records the replacement UUID in the binding path' \
        /bin/sh -c 'jq -e ".fs_uuid == \"replaced-uuid\"" "$1" >/dev/null' sh \
        "$TARGET_MOUNT/backups/.card-identities/$CARD_UUID.json"

    reset_case || { ms_fail 'S12 read-failure fixture setup failed'; return; }
    prepare_existing_card
    TEST_SOURCE_POSTMOUNT_BLOCK_FAIL=1
    export TEST_SOURCE_POSTMOUNT_BLOCK_FAIL
    ms_manager_nonzero add sda1 /devices/mock
    unset TEST_SOURCE_POSTMOUNT_BLOCK_FAIL
    ms_success 'S12 post-mount read failure emits the static source-identity diagnostic' \
        grep -F -q 'source filesystem UUID cannot be read after read-only mount' "$NOTICES"
    ms_equal "$(cat "$TEST_ROOT/red/trigger")" none \
        'S12 post-mount read failure uses the device_unknown LED classification'
}

assert_assertion_gate_is_live() {
    [ "${2:-}" = '--skip-assertion-mutant' ] && return 0
    mutant="$TEST_ROOT/assertion-count-mutant.sh"
    cp "$0" "$mutant" || { ms_fail 'assertion gate fixture could not copy suite'; return; }
    assertion_description='S11 cancellation before RW leaves blank card unconfigured'
    assertion_line="    ms_absent \"\$SOURCE_MOUNT/FieldBackup.conf\" '$assertion_description'"
    assertion_count=$(grep -F -c "$assertion_line" "$0" || :)
    [ "$assertion_count" -eq 1 ] || {
        ms_fail 'assertion gate fixture requires exactly one S11 blank-card assertion'
        return
    }
    sed -i "\|^[[:space:]]*ms_absent .*${assertion_description}|d" "$mutant" || {
        ms_fail 'assertion gate fixture could not delete assertion'
        return
    }
    ms_failure 'deleting one source-observation assertion makes the exact MS_ASSERTIONS gate fail' \
        /bin/ash "$mutant" --inside --skip-assertion-mutant > "$TEST_ROOT/assertion-mutant.stdout" 2> "$TEST_ROOT/assertion-mutant.stderr"
    ms_success 'assertion-count mutant failed specifically at the MS_ASSERTIONS gate' \
        /bin/ash -c "grep -F -q \"\$1\" \"\$2\" && grep -F -q \"\$3\" \"\$4\"" \
        assertion-count-mutant \
        'expected 245 base assertions, ran 244' "$TEST_ROOT/assertion-mutant.stderr" \
        'RESULT cases=12 assertions=244 failed=1' "$TEST_ROOT/assertion-mutant.stdout"
}

main() {
    trap 'settle_led_fixture; unmount_target; rm -rf "$SUITE_ROOT" /opt/outdoor-backup/conf "$TEST_ASYNC_STDERR"' EXIT INT TERM
    case_s01_normal_three_four_and_diskseq_absence
    case_s02_waiter_uuid_change_has_own_acquisition_and_device_rejection
    case_s03_waiter_topology_changes_have_own_acquisition_and_rejection
    case_s04_waiter_disappearance_and_downgrade_have_own_acquisition_and_rejection
    case_s05_capture_failure_disabled_and_remove_do_not_touch_source
    case_s06_afterlock_gate_rejects_before_led_and_afterlock_mutant_is_red
    case_s07_prerw_gate_rejects_and_single_gate_mutant_opens_rw
    case_s08_prero_gate_rejects_after_rw_and_single_gate_mutant_restores_ro
    case_s09_prelock_probe_term_stops_before_lock
    case_s10_afterlock_probe_term_stops_before_led
    case_s11_premount_probe_term_stops_before_rw
    case_s12_postmount_uuid_mismatch_and_read_failure_are_source_rejections
    [ "$MS_CASES" -eq 12 ] || ms_fail "expected 12 cases, ran $MS_CASES"
    [ "$MS_ASSERTIONS" -eq 245 ] || ms_fail "expected 245 base assertions, ran $MS_ASSERTIONS"
    assert_assertion_gate_is_live "$@"
    printf 'RESULT cases=%s assertions=%s failed=%s\n' "$MS_CASES" "$MS_ASSERTIONS" "$MS_FAILED"
    [ "$MS_FAILED" -eq 0 ]
}

main "$@"

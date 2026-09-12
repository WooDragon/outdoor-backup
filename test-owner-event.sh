#!/bin/sh
#
# BDD tests for owner-event.sh. The host re-executes this suite in a pinned,
# native OpenWrt rootfs; all owner processes are temporary exact PIDs.
#

set -u

case "$(uname -m)" in
    arm64|aarch64)
        PLATFORM=linux/aarch64_generic
        IMAGE='openwrt/rootfs@sha256:f6dd33c1d9b7d6f1e0848f2fbb92b8d03fc9b425dc08c3574a44936b93133704'
        ;;
    x86_64|amd64)
        PLATFORM=linux/amd64
        IMAGE='openwrt/rootfs:x86_64-24.10.8@sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9'
        ;;
    *)
        printf 'FAIL: unsupported host architecture for real OpenWrt proc tests: %s\n' "$(uname -m)" >&2
        exit 1
        ;;
esac

if [ "${IN_OWNER_EVENT_TEST:-}" != 1 ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform "$PLATFORM" \
        -e IN_OWNER_EVENT_TEST=1 -v "$REPO_ROOT:/src:ro" \
        "$IMAGE" /bin/ash /src/test-owner-event.sh
fi

REPO_ROOT=/src
OWNER_EVENT_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/owner-event.sh"
TARGET_DEVICE_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/target-device.sh"
TEST_ROOT="/tmp/outdoor-owner-event-test.$$"
MANAGER="$TEST_ROOT/manager.sh"
OTHER_MANAGER="$TEST_ROOT/other-manager.sh"
LOCK="$TEST_ROOT/backup.lock"
NOTICES="$TEST_ROOT/notices.log"
ACTIVE_PIDS=''
CASES=0
ASSERTIONS=0
FAILED=0
ORIGINAL_PATH=$PATH

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

assert_file_exists() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ -f "$1" ] || fail "$2"
}

assert_file_absent() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "$2"
}

assert_owner_alive() {
    ASSERTIONS=$((ASSERTIONS + 1))
    kill -0 "$1" 2>/dev/null || fail "$2"
}

logger() {
    printf '%s\n' "$*" >> "$NOTICES"
    return 0
}

cleanup_processes() {
    for pid in $ACTIVE_PIDS; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || :
        fi
        wait "$pid" 2>/dev/null || :
    done
    ACTIVE_PIDS=''
}

cleanup() {
    cleanup_processes
    rm -rf "$TEST_ROOT"
}

load_libraries() {
    # shellcheck disable=SC1090
    . "$TARGET_DEVICE_SCRIPT"
    # shellcheck disable=SC1090
    . "$OWNER_EVENT_SCRIPT"
}

write_owner_script() {
    cat > "$1" <<'EOF'
#!/bin/sh
trap 'printf TERM > "$TERM_FILE"; exit 143' TERM
while :; do
    sleep 1
done
EOF
    chmod 755 "$1"
}

reset_case() {
    cleanup_processes
    rm -rf "$TEST_ROOT"
    mkdir -p "$TEST_ROOT"
    : > "$NOTICES"
    write_owner_script "$MANAGER"
    write_owner_script "$OTHER_MANAGER"
    PATH=$ORIGINAL_PATH
    export PATH
    logger() {
        printf '%s\n' "$*" >> "$NOTICES"
        return 0
    }
    load_libraries
}

start_owner() {
    term_file=$1
    devname=$2
    devpath=$3
    seq=$4
    TERM_FILE="$term_file" "$MANAGER" add "$devname" "$devpath" "$seq" &
    OWNER_PID=$!
    ACTIVE_PIDS="$ACTIVE_PIDS $OWNER_PID"
    sleep 1
    ln -s "/proc/$OWNER_PID" "$LOCK"
}

start_legacy_owner() {
    term_file=$1
    devname=$2
    legacy_data_slot=$3
    TERM_FILE="$term_file" "$MANAGER" add "$devname" "$legacy_data_slot" &
    OWNER_PID=$!
    ACTIVE_PIDS="$ACTIVE_PIDS $OWNER_PID"
    sleep 1
    ln -s "/proc/$OWNER_PID" "$LOCK"
}

write_reusable_owner_script() {
    cat > "$1" <<'EOF'
#!/bin/sh
trap 'printf TERM >> "$TERM_FILE"; [ "$(wc -c < "$TERM_FILE")" -lt 8 ] || exit 143' TERM
while :; do
    sleep 1
done
EOF
    chmod 755 "$1"
}

start_reusable_owner() {
    term_file=$1
    devname=$2
    devpath=$3
    seq=$4
    write_reusable_owner_script "$MANAGER"
    TERM_FILE="$term_file" "$MANAGER" add "$devname" "$devpath" "$seq" &
    OWNER_PID=$!
    ACTIVE_PIDS="$ACTIVE_PIDS $OWNER_PID"
    sleep 1
    ln -s "/proc/$OWNER_PID" "$LOCK"
}

assert_status() {
    actual=$1
    expected=$2
    message=$3
    assert_equal "$actual" "$expected" "$message"
}

call_stop() {
    owner_event_stop "$@"
    STOP_STATUS=$?
}

# Record each sender invocation synchronously, then preserve the real TERM path.
# Argument: test-private append-only PID log path.
install_counting_sender() {
    OWNER_EVENT_SEND_LOG=$1
    owner_event_send_term() {
        printf '%s\n' "$1" >> "$OWNER_EVENT_SEND_LOG" || return 1
        kill -TERM "$1"
    }
}

# Build a test-private mutant which incorrectly sends TERM for same identity.
# Argument: output library path. The production source is never modified.
write_same_previous_sender_mutant() {
    awk '
        {
            print
            if ($0 ~ /current owner already received stop request/) {
                print "        owner_event_send_term \"$owner_event_pid\" || return 1"
                matches++
            }
        }
        END { exit(matches == 1 ? 0 : 1) }
    ' "$OWNER_EVENT_SCRIPT" > "$1"
}

start_raw_owner() {
    term_file=$1
    shift
    TERM_FILE="$term_file" "$@" &
    OWNER_PID=$!
    ACTIVE_PIDS="$ACTIVE_PIDS $OWNER_PID"
    sleep 1
    ln -s "/proc/$OWNER_PID" "$LOCK"
}

wait_for_term() {
    term_file=$1
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        [ -f "$term_file" ] && return 0
        sleep 1
    done
    return 1
}

# Assert a real owner neither observed TERM nor exited during one scheduler tick.
# Arguments: PID, term marker path, assertion description.
assert_owner_unterminated() {
    sleep 1
    assert_owner_alive "$1" "$3"
    assert_file_absent "$2" "$3"
}

# Wrap the private reader only in tests. It reads real proc stat, then controls
# just state/starttime so the cancellation sequence can exercise its recheck.
install_stat_sequence_wrapper() {
    owner_event_read_stat_file() {
        stat_spec=$(sed -n '1p' "$TEST_ROOT/stat-sequence") || return 1
        [ -n "$stat_spec" ] || return 1
        sed -n '2,$p' "$TEST_ROOT/stat-sequence" > "$TEST_ROOT/stat-sequence.next" || return 1
        mv "$TEST_ROOT/stat-sequence.next" "$TEST_ROOT/stat-sequence" || return 1
        forced_state=${stat_spec%% *}
        forced_start=${stat_spec#* }
        actual_stat=$(sed -n '1p' "/proc/$1/stat") || return 1
        [ -n "$actual_stat" ] || return 1
        printf '%s\n' "$actual_stat" | awk -v state="$forced_state" -v start="$forced_start" '
            match($0, /.*\) /) {
                prefix = substr($0, 1, RSTART + RLENGTH - 1)
                count = split(substr($0, RSTART + RLENGTH), fields, " ")
                if (count < 20) exit 1
                fields[1] = state
                if (start != "keep") fields[20] = start
                output = prefix
                for (field_index = 1; field_index <= count; field_index++)
                    output = output (field_index == 1 ? "" : " ") fields[field_index]
                print output
                exit 0
            }
            { exit 1 }
        '
    }
}

case_source_only_has_no_side_effect() {
    begin_case A01 'sourcing the library creates no files, logs, or traps'
    reset_case
    before=$(find "$TEST_ROOT" -type f -exec sha256sum {} \; | sort)
    trap_before=$(trap)
    # shellcheck disable=SC1090
    . "$OWNER_EVENT_SCRIPT"
    after=$(find "$TEST_ROOT" -type f -exec sha256sum {} \; | sort)
    trap_after=$(trap)
    assert_equal "$after" "$before" 'A01 source changed fixture files'
    assert_equal "$trap_after" "$trap_before" 'A01 source installed a trap'
    assert_equal "$(wc -c < "$NOTICES")" 0 'A01 source wrote a notice'
}

case_validator_accepts_only_canonical_event_values() {
    begin_case A02 'validator accepts canonical event values and rejects malformed fields'
    reset_case
    valid_path=/devices/pci0000:00/block/sda/sda1
    assert_success 'A02 accepts canonical partition event' \
        owner_event_validate_event sda1 "$valid_path" 9007199254740993
    assert_success 'A02 accepts u64 maximum' \
        owner_event_validate_event sda1 "$valid_path" 18446744073709551615
    assert_failure 'A02 rejects zero SEQNUM' \
        owner_event_validate_event sda1 "$valid_path" 0
    for bad_devname in '' . .. '../sda1' 'sda 1'; do
        assert_failure 'A02 rejects malformed DEVNAME' \
            owner_event_validate_event "$bad_devname" "$valid_path" 2
    done
    for bad_path in /device/sda1 /devices/ /devices/a//sda1 /devices/a/./sda1 \
        /devices/a/../sda1 /devices/a/sda1/ /devices/a/sda2; do
        assert_failure 'A02 rejects malformed DEVPATH' \
            owner_event_validate_event sda1 "$bad_path" 2
    done
    bad_path_with_lf='/devices/a/sda
1'
    assert_failure 'A02 rejects DEVPATH containing LF' \
        owner_event_validate_event sda1 "$bad_path_with_lf" 2
    bad_seq_with_lf='2
3'
    for bad_seq in '' 00 01 -1 18446744073709551616 "$bad_seq_with_lf"; do
        assert_failure 'A02 rejects malformed SEQNUM' \
            owner_event_validate_event sda1 "$valid_path" "$bad_seq"
    done
}

case_real_owner_exact_argv_receives_one_term() {
    begin_case A03 'real strict shebang owner receives TERM for newer matching partition event'
    reset_case
    term_file="$TEST_ROOT/exact.term"
    path=/devices/pci0000:00/block/sda/sda1
    start_owner "$term_file" sda1 "$path" 9007199254740992
    assert_success 'A03 validates real proc argv exactly' \
        owner_event_cmdline_matches "/proc/$OWNER_PID/cmdline" "$MANAGER" \
        sda1 "$path" 9007199254740993
    assert_success 'A03 sends TERM to the matched owner' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 9007199254740993
    assert_success 'A03 real owner observed TERM' wait_for_term "$term_file"
    if [ -f "$term_file" ]; then
        wait "$OWNER_PID" 2>/dev/null || owner_status=$?
        assert_equal "${owner_status:-0}" 143 'A03 owner exited through TERM trap'
    fi
}

case_direct_parent_only_matches() {
    begin_case A04 'exact and direct-parent paths match while sibling and grandparent reject'
    reset_case
    owner_path=/devices/pci0000:00/block/sda/sda1
    term_file="$TEST_ROOT/exact-parent.term"
    start_owner "$term_file" sda1 "$owner_path" 10
    assert_success 'A04 exact path matches' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$owner_path" 11
    assert_success 'A04 exact owner received TERM' wait_for_term "$term_file"

    reset_case
    term_file="$TEST_ROOT/direct-parent.term"
    start_owner "$term_file" sda1 "$owner_path" 10
    assert_success 'A04 direct parent disk matches partition owner' \
        owner_event_cancel "$LOCK" "$MANAGER" sda /devices/pci0000:00/block/sda 11
    assert_success 'A04 parent removal signalled owner' wait_for_term "$term_file"

    reset_case
    term_file="$TEST_ROOT/sibling.term"
    start_owner "$term_file" sda1 "$owner_path" 10
    assert_success 'A04 sibling remove is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda2 /devices/pci0000:00/block/sda/sda2 11
    assert_owner_alive "$OWNER_PID" 'A04 sibling remove signalled owner'
    assert_file_absent "$term_file" 'A04 sibling remove recorded TERM'

    reset_case
    term_file="$TEST_ROOT/grandparent.term"
    start_owner "$term_file" sda1 "$owner_path" 10
    assert_success 'A04 grandparent remove is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" block /devices/pci0000:00/block 11
    assert_owner_alive "$OWNER_PID" 'A04 grandparent remove signalled owner'
    assert_file_absent "$term_file" 'A04 grandparent remove recorded TERM'
}

case_sequence_order_is_string_safe() {
    begin_case A05 'old equal and invalid sequences reject while 2^53 adjacent and u64 maximum work'
    reset_case
    path=/devices/pci0000:00/block/sda/sda1
    term_file="$TEST_ROOT/sequence.term"
    start_owner "$term_file" sda1 "$path" 9007199254740992
    assert_success 'A05 equal sequence is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 9007199254740992
    assert_success 'A05 older sequence is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 9007199254740991
    assert_owner_alive "$OWNER_PID" 'A05 old sequence signalled owner'
    assert_success 'A05 2^53 adjacent newer sequence matches' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 9007199254740993
    assert_success 'A05 2^53 owner received TERM' wait_for_term "$term_file"

    reset_case
    term_file="$TEST_ROOT/max.term"
    start_owner "$term_file" sda1 "$path" 18446744073709551614
    assert_success 'A05 maximum u64 is newer by string comparison' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 18446744073709551615
    assert_success 'A05 maximum u64 owner received TERM' wait_for_term "$term_file"

    reset_case
    term_file="$TEST_ROOT/zero-owner.term"
    start_owner "$term_file" sda1 "$path" 0
    assert_success 'A05 zero owner sequence is not authorized' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 1
    assert_owner_unterminated "$OWNER_PID" "$term_file" \
        'A05 zero owner sequence was signalled'

    reset_case
    term_file="$TEST_ROOT/zero-event.term"
    start_owner "$term_file" sda1 "$path" 10
    assert_failure 'A05 zero remove sequence is invalid' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 0
    assert_owner_alive "$OWNER_PID" 'A05 zero remove sequence was signalled'
}

case_wrong_real_argv_never_signals() {
    begin_case A06 'wrong action path slot and extra argv are real processes but never owners'
    reset_case
    path=/devices/pci0000:00/block/sda/sda1
    term_file="$TEST_ROOT/wrong-action.term"
    start_raw_owner "$term_file" "$MANAGER" remove sda1 "$path" 10
    assert_success 'A06 wrong action is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_owner_alive "$OWNER_PID" 'A06 wrong action was signalled'

    reset_case
    term_file="$TEST_ROOT/wrong-path.term"
    start_raw_owner "$term_file" "$OTHER_MANAGER" add sda1 "$path" 10
    assert_success 'A06 wrong manager path is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_owner_alive "$OWNER_PID" 'A06 wrong script was signalled'

    reset_case
    term_file="$TEST_ROOT/extra-slot.term"
    start_raw_owner "$term_file" "$MANAGER" add sda1 "$path" 10 extra
    assert_success 'A06 extra argv slot is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_owner_alive "$OWNER_PID" 'A06 extra slot was signalled'

    reset_case
    term_file="$TEST_ROOT/shell-c.term"
    start_raw_owner "$term_file" /bin/sh -c 'trap "printf TERM > \"$TERM_FILE\"; exit 143" TERM; while :; do sleep 1; done'
    assert_success 'A06 shell -c argv is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_owner_alive "$OWNER_PID" 'A06 shell -c process was signalled'
}

case_missing_dead_and_self_locks_noop() {
    begin_case A07 'missing dangling dead and self lock targets are no-op classifications'
    reset_case
    path=/devices/pci0000:00/block/sda/sda1
    assert_success 'A07 absent lock is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 2
    ln -s /proc/999999 "$LOCK"
    assert_success 'A07 dangling lock is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 2
    rm -f "$LOCK"
    ln -s "/proc/$$" "$LOCK"
    assert_success 'A07 self lock is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 2

    reset_case
    term_file="$TEST_ROOT/one-lf-lock.term"
    start_owner "$term_file" sda1 "$path" 10
    lock_payload="/proc/$OWNER_PID
"
    rm -f "$LOCK"
    ln -s "$lock_payload" "$LOCK"
    assert_success 'A07 single trailing LF lock target is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_owner_unterminated "$OWNER_PID" "$term_file" 'A07 single trailing LF lock signalled owner'

    reset_case
    term_file="$TEST_ROOT/two-lf-lock.term"
    start_owner "$term_file" sda1 "$path" 10
    lock_payload="/proc/$OWNER_PID

"
    rm -f "$LOCK"
    ln -s "$lock_payload" "$LOCK"
    assert_success 'A07 double trailing LF lock target is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_owner_unterminated "$OWNER_PID" "$term_file" 'A07 double trailing LF lock signalled owner'

    reset_case
    term_file="$TEST_ROOT/middle-lf-lock.term"
    start_owner "$term_file" sda1 "$path" 10
    lock_payload="/proc/$OWNER_PID
suffix"
    rm -f "$LOCK"
    ln -s "$lock_payload" "$LOCK"
    assert_success 'A07 middle LF lock target is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_owner_unterminated "$OWNER_PID" "$term_file" 'A07 middle LF lock signalled owner'
}

case_bad_proc_evidence_is_noop() {
    begin_case A08 'unreadable cmdline and empty malformed or failing stat evidence do not signal'
    reset_case
    path=/devices/pci0000:00/block/sda/sda1
    term_file="$TEST_ROOT/unreadable.term"
    start_owner "$term_file" sda1 "$path" 10
    owner_event_cmdline_path() { printf '%s\n' "$TEST_ROOT/not-readable-cmdline"; }
    assert_success 'A08 unreadable proc cmdline is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_owner_unterminated "$OWNER_PID" "$term_file" \
        'A08 unreadable cmdline signalled owner'

    reset_case
    term_file="$TEST_ROOT/empty-stat.term"
    start_owner "$term_file" sda1 "$path" 10
    owner_event_read_stat_file() { return 0; }
    assert_success 'A08 empty successful stat reader is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_owner_unterminated "$OWNER_PID" "$term_file" \
        'A08 empty stat signalled owner'

    reset_case
    term_file="$TEST_ROOT/failing-stat.term"
    start_owner "$term_file" sda1 "$path" 10
    owner_event_read_stat_file() { return 1; }
    assert_success 'A08 failing stat reader is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_owner_unterminated "$OWNER_PID" "$term_file" \
        'A08 failing stat signalled owner'

    reset_case
    term_file="$TEST_ROOT/malformed-stat.term"
    start_owner "$term_file" sda1 "$path" 10
    owner_event_read_stat_file() { printf 'bad stat record\n'; }
    assert_success 'A08 malformed stat is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_owner_unterminated "$OWNER_PID" "$term_file" \
        'A08 malformed stat signalled owner'

    reset_case
    printf '/bin/sh\000%s\000add\000sda1' "$MANAGER" > "$TEST_ROOT/truncated-cmdline"
    assert_failure 'A08 cmdline without final NUL rejects' \
        owner_event_cmdline_matches "$TEST_ROOT/truncated-cmdline" "$MANAGER" sda1 "$path" 11
}

case_stat_and_lock_rechecks_block_races() {
    begin_case A09 'last-parenthesis parsing accepts S-to-R but rejects starttime or lock changes'
    reset_case
    expected_stat='777 (worker ) with space) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 1234'
    owner_event_read_stat_file() { printf '%s\n' "$expected_stat"; }
    assert_equal "$(owner_event_stat_identity 777)" 1234 \
        'A09 stat parser uses fields after the final parenthesis delimiter'

    reset_case
    path=/devices/pci0000:00/block/sda/sda1
    term_file="$TEST_ROOT/state-transition.term"
    start_owner "$term_file" sda1 "$path" 10
    starttime=$(owner_event_stat_identity "$OWNER_PID")
    printf 'S %s\nR %s\n' "$starttime" "$starttime" > "$TEST_ROOT/stat-sequence"
    install_stat_sequence_wrapper
    assert_success 'A09 S-to-R with same starttime still signals owner' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_success 'A09 S-to-R owner received one TERM' wait_for_term "$term_file"

    reset_case
    term_file="$TEST_ROOT/starttime-change.term"
    start_owner "$term_file" sda1 "$path" 10
    printf 'S 100\nR 101\n' > "$TEST_ROOT/stat-sequence"
    install_stat_sequence_wrapper
    assert_success 'A09 changed starttime is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_owner_unterminated "$OWNER_PID" "$term_file" \
        'A09 changed starttime signalled owner'

    reset_case
    term_file="$TEST_ROOT/lock-change.term"
    start_owner "$term_file" sda1 "$path" 10
    printf 'first\nsecond\n' > "$TEST_ROOT/lock-sequence"
    owner_event_read_lock() {
        lock_step=$(sed -n '1p' "$TEST_ROOT/lock-sequence") || return 1
        sed -n '2,$p' "$TEST_ROOT/lock-sequence" > "$TEST_ROOT/lock-sequence.next" || return 1
        mv "$TEST_ROOT/lock-sequence.next" "$TEST_ROOT/lock-sequence" || return 1
        [ "$lock_step" = first ] && readlink "$1" || printf '/proc/999999\n'
    }
    assert_success 'A09 changed lock target is a no-op' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_owner_unterminated "$OWNER_PID" "$term_file" \
        'A09 changed lock signalled owner'
}

case_missing_dependencies_and_action_failures() {
    begin_case A10 'missing jq missing helper kill failure and logger failure preserve result rules'
    reset_case
    path=/devices/pci0000:00/block/sda/sda1
    PATH=/no-such-path
    export PATH
    assert_failure 'A10 missing jq fails loud' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 2
    PATH=$ORIGINAL_PATH
    export PATH
    unset -f target_device_valid_devname
    assert_failure 'A10 missing target validation helper fails loud' \
        owner_event_validate_event sda1 "$path" 2
    load_libraries

    reset_case
    term_file="$TEST_ROOT/kill-failure.term"
    start_owner "$term_file" sda1 "$path" 10
    owner_event_send_term() { return 1; }
    assert_failure 'A10 failed TERM returns nonzero without retry' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_owner_alive "$OWNER_PID" 'A10 failed TERM unexpectedly killed owner'
    assert_file_absent "$term_file" 'A10 failed TERM recorded signal'

    reset_case
    term_file="$TEST_ROOT/logger-failure.term"
    start_owner "$term_file" sda1 "$path" 10
    logger() { return 1; }
    assert_success 'A10 logger failure does not change a valid cancellation result' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 11
    assert_success 'A10 logger failure owner received actual TERM' wait_for_term "$term_file"
}

case_stop_accepts_proven_legacy_and_new_owners() {
    begin_case A11 'administrator stop accepts complete legacy and new add argv without remove event data'
    reset_case
    term_file="$TEST_ROOT/legacy-stop.term"
    start_legacy_owner "$term_file" sda1 /devices/mock
    expected_identity="$OWNER_PID:$(owner_event_stat_identity "$OWNER_PID")"
    call_stop "$LOCK" "$MANAGER"
    assert_status "$STOP_STATUS" 0 'A11 legacy owner is a proven stop target'
    assert_equal "$OWNER_EVENT_STOP_IDENTITY" "$expected_identity" 'A11 legacy stop exports PID:starttime'
    assert_success 'A11 legacy owner received TERM' wait_for_term "$term_file"

    reset_case
    term_file="$TEST_ROOT/new-stop.term"
    start_owner "$term_file" sda1 /devices/pci0000:00/block/sda/sda1 10
    call_stop "$LOCK" "$MANAGER"
    assert_status "$STOP_STATUS" 0 'A11 new owner needs no remove SEQNUM'
    assert_success 'A11 new owner received TERM' wait_for_term "$term_file"
}

case_stop_rejects_non_owner_argv() {
    begin_case A12 'administrator stop rejects malformed complete argv without signalling'
    reset_case
    term_file="$TEST_ROOT/wrong-action-stop.term"
    start_raw_owner "$term_file" "$MANAGER" remove sda1 /devices/mock
    call_stop "$LOCK" "$MANAGER"
    assert_status "$STOP_STATUS" 1 'A12 remove action is not a stop owner'
    assert_owner_unterminated "$OWNER_PID" "$term_file" 'A12 remove action was signalled'

    reset_case
    term_file="$TEST_ROOT/wrong-manager-stop.term"
    start_raw_owner "$term_file" "$OTHER_MANAGER" add sda1 /devices/mock
    call_stop "$LOCK" "$MANAGER"
    assert_status "$STOP_STATUS" 1 'A12 another manager is not a stop owner'
    assert_owner_unterminated "$OWNER_PID" "$term_file" 'A12 another manager was signalled'

    reset_case
    term_file="$TEST_ROOT/prefix-manager-stop.term"
    write_owner_script "${MANAGER}.bak"
    start_raw_owner "$term_file" "${MANAGER}.bak" add sda1 /devices/mock
    call_stop "$LOCK" "$MANAGER"
    assert_status "$STOP_STATUS" 1 'A12 manager prefix is not an exact path match'
    assert_owner_unterminated "$OWNER_PID" "$term_file" 'A12 prefix manager was signalled'

    reset_case
    term_file="$TEST_ROOT/extra-argv-stop.term"
    start_raw_owner "$term_file" "$MANAGER" add sda1 /devices/mock extra
    call_stop "$LOCK" "$MANAGER"
    assert_status "$STOP_STATUS" 1 'A12 extra argv slot is not an owner'
    assert_owner_unterminated "$OWNER_PID" "$term_file" 'A12 extra argv was signalled'

    reset_case
    term_file="$TEST_ROOT/shell-c-stop.term"
    start_raw_owner "$term_file" /bin/sh -c 'while :; do sleep 1; done'
    call_stop "$LOCK" "$MANAGER"
    assert_status "$STOP_STATUS" 1 'A12 shell -c is not an owner'
    assert_owner_unterminated "$OWNER_PID" "$term_file" 'A12 shell -c was signalled'
}

case_stop_fails_closed_for_lock_and_evidence_errors() {
    begin_case A13 'administrator stop distinguishes missing lock from every unproven owner state'
    reset_case
    OWNER_EVENT_STOP_IDENTITY=stale
    call_stop "$LOCK" "$MANAGER"
    assert_status "$STOP_STATUS" 2 'A13 entirely absent lock returns 2'
    assert_equal "${OWNER_EVENT_STOP_IDENTITY:-}" '' 'A13 absent lock clears prior identity'

    reset_case
    ln -s /proc/999999 "$LOCK"
    OWNER_EVENT_STOP_IDENTITY=stale
    call_stop "$LOCK" "$MANAGER"
    assert_status "$STOP_STATUS" 1 'A13 dangling lock is unproven, not absent'
    assert_equal "${OWNER_EVENT_STOP_IDENTITY:-}" '' 'A13 dangling lock clears prior identity'

    reset_case
    printf 'business lock residue\n' > "$LOCK"
    call_stop "$LOCK" "$MANAGER"
    assert_status "$STOP_STATUS" 1 'A13 ordinary lock residue is not deleted or classified absent'
    assert_equal "$(sed -n '1p' "$LOCK")" 'business lock residue' 'A13 ordinary lock remains intact'

    reset_case
    term_file="$TEST_ROOT/unreadable-stop.term"
    start_owner "$term_file" sda1 /devices/pci0000:00/block/sda/sda1 10
    owner_event_cmdline_path() { printf '%s\n' "$TEST_ROOT/not-readable-cmdline"; }
    call_stop "$LOCK" "$MANAGER"
    assert_status "$STOP_STATUS" 1 'A13 unreadable cmdline is unproven'
    assert_owner_unterminated "$OWNER_PID" "$term_file" 'A13 unreadable cmdline was signalled'

    reset_case
    term_file="$TEST_ROOT/changing-identity-stop.term"
    start_owner "$term_file" sda1 /devices/pci0000:00/block/sda/sda1 10
    printf 'S 100\nR 101\n' > "$TEST_ROOT/stat-sequence"
    install_stat_sequence_wrapper
    call_stop "$LOCK" "$MANAGER"
    assert_status "$STOP_STATUS" 1 'A13 starttime change is unproven'
    assert_owner_unterminated "$OWNER_PID" "$term_file" 'A13 changed identity was signalled'
}

case_stop_dependency_and_term_failures_are_errors() {
    begin_case A14 'administrator stop treats missing jq and TERM failure as errors'
    reset_case
    PATH=/no-such-path
    export PATH
    call_stop "$LOCK" "$MANAGER"
    assert_status "$STOP_STATUS" 1 'A14 missing jq returns 1 even without a lock'
    PATH=$ORIGINAL_PATH
    export PATH

    reset_case
    term_file="$TEST_ROOT/term-failure-stop.term"
    start_owner "$term_file" sda1 /devices/pci0000:00/block/sda/sda1 10
    owner_event_send_term() { return 1; }
    call_stop "$LOCK" "$MANAGER"
    assert_status "$STOP_STATUS" 1 'A14 failed TERM returns 1'
    assert_equal "${OWNER_EVENT_STOP_IDENTITY:-}" '' 'A14 failed TERM clears output identity'
    assert_owner_unterminated "$OWNER_PID" "$term_file" 'A14 failed TERM unexpectedly signalled owner'
}

case_stop_previous_identity_is_idempotent_without_event_mode_leak() {
    begin_case A15 'same previous identity skips a second TERM and a new identity is signalled once'
    reset_case
    path=/devices/pci0000:00/block/sda/sda1
    term_file="$TEST_ROOT/first-idempotent.term"
    sender_log="$TEST_ROOT/first-sender.log"
    start_reusable_owner "$term_file" sda1 "$path" 10
    first_pid=$OWNER_PID
    install_counting_sender "$sender_log"
    call_stop "$LOCK" "$MANAGER"
    first_identity=$OWNER_EVENT_STOP_IDENTITY
    assert_status "$STOP_STATUS" 0 'A15 first stop succeeds'
    assert_success 'A15 first owner received TERM' wait_for_term "$term_file"
    assert_equal "$(wc -l < "$sender_log")" 1 'A15 first stop calls sender once'
    assert_equal "$(sed -n '1p' "$sender_log")" "$first_pid" 'A15 first sender targets proven PID'
    call_stop "$LOCK" "$MANAGER" "$first_identity"
    assert_status "$STOP_STATUS" 0 'A15 same verified identity returns success'
    assert_equal "$OWNER_EVENT_STOP_IDENTITY" "$first_identity" 'A15 same identity remains stable'
    assert_equal "$(wc -l < "$sender_log")" 1 'A15 same identity does not call sender again'
    assert_equal "$(sed -n '1p' "$sender_log")" "$first_pid" 'A15 same identity retains original sender target'
    assert_success 'A15 old event API still makes equal sequence a no-op after stop' \
        owner_event_cancel "$LOCK" "$MANAGER" sda1 "$path" 10
    assert_equal "$(wc -l < "$sender_log")" 1 'A15 old event API does not call stop sender'
    assert_equal "$(sed -n '1p' "$sender_log")" "$first_pid" 'A15 event mode retains original sender target'

    reset_case
    term_file="$TEST_ROOT/new-identity.term"
    sender_log="$TEST_ROOT/new-sender.log"
    start_reusable_owner "$term_file" sda1 "$path" 10
    new_pid=$OWNER_PID
    install_counting_sender "$sender_log"
    call_stop "$LOCK" "$MANAGER" "$first_identity"
    assert_status "$STOP_STATUS" 0 'A15 distinct owner identity receives a new TERM'
    assert_success 'A15 new owner received TERM' wait_for_term "$term_file"
    assert_equal "$(wc -l < "$sender_log")" 1 'A15 distinct identity calls sender once'
    assert_equal "$(sed -n '1p' "$sender_log")" "$new_pid" 'A15 distinct identity targets new proven PID'
    assert_failure 'A15 new PID:starttime differs from prior identity' \
        test "$OWNER_EVENT_STOP_IDENTITY" = "$first_identity"

    reset_case
    mutant_library="$TEST_ROOT/owner-event-same-identity-mutant.sh"
    assert_success 'A15 writes a test-private same-identity sender mutant' \
        write_same_previous_sender_mutant "$mutant_library"
    # shellcheck disable=SC1090
    . "$mutant_library"
    term_file="$TEST_ROOT/mutant-idempotent.term"
    sender_log="$TEST_ROOT/mutant-sender.log"
    start_reusable_owner "$term_file" sda1 "$path" 10
    mutant_pid=$OWNER_PID
    install_counting_sender "$sender_log"
    call_stop "$LOCK" "$MANAGER"
    mutant_identity=$OWNER_EVENT_STOP_IDENTITY
    assert_status "$STOP_STATUS" 0 'A15 mutant first stop remains a valid delivery path'
    assert_success 'A15 mutant first owner received TERM before extra sender call' \
        wait_for_term "$term_file"
    call_stop "$LOCK" "$MANAGER" "$mutant_identity"
    assert_status "$STOP_STATUS" 0 'A15 mutant same identity exposes its extra sender call'
    assert_equal "$(wc -l < "$sender_log")" 2 'A15 mutant invoked sender twice'
    assert_equal "$(sed -n '1p' "$sender_log")" "$mutant_pid" 'A15 mutant first sender targets proven PID'
    assert_equal "$(sed -n '2p' "$sender_log")" "$mutant_pid" 'A15 mutant extra sender targets the same proven PID'
    [ "$(wc -l < "$sender_log")" -eq 1 ]
    mutant_sender_oracle_rc=$?
    printf 'MUTANT A15 sender-count oracle: calls=%s rc=%s\n' \
        "$(wc -l < "$sender_log")" "$mutant_sender_oracle_rc"
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$mutant_sender_oracle_rc" -eq 0 ]; then
        fail 'A15 sender-count oracle failed to detect same-identity mutant'
    fi
    # Restore production functions after the test-private seam and mutant source.
    load_libraries
}

main() {
    mkdir -p /var/lock
    opkg update >/dev/null || {
        printf '%s\n' 'FAIL: cannot refresh package metadata for real jq' >&2
        exit 1
    }
    opkg install jq >/dev/null || {
        printf '%s\n' 'FAIL: cannot install real jq for proc parser test' >&2
        exit 1
    }
    if [ ! -r "$TARGET_DEVICE_SCRIPT" ]; then
        printf 'FAIL: target-device helper is absent: %s\n' "$TARGET_DEVICE_SCRIPT" >&2
        exit 1
    fi
    if [ ! -r "$OWNER_EVENT_SCRIPT" ]; then
        begin_case RED 'owner-event library must exist before behavior can pass'
        ASSERTIONS=$((ASSERTIONS + 1))
        fail "owner-event library is absent: $OWNER_EVENT_SCRIPT"
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    trap cleanup EXIT INT TERM

    case_source_only_has_no_side_effect
    case_validator_accepts_only_canonical_event_values
    case_real_owner_exact_argv_receives_one_term
    case_direct_parent_only_matches
    case_sequence_order_is_string_safe
    case_wrong_real_argv_never_signals
    case_missing_dead_and_self_locks_noop
    case_bad_proc_evidence_is_noop
    case_stat_and_lock_rechecks_block_races
    case_missing_dependencies_and_action_failures
    case_stop_accepts_proven_legacy_and_new_owners
    case_stop_rejects_non_owner_argv
    case_stop_fails_closed_for_lock_and_evidence_errors
    case_stop_dependency_and_term_failures_are_errors
    case_stop_previous_identity_is_idempotent_without_event_mode_leak

    assert_equal "$CASES" 15 'all required owner-event cases executed'
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

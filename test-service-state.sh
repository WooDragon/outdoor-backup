#!/bin/sh
#
# BDD integration tests for the service state / lease flock primitive. The host
# entry re-execs only this suite in a fixed OpenWrt rootfs; /src is read-only,
# while all raw command output, return codes, and /proc/lock evidence live in a
# unique host-visible /tmp directory until the host process removes it.
#
set -u

LIB_REL='files/opt/outdoor-backup/scripts/service-state.sh'
ARM_IMAGE='openwrt/rootfs:aarch64_generic-24.10.8'
ARM_DIGEST='sha256:f6dd33c1d9b7d6f1e0848f2fbb92b8d03fc9b425dc08c3574a44936b93133704'
X86_IMAGE='openwrt/rootfs:x86_64-24.10.8'
X86_DIGEST='sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9'

if [ "${1:-}" != '--inside' ]; then
    REPO_ROOT=$(dirname -- "$0")
    EVIDENCE_ROOT=$(mktemp -d /tmp/outdoor-backup-service-state.XXXXXX) || exit 1
    case "$(uname -m)" in
        arm64|aarch64)
            image=$ARM_IMAGE
            digest=$ARM_DIGEST
            platform='linux/aarch64_generic'
            ;;
        *)
            image=$X86_IMAGE
            digest=$X86_DIGEST
            platform='linux/amd64'
            ;;
    esac
    image_ref="$image@$digest"
    reader_container=$(docker run -d --rm --platform "$platform" --tmpfs /tmp:rw,exec \
        -v "$REPO_ROOT:/src:ro" "$image_ref" /bin/ash -c 'while :; do /bin/sleep 3600; done') || exit 1
    cleanup_reader_container() { docker stop "$reader_container" >/dev/null 2>&1 || :; }
    trap 'cleanup_reader_container' EXIT INT TERM
    docker exec "$reader_container" /bin/ash -c 'mkdir -p /var/lock && opkg update >/dev/null && opkg install --force-space jq >/dev/null' \
        >"$EVIDENCE_ROOT/reader-jq.stdout" 2>"$EVIDENCE_ROOT/reader-jq.stderr"
    reader_jq_rc=$?
    printf '%s\n' "$reader_jq_rc" > "$EVIDENCE_ROOT/reader-jq.rc"
    if [ "$reader_jq_rc" -ne 0 ]; then
        printf 'FAIL: cannot install real jq in controlled-reader container; evidence=%s\n' "$EVIDENCE_ROOT" >&2
        exit 1
    fi
    docker exec "$reader_container" /bin/ash -c \
        'mkdir -p /tmp/reader/runtime; printf "running:7\\n" > /tmp/reader/runtime/state; chmod 755 /tmp/reader /tmp/reader/runtime; chmod 600 /tmp/reader/runtime/state' \
        >"$EVIDENCE_ROOT/reader-prepare.stdout" 2>"$EVIDENCE_ROOT/reader-prepare.stderr"
    prepare_rc=$?
    printf '%s\n' "$prepare_rc" > "$EVIDENCE_ROOT/reader-prepare.rc"
    if [ "$prepare_rc" -ne 0 ]; then
        printf 'FAIL: controlled-reader fixture setup failed; evidence=%s\n' "$EVIDENCE_ROOT" >&2
        exit 1
    fi
    docker exec --user 65534:65534 "$reader_container" /bin/ash -c \
        'OUTDOOR_BACKUP_SERVICE_DIR=/tmp/reader/runtime; export OUTDOOR_BACKUP_SERVICE_DIR; . /src/files/opt/outdoor-backup/scripts/service-state.sh; service_state_read; printf "rc=%s\\n" "$?"' \
        >"$EVIDENCE_ROOT/reader.stdout" 2>"$EVIDENCE_ROOT/reader.stderr"
    reader_rc=$?
    printf '%s\n' "$reader_rc" > "$EVIDENCE_ROOT/reader.rc"
    cleanup_reader_container
    trap - EXIT INT TERM
    if [ "$reader_rc" -ne 0 ] || [ "$(cat "$EVIDENCE_ROOT/reader.stdout")" != 'rc=1' ]; then
        printf 'FAIL: controlled reader did not report strict state read failure; evidence=%s\n' "$EVIDENCE_ROOT" >&2
        exit 1
    fi
    docker run --rm --platform "$platform" --tmpfs /tmp:rw,exec -e TEST_EVIDENCE=/evidence \
        -v "$REPO_ROOT:/src:ro" -v "$EVIDENCE_ROOT:/evidence" "$image_ref" \
        /bin/ash /src/test-service-state.sh --inside >"$EVIDENCE_ROOT/suite.stdout" 2>"$EVIDENCE_ROOT/suite.stderr"
    suite_rc=$?
    printf '%s\n' "$suite_rc" > "$EVIDENCE_ROOT/suite.rc"
    cat "$EVIDENCE_ROOT/suite.stdout"
    cat "$EVIDENCE_ROOT/suite.stderr" >&2
    printf 'evidence=%s\n' "$EVIDENCE_ROOT"
    exit "$suite_rc"
fi

[ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || {
    printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
    exit 1
}

mkdir -p /var/lock
opkg update >/dev/null || {
    printf '%s\n' 'FAIL: cannot refresh package metadata for real jq' >&2
    exit 1
}
opkg install --force-space jq >/dev/null || {
    printf '%s\n' 'FAIL: cannot install real jq for service state parser test' >&2
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    printf '%s\n' 'FAIL: jq is absent after successful installation' >&2
    exit 1
}

REPO_ROOT=/src
LIB="$REPO_ROOT/$LIB_REL"
SUITE_ROOT="/tmp/outdoor-backup-service-state.$$"
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

assert_equal() {
    actual=$1
    expected=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    [ "$actual" = "$expected" ] || fail "$message (expected=[$expected], actual=[$actual])"
}

assert_success() {
    message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    "$@" || fail "$message"
}

assert_failure() {
    message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    if "$@"; then
        fail "$message (unexpected success)"
    fi
}

assert_file_absent() {
    path=$1
    message=$2
    ASSERTIONS=$((ASSERTIONS + 1))
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail "$message (path=[$path])"
}

assert_regular() {
    path=$1
    message=$2
    ASSERTIONS=$((ASSERTIONS + 1))
    [ -f "$path" ] && [ ! -L "$path" ] || fail "$message (path=[$path])"
}

# Wait at most one minute for a holder that must remain alive until released.
wait_holder_ready() {
    ready_path=$1
    holder_pid=$2
    label=$3
    attempt=0
    while [ "$attempt" -lt 60 ]; do
        [ -e "$ready_path" ] && return 0
        if ! kill -0 "$holder_pid" 2>/dev/null; then
            fail "$label exited before ready"
            wait "$holder_pid" 2>/dev/null || :
            return 1
        fi
        /bin/sleep 1
        attempt=$((attempt + 1))
    done
    fail "$label did not become ready within 60 seconds"
    kill "$holder_pid" 2>/dev/null || :
    wait "$holder_pid" 2>/dev/null || :
    return 1
}

run_ash() {
    output=$1
    shift
    /bin/ash -c "$*" >"$output" 2>&1
}

read_result() {
    runtime=$1
    rcdir=$2
    init=$3
    output=$4
    if OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" \
        OUTDOOR_BACKUP_INIT_SCRIPT="$init" /bin/ash -c \
        '. "$1"; service_state_read; rc=$?; printf "rc=%s mode=%s generation=%s\\n" "$rc" "${SERVICE_STATE_MODE:-}" "${SERVICE_STATE_GENERATION:-}"' \
        ash "$LIB" >"$output" 2>&1; then
        return 0
    fi
    return $?
}

prepare_runtime() {
    runtime=$1
    rcdir=$2
    init=$3
    mkdir -p "$runtime" "$rcdir" "${init%/*}"
    : > "$init"
}

enable_rc() {
    rcdir=$1
    init=$2
    ln -s "$init" "$rcdir/S95outdoor-backup"
}

write_state() {
    runtime=$1
    value=$2
    printf '%b' "$value" > "$runtime/state"
}

# Write one driver which fails only its pre-explicit-release X-lock contract.
write_lease_current_driver() {
    driver=$1
    cat > "$driver" <<'EOF'
#!/bin/ash
. "$1"
service_lease_acquire 11
lease_rc=$?
printf '%s\n' "$2" > "$OUTDOOR_BACKUP_SERVICE_DIR/state"
service_lease_current
current_rc=$?
[ "${SERVICE_LEASE_HELD:-}" = 1 ] && held=1 || held=0
lease_generation=${SERVICE_LEASE_GENERATION:-}
[ -e /proc/self/fd/8 ] && fd_open=1 || fd_open=0
if grep -q 'FLOCK.*READ' /proc/self/fdinfo/8 2>/dev/null; then
    fd_read=1
else
    fd_read=0
fi
before=$(/bin/ash -c \
    'exec 8>&-; . "$1"; service_admission_exclusive; probe_rc=$?; service_lease_release; printf "%s" "$probe_rc"' \
    ash "$1")
service_lease_release
release_rc=$?
after=$(/bin/ash -c \
    'exec 8>&-; . "$1"; service_admission_exclusive; probe_rc=$?; service_lease_release; printf "%s" "$probe_rc"' \
    ash "$1")
checks=1
failed=0
[ "$before" = 2 ] || failed=1
printf 'lease=%s current=%s held=%s gen=%s fd-open=%s fd-read=%s before=%s release=%s after=%s checks=%s failed=%s\n' \
    "$lease_rc" "$current_rc" "$held" "$lease_generation" "$fd_open" "$fd_read" \
    "$before" "$release_rc" "$after" "$checks" "$failed"
[ "$failed" -eq 0 ]
EOF
    chmod 700 "$driver"
}

assert_bad_state() {
    runtime=$1
    rcdir=$2
    init=$3
    value=$4
    label=$5
    write_state "$runtime" "$value"
    read_result "$runtime" "$rcdir" "$init" "$SUITE_ROOT/s02.bad"
    assert_equal "$(cat "$SUITE_ROOT/s02.bad")" 'rc=1 mode= generation=' "$label"
}

# Write escaped fixture bytes directly through printf, then prove their on-disk
# representation before state_read runs. Shell variables only carry backslash
# notation here; no shell variable ever contains a NUL byte.
assert_bad_state_bytes() {
    runtime=$1
    rcdir=$2
    init=$3
    escaped_bytes=$4
    expected_hex=$5
    label=$6
    printf '%b' "$escaped_bytes" > "$runtime/state"
    actual_hex=$(hexdump -v -e '1/1 "%02x"' "$runtime/state")
    assert_equal "$actual_hex" "$expected_hex" "$label fixture preserves exact raw bytes"
    read_result "$runtime" "$rcdir" "$init" "$SUITE_ROOT/s02.bad"
    assert_equal "$(cat "$SUITE_ROOT/s02.bad")" 'rc=1 mode= generation=' "$label"
}

case_s01_source_is_inert() {
    begin_case S01 'sourcing the delivered library performs no I/O, installs no trap, and preserves locale'
    runtime="$SUITE_ROOT/s01/runtime"
    output="$SUITE_ROOT/s01.out"
    mkdir -p "$SUITE_ROOT/s01"
    if OUTDOOR_BACKUP_SERVICE_DIR="$runtime" LC_ALL=C /bin/ash -c \
        'before=$(trap); before_locale=${LC_ALL-}; . "$1"; rc=$?; after=$(trap); printf "rc=%s locale=%s traps=%s\\n" "$rc" "${LC_ALL-}" "$( [ "$before" = "$after" ] && printf same || printf changed )"; [ ! -e "$OUTDOOR_BACKUP_SERVICE_DIR" ] && [ ! -L "$OUTDOOR_BACKUP_SERVICE_DIR" ]' \
        ash "$LIB" >"$output" 2>&1; then
        source_rc=0
    else
        source_rc=$?
    fi
    assert_equal "$source_rc" 0 'S01 source succeeds without creating runtime state'
    assert_equal "$(cat "$output" 2>/dev/null || :)" 'rc=0 locale=C traps=same' \
        'S01 source leaves locale and caller traps unchanged'
}

case_s02_strict_state_records() {
    begin_case S02 'state accepts exactly one canonical physical record and rejects malformed, linked, or unreadable input'
    runtime="$SUITE_ROOT/s02/runtime"
    rcdir="$SUITE_ROOT/s02/rc"
    init="$SUITE_ROOT/s02/init/outdoor-backup"
    mkdir -p "$SUITE_ROOT/s02"
    prepare_runtime "$runtime" "$rcdir" "$init"

    write_state "$runtime" 'running:0\n'
    read_result "$runtime" "$rcdir" "$init" "$SUITE_ROOT/s02.valid-lf"
    assert_equal "$(cat "$SUITE_ROOT/s02.valid-lf")" 'rc=0 mode=running generation=0' 'S02 accepts running:0 with LF'
    write_state "$runtime" 'stopped:2147483647'
    read_result "$runtime" "$rcdir" "$init" "$SUITE_ROOT/s02.valid-nolf"
    assert_equal "$(cat "$SUITE_ROOT/s02.valid-nolf")" 'rc=0 mode=stopped generation=2147483647' 'S02 accepts max stopped record without LF'
    mkdir "$SUITE_ROOT/s02/no-jq-path"
    PATH="$SUITE_ROOT/s02/no-jq-path" read_result "$runtime" "$rcdir" "$init" "$SUITE_ROOT/s02.no-jq" || :
    assert_equal "$(cat "$SUITE_ROOT/s02.no-jq")" 'rc=1 mode= generation=' \
        'S02 existing state fails when jq is unavailable instead of falling back to rc state'

    assert_bad_state "$runtime" "$rcdir" "$init" 'running:00\n' 'S02 rejects a leading-zero generation'
    assert_bad_state "$runtime" "$rcdir" "$init" 'running:+1\n' 'S02 rejects a signed generation'
    assert_bad_state "$runtime" "$rcdir" "$init" 'running: 1\n' 'S02 rejects whitespace in a generation'
    assert_bad_state "$runtime" "$rcdir" "$init" 'running:2147483648\n' 'S02 rejects generation overflow'
    assert_bad_state "$runtime" "$rcdir" "$init" 'running:1\nstopped:1\n' 'S02 rejects multiple physical records'
    assert_bad_state "$runtime" "$rcdir" "$init" 'running:1\n\n' 'S02 rejects an extra blank record'
    assert_bad_state "$runtime" "$rcdir" "$init" 'stopped:-1\n' 'S02 rejects a negative generation'
    assert_bad_state "$runtime" "$rcdir" "$init" 'unknown:1\n' 'S02 rejects an unknown state mode'

    assert_bad_state_bytes "$runtime" "$rcdir" "$init" 'running:1\000' \
        '72756e6e696e673a3100' 'S02 rejects running tail NUL'
    assert_bad_state_bytes "$runtime" "$rcdir" "$init" 'running:\000\061' \
        '72756e6e696e673a0031' 'S02 rejects running middle NUL'
    assert_bad_state_bytes "$runtime" "$rcdir" "$init" '\000running:1' \
        '0072756e6e696e673a31' 'S02 rejects running leading NUL'
    assert_bad_state_bytes "$runtime" "$rcdir" "$init" 'running:1\000\062' \
        '72756e6e696e673a310032' 'S02 rejects running NUL followed by a digit'
    assert_bad_state_bytes "$runtime" "$rcdir" "$init" 'running:1\000\n' \
        '72756e6e696e673a31000a' 'S02 rejects running NUL followed by a newline'
    assert_bad_state_bytes "$runtime" "$rcdir" "$init" 'stopped:1\000' \
        '73746f707065643a3100' 'S02 rejects stopped tail NUL'
    assert_bad_state_bytes "$runtime" "$rcdir" "$init" 'stopped:\000\061' \
        '73746f707065643a0031' 'S02 rejects stopped middle NUL'
    assert_bad_state_bytes "$runtime" "$rcdir" "$init" '\000stopped:1' \
        '0073746f707065643a31' 'S02 rejects stopped leading NUL'
    assert_bad_state_bytes "$runtime" "$rcdir" "$init" 'stopped:1\000\062' \
        '73746f707065643a310032' 'S02 rejects stopped NUL followed by a digit'
    assert_bad_state_bytes "$runtime" "$rcdir" "$init" 'stopped:1\000\n' \
        '73746f707065643a31000a' 'S02 rejects stopped NUL followed by a newline'
    assert_bad_state_bytes "$runtime" "$rcdir" "$init" 'running:1\r' \
        '72756e6e696e673a310d' 'S02 rejects carriage return'
    assert_bad_state_bytes "$runtime" "$rcdir" "$init" 'running:1\t' \
        '72756e6e696e673a3109' 'S02 rejects tab'
    assert_bad_state_bytes "$runtime" "$rcdir" "$init" 'running:1\303\251' \
        '72756e6e696e673a31c3a9' 'S02 rejects non-ASCII bytes'

    printf 'running:1\n' > "$SUITE_ROOT/s02/real-state"
    rm -f "$runtime/state"
    ln -s "$SUITE_ROOT/s02/real-state" "$runtime/state"
    read_result "$runtime" "$rcdir" "$init" "$SUITE_ROOT/s02.link"
    assert_equal "$(cat "$SUITE_ROOT/s02.link")" 'rc=1 mode= generation=' 'S02 rejects linked state instead of following it'
    rm -f "$runtime/state"
    mkdir "$runtime/state"
    read_result "$runtime" "$rcdir" "$init" "$SUITE_ROOT/s02.directory"
    assert_equal "$(cat "$SUITE_ROOT/s02.directory")" 'rc=1 mode= generation=' 'S02 rejects state directories'
    rmdir "$runtime/state"

    assert_equal "$(cat "${TEST_EVIDENCE:?}/reader.stdout")" 'rc=1' \
        'S02 separate UID 65534 reader reports actual state open failure'
    assert_equal "$(cat "${TEST_EVIDENCE:?}/reader.rc")" 0 \
        'S02 controlled reader command itself completes with observed failure status'
}

case_s03_rc_fallback_and_precedence() {
    begin_case S03 'missing state falls back only to a correctly resolved rc enable link, while existing stopped wins'
    runtime="$SUITE_ROOT/s03/runtime"
    rcdir="$SUITE_ROOT/s03/rc"
    init="$SUITE_ROOT/s03/init/outdoor-backup"
    mkdir -p "$SUITE_ROOT/s03"
    prepare_runtime "$runtime" "$rcdir" "$init"
    read_result "$runtime" "$rcdir" "$init" "$SUITE_ROOT/s03.disabled"
    assert_equal "$(cat "$SUITE_ROOT/s03.disabled")" 'rc=0 mode=stopped generation=0' 'S03 missing state plus disabled rc is stopped'

    enable_rc "$rcdir" "$init"
    read_result "$runtime" "$rcdir" "$init" "$SUITE_ROOT/s03.enabled"
    assert_equal "$(cat "$SUITE_ROOT/s03.enabled")" 'rc=0 mode=running generation=0' 'S03 matching rc link enables virtual running state'
    rm -f "$rcdir/S95outdoor-backup"
    : > "$SUITE_ROOT/s03/init/other"
    ln -s "$SUITE_ROOT/s03/init/other" "$rcdir/S95outdoor-backup"
    read_result "$runtime" "$rcdir" "$init" "$SUITE_ROOT/s03.wrong-target"
    assert_equal "$(cat "$SUITE_ROOT/s03.wrong-target")" 'rc=0 mode=stopped generation=0' 'S03 wrong init target is not enabled'
    rm -f "$rcdir/S95outdoor-backup"
    : > "$rcdir/S95outdoor-backup"
    read_result "$runtime" "$rcdir" "$init" "$SUITE_ROOT/s03.regular"
    assert_equal "$(cat "$SUITE_ROOT/s03.regular")" 'rc=0 mode=stopped generation=0' 'S03 regular rc file is not enabled'
    rm -f "$rcdir/S95outdoor-backup"
    enable_rc "$rcdir" "$init"
    write_state "$runtime" 'stopped:9\n'
    read_result "$runtime" "$rcdir" "$init" "$SUITE_ROOT/s03.stopped"
    assert_equal "$(cat "$SUITE_ROOT/s03.stopped")" 'rc=0 mode=stopped generation=9' \
        'S03 explicit stopped state overrides enabled fallback'
}

case_s04_lease_admission() {
    begin_case S04 'shared lease admits only running matching epochs and two readers coexist while X is blocked'
    runtime="$SUITE_ROOT/s04/runtime"
    rcdir="$SUITE_ROOT/s04/rc"
    init="$SUITE_ROOT/s04/init/outdoor-backup"
    mkdir -p "$SUITE_ROOT/s04"
    prepare_runtime "$runtime" "$rcdir" "$init"
    write_state "$runtime" 'running:4\n'
    printf 'admission-sentinel\n' > "$SUITE_ROOT/s04/outside-admission"
    ln -s "$SUITE_ROOT/s04/outside-admission" "$runtime/admission.lock"
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" /bin/ash -c '. "$1"; service_lease_acquire; printf "rc=%s\\n" "$?"' ash "$LIB" > "$SUITE_ROOT/s04/admission-link" 2>&1 || :
    assert_equal "$(cat "$SUITE_ROOT/s04/admission-link")" 'rc=1' 'S04 linked admission lock is rejected'
    assert_equal "$(cat "$SUITE_ROOT/s04/outside-admission")" 'admission-sentinel' 'S04 rejected admission link leaves target bytes unchanged'
    rm -f "$runtime/admission.lock"
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash -c '. "$1"; service_lease_acquire 4; rc=$?; printf "rc=%s held=%s gen=%s\\n" "$rc" "${SERVICE_LEASE_HELD:-}" "${SERVICE_LEASE_GENERATION:-}"; service_lease_release' \
        ash "$LIB" > "$SUITE_ROOT/s04.same" 2>&1
    assert_equal "$(cat "$SUITE_ROOT/s04.same")" 'rc=0 held=1 gen=4' 'S04 exact generation leases running state'
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash -c '. "$1"; service_lease_acquire 5; printf "rc=%s held=%s\\n" "$?" "${SERVICE_LEASE_HELD:-}"' ash "$LIB" > "$SUITE_ROOT/s04.mismatch" 2>&1 || :
    assert_equal "$(cat "$SUITE_ROOT/s04.mismatch")" 'rc=2 held=0' 'S04 mismatched generation is normal not-admitted'
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash -c '. "$1"; service_lease_acquire ""; printf "rc=%s\\n" "$?"' ash "$LIB" > "$SUITE_ROOT/s04.empty" 2>&1 || :
    assert_equal "$(cat "$SUITE_ROOT/s04.empty")" 'rc=1' 'S04 explicit empty expected generation is invalid'
    write_state "$runtime" 'stopped:4\n'
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash -c '. "$1"; service_lease_acquire; printf "rc=%s\\n" "$?"' ash "$LIB" > "$SUITE_ROOT/s04.stopped" 2>&1 || :
    assert_equal "$(cat "$SUITE_ROOT/s04.stopped")" 'rc=2' 'S04 stopped state is normal not-admitted'

    write_state "$runtime" 'running:6\n'
    ( exit 0 ) &
    early_exit_holder=$!
    if ( wait_holder_ready "$SUITE_ROOT/s04/never-ready" "$early_exit_holder" 'S04 negative control holder' ) >/dev/null 2>&1; then
        early_exit_rc=0
    else
        early_exit_rc=$?
    fi
    assert_equal "$early_exit_rc" 1 'S04 readiness fails promptly when a holder exits before ready'
    cat > "$SUITE_ROOT/s04/holder.sh" <<'EOF'
#!/bin/ash
. "$1"
service_lease_acquire 6 || exit $?
printf 'pid=%s held=%s\n' "$$" "$SERVICE_LEASE_HELD" > "$2"
while [ ! -e "$3" ]; do /bin/sleep 1; done
service_lease_release
EOF
    chmod 700 "$SUITE_ROOT/s04/holder.sh"
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash "$SUITE_ROOT/s04/holder.sh" "$LIB" "$SUITE_ROOT/s04/ready-a" "$SUITE_ROOT/s04/release" &
    holder_a=$!
    wait_holder_ready "$SUITE_ROOT/s04/ready-a" "$holder_a" 'S04 first shared holder' || return
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash "$SUITE_ROOT/s04/holder.sh" "$LIB" "$SUITE_ROOT/s04/ready-b" "$SUITE_ROOT/s04/release" &
    holder_b=$!
    wait_holder_ready "$SUITE_ROOT/s04/ready-b" "$holder_b" 'S04 second shared holder' || {
        : > "$SUITE_ROOT/s04/release"
        wait "$holder_a" 2>/dev/null || :
        return
    }
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash -c '. "$1"; service_admission_exclusive; printf "rc=%s\\n" "$?"' ash "$LIB" > "$SUITE_ROOT/s04/x-busy" 2>&1 || :
    assert_equal "$(cat "$SUITE_ROOT/s04/x-busy")" 'rc=2' 'S04 two shared leases block exclusive admission'
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash -c '. "$1"; service_control_acquire; a=$?; service_state_write stopped 6; b=$?; service_control_release; printf "control=%s write=%s\\n" "$a" "$b"' \
        ash "$LIB" > "$SUITE_ROOT/s04/stop-write" 2>&1
    assert_equal "$(cat "$SUITE_ROOT/s04/stop-write")" 'control=0 write=0' \
        'S04 controller publishes stopped while shared leases still exist'
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash -c '. "$1"; service_admission_exclusive; printf "rc=%s\\n" "$?"' ash "$LIB" > "$SUITE_ROOT/s04/x-still-busy" 2>&1 || :
    assert_equal "$(cat "$SUITE_ROOT/s04/x-still-busy")" 'rc=2' \
        'S04 stopped publication does not revoke existing shared locks before release'
    : > "$SUITE_ROOT/s04/release"
    wait "$holder_a" || fail 'S04 first shared holder exits cleanly'
    wait "$holder_b" || fail 'S04 second shared holder exits cleanly'
}

case_s05_owner_and_subshell_release() {
    begin_case S05 'a child closes only its inherited lease FD, clears its copy of metadata, and cannot close a reused FD'
    runtime="$SUITE_ROOT/s05/runtime"
    rcdir="$SUITE_ROOT/s05/rc"
    init="$SUITE_ROOT/s05/init/outdoor-backup"
    mkdir -p "$SUITE_ROOT/s05"
    prepare_runtime "$runtime" "$rcdir" "$init"
    write_state "$runtime" 'running:8\n'
    cat > "$SUITE_ROOT/s05/parent.sh" <<'EOF'
#!/bin/ash
. "$1"
[ -z "${7-}" ] || . "$7"
service_lease_acquire 8 || exit $?
command_result=$(service_lease_release; command_rc=$?; [ ! -e /proc/self/fd/8 ] && command_closed=1 || command_closed=0; printf 'rc=%s closed=%s\n' "$command_rc" "$command_closed")
printf '%s\n' "$command_result" > "$8"
(
    service_lease_release
    foreground_rc=$?
    [ ! -e /proc/self/fd/8 ] && foreground_closed=1 || foreground_closed=0
    printf 'rc=%s closed=%s\n' "$foreground_rc" "$foreground_closed" > "$9"
)
(
    service_lease_release
    first_rc=$?
    [ ! -e /proc/self/fd/8 ] && first_closed=1 || first_closed=0
    exec 8> "$3"
    service_lease_release
    second_rc=$?
    [ -e /proc/self/fd/8 ] && unrelated_open=1 || unrelated_open=0
    printf 'first=%s closed=%s second=%s unrelated=%s held=%s owner=%s type=%s gen=%s\n' \
        "$first_rc" "$first_closed" "$second_rc" "$unrelated_open" "${SERVICE_LEASE_HELD:-}" \
        "${SERVICE_LEASE_OWNER_PID:-}" "${SERVICE_LEASE_TYPE:-}" "${SERVICE_LEASE_GENERATION:-}" > "$4"
    : > "$5"
    while [ ! -e "$6" ]; do /bin/sleep 1; done
) &
child=$!
printf '%s\n' "$child" > "$2"
wait "$child"
service_lease_release
EOF
    chmod 700 "$SUITE_ROOT/s05/parent.sh"
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash "$SUITE_ROOT/s05/parent.sh" "$LIB" "$SUITE_ROOT/s05/child-pid" "$SUITE_ROOT/s05/unrelated" \
        "$SUITE_ROOT/s05/result" "$SUITE_ROOT/s05/child-ready" "$SUITE_ROOT/s05/child-release" "$LIB" \
        "$SUITE_ROOT/s05/command" "$SUITE_ROOT/s05/foreground" > "$SUITE_ROOT/s05/raw" 2>&1 &
    parent_pid=$!
    wait_holder_ready "$SUITE_ROOT/s05/child-ready" "$parent_pid" 'S05 child holder' || return
    assert_equal "$(cat "$SUITE_ROOT/s05/command")" 'rc=0 closed=1' \
        'S05 command-substitution child captures a successful release and closes inherited FD'
    assert_equal "$(cat "$SUITE_ROOT/s05/foreground")" 'rc=0 closed=1' \
        'S05 foreground child captures a successful release and closes inherited FD'
    assert_equal "$(cat "$SUITE_ROOT/s05/result")" 'first=0 closed=1 second=0 unrelated=1 held=0 owner= type= gen=' \
        'S05 background child closes inherited FD, clears its own metadata, and preserves a reused unrelated FD'
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" /bin/ash -c '. "$1"; service_admission_exclusive; printf "rc=%s\n" "$?"; service_lease_release' ash "$LIB" > "$SUITE_ROOT/s05/x-busy" 2>&1 || :
    assert_equal "$(cat "$SUITE_ROOT/s05/x-busy")" 'rc=2' 'S05 live child does not unlock the parent lease'
    : > "$SUITE_ROOT/s05/child-release"
    wait "$parent_pid" || fail 'S05 parent exits after explicit child release'
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" /bin/ash -c '. "$1"; service_admission_exclusive; printf "rc=%s\n" "$?"; service_lease_release' ash "$LIB" > "$SUITE_ROOT/s05/x-free" 2>&1
    assert_equal "$(cat "$SUITE_ROOT/s05/x-free")" 'rc=0' 'S05 parent release admits X after child exits'

    cat > "$SUITE_ROOT/s05/mutant.sh" <<'EOF'
. "$1"
service_lease_release() {
    service_state_self_pid || return 1
    if [ "$SERVICE_STATE_SELF_PID" != "${SERVICE_LEASE_OWNER_PID:-}" ]; then
        return 0
    fi
    flock -u 8 || return 1
    exec 8>&-
    SERVICE_LEASE_HELD=0
    SERVICE_LEASE_OWNER_PID=
    SERVICE_LEASE_TYPE=
    SERVICE_LEASE_GENERATION=
}
EOF
    chmod 700 "$SUITE_ROOT/s05/mutant.sh"
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash "$SUITE_ROOT/s05/parent.sh" "$LIB" "$SUITE_ROOT/s05/mutant-child-pid" \
        "$SUITE_ROOT/s05/mutant-unrelated" "$SUITE_ROOT/s05/mutant-result" "$SUITE_ROOT/s05/mutant-ready" "$SUITE_ROOT/s05/mutant-release" "$SUITE_ROOT/s05/mutant.sh" \
        "$SUITE_ROOT/s05/mutant-command" "$SUITE_ROOT/s05/mutant-foreground" > "$SUITE_ROOT/s05/mutant-raw" 2>&1 &
    mutant_parent_pid=$!
    wait_holder_ready "$SUITE_ROOT/s05/mutant-ready" "$mutant_parent_pid" 'S05 mutant child holder' || return
    assert_success 'S05 negative control leaves inherited FD open when child release is a no-op' \
        grep -F -q 'first=0 closed=0 ' "$SUITE_ROOT/s05/mutant-result"
    : > "$SUITE_ROOT/s05/mutant-release"
    wait "$mutant_parent_pid" || fail 'S05 mutant parent exits after cleanup'
}

case_s06_control_write_and_inode_stability() {
    begin_case S06 'control is nonblocking, state publication is atomic, and running requires admission X without replacing lock inodes'
    runtime="$SUITE_ROOT/s06/runtime"
    rcdir="$SUITE_ROOT/s06/rc"
    init="$SUITE_ROOT/s06/init/outdoor-backup"
    mkdir -p "$SUITE_ROOT/s06"
    prepare_runtime "$runtime" "$rcdir" "$init"
    write_state "$runtime" 'stopped:1\n'
    printf 'control-sentinel\n' > "$SUITE_ROOT/s06/outside-control"
    ln -s "$SUITE_ROOT/s06/outside-control" "$runtime/control.lock"
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" /bin/ash -c '. "$1"; service_control_acquire; printf "rc=%s\\n" "$?"' ash "$LIB" > "$SUITE_ROOT/s06/control-link" 2>&1 || :
    assert_equal "$(cat "$SUITE_ROOT/s06/control-link")" 'rc=1' 'S06 linked control lock is rejected'
    assert_equal "$(cat "$SUITE_ROOT/s06/outside-control")" 'control-sentinel' 'S06 rejected control link leaves target bytes unchanged'
    rm -f "$runtime/control.lock"
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash -c '. "$1"; service_control_acquire; a=$?; service_control_acquire; b=$?; service_state_write running 2; c=$?; service_admission_exclusive; d=$?; service_state_write running 2; e=$?; service_lease_release; service_control_release; printf "a=%s b=%s c=%s d=%s e=%s\\n" "$a" "$b" "$c" "$d" "$e"' \
        ash "$LIB" > "$SUITE_ROOT/s06.write" 2>&1
    assert_equal "$(cat "$SUITE_ROOT/s06.write")" 'a=0 b=1 c=1 d=0 e=0' \
        'S06 acquisition cannot overwrite FD7 and running publication requires X'
    assert_equal "$(cat "$runtime/state")" 'running:2' 'S06 atomic state publication has exactly canonical bytes'
    control_inode_before=$(ls -i "$runtime/control.lock" | awk '{print $1}')
    admission_inode_before=$(ls -i "$runtime/admission.lock" | awk '{print $1}')
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash -c '. "$1"; service_control_acquire; service_state_write stopped 2; rc=$?; service_control_release; printf "rc=%s\\n" "$rc"' ash "$LIB" > "$SUITE_ROOT/s06.stop" 2>&1
    assert_equal "$(cat "$SUITE_ROOT/s06.stop")" 'rc=0' 'S06 stopped publication needs control but not admission X'
    assert_equal "$(ls -i "$runtime/control.lock" | awk '{print $1}')" "$control_inode_before" \
        'S06 control lock inode survives state publish'
    assert_equal "$(ls -i "$runtime/admission.lock" | awk '{print $1}')" "$admission_inode_before" \
        'S06 admission lock inode survives state publish'

    cat > "$SUITE_ROOT/s06/control-holder.sh" <<'EOF'
#!/bin/ash
. "$1"
service_control_acquire || exit $?
printf '%s\n' "$$" > "$2"
while [ ! -e "$3" ]; do /bin/sleep 1; done
service_control_release
EOF
    chmod 700 "$SUITE_ROOT/s06/control-holder.sh"
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash "$SUITE_ROOT/s06/control-holder.sh" "$LIB" "$SUITE_ROOT/s06/holder-ready" "$SUITE_ROOT/s06/holder-release" &
    holder=$!
    wait_holder_ready "$SUITE_ROOT/s06/holder-ready" "$holder" 'S06 control holder' || return
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" /bin/ash -c '. "$1"; service_control_acquire; printf "rc=%s\\n" "$?"' ash "$LIB" > "$SUITE_ROOT/s06/contender" 2>&1 || :
    assert_equal "$(cat "$SUITE_ROOT/s06/contender")" 'rc=2' 'S06 controller contention returns nonblocking busy status'
    : > "$SUITE_ROOT/s06/holder-release"
    wait "$holder" || fail 'S06 control holder exits cleanly'
}

case_s11_atomic_publication_reader_contract() {
    begin_case S11 'a blocked real mv leaves every pre-release reader on the complete old record, while a truncate mutant is caught'
    runtime="$SUITE_ROOT/s11/runtime"
    rcdir="$SUITE_ROOT/s11/rc"
    init="$SUITE_ROOT/s11/init/outdoor-backup"
    fake_bin="$SUITE_ROOT/s11/fake-bin"
    mkdir -p "$SUITE_ROOT/s11" "$fake_bin"
    prepare_runtime "$runtime" "$rcdir" "$init"
    cat > "$fake_bin/mv" <<'EOF'
#!/bin/ash
if [ "$#" -eq 2 ] && [ "$2" = "${STATE_PUBLISH_PATH:-}" ]; then
    : > "$STATE_PUBLISH_READY" || exit 1
    attempts=0
    while [ ! -e "$STATE_PUBLISH_RELEASE" ]; do
        [ "$attempts" -lt 60 ] || {
            printf '%s\n' 'fake mv: release barrier timed out' >&2
            exit 1
        }
        /bin/sleep 1
        attempts=$((attempts + 1))
    done
fi
exec /bin/mv "$@"
EOF
    chmod 700 "$fake_bin/mv"
    cat > "$SUITE_ROOT/s11/writer.sh" <<'EOF'
#!/bin/ash
. "$1"
service_control_acquire || exit $?
service_admission_exclusive || { service_control_release; exit $?; }
service_state_write running 31
write_rc=$?
service_lease_release
lease_release_rc=$?
service_control_release
control_release_rc=$?
printf 'write=%s lease-release=%s control-release=%s\n' \
    "$write_rc" "$lease_release_rc" "$control_release_rc"
[ "$write_rc" -eq 0 ]
EOF
    chmod 700 "$SUITE_ROOT/s11/writer.sh"

    for trial in normal mutant; do
        trial_root="$SUITE_ROOT/s11/$trial"
        trial_runtime="$trial_root/runtime"
        mkdir -p "$trial_root" "$trial_runtime"
        printf 'stopped:30' > "$trial_runtime/state"
        : > "$trial_runtime/control.lock"
        : > "$trial_runtime/admission.lock"
        state_inode_before=$(ls -i "$trial_runtime/state" | awk '{print $1}')
        control_inode_before=$(ls -i "$trial_runtime/control.lock" | awk '{print $1}')
        admission_inode_before=$(ls -i "$trial_runtime/admission.lock" | awk '{print $1}')
        trial_library=$LIB
        if [ "$trial" = mutant ]; then
            trial_library="$trial_root/service-state-truncate-mutant.sh"
            awk '
                /^service_state_write\(\)/ { write_function = 1 }
                write_function && /^    if ! mv "\$SERVICE_STATE_TMP" "\$SERVICE_STATE_PATH"; then$/ {
                    print "    : > \"$SERVICE_STATE_PATH\" || { rm -f \"$SERVICE_STATE_TMP\"; return 1; }"
                }
                { print }
                write_function && /^}$/ { write_function = 0 }
            ' "$LIB" > "$trial_library"
            chmod 600 "$trial_library"
            assert_equal "$(grep -F -c ': > "$SERVICE_STATE_PATH" || { rm -f "$SERVICE_STATE_TMP"; return 1; }' "$trial_library")" 1 \
                'S11 mutant injects exactly one pre-rename direct truncate'
        fi
        ready="$trial_root/ready"
        release="$trial_root/release"
        PATH="$fake_bin:$PATH" STATE_PUBLISH_READY="$ready" STATE_PUBLISH_RELEASE="$release" \
            STATE_PUBLISH_PATH="$trial_runtime/state" OUTDOOR_BACKUP_SERVICE_DIR="$trial_runtime" \
            OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
            /bin/ash "$SUITE_ROOT/s11/writer.sh" "$trial_library" > "$trial_root/writer.stdout" \
            2> "$trial_root/writer.stderr" &
        writer_pid=$!
        wait_holder_ready "$ready" "$writer_pid" "S11 $trial writer" || return
        old_reads=0
        changed_reads=0
        invalid_reads=0
        read_count=0
        while [ "$read_count" -lt 8 ]; do
            assert_success "S11 $trial writer remains live during barrier reader $read_count" kill -0 "$writer_pid"
            observed=$(cat "$trial_runtime/state")
            case $observed in
                stopped:30) old_reads=$((old_reads + 1)) ;;
                running:31) changed_reads=$((changed_reads + 1)) ;;
                *) invalid_reads=$((invalid_reads + 1)) ;;
            esac
            read_count=$((read_count + 1))
        done
        pre_inode=$(ls -i "$trial_runtime/state" | awk '{print $1}')
        if [ "$trial" = normal ]; then
            assert_equal "$old_reads/$changed_reads/$invalid_reads/$read_count" '8/0/0/8' \
                'S11 normal barrier readers see only the complete old record'
        else
            assert_equal "$old_reads/$changed_reads/$invalid_reads/$read_count" '0/0/8/8' \
                'S11 negative control exposes only the injected early non-record'
        fi
        assert_equal "$pre_inode" "$state_inode_before" "S11 $trial barrier has not replaced the state inode"
        : > "$release"
        wait "$writer_pid" || writer_rc=$?
        writer_rc=${writer_rc:-0}
        writer_stdout=$(cat "$trial_root/writer.stdout")
        writer_stderr=$(cat "$trial_root/writer.stderr")
        assert_equal "$writer_rc" 0 "S11 $trial writer completes after bounded release"
        assert_equal "$writer_stdout" 'write=0 lease-release=0 control-release=0' \
            "S11 $trial writer reports a complete real state publication"
        assert_equal "$writer_stderr" '' "S11 $trial writer has no fixture or tool error"
        assert_equal "$(cat "$trial_runtime/state")" 'running:31' "S11 $trial release publishes the complete new record"
        state_inode_after=$(ls -i "$trial_runtime/state" | awk '{print $1}')
        assert_success "S11 $trial real mv replaces the state inode after release" test "$state_inode_after" != "$state_inode_before"
        assert_equal "$(ls -i "$trial_runtime/control.lock" | awk '{print $1}')" "$control_inode_before" \
            "S11 $trial control lock inode remains stable"
        assert_equal "$(ls -i "$trial_runtime/admission.lock" | awk '{print $1}')" "$admission_inode_before" \
            "S11 $trial admission lock inode remains stable"
        printf 'S11 %s rc=%s reads=%s/%s/%s/%s stdout=%s stderr=[%s]\n' \
            "$trial" "$writer_rc" "$old_reads" "$changed_reads" "$invalid_reads" "$read_count" \
            "$writer_stdout" "$writer_stderr"
    done
}

case_s07_state_change_and_fd_preoccupation() {
    begin_case S07 'lease-current sees stopped/epoch changes without implicit release and FD8 preoccupation is untouched'
    runtime="$SUITE_ROOT/s07/runtime"
    rcdir="$SUITE_ROOT/s07/rc"
    init="$SUITE_ROOT/s07/init/outdoor-backup"
    mkdir -p "$SUITE_ROOT/s07"
    prepare_runtime "$runtime" "$rcdir" "$init"
    write_state "$runtime" 'running:11\n'
    write_lease_current_driver "$SUITE_ROOT/s07/current-driver.sh"
    for changed_record in 'stopped:11' 'running:12'; do
        printf '%s\n' "$changed_record" > "$SUITE_ROOT/s07/changed-record"
        OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
            /bin/ash "$SUITE_ROOT/s07/current-driver.sh" "$LIB" "$changed_record" \
            > "$SUITE_ROOT/s07/normal-${changed_record#*:}.stdout" \
            2> "$SUITE_ROOT/s07/normal-${changed_record#*:}.stderr"
        normal_rc=$?
        normal_stdout=$(cat "$SUITE_ROOT/s07/normal-${changed_record#*:}.stdout")
        normal_stderr=$(cat "$SUITE_ROOT/s07/normal-${changed_record#*:}.stderr")
        assert_equal "$normal_rc" 0 "S07 $changed_record normal lease-current driver passes its one X-lock contract"
        assert_equal "$normal_stdout" \
            'lease=0 current=2 held=1 gen=11 fd-open=1 fd-read=1 before=2 release=0 after=0 checks=1 failed=0' \
            "S07 $changed_record keeps the original READ lease and metadata until explicit release"
        assert_equal "$normal_stderr" '' "S07 $changed_record normal driver reports no fixture or tool error"
        printf 'S07 normal record=%s rc=%s stdout=%s stderr=[%s]\n' \
            "$changed_record" "$normal_rc" "$normal_stdout" "$normal_stderr"
        write_state "$runtime" 'running:11\n'
    done

    mutant_lib="$SUITE_ROOT/s07/service-state-current-release-mutant.sh"
    awk '
        /^service_lease_current\(\)/ { current = 1 }
        current && /^    return 2$/ {
            print "    service_lease_release || return 1"
        }
        { print }
        current && /^}$/ { current = 0 }
    ' "$LIB" > "$mutant_lib"
    chmod 600 "$mutant_lib"
    assert_success 'S07 mutant library is a complete copy with only current mismatch release injected' \
        grep -F -q 'service_lease_release || return 1' "$mutant_lib"
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash "$SUITE_ROOT/s07/current-driver.sh" "$mutant_lib" stopped:11 \
        > "$SUITE_ROOT/s07/mutant.stdout" 2> "$SUITE_ROOT/s07/mutant.stderr" || mutant_rc=$?
    mutant_rc=${mutant_rc:-0}
    mutant_stdout=$(cat "$SUITE_ROOT/s07/mutant.stdout")
    mutant_stderr=$(cat "$SUITE_ROOT/s07/mutant.stderr")
    assert_equal "$mutant_rc" 1 'S07 negative control fails its pre-explicit-release X-lock contract'
    assert_equal "$mutant_stdout" \
        'lease=0 current=2 held=0 gen= fd-open=0 fd-read=0 before=0 release=0 after=0 checks=1 failed=1' \
        'S07 mutant proof shows only the injected implicit release made X available early'
    assert_equal "$mutant_stderr" '' 'S07 mutant has no fixture or tool failure diagnostic'
    printf 'S07 mutant record=stopped:11 rc=%s stdout=%s stderr=[%s]\n' \
        "$mutant_rc" "$mutant_stdout" "$mutant_stderr"
    write_state "$runtime" 'running:11\n'
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" /bin/ash -c 'exec 8> "$1"; before=$(readlink /proc/self/fd/8); . "$2"; service_lease_acquire; rc=$?; service_lease_release; release_rc=$?; after=$(readlink /proc/self/fd/8); printf "rc=%s release=%s before=%s after=%s\\n" "$rc" "$release_rc" "$before" "$after"' ash \
        "$SUITE_ROOT/s07/caller-owned-fd8" "$LIB" > "$SUITE_ROOT/s07/fd8" 2>&1 || :
    assert_success 'S07 FD8 preoccupation returns environment failure' grep -F -q 'rc=1 release=0 ' "$SUITE_ROOT/s07/fd8"
    before_target=$(sed -n 's/^rc=1 release=0 before=\([^ ]*\) after=.*/\1/p' "$SUITE_ROOT/s07/fd8")
    after_target=$(sed -n 's/^.* after=\(.*\)$/\1/p' "$SUITE_ROOT/s07/fd8")
    assert_equal "$after_target" "$before_target" 'S07 unheld acquire and release never overwrite or close caller FD8'
}

case_s09_fd_identity_lifecycle() {
    begin_case S09 'owner validation binds FD identity and flock mode, rejects loss or reuse, and clears metadata only after a valid parent release'
    runtime="$SUITE_ROOT/s09/runtime"
    rcdir="$SUITE_ROOT/s09/rc"
    init="$SUITE_ROOT/s09/init/outdoor-backup"
    mkdir -p "$SUITE_ROOT/s09"
    prepare_runtime "$runtime" "$rcdir" "$init"
    write_state "$runtime" 'stopped:20\n'
    printf 'unrelated-control\n' > "$SUITE_ROOT/s09/unrelated-control"
    printf 'unrelated-admission\n' > "$SUITE_ROOT/s09/unrelated-admission"
    cat > "$SUITE_ROOT/s09/reused-fd-holder.sh" <<'EOF'
#!/bin/ash
. "$1"
service_control_acquire || exit $?
service_admission_exclusive || exit $?
exec 7>&-
exec 7> "$2"
exec 8>&-
exec 8> "$3"
service_state_write running 21
write_rc=$?
service_control_owner
control_owner_rc=$?
service_lease_owner
lease_owner_rc=$?
service_control_release
control_release_rc=$?
service_lease_release
lease_release_rc=$?
[ -e /proc/self/fd/7 ] && control_unrelated_open=1 || control_unrelated_open=0
[ -e /proc/self/fd/8 ] && lease_unrelated_open=1 || lease_unrelated_open=0
printf 'write=%s control-owner=%s lease-owner=%s control-release=%s lease-release=%s fd7=%s fd8=%s state=%s\n' \
    "$write_rc" "$control_owner_rc" "$lease_owner_rc" "$control_release_rc" "$lease_release_rc" \
    "$control_unrelated_open" "$lease_unrelated_open" "$(cat "$OUTDOOR_BACKUP_SERVICE_DIR/state")" > "$4"
: > "$5"
while [ ! -e "$6" ]; do /bin/sleep 1; done
EOF
    chmod 700 "$SUITE_ROOT/s09/reused-fd-holder.sh"
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash "$SUITE_ROOT/s09/reused-fd-holder.sh" "$LIB" "$SUITE_ROOT/s09/unrelated-control" \
        "$SUITE_ROOT/s09/unrelated-admission" "$SUITE_ROOT/s09/reused-result" "$SUITE_ROOT/s09/reused-ready" \
        "$SUITE_ROOT/s09/reused-release" > "$SUITE_ROOT/s09/reused-raw" 2>&1 &
    reused_holder=$!
    wait_holder_ready "$SUITE_ROOT/s09/reused-ready" "$reused_holder" 'S09 reused-FD holder' || return
    assert_equal "$(cat "$SUITE_ROOT/s09/reused-result")" \
        'write=1 control-owner=1 lease-owner=1 control-release=1 lease-release=1 fd7=1 fd8=1 state=stopped:20' \
        'S09 closed and reused FDs fail closed, preserve state, and never close unrelated FDs'
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" /bin/ash -c \
        '. "$1"; service_control_acquire; control=$?; service_admission_exclusive; admission=$?; service_lease_release; service_control_release; printf "control=%s admission=%s\\n" "$control" "$admission"' \
        ash "$LIB" > "$SUITE_ROOT/s09/reused-contender" 2>&1
    assert_equal "$(cat "$SUITE_ROOT/s09/reused-contender")" 'control=0 admission=0' \
        'S09 competitors acquire the original locks after their owner closed them'
    assert_equal "$(cat "$runtime/state")" 'stopped:20' 'S09 rejected write leaves the old state record unchanged'
    : > "$SUITE_ROOT/s09/reused-release"
    wait "$reused_holder" || fail 'S09 reused-FD holder exits after release'

    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash -c \
        '. "$1"; service_control_acquire; service_admission_exclusive; flock -u 7; flock -u 8; service_state_write running 22; write=$?; service_control_owner; control=$?; service_lease_owner; lease=$?; service_control_release; control_release=$?; service_lease_release; lease_release=$?; printf "write=%s control=%s lease=%s control-release=%s lease-release=%s\\n" "$write" "$control" "$lease" "$control_release" "$lease_release"' \
        ash "$LIB" > "$SUITE_ROOT/s09/unlocked" 2>&1 || :
    assert_equal "$(cat "$SUITE_ROOT/s09/unlocked")" 'write=1 control=1 lease=1 control-release=1 lease-release=1' \
        'S09 same inode with explicit flock unlock fails owner and state-write checks'
    assert_equal "$(cat "$runtime/state")" 'stopped:20' 'S09 explicit unlock rejection leaves state unchanged'

    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash -c \
        '. "$1"; service_control_acquire; control_acquire=$?; service_admission_exclusive; admission_acquire=$?; service_lease_release; lease_release=$?; service_control_release; control_release=$?; printf "acquire=%s/%s release=%s/%s control-held=%s control-owner=%s lease-held=%s lease-owner=%s lease-type=%s lease-gen=%s\\n" "$control_acquire" "$admission_acquire" "$lease_release" "$control_release" "${SERVICE_CONTROL_HELD:-}" "${SERVICE_CONTROL_OWNER_PID:-}" "${SERVICE_LEASE_HELD:-}" "${SERVICE_LEASE_OWNER_PID:-}" "${SERVICE_LEASE_TYPE:-}" "${SERVICE_LEASE_GENERATION:-}"' \
        ash "$LIB" > "$SUITE_ROOT/s09/valid-release" 2>&1
    assert_equal "$(cat "$SUITE_ROOT/s09/valid-release")" 'acquire=0/0 release=0/0 control-held=0 control-owner= lease-held=0 lease-owner= lease-type= lease-gen=' \
        'S09 valid parent release closes locks and clears all owner metadata'
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" /bin/ash -c \
        '. "$1"; service_control_acquire; control=$?; service_admission_exclusive; admission=$?; service_lease_release; service_control_release; printf "control=%s admission=%s\\n" "$control" "$admission"' \
        ash "$LIB" > "$SUITE_ROOT/s09/released-contender" 2>&1
    assert_equal "$(cat "$SUITE_ROOT/s09/released-contender")" 'control=0 admission=0' \
        'S09 a contender takes both locks after valid parent release'
}

case_s10_flock_failure_classification() {
    begin_case S10 'flock reports only silent nonblocking contention as busy and exposes operational failures'
    runtime="$SUITE_ROOT/s10/runtime"
    rcdir="$SUITE_ROOT/s10/rc"
    init="$SUITE_ROOT/s10/init/outdoor-backup"
    fake_bin="$SUITE_ROOT/s10/fake-bin"
    mkdir -p "$SUITE_ROOT/s10" "$fake_bin"
    prepare_runtime "$runtime" "$rcdir" "$init"
    cat > "$fake_bin/flock" <<'EOF'
#!/bin/ash
case ${FLOCK_TEST_MODE:-} in
    rc73) printf '%s\n' 'test flock: operational failure' >&2; exit 73 ;;
    stderr1) printf '%s\n' 'test flock: bad descriptor' >&2; exit 1 ;;
    *) exit 99 ;;
esac
EOF
    chmod 700 "$fake_bin/flock"
    cat > "$SUITE_ROOT/s10/holder.sh" <<'EOF'
#!/bin/ash
exec 9<> "$1" || exit 1
flock "$2" 9 || exit 1
: > "$3"
while [ ! -e "$4" ]; do /bin/sleep 1; done
EOF
    chmod 700 "$SUITE_ROOT/s10/holder.sh"

    for failure_mode in rc73 stderr1; do
        for acquire in service_control_acquire service_lease_acquire service_admission_exclusive; do
            output="$SUITE_ROOT/s10/$failure_mode-$acquire"
            OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" \
                OUTDOOR_BACKUP_INIT_SCRIPT="$init" PATH="$fake_bin:$PATH" FLOCK_TEST_MODE="$failure_mode" \
                /bin/ash -c '. "$1"; "$2"; rc=$?; [ -e /proc/self/fd/7 ] && fd7=1 || fd7=0; [ -e /proc/self/fd/8 ] && fd8=1 || fd8=0; printf "rc=%s fd7=%s fd8=%s control=%s lease=%s\\n" "$rc" "$fd7" "$fd8" "${SERVICE_CONTROL_HELD:-0}" "${SERVICE_LEASE_HELD:-0}"' \
                ash "$LIB" "$acquire" > "$output" 2>&1 || :
            assert_success "S10 $acquire $failure_mode returns environment failure" \
                grep -F -q 'rc=1 fd7=0 fd8=0 control=0 lease=0' "$output"
            assert_success "S10 $acquire $failure_mode keeps original flock diagnostic" \
                grep -F -q 'test flock:' "$output"
            assert_success "S10 $acquire $failure_mode emits static acquisition error" \
                grep -F -q 'service-state: flock acquisition failed' "$output"
        done
    done

    for contention_spec in \
        'control.lock -x service_control_acquire' \
        'admission.lock -x service_lease_acquire' \
        'admission.lock -s service_admission_exclusive'; do
        set -- $contention_spec
        lock_path="$runtime/$1"
        holder_mode=$2
        acquire=$3
        ready="$SUITE_ROOT/s10/real-$acquire-ready"
        release="$SUITE_ROOT/s10/real-$acquire-release"
        output="$SUITE_ROOT/s10/real-$acquire"
        rm -f "$ready" "$release"
        /bin/ash "$SUITE_ROOT/s10/holder.sh" "$lock_path" "$holder_mode" "$ready" "$release" &
        holder=$!
        wait_holder_ready "$ready" "$holder" "S10 real $acquire holder" || return
        OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
            /bin/ash -c '. "$1"; "$2"; rc=$?; service_lease_release; service_control_release; printf "rc=%s\\n" "$rc"' \
            ash "$LIB" "$acquire" > "$output" 2>&1 || :
        assert_equal "$(cat "$output")" 'rc=2' "S10 real BusyBox $acquire contention returns busy"
        : > "$release"
        wait "$holder" || fail "S10 real $acquire holder exits cleanly"
    done
}

case_s08_guard_exit_releases_before_timer_child() {
    begin_case S08 'caller-owned EXIT trap can explicitly release inherited lock before a live LED-style timer child outlives parent'
    runtime="$SUITE_ROOT/s08/runtime"
    rcdir="$SUITE_ROOT/s08/rc"
    init="$SUITE_ROOT/s08/init/outdoor-backup"
    mkdir -p "$SUITE_ROOT/s08"
    prepare_runtime "$runtime" "$rcdir" "$init"
    write_state "$runtime" 'running:12\n'
    cat > "$SUITE_ROOT/s08/guard.sh" <<'EOF'
#!/bin/ash
. "$1"
service_lease_acquire 12 || exit $?
( while :; do /bin/sleep 1; done ) &
printf '%s\n' "$!" > "$2"
trap 'service_lease_release' EXIT
exit 23
EOF
    chmod 700 "$SUITE_ROOT/s08/guard.sh"
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" OUTDOOR_BACKUP_RC_DIR="$rcdir" OUTDOOR_BACKUP_INIT_SCRIPT="$init" \
        /bin/ash "$SUITE_ROOT/s08/guard.sh" "$LIB" "$SUITE_ROOT/s08/timer-pid" > "$SUITE_ROOT/s08/guard.out" 2>&1 || guard_rc=$?
    guard_rc=${guard_rc:-0}
    timer_pid=$(cat "$SUITE_ROOT/s08/timer-pid")
    assert_equal "$guard_rc" 23 'S08 simulated guard failure returns while timer child stays alive'
    assert_success 'S08 timer child is live evidence, not a mock' kill -0 "$timer_pid"
    OUTDOOR_BACKUP_SERVICE_DIR="$runtime" /bin/ash -c '. "$1"; service_admission_exclusive; printf "rc=%s\\n" "$?"; service_lease_release' ash "$LIB" > "$SUITE_ROOT/s08/x" 2>&1
    assert_equal "$(cat "$SUITE_ROOT/s08/x")" 'rc=0' 'S08 parent explicit release permits controller X despite timer child'
    kill "$timer_pid" 2>/dev/null || :
    wait "$timer_pid" 2>/dev/null || :
}

main() {
    trap 'rm -rf "$SUITE_ROOT"' EXIT INT TERM
    mkdir -p "$SUITE_ROOT"
    assert_regular "$LIB" 'precondition: delivered service-state library exists'
    [ "$FAILED" -eq 0 ] || exit 1
    case_s01_source_is_inert
    case_s02_strict_state_records
    case_s03_rc_fallback_and_precedence
    case_s04_lease_admission
    case_s05_owner_and_subshell_release
    case_s06_control_write_and_inode_stability
    case_s07_state_change_and_fd_preoccupation
    case_s08_guard_exit_releases_before_timer_child
    case_s09_fd_identity_lifecycle
    case_s10_flock_failure_classification
    case_s11_atomic_publication_reader_contract
    assert_equal "$CASES" 11 'all BDD behavior groups executed'
    assert_equal "$ASSERTIONS" 152 'all BDD assertions executed exactly'
    printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
    [ "$FAILED" -eq 0 ]
}

main "$@"

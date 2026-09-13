#!/bin/sh
#
# BDD tests for the anchored source filesystem identity record.
# The host entry point replaces itself with the pinned OpenWrt rootfs. The
# target tmpfs and FD 9 anchor are real; block output and failure seams are
# isolated fixtures.
#
set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 --network bridge \
        --cap-add SYS_ADMIN --security-opt seccomp=unconfined --tmpfs /tmp:rw,exec \
        -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-card-identity.sh --inside
fi

[ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || {
    printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
    exit 1
}

mkdir -p /var/lock || { printf '%s\n' 'FAIL: cannot create OpenWrt package lock directory' >&2; exit 1; }
opkg update >/dev/null || { printf '%s\n' 'FAIL: cannot refresh OpenWrt package metadata' >&2; exit 1; }
opkg install jq >/dev/null || { printf '%s\n' 'FAIL: cannot install jq in pinned OpenWrt rootfs' >&2; exit 1; }

REPO_ROOT=/src
TARGET_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/target.sh"
GETTER_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/target-device.sh"
COMMON_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/common.sh"
IDENTITY_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/card-identity.sh"
TEST_ROOT="/tmp/outdoor-backup-card-identity.$$"
TARGET_MOUNT="$TEST_ROOT/target"
BIN="$TEST_ROOT/bin"
SOURCE_NODE=/dev/sda1
CARD_A=550e8400-e29b-41d4-a716-446655440000
CARD_B=660e8400-e29b-41d4-a716-446655440000
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
        fail "$message (exists=[$path])"
    fi
}

assert_present() {
    path=$1
    message=$2
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ ! -e "$path" ]; then
        fail "$message (missing=[$path])"
    fi
}

record_path() {
    printf '%s\n' "$TARGET_MOUNT/backups/.card-identities/$1.json"
}

mount_target() {
    mkdir -p "$TARGET_MOUNT"
    mount -t tmpfs -o rw,size=1m tmpfs "$TARGET_MOUNT"
}

unmount_target() {
    umount "$TARGET_MOUNT" 2>/dev/null || :
}

prepare_bin() {
    mkdir -p "$BIN"
    cat > "$BIN/block" <<'EOF'
#!/bin/sh
case "${TEST_BLOCK_MODE:-ok}:$2" in
    ok:/dev/sda1)
        printf '%s: UUID="%s" TYPE="vfat"\n' "$2" "$TEST_SOURCE_UUID"
        ;;
    wrong-node:/dev/sda1)
        printf '%s: UUID="%s" TYPE="vfat"\n' /dev/sdb1 "$TEST_SOURCE_UUID"
        ;;
    fail:*) exit 1 ;;
    *) printf '%s: UUID="%s" TYPE="vfat"\n' /dev/sdb1 "$TEST_SOURCE_UUID" ;;
esac
EOF
    cat > "$BIN/mktemp" <<'EOF'
#!/bin/sh
[ "${TEST_IDENTITY_MKTEMP_FAIL:-0}" = 1 ] && exit 1
exec /bin/mktemp "$@"
EOF
    cat > "$BIN/jq" <<'EOF'
#!/bin/sh
if [ "${TEST_IDENTITY_JQ_FAIL:-0}" = 1 ] && [ "$1" = -n ]; then
    exit 1
fi
exec /usr/bin/jq "$@"
EOF
    cat > "$BIN/mv" <<'EOF'
#!/bin/sh
[ "${TEST_IDENTITY_MV_FAIL:-0}" = 1 ] && exit 1
exec /bin/mv "$@"
EOF
    cat > "$BIN/sync" <<'EOF'
#!/bin/sh
[ "${TEST_IDENTITY_SYNC_FAIL:-0}" = 1 ] && exit 1
exec /bin/sync "$@"
EOF
    chmod 755 "$BIN"/*
}

reset_case() {
    target_close >/dev/null 2>&1 || :
    unmount_target
    rm -rf "$TEST_ROOT"
    mkdir -p "$TEST_ROOT"
    TARGET_MOUNT="$TEST_ROOT/target"
    BIN="$TEST_ROOT/bin"
    mount_target || return 1
    prepare_bin
    TEST_BLOCK_MODE=ok
    TEST_SOURCE_UUID=ABCD-1234
    export TEST_BLOCK_MODE TEST_SOURCE_UUID
    PATH="$BIN:$PATH"
    export PATH
    target_open "$TARGET_MOUNT" || return 1
    target_prepare_root "$TARGET_MOUNT/backups" || return 1
}

run_bind() {
    source_uuid=$(card_identity_read_source_uuid "$SOURCE_NODE") || return 1
    card_identity_bind "$CARD_A" "$source_uuid"
}

record_hash() {
    sha256sum "$(record_path "$1")" | awk '{print $1}'
}

case_i01_first_bind_and_idempotence() {
    begin_case I01 'first source observation publishes exact JSON and same source is read-only idempotent'
    reset_case || { fail 'I01 fixture setup failed'; return; }
    assert_success 'I01 first bind succeeds' run_bind
    assert_success 'I01 record exists' test -f "$(record_path "$CARD_A")"
    assert_success 'I01 record is exactly v1 contract' jq -e \
        --arg sd "$CARD_A" --arg fs abcd-1234 \
        'keys == ["fs_uuid", "sd_uuid", "version"] and .version == 1 and .sd_uuid == $sd and .fs_uuid == $fs' \
        "$(record_path "$CARD_A")"
    first_hash=$(record_hash "$CARD_A")
    assert_success 'I01 same source bind succeeds again' run_bind
    assert_equal "$(record_hash "$CARD_A")" "$first_hash" 'I01 same source does not rewrite record'
}

case_i02_independent_cards_and_source_forms() {
    begin_case I02 'different card UUIDs are independent and accepted source UUID forms normalize'
    reset_case || { fail 'I02 fixture setup failed'; return; }
    for source_uuid in A1B2C3D4 1234-ABCD-5678 550E8400-E29B-41D4-A716-446655440000; do
        TEST_SOURCE_UUID=$source_uuid
        export TEST_SOURCE_UUID
        source_uuid=$(card_identity_read_source_uuid "$SOURCE_NODE") || { fail 'I02 fixture getter failed'; continue; }
        assert_success "I02 accepts [$source_uuid]" card_identity_bind "$CARD_B" "$source_uuid"
        rm -f "$(record_path "$CARD_B")"
    done
    TEST_SOURCE_UUID=ABCD-1234
    export TEST_SOURCE_UUID
    assert_success 'I02 card A bind succeeds' run_bind
    source_uuid=$(card_identity_read_source_uuid "$SOURCE_NODE") || return
    assert_success 'I02 card B bind succeeds' card_identity_bind "$CARD_B" "$source_uuid"
    assert_present "$(record_path "$CARD_A")" 'I02 card A record survives card B bind'
    assert_present "$(record_path "$CARD_B")" 'I02 card B gets a separate record'
}

case_i03_conflict_and_legacy_preservation() {
    begin_case I03 'conflict and legacy first bind preserve existing target and alias bytes'
    reset_case || { fail 'I03 fixture setup failed'; return; }
    assert_success 'I03 initial bind succeeds' run_bind
    mkdir -p "$TARGET_MOUNT/backups/$CARD_A"
    printf '%s\n' target-sentinel > "$TARGET_MOUNT/backups/$CARD_A/data"
    printf '%s\n' alias-sentinel > "$TARGET_MOUNT/aliases-copy"
    record_before=$(record_hash "$CARD_A")
    target_before=$(sha256sum "$TARGET_MOUNT/backups/$CARD_A/data" | awk '{print $1}')
    alias_before=$(sha256sum "$TARGET_MOUNT/aliases-copy" | awk '{print $1}')
    TEST_SOURCE_UUID=DIFFERENT-9
    export TEST_SOURCE_UUID
    assert_failure 'I03 different source conflicts' run_bind
    assert_equal "$(record_hash "$CARD_A")" "$record_before" 'I03 conflict retains record'
    assert_equal "$(sha256sum "$TARGET_MOUNT/backups/$CARD_A/data" | awk '{print $1}')" "$target_before" 'I03 conflict retains target files'
    assert_equal "$(sha256sum "$TARGET_MOUNT/aliases-copy" | awk '{print $1}')" "$alias_before" 'I03 conflict retains alias bytes'
    rm "$(record_path "$CARD_A")"
    TEST_SOURCE_UUID=ABCD-1234
    export TEST_SOURCE_UUID
    assert_success 'I03 legacy directory receives first binding without migration' run_bind
    assert_equal "$(cat "$TARGET_MOUNT/backups/$CARD_A/data")" target-sentinel 'I03 legacy data remains'
    assert_equal "$(cat "$TARGET_MOUNT/aliases-copy")" alias-sentinel 'I03 legacy alias remains'
}

case_i04_rejects_unknown_and_bad_records() {
    begin_case I04 'getter failures and malformed formal records fail closed without replacement'
    reset_case || { fail 'I04 fixture setup failed'; return; }
    for mode in fail wrong-node; do
        TEST_BLOCK_MODE=$mode
        export TEST_BLOCK_MODE
        assert_failure "I04 getter [$mode] rejects" run_bind
        assert_absent "$(record_path "$CARD_A")" "I04 getter [$mode] writes no record"
    done
    TEST_BLOCK_MODE=ok
    export TEST_BLOCK_MODE
    identity_dir=$(dirname "$(record_path "$CARD_A")")
    mkdir -p "$identity_dir"
    for record in \
        '{"version":2,"sd_uuid":"550e8400-e29b-41d4-a716-446655440000","fs_uuid":"abcd-1234"}' \
        '{"version":1,"sd_uuid":"660e8400-e29b-41d4-a716-446655440000","fs_uuid":"abcd-1234"}' \
        '{"version":1,"sd_uuid":"550e8400-e29b-41d4-a716-446655440000}' \
        '{"version":1,"sd_uuid":"550e8400-e29b-41d4-a716-446655440000","fs_uuid":"bad value"}' \
        '{"version":1,"sd_uuid":"550e8400-e29b-41d4-a716-446655440000","fs_uuid":"abcd-1234","extra":true}' \
        '{"version":1,"sd_uuid":"550e8400-e29b-41d4-a716-446655440000","fs_uuid":"abcd-1234\n"}' \
        '{"version":1,"sd_uuid":"550e8400-e29b-41d4-a716-446655440000","fs_uuid":"abcd-1234\n\n"}' \
        '{"version":1,"sd_uuid":"550e8400-e29b-41d4-a716-446655440000","fs_uuid":"abcd-1234\r"}'; do
        printf '%s\n' "$record" > "$(record_path "$CARD_A")"
        before=$(record_hash "$CARD_A")
        assert_failure 'I04 malformed record rejects' run_bind
        assert_equal "$(record_hash "$CARD_A")" "$before" 'I04 malformed record is never replaced'
    done
    : > "$(record_path "$CARD_A")"
    before=$(record_hash "$CARD_A")
    assert_failure 'I04 empty record rejects' run_bind
    assert_equal "$(record_hash "$CARD_A")" "$before" 'I04 empty record is never replaced'
    printf '%s\n%s\n' \
        '{"version":1,"sd_uuid":"550e8400-e29b-41d4-a716-446655440000","fs_uuid":"abcd-1234"}' \
        '{"version":2,"sd_uuid":"550e8400-e29b-41d4-a716-446655440000","fs_uuid":"abcd-1234"}' \
        > "$(record_path "$CARD_A")"
    before=$(record_hash "$CARD_A")
    assert_failure 'I04 multiple JSON documents reject' run_bind
    assert_equal "$(record_hash "$CARD_A")" "$before" 'I04 multiple documents are never replaced'
    rm -f "$(record_path "$CARD_A")"
    ln -s "$identity_dir/missing" "$(record_path "$CARD_A")"
    assert_failure 'I04 symbolic record rejects' run_bind
    rm -f "$(record_path "$CARD_A")"
    mkdir "$(record_path "$CARD_A")"
    assert_failure 'I04 directory record rejects' run_bind
}

case_i06_mutation_proves_schema_condition_matters() {
    begin_case I06 'removing the version condition lets the version-only defect evade validation'
    reset_case || { fail 'I06 fixture setup failed'; return; }
    identity_dir=$(dirname "$(record_path "$CARD_A")")
    mkdir -p "$identity_dir"
    printf '%s\n' \
        '{"version":2,"sd_uuid":"550e8400-e29b-41d4-a716-446655440000","fs_uuid":"abcd-1234"}' \
        > "$(record_path "$CARD_A")"
    mutated_identity="$TEST_ROOT/card-identity-version-mutated.sh"
    cp "$IDENTITY_SCRIPT" "$mutated_identity"
    sed -i 's/(.version == 1 and (.version | type == "number")) and//' "$mutated_identity"
    # shellcheck disable=SC1090
    . "$mutated_identity"
    assert_success 'I06 version-condition mutation accepts the version-only defect' run_bind
}

case_i05_write_failures_and_anchor_health() {
    begin_case I05 'creation, serialization, publication and unhealthy-anchor failures leave no formal record'
    for failure_var in TEST_IDENTITY_MKTEMP_FAIL TEST_IDENTITY_JQ_FAIL TEST_IDENTITY_MV_FAIL TEST_IDENTITY_SYNC_FAIL; do
        reset_case || { fail 'I05 fixture setup failed'; return; }
        eval "$failure_var=1"
        export "$failure_var"
        assert_failure "I05 [$failure_var] rejects" run_bind
        unset "$failure_var"
        if [ "$failure_var" = TEST_IDENTITY_SYNC_FAIL ]; then
            assert_present "$(record_path "$CARD_A")" \
                'I05 sync failure leaves only the published formal record'
        else
            assert_absent "$(record_path "$CARD_A")" "I05 [$failure_var] publishes no record"
        fi
        leftovers=$(find "$(dirname "$(record_path "$CARD_A")")" -maxdepth 1 -name ".${CARD_A}.json.*" -print | wc -l)
        assert_equal "$leftovers" 0 "I05 [$failure_var] cleans only its temporary record"
    done
    reset_case || { fail 'I05 detached fixture setup failed'; return; }
    assert_success 'I05 lazy detach target' umount -l "$TARGET_MOUNT"
    assert_failure 'I05 detached target rejects before record creation' run_bind
    assert_absent "$(record_path "$CARD_A")" 'I05 detached target does not write naked lower directory'

    reset_case || { fail 'I05 read-only fixture setup failed'; return; }
    assert_success 'I05 remounts target read-only' /bin/mount -o remount,ro "$TARGET_MOUNT"
    assert_failure 'I05 read-only target rejects before record creation' run_bind
    assert_absent "$(record_path "$CARD_A")" 'I05 read-only target does not write identity data'

    reset_case || { fail 'I05 closed fixture setup failed'; return; }
    target_close
    assert_success 'I05 unmounts closed target' /bin/umount "$TARGET_MOUNT"
    assert_failure 'I05 closed target rejects before record creation' run_bind
    assert_absent "$(record_path "$CARD_A")" 'I05 closed target does not write lower directory'
}

main() {
    trap 'target_close >/dev/null 2>&1 || :; unmount_target; rm -rf "$TEST_ROOT"' EXIT INT TERM
    [ -r "$TARGET_SCRIPT" ] && [ -r "$GETTER_SCRIPT" ] && [ -r "$COMMON_SCRIPT" ] && \
        [ -r "$IDENTITY_SCRIPT" ] || {
            printf '%s\n' 'FAIL: required delivered identity sources are absent' >&2
            exit 1
        }
    # shellcheck disable=SC1090
    . "$TARGET_SCRIPT"
    # shellcheck disable=SC1090
    . "$GETTER_SCRIPT"
    # shellcheck disable=SC1090
    . "$COMMON_SCRIPT"
    # shellcheck disable=SC1090
    . "$IDENTITY_SCRIPT"
    case_i01_first_bind_and_idempotence
    case_i02_independent_cards_and_source_forms
    case_i03_conflict_and_legacy_preservation
    case_i04_rejects_unknown_and_bad_records
    case_i05_write_failures_and_anchor_health
    case_i06_mutation_proves_schema_condition_matters
    assert_equal "$CASES" 6 'all required cases executed'
    assert_equal "$ASSERTIONS" 69 'all required assertions executed'
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

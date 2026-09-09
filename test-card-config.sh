#!/bin/sh
# BDD tests for the shipped, data-only SD card configuration reader.
set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"
if [ "${1:-}" != "--inside" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 --network none --read-only \
        --tmpfs /tmp:rw,exec -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-card-config.sh --inside
fi
[ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || {
    printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2; exit 1;
}

COMMON=/src/files/opt/outdoor-backup/scripts/common.sh
CARD_CONFIG=/src/files/opt/outdoor-backup/scripts/card-config.sh
TEST_ROOT="/tmp/outdoor-backup-card-config.$$"
CARD_FILE="$TEST_ROOT/FieldBackup.conf"
VALID_UUID=550e8400-e29b-41d4-a716-446655440000
INITIAL_PATH=$PATH
CASES=0 ASSERTIONS=0 FAILED=0

fail() { printf 'FAIL: %s\n' "$1" >&2; FAILED=$((FAILED + 1)); }
begin_case() { CASES=$((CASES + 1)); printf 'CASE %s: %s\n' "$1" "$2"; }
assert_success() { message=$1; shift; ASSERTIONS=$((ASSERTIONS + 1)); "$@" || fail "$message"; }
assert_failure() { message=$1; shift; ASSERTIONS=$((ASSERTIONS + 1)); "$@" && fail "$message"; }
assert_equal() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ "$1" = "$2" ] || fail "$3 (expected=[$2], actual=[$1])"
}
assert_absent() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "$2 (exists=[$1])"
}
write_card() { printf '%s\n' "$1" > "$CARD_FILE"; }
set_runtime_sentinels() {
    SD_UUID=old-uuid BACKUP_MODE=OLD CREATED_AT=old-created SD_NAME=old-name
    TARGET_FD_ROOT=/proc/sentinel/fd/9
    TARGET_BACKUP_ROOT=/proc/sentinel/fd/9/backups
    TARGET_UUID=TARGET-OLD TARGET_SYSFS_ROOT=/sentinel/sys
    PATH=$INITIAL_PATH IFS=' '
}
assert_runtime_sentinels() {
    assert_equal "$TARGET_FD_ROOT" /proc/sentinel/fd/9 "$1 keeps TARGET_FD_ROOT"
    assert_equal "$TARGET_BACKUP_ROOT" /proc/sentinel/fd/9/backups "$1 keeps TARGET_BACKUP_ROOT"
    assert_equal "$TARGET_UUID" TARGET-OLD "$1 keeps TARGET_UUID"
    assert_equal "$TARGET_SYSFS_ROOT" /sentinel/sys "$1 keeps TARGET_SYSFS_ROOT"
    assert_equal "$PATH" "$INITIAL_PATH" "$1 keeps PATH"
    assert_equal "$IFS" ' ' "$1 keeps IFS"
}

case_c01_literals_and_unknowns() {
    begin_case C01 'reader accepts literals and ignores unknown assignments'
    set_runtime_sentinels
    write_card "SD_UUID=$VALID_UUID
BACKUP_MODE='PRIMARY'
CREATED_AT=\"2026-09-09 12:34:56\"
SD_NAME='old card name'
TARGET_FD_ROOT=/attacker/fd
TARGET_BACKUP_ROOT=/attacker/backups
TARGET_UUID=ATTACKER
TARGET_SYSFS_ROOT=/attacker/sys
PATH=/attacker/bin
IFS=attacker"
    assert_success 'C01 loads valid data-only card' card_config_load "$CARD_FILE"
    assert_equal "$SD_UUID" "$VALID_UUID" 'C01 returns unquoted UUID'
    assert_equal "$BACKUP_MODE" PRIMARY 'C01 returns single-quoted mode'
    assert_equal "$CREATED_AT" '2026-09-09 12:34:56' 'C01 returns quoted timestamp'
    assert_equal "$SD_NAME" 'old card name' 'C01 returns legacy name'
    assert_runtime_sentinels C01
}
case_c02_defaults_optional_fields() {
    begin_case C02 'minimal historical card defaults optional fields'
    set_runtime_sentinels
    write_card "# historical minimal card

SD_UUID=\"$VALID_UUID\"
SD_NAME=\"\""
    assert_success 'C02 accepts minimal historical card' card_config_load "$CARD_FILE"
    assert_equal "$SD_UUID" "$VALID_UUID" 'C02 returns UUID'
    assert_equal "$BACKUP_MODE" PRIMARY 'C02 defaults mode'
    assert_equal "$CREATED_AT" '' 'C02 clears absent timestamp'
    assert_equal "$SD_NAME" '' 'C02 accepts empty quoted legacy name'
}
case_c03_replica() {
    begin_case C03 'REPLICA remains a supported data value'
    set_runtime_sentinels
    write_card "SD_UUID='$VALID_UUID'
BACKUP_MODE=REPLICA"
    assert_success 'C03 accepts REPLICA' card_config_load "$CARD_FILE"
    assert_equal "$BACKUP_MODE" REPLICA 'C03 returns REPLICA unchanged'
}
case_c04_inert_execution_like_data() {
    begin_case C04 'quoted unknown shell-looking values stay inert'
    set_runtime_sentinels; marker="$TEST_ROOT/marker"
    write_card "SD_UUID=$VALID_UUID
UNKNOWN=\"\$(touch $marker)\"
ANOTHER='\`touch $marker\`'
BACKUP_ROOT='literal\\path'
TARGET_FD_ROOT=\"\$(touch $marker)\""
    assert_success 'C04 ignores unknown shell-looking values' card_config_load "$CARD_FILE"
    assert_absent "$marker" 'C04 did not execute substitutions or backticks'
    assert_runtime_sentinels C04
}
case_c05_duplicate_is_atomic() {
    begin_case C05 'duplicate recognized fields fail atomically'
    set_runtime_sentinels
    write_card "SD_UUID=$VALID_UUID
SD_UUID=$VALID_UUID"
    assert_failure 'C05 rejects duplicate UUID' card_config_load "$CARD_FILE"
    assert_equal "$SD_UUID" old-uuid 'C05 keeps prior UUID'
    assert_equal "$BACKUP_MODE" OLD 'C05 keeps prior mode'
}
case_c06_bad_identity() {
    begin_case C06 'missing and malformed UUID do not replace identity'
    set_runtime_sentinels; write_card 'BACKUP_MODE=PRIMARY'
    assert_failure 'C06 rejects missing UUID' card_config_load "$CARD_FILE"
    assert_equal "$SD_UUID" old-uuid 'C06 missing UUID preserves prior value'
    write_card 'SD_UUID=not-a-uuid'
    assert_failure 'C06 rejects malformed UUID' card_config_load "$CARD_FILE"
    assert_equal "$SD_UUID" old-uuid 'C06 malformed UUID preserves prior value'
}
case_c07_bad_mode_and_known_payload() {
    begin_case C07 'invalid mode and known payload fail inertly'
    set_runtime_sentinels; marker="$TEST_ROOT/known-marker"
    write_card "SD_UUID=$VALID_UUID
BACKUP_MODE=REVERSE"
    assert_failure 'C07 rejects invalid mode' card_config_load "$CARD_FILE"
    write_card "SD_UUID=\"\$(touch $marker)\""
    assert_failure 'C07 rejects known UUID payload' card_config_load "$CARD_FILE"
    assert_absent "$marker" 'C07 did not execute known UUID payload'
}
case_c08_shell_syntax_and_controls() {
    begin_case C08 'shell syntax, tails and controls are not data records'
    set_runtime_sentinels
    write_card "SD_UUID=$VALID_UUID;touch $TEST_ROOT/semicolon"
    assert_failure 'C08 rejects semicolon tail' card_config_load "$CARD_FILE"
    write_card "evil() { touch $TEST_ROOT/function; }"
    assert_failure 'C08 rejects function definition' card_config_load "$CARD_FILE"
    write_card "touch $TEST_ROOT/bare"
    assert_failure 'C08 rejects bare command' card_config_load "$CARD_FILE"
    printf 'SD_UUID=%s\r\n' "$VALID_UUID" > "$CARD_FILE"
    assert_failure 'C08 rejects controls' card_config_load "$CARD_FILE"
    assert_absent "$TEST_ROOT/semicolon" 'C08 did not execute tail'
    assert_absent "$TEST_ROOT/function" 'C08 did not execute function'
    assert_absent "$TEST_ROOT/bare" 'C08 did not execute command'
}
case_c09_bad_file() {
    begin_case C09 'unclosed, empty and absent files fail explicitly'
    set_runtime_sentinels; write_card "SD_UUID=\"$VALID_UUID"
    assert_failure 'C09 rejects unclosed quote' card_config_load "$CARD_FILE"
    : > "$CARD_FILE"; assert_failure 'C09 rejects empty card' card_config_load "$CARD_FILE"
    rm -f "$CARD_FILE"; assert_failure 'C09 rejects absent card' card_config_load "$CARD_FILE"
    assert_equal "$SD_UUID" old-uuid 'C09 keeps prior identity'
}

main() {
    trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM; mkdir -p "$TEST_ROOT"
    # shellcheck disable=SC1090
    . "$COMMON"
    # shellcheck disable=SC1090
    . "$CARD_CONFIG"
    case_c01_literals_and_unknowns; case_c02_defaults_optional_fields; case_c03_replica
    case_c04_inert_execution_like_data; case_c05_duplicate_is_atomic; case_c06_bad_identity
    case_c07_bad_mode_and_known_payload; case_c08_shell_syntax_and_controls; case_c09_bad_file
    assert_equal "$CASES" 9 'all required cases executed'
    [ "$ASSERTIONS" -eq 48 ] || fail "all required assertions executed (expected=48, actual=$ASSERTIONS)"
    [ "$FAILED" -eq 0 ] || { printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"; exit 1; }
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}
main "$@"

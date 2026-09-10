#!/bin/sh
#
# BDD regression tests for outdoor-backup UCI configuration loading.
# Run on the host; the script re-executes itself in a fixed OpenWrt rootfs.
#

set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${IN_OPENWRT_TEST:-}" != "1" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 \
        -e IN_OPENWRT_TEST=1 \
        -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-config.sh
fi

REPO_ROOT=/src
CONFIG_SCRIPT="$REPO_ROOT/files/opt/outdoor-backup/scripts/config.sh"
MANAGER="$REPO_ROOT/files/opt/outdoor-backup/scripts/backup-manager.sh"
FACTORY_UCI="$REPO_ROOT/files/etc/config/outdoor-backup"
TEST_ROOT="/tmp/outdoor-backup-config-test.$$"
UCI_DIR="$TEST_ROOT/uci"
LEGACY_FILE="$TEST_ROOT/backup.conf"
EFFECTS_FILE="$TEST_ROOT/effects.log"
NOTICES_FILE="$TEST_ROOT/notices.log"
RUNTIME_BASE="$TEST_ROOT/runtime/opt/outdoor-backup"
RUNTIME_SCRIPTS="$RUNTIME_BASE/scripts"
RUNTIME_MANAGER="$RUNTIME_SCRIPTS/backup-manager.sh"
ORIGINAL_PATH=$PATH
CASES=0
ASSERTIONS=0
FAILED=0

cleanup_test_data() {
    rm -rf "$TEST_ROOT"
}

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
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! "$@"; then
        fail "$1 should succeed"
    fi
}

assert_failure() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if "$@"; then
        fail "$1 should fail"
    fi
}

prepare_config_state() {
    rm -rf "$UCI_DIR"
    mkdir -p "$UCI_DIR"
    rm -f "$LEGACY_FILE"
    unset ENABLED BACKUP_ROOT MOUNT_POINT TARGET_MOUNT TARGET_UUID DEBUG LED_GREEN \
        LED_RED EXTRA_LEGACY CONFIG_PACKAGE CONFIG_SECTION
    PATH=$ORIGINAL_PATH
    export PATH
    export UCI_CONFIG_DIR="$UCI_DIR"
}

write_uci() {
    printf '%s\n' "$1" > "$UCI_DIR/outdoor-backup"
}

load_config() {
    # shellcheck disable=SC1090
    . "$CONFIG_SCRIPT"
    config_load "$LEGACY_FILE"
}

prepare_manager_runtime() {
    rm -rf "$RUNTIME_BASE" "$TEST_ROOT/led-green" "$TEST_ROOT/led-red" \
        "$TEST_ROOT/card" "$TEST_ROOT/backups"
    mkdir -p "$RUNTIME_SCRIPTS" "$RUNTIME_BASE/conf" \
        "$RUNTIME_BASE/var/lock" "$RUNTIME_BASE/log" \
        "$TEST_ROOT/led-green" "$TEST_ROOT/led-red"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/backup-manager.sh" \
        "$RUNTIME_SCRIPTS/backup-manager.sh"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/config.sh" \
        "$RUNTIME_SCRIPTS/config.sh"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/common.sh" \
        "$RUNTIME_SCRIPTS/common.sh"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/target.sh" \
        "$RUNTIME_SCRIPTS/target.sh"
    ln -s "$REPO_ROOT/files/opt/outdoor-backup/scripts/target-device.sh" \
        "$RUNTIME_SCRIPTS/target-device.sh"
    cat > "$RUNTIME_BASE/conf/backup.conf" <<EOF
BACKUP_ROOT="$TEST_ROOT/backups"
MOUNT_POINT="$TEST_ROOT/card"
LED_GREEN="$TEST_ROOT/led-green"
LED_RED="$TEST_ROOT/led-red"
EOF
}

write_effect_stubs() {
    mkdir -p "$TEST_ROOT/bin"
    : > "$EFFECTS_FILE"
    : > "$NOTICES_FILE"

    cat > "$TEST_ROOT/bin/logger" <<'EOF'
#!/bin/sh
printf 'logger:%s\n' "$*" >> "$TEST_NOTICES"
EOF
    cat > "$TEST_ROOT/bin/mount" <<'EOF'
#!/bin/sh
printf 'mount argc=%s arg1=[%s] arg2=[%s] arg3=[%s] arg4=[%s]\n' "$#" "$1" "$2" "$3" "$4" >> "$TEST_EFFECTS"
exit 1
EOF
    cat > "$TEST_ROOT/bin/mountpoint" <<'EOF'
#!/bin/sh
printf 'mountpoint:%s\n' "$*" >> "$TEST_EFFECTS"
exit 1
EOF
    cat > "$TEST_ROOT/bin/pkill" <<'EOF'
#!/bin/sh
printf 'pkill:%s\n' "$*" >> "$TEST_EFFECTS"
exit 0
EOF
    cat > "$TEST_ROOT/bin/sync" <<'EOF'
#!/bin/sh
printf 'sync\n' >> "$TEST_EFFECTS"
EOF
    chmod 755 "$TEST_ROOT/bin"/*
}

run_manager() {
    TEST_EFFECTS="$EFFECTS_FILE" \
        TEST_NOTICES="$NOTICES_FILE" \
        PATH="$TEST_ROOT/bin:$ORIGINAL_PATH" \
        UCI_CONFIG_DIR="$UCI_DIR" \
        /bin/ash "$RUNTIME_MANAGER" "$@"
}

assert_effect_absent() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ -s "$EFFECTS_FILE" ]; then
        fail "$1 (effects: $(tr '\n' ' ' < "$EFFECTS_FILE"))"
    fi
}

assert_effect_present() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! grep -F -q -- "$1" "$EFFECTS_FILE"; then
        fail "$2 (missing [$1])"
    fi
}

assert_effect_not_present() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if grep -F -q -- "$1" "$EFFECTS_FILE"; then
        fail "$2 (unexpected [$1])"
    fi
}

assert_file_contains() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! grep -F -q -- "$1" "$2"; then
        fail "$3 (missing [$1])"
    fi
}

assert_path_absent() {
    ASSERTIONS=$((ASSERTIONS + 1))
    # -e follows symlinks and is false for a dangling one, so a leftover lock
    # symlink whose holder is gone would slip through. -L catches that case.
    if [ -e "$1" ] || [ -L "$1" ]; then
        fail "$2 (path exists: $1)"
    fi
}

read_snapshot() {
    while IFS= read -r snapshot_line; do
        printf '%s\n' "$snapshot_line"
    done < "$1"
}

snapshot_c08_runtime() {
    find "$RUNTIME_BASE" "$TEST_ROOT/led-green" "$TEST_ROOT/led-red" \
        -type f -exec sha256sum {} \; | sort > "$1"
}

case_c14_factory_config_reaches_task_decision() {
    begin_case C14 "factory UCI config reaches manager task decision"
    prepare_config_state
    prepare_manager_runtime
    cp "$FACTORY_UCI" "$UCI_DIR/outdoor-backup"
    write_effect_stubs

    c14_manager_err="$TEST_ROOT/c14-manager.err"
    if run_manager add sda1 /devices/test > /dev/null 2> "$c14_manager_err"; then
        fail "C14 manager unexpectedly completed without a configured target UUID"
    fi
    assert_file_contains "target UUID is unconfigured" "$c14_manager_err" \
        "C14 factory config did not reach the target UUID decision"
    assert_effect_absent "C14 factory config reached a source mount despite no target UUID"
}

case_c01_no_configuration_uses_defaults() {
    begin_case C01 "missing legacy and UCI configuration uses defaults"
    prepare_config_state
    assert_success load_config
    assert_equal "$ENABLED" "1" "C01 enabled default"
    assert_equal "$BACKUP_ROOT" "/mnt/ssd/SDMirrors" "C01 backup root default"
    assert_equal "$TARGET_MOUNT" "/mnt/ssd" "C01 target mount default"
    assert_equal "$TARGET_UUID" "" "C01 target UUID defaults unconfigured"
    assert_equal "$MOUNT_POINT" "/mnt/sdcard" "C01 mount point default"
}

case_c02_legacy_only_preserves_extra_values() {
    begin_case C02 "legacy configuration overrides defaults and preserves extras"
    prepare_config_state
    cat > "$LEGACY_FILE" <<'EOF'
BACKUP_ROOT="/legacy/backups"
MOUNT_POINT="/legacy/card"
DEBUG=1
EXTRA_LEGACY="kept"
EOF
    assert_success load_config
    assert_equal "$BACKUP_ROOT" "/legacy/backups" "C02 legacy backup root"
    assert_equal "$EXTRA_LEGACY" "kept" "C02 non-UCI legacy option retained"
}

case_c03_uci_only_overrides_defaults() {
    begin_case C03 "UCI named section overrides defaults"
    prepare_config_state
    write_uci "config outdoor-backup 'config'
	option enabled '0'
	option backup_root '/uci/backups'
	option mount_point '/uci/card'
	option debug '1'
	option led_green '/led/green'
	option led_red '/led/red'"
    assert_success load_config
    assert_equal "$ENABLED" "0" "C03 enabled UCI mapping"
    assert_equal "$BACKUP_ROOT" "/uci/backups" "C03 backup root UCI mapping"
    assert_equal "$MOUNT_POINT" "/uci/card" "C03 mount point UCI mapping"
    assert_equal "$LED_GREEN" "/led/green" "C03 green LED UCI mapping"
}

case_c04_only_explicit_uci_options_override_legacy() {
    begin_case C04 "only explicit UCI options override legacy values"
    prepare_config_state
    cat > "$LEGACY_FILE" <<'EOF'
BACKUP_ROOT="/legacy/backups"
MOUNT_POINT="/legacy/card"
DEBUG=0
EOF
    write_uci "config outdoor-backup 'config'
	option debug '1'"
    assert_success load_config
    assert_equal "$BACKUP_ROOT" "/legacy/backups" "C04 omitted root keeps legacy value"
    assert_equal "$MOUNT_POINT" "/legacy/card" "C04 omitted mount keeps legacy value"
    assert_equal "$DEBUG" "1" "C04 explicit debug overrides legacy value"
}

case_c04b_target_options_follow_legacy_then_named_uci_precedence() {
    begin_case C04b "target mount and UUID preserve precedence and normalize mount"
    prepare_config_state
    cat > "$LEGACY_FILE" <<'EOF'
TARGET_MOUNT="/legacy/target/"
TARGET_UUID="LEGACY-1234"
EOF
    write_uci "config outdoor-backup 'config'
	option target_mount '/uci/target/'
	option target_uuid 'UCI-5678'"
    assert_success load_config
    assert_equal "$TARGET_MOUNT" "/uci/target" "C04b UCI target mount overrides legacy"
    assert_equal "$TARGET_UUID" "UCI-5678" "C04b UCI target UUID overrides legacy"

    prepare_config_state
    cat > "$LEGACY_FILE" <<'EOF'
TARGET_MOUNT="/legacy/target/"
TARGET_UUID="LEGACY-1234"
EOF
    write_uci "config outdoor-backup 'config'
	option target_mount ''
	option target_uuid ''"
    assert_success load_config
    assert_equal "$TARGET_MOUNT" "/legacy/target" "C04b empty UCI target mount retains legacy"
    assert_equal "$TARGET_UUID" "LEGACY-1234" "C04b empty UCI target UUID retains legacy"

    prepare_config_state
    write_uci "config outdoor-backup 'config'
	option target_mount '/target with space/'
	option target_uuid 'bad value'"
    assert_failure load_config
}

case_c05_empty_uci_options_inherit_lower_precedence() {
    begin_case C05 "empty UCI options inherit lower-precedence values"
    prepare_config_state
    cat > "$LEGACY_FILE" <<'EOF'
BACKUP_ROOT="/legacy/backups"
MOUNT_POINT="/legacy/card"
ENABLED=0
DEBUG=1
EOF
    write_uci "config outdoor-backup 'config'
	option backup_root ''
	option mount_point ''
	option enabled ''
	option debug ''"
    assert_success load_config
    assert_equal "$BACKUP_ROOT" "/legacy/backups" "C05 empty UCI root retains legacy value"
    assert_equal "$MOUNT_POINT" "/legacy/card" "C05 empty UCI mount retains legacy value"
    assert_equal "$ENABLED" "0" "C05 empty UCI enabled retains legacy value"
    assert_equal "$DEBUG" "1" "C05 empty UCI debug retains legacy value"

    prepare_config_state
    write_uci "config outdoor-backup 'config'
	option backup_root ''
	option mount_point ''
	option enabled ''
	option debug ''"
    assert_success load_config
    assert_equal "$BACKUP_ROOT" "/mnt/ssd/SDMirrors" "C05 empty UCI root retains builtin default"
    assert_equal "$MOUNT_POINT" "/mnt/sdcard" "C05 empty UCI mount retains builtin default"
    assert_equal "$ENABLED" "1" "C05 empty UCI enabled retains builtin default"
    assert_equal "$DEBUG" "0" "C05 empty UCI debug retains builtin default"

    prepare_config_state
    printf 'BACKUP_ROOT=""\n' > "$LEGACY_FILE"
    assert_failure load_config
}

case_c06_bad_uci_and_missing_cli_fail_loud() {
    begin_case C06 "malformed UCI and missing UCI CLI fail loud"
    prepare_config_state
    write_uci "broken"
    assert_failure load_config

    prepare_config_state
    write_uci "broken"
    prepare_manager_runtime
    write_effect_stubs
    c06_manager_err="$TEST_ROOT/c06-manager.err"
    run_manager add sda1 /devices/test > /dev/null 2> "$c06_manager_err" &
    c06_manager_pid=$!
    ASSERTIONS=$((ASSERTIONS + 1))
    if wait "$c06_manager_pid"; then
        fail "C06 malformed UCI manager should fail"
    fi
    assert_file_contains "configuration error" "$c06_manager_err" \
        "C06 manager hid malformed UCI configuration error"
    assert_file_contains "configuration error" "$NOTICES_FILE" \
        "C06 manager did not syslog malformed UCI configuration error"
    assert_effect_absent "C06 malformed UCI manager performed a side effect"

    prepare_config_state
    write_uci "config outdoor-backup 'config'"
    ASSERTIONS=$((ASSERTIONS + 1))
    # shellcheck disable=SC2123 # Deliberately hide UCI to test fail-loud behavior.
    if (PATH=/no-such-path; export PATH; load_config); then
        fail "C06 missing UCI CLI should fail"
    fi
}

case_c07_enabled_defaults_to_one() {
    begin_case C07 "enabled defaults to one"
    prepare_config_state
    assert_success load_config
    assert_equal "$ENABLED" "1" "C07 enabled default"
}

case_c08_disabled_add_has_no_side_effects() {
    begin_case C08 "disabled add exits before common or device side effects"
    prepare_config_state
    write_uci "config outdoor-backup 'config'
	option enabled '0'"
    prepare_manager_runtime
    write_effect_stubs
    c08_before="$TEST_ROOT/c08-before.snapshot"
    c08_after="$TEST_ROOT/c08-after.snapshot"
    c08_disabled_err="$TEST_ROOT/disabled.err"
    snapshot_c08_runtime "$c08_before"

    run_manager add sda1 /devices/test > /dev/null 2> "$c08_disabled_err" &
    c08_manager_pid=$!
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! wait "$c08_manager_pid"; then
        fail "C08 disabled add must exit zero"
    fi
    snapshot_c08_runtime "$c08_after"
    c08_before_contents=$(read_snapshot "$c08_before")
    c08_after_contents=$(read_snapshot "$c08_after")
    assert_equal "$c08_after_contents" "$c08_before_contents" \
        "C08 disabled add changed runtime file contents"
    assert_file_contains \
        "outdoor-backup: backup disabled; ignoring add event for sda1" \
        "$c08_disabled_err" "C08 disabled add hid its disabled message"
    assert_file_contains \
        "logger:-t outdoor-backup backup disabled; ignoring add event for sda1" \
        "$NOTICES_FILE" "C08 disabled add did not syslog its disabled message"
    assert_effect_absent "C08 disabled add performed a side effect"
    assert_path_absent "$RUNTIME_BASE/var/lock/backup.lock" \
        "C08 disabled add created a lock"
    assert_path_absent "$RUNTIME_BASE/var/lock/backup.pid" \
        "C08 disabled add created a legacy lock file"
    assert_path_absent "$TEST_ROOT/backups" \
        "C08 disabled add created BACKUP_ROOT"
    assert_path_absent "$TEST_ROOT/card" \
        "C08 disabled add created MOUNT_POINT"
}

case_c09_disabled_remove_still_runs_cleanup_path() {
    begin_case C09 "disabled remove remains eligible for cleanup"
    prepare_config_state
    write_uci "config outdoor-backup 'config'
	option enabled '0'"
    prepare_manager_runtime
    write_effect_stubs
    cat > "$TEST_ROOT/bin/mountpoint" <<'EOF'
#!/bin/sh
printf 'mountpoint:%s\n' "$*" >> "$TEST_EFFECTS"
exit 0
EOF
    cat > "$TEST_ROOT/bin/umount" <<'EOF'
#!/bin/sh
printf 'umount:%s\n' "$*" >> "$TEST_EFFECTS"
exit 0
EOF
    chmod 755 "$TEST_ROOT/bin/mountpoint" "$TEST_ROOT/bin/umount"
    if ! run_manager remove sda1 /devices/test >/dev/null 2>&1; then
        fail "C09 disabled remove should complete through isolated cleanup"
    fi
    assert_effect_present "pkill:" "C09 remove was blocked by enabled setting"
    assert_effect_not_present "umount:" "C09 non-owner remove cleanup did not unmount source"
    assert_path_absent "$TEST_ROOT/led-green/trigger" \
        "C09 non-owner remove cleanup did not alter the green LED"
    assert_path_absent "$TEST_ROOT/led-red/trigger" \
        "C09 non-owner remove cleanup did not signal an error LED"
}

case_c10_invalid_paths_and_controls_fail() {
    begin_case C10 "invalid path shapes and control characters fail"
    for invalid_root in / relative /bad//path /bad/./path /bad/../path "$(printf '/bad\npath')"; do
        prepare_config_state
        write_uci "config outdoor-backup 'config'
	option backup_root '$invalid_root'"
        assert_failure load_config
    done

    prepare_config_state
    write_uci "config outdoor-backup 'config'
	option backup_root 'relative'"
    prepare_manager_runtime
    write_effect_stubs
    c10_manager_err="$TEST_ROOT/c10-manager.err"
    run_manager add sda1 /devices/test > /dev/null 2> "$c10_manager_err" &
    c10_manager_pid=$!
    ASSERTIONS=$((ASSERTIONS + 1))
    if wait "$c10_manager_pid"; then
        fail "C10 invalid backup_root manager should fail"
    fi
    assert_file_contains "configuration error" "$c10_manager_err" \
        "C10 manager hid invalid backup_root configuration error"
    assert_file_contains "configuration error" "$NOTICES_FILE" \
        "C10 manager did not syslog invalid backup_root configuration error"
    assert_effect_absent "C10 invalid backup_root manager performed a side effect"
}

case_c11_same_and_nested_paths_fail() {
    begin_case C11 "same or nested source and destination paths fail"
    prepare_config_state
    write_uci "config outdoor-backup 'config'
	option backup_root '/data'
	option mount_point '/data'"
    assert_failure load_config

    prepare_config_state
    write_uci "config outdoor-backup 'config'
	option backup_root '/data/backups'
	option mount_point '/data'"
    assert_failure load_config

    prepare_config_state
    write_uci "config outdoor-backup 'config'
	option backup_root '/data'
	option mount_point '/data/card'"
    assert_failure load_config
}

case_c12_invalid_enabled_and_debug_fail() {
    begin_case C12 "enabled and debug accept only zero or one"
    for field in enabled debug; do
        prepare_config_state
        write_uci "config outdoor-backup 'config'
	option $field 'yes'"
        assert_failure load_config
    done
}

case_c13_non_target_section_cannot_override() {
    begin_case C13 "other UCI sections cannot override the named config section"
    prepare_config_state
    write_uci "config outdoor-backup 'ignored'
	option backup_root '/wrong'
config outdoor-backup 'config'
	option debug '1'"
    assert_success load_config
    assert_equal "$BACKUP_ROOT" "/mnt/ssd/SDMirrors" "C13 ignored section changed backup root"
    assert_equal "$DEBUG" "1" "C13 named section was not loaded"
}

case_trailing_slashes_are_normalized() {
    begin_case EDGE01 "trailing slashes are normalized"
    prepare_config_state
    write_uci "config outdoor-backup 'config'
	option backup_root '/data/backups/'
	option mount_point '/data/card/'"
    assert_success load_config
    assert_equal "$BACKUP_ROOT" "/data/backups" "EDGE01 backup root normalization"
    assert_equal "$MOUNT_POINT" "/data/card" "EDGE01 mount point normalization"
}

case_spaces_survive_loader_normalization() {
    begin_case EDGE02 "space-containing target mount remains one normalized loader value"
    prepare_config_state
    write_uci "config outdoor-backup 'config'
	option target_mount '/tmp/target mount/'"
    assert_success load_config
    assert_equal "$TARGET_MOUNT" "/tmp/target mount" \
        "EDGE02 target mount was changed or shell-split by the loader"
}

case_uci_shell_text_is_not_executed() {
    begin_case EDGE03 "UCI value is data and never shell code"
    prepare_config_state
    rm -f "$TEST_ROOT/pwned"
    write_uci "config outdoor-backup 'config'
	option backup_root '/tmp/backups; touch $TEST_ROOT/pwned'"
    assert_success load_config
    assert_equal "$BACKUP_ROOT" "/tmp/backups; touch $TEST_ROOT/pwned" "EDGE03 UCI text changed"
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ -e "$TEST_ROOT/pwned" ]; then
        fail "EDGE03 UCI value executed shell text"
    fi
}

case_legacy_variable_names_do_not_control_uci() {
    begin_case EDGE04 "legacy UCI selector variables remain data"
    prepare_config_state
    cat > "$LEGACY_FILE" <<'EOF'
CONFIG_PACKAGE=keep-package
CONFIG_SECTION=keep-section
BACKUP_ROOT=/legacy/backups
EOF
    write_uci "config outdoor-backup 'config'
	option backup_root '/uci/backups'"
    assert_success load_config
    assert_equal "$BACKUP_ROOT" "/uci/backups" "EDGE04 named UCI backup root"
    assert_equal "$CONFIG_PACKAGE" "keep-package" "EDGE04 legacy CONFIG_PACKAGE retained"
    assert_equal "$CONFIG_SECTION" "keep-section" "EDGE04 legacy CONFIG_SECTION retained"
}

case_common_sources_preserve_legacy_led_values() {
    begin_case EDGE05 "common source preserves legacy LED values"
    prepare_config_state
    cat > "$LEGACY_FILE" <<'EOF'
LED_GREEN=''
LED_RED='/sys//class/leds/red:sys'
EOF
    write_uci "config outdoor-backup 'config'"
    assert_success load_config
    assert_equal "$LED_GREEN" "" "EDGE05 empty legacy green LED retained"
    assert_equal "$LED_RED" "/sys//class/leds/red:sys" "EDGE05 legacy red LED retained"

    common_green=$(LED_GREEN="$LED_GREEN" LED_RED="$LED_RED" \
        /bin/ash -c '. "$1"; printf "%s" "$LED_GREEN"' \
        outdoor-backup-common "$REPO_ROOT/files/opt/outdoor-backup/scripts/common.sh")
    common_red=$(LED_GREEN="$LED_GREEN" LED_RED="$LED_RED" \
        /bin/ash -c '. "$1"; printf "%s" "$LED_RED"' \
        outdoor-backup-common "$REPO_ROOT/files/opt/outdoor-backup/scripts/common.sh")
    assert_equal "$common_green" "/sys/class/leds/green:lan" \
        "EDGE05 common defaulted empty green LED"
    assert_equal "$common_red" "/sys//class/leds/red:sys" \
        "EDGE05 common preserved non-empty red LED"
}

main() {
    trap cleanup_test_data EXIT INT TERM
    mkdir -p "$TEST_ROOT"

    # C14 uses the factory template in the temporary UCI directory to verify
    # that it reaches the manager task decision. The historical baseline Red
    # is recorded in the PR validation record.
    case_c14_factory_config_reaches_task_decision

    if [ ! -r "$CONFIG_SCRIPT" ]; then
        fail "configuration loader is absent after C14 baseline execution"
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi

    case_c01_no_configuration_uses_defaults
    case_c02_legacy_only_preserves_extra_values
    case_c03_uci_only_overrides_defaults
    case_c04_only_explicit_uci_options_override_legacy
    case_c04b_target_options_follow_legacy_then_named_uci_precedence
    case_c05_empty_uci_options_inherit_lower_precedence
    case_c06_bad_uci_and_missing_cli_fail_loud
    case_c07_enabled_defaults_to_one
    case_c08_disabled_add_has_no_side_effects
    case_c09_disabled_remove_still_runs_cleanup_path
    case_c10_invalid_paths_and_controls_fail
    case_c11_same_and_nested_paths_fail
    case_c12_invalid_enabled_and_debug_fail
    case_c13_non_target_section_cannot_override
    case_trailing_slashes_are_normalized
    case_spaces_survive_loader_normalization
    case_uci_shell_text_is_not_executed
    case_legacy_variable_names_do_not_control_uci
    case_common_sources_preserve_legacy_led_values

    assert_equal "$CASES" "20" "all required cases executed"
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$ASSERTIONS" -ne 96 ]; then
        fail "all required assertions executed (expected=96, actual=$ASSERTIONS)"
    fi
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

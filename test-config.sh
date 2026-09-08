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
    unset ENABLED BACKUP_ROOT MOUNT_POINT DEBUG LED_GREEN LED_RED EXTRA_LEGACY \
        CONFIG_PACKAGE CONFIG_SECTION
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

    cat > "$TEST_ROOT/bin/logger" <<'EOF'
#!/bin/sh
printf 'logger:%s\n' "$*" >> "$TEST_EFFECTS"
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

assert_file_contains() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! grep -F -q -- "$1" "$2"; then
        fail "$3 (missing [$1])"
    fi
}

assert_path_absent() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ -e "$1" ]; then
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
    mkdir -p /etc/config
    cp "$FACTORY_UCI" "$UCI_DIR/outdoor-backup"
    cp "$FACTORY_UCI" /etc/config/outdoor-backup
    write_effect_stubs

    if run_manager add sda1 /devices/test >/dev/null 2>&1; then
        fail "C14 manager unexpectedly completed with mount stub"
    fi
    assert_effect_present "mount argc=4" "C14 manager never reached mount decision"
}

case_c01_no_configuration_uses_defaults() {
    begin_case C01 "missing legacy and UCI configuration uses defaults"
    prepare_config_state
    assert_success load_config
    assert_equal "$ENABLED" "1" "C01 enabled default"
    assert_equal "$BACKUP_ROOT" "/mnt/ssd/SDMirrors" "C01 backup root default"
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

    ASSERTIONS=$((ASSERTIONS + 1))
    if ! run_manager add sda1 /devices/test > /dev/null 2> "$c08_disabled_err"; then
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
    assert_effect_absent "C08 disabled add performed a side effect"
    assert_path_absent "$RUNTIME_BASE/var/lock/backup.pid" \
        "C08 disabled add created a lock"
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
    if ! run_manager remove sda1 /devices/test >/dev/null 2>&1; then
        fail "C09 disabled remove should complete through isolated cleanup"
    fi
    assert_effect_present "pkill:" "C09 remove was blocked by enabled setting"
}

case_c10_invalid_paths_and_controls_fail() {
    begin_case C10 "invalid path shapes and control characters fail"
    for invalid_root in / relative /bad//path /bad/./path /bad/../path "$(printf '/bad\npath')"; do
        prepare_config_state
        write_uci "config outdoor-backup 'config'
	option backup_root '$invalid_root'"
        assert_failure load_config
    done
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

case_spaces_remain_one_manager_argument() {
    begin_case EDGE02 "space-containing mount path remains one mount argument"
    prepare_config_state
    write_uci "config outdoor-backup 'config'
	option mount_point '/tmp/card mount'"
    prepare_manager_runtime
    write_effect_stubs
    run_manager add sda1 /devices/test >/dev/null 2>&1 || true
    assert_effect_present "arg4=[/tmp/card mount]" "EDGE02 mount point was shell-split"
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

    # C14 runs before config.sh is loaded so baseline Red proves the old manager
    # sources the factory UCI file as shell syntax instead of calling UCI.
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
    case_spaces_remain_one_manager_argument
    case_uci_shell_text_is_not_executed
    case_legacy_variable_names_do_not_control_uci
    case_common_sources_preserve_legacy_led_values

    assert_equal "$CASES" "19" "all required cases executed"
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$ASSERTIONS" -ne 72 ]; then
        fail "all required assertions executed (expected=72, actual=$ASSERTIONS)"
    fi
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

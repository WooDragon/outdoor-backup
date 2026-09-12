#!/bin/sh
#
# BDD integration tests for init forwarding and real ImmortalWrt package wrappers.
# The host fetches the exact v24.10.6 wrapper sources before starting a disposable
# pinned OpenWrt rootfs. Production sources remain read-only under /src.
#
set -u

IMAGE='openwrt/rootfs:x86_64-24.10.8'
IMAGE_DIGEST='sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9'
UPSTREAM_COMMIT='5fa11a1b5689154d296fdacf1e16a7abccb897b9'
FUNCTIONS_URL="https://raw.githubusercontent.com/immortalwrt/immortalwrt/$UPSTREAM_COMMIT/package/base-files/files/lib/functions.sh"
RC_COMMON_URL="https://raw.githubusercontent.com/immortalwrt/immortalwrt/$UPSTREAM_COMMIT/package/base-files/files/etc/rc.common"
FUNCTIONS_SHA256='0a834605bca24da7d31e15f6f37767290d12f95b1cdb5804f797684b329f66dc'
RC_COMMON_SHA256='dd8ae95c78d10cccf78cb487874f163ace4c1ee14dace05fe28393b19ba639e4'

if [ "${1:-}" != '--inside' ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 1
    EVIDENCE_ROOT=$(mktemp -d /tmp/outdoor-backup-service-lifecycle.XXXXXX) || exit 1
    UPSTREAM_ROOT="$EVIDENCE_ROOT/upstream"
    mkdir -p "$UPSTREAM_ROOT" || exit 1
    curl --fail --silent --show-error --location "$FUNCTIONS_URL" > "$UPSTREAM_ROOT/functions.sh" || {
        printf '%s\n' 'FAIL: cannot fetch pinned ImmortalWrt functions.sh' >&2
        exit 1
    }
    curl --fail --silent --show-error --location "$RC_COMMON_URL" > "$UPSTREAM_ROOT/rc.common" || {
        printf '%s\n' 'FAIL: cannot fetch pinned ImmortalWrt rc.common' >&2
        exit 1
    }
    actual_functions_sha=$(shasum -a 256 "$UPSTREAM_ROOT/functions.sh" | awk '{print $1}')
    actual_rc_common_sha=$(shasum -a 256 "$UPSTREAM_ROOT/rc.common" | awk '{print $1}')
    [ "$actual_functions_sha" = "$FUNCTIONS_SHA256" ] || {
        printf '%s\n' 'FAIL: pinned functions.sh checksum changed' >&2
        exit 1
    }
    [ "$actual_rc_common_sha" = "$RC_COMMON_SHA256" ] || {
        printf '%s\n' 'FAIL: pinned rc.common checksum changed' >&2
        exit 1
    }
    printf '%s\n' "$UPSTREAM_COMMIT" > "$UPSTREAM_ROOT/commit"
    docker run --rm --platform linux/amd64 --tmpfs /tmp:rw,exec \
        -e TEST_EVIDENCE=/evidence -v "$REPO_ROOT:/src:ro" -v "$EVIDENCE_ROOT:/evidence" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-service-lifecycle.sh --inside \
        >"$EVIDENCE_ROOT/suite.stdout" 2>"$EVIDENCE_ROOT/suite.stderr"
    suite_rc=$?
    awk '{ print }' "$EVIDENCE_ROOT/suite.stdout"
    awk '{ print }' "$EVIDENCE_ROOT/suite.stderr" >&2
    printf 'evidence=%s wrapper_commit=%s\n' "$EVIDENCE_ROOT" "$UPSTREAM_COMMIT"
    exit "$suite_rc"
fi

[ -f /.dockerenv ] && [ -r /etc/openwrt_release ] || {
    printf '%s\n' 'FAIL: --inside requires the pinned OpenWrt rootfs' >&2
    exit 1
}
[ -r "$TEST_EVIDENCE/upstream/functions.sh" ] && [ -r "$TEST_EVIDENCE/upstream/rc.common" ] || {
    printf '%s\n' 'FAIL: host did not provide pinned wrapper evidence' >&2
    exit 1
}
[ "$(awk '{print $1}' "$TEST_EVIDENCE/upstream/commit")" = "$UPSTREAM_COMMIT" ] || {
    printf '%s\n' 'FAIL: wrapper evidence commit marker is wrong' >&2
    exit 1
}
mkdir -p /var/lock || exit 1
opkg update >/dev/null || { printf '%s\n' 'FAIL: cannot refresh OpenWrt metadata' >&2; exit 1; }
opkg install --force-space jq flock >/dev/null || {
    printf '%s\n' 'FAIL: cannot install jq and flock' >&2
    exit 1
}
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || {
    printf '%s\n' 'FAIL: jq or flock missing after installation' >&2
    exit 1
}

REPO_ROOT=/src
SOURCE_SCRIPTS="$REPO_ROOT/files/opt/outdoor-backup/scripts"
SOURCE_INIT="$REPO_ROOT/files/etc/init.d/outdoor-backup"
MAKEFILE="$REPO_ROOT/Makefile"
INIT=/etc/init.d/outdoor-backup
CONTROL=/opt/outdoor-backup/scripts/service-control.sh
RUNTIME=/var/run/outdoor-backup
BUSINESS_LOCK=/opt/outdoor-backup/var/lock/backup.lock
SERVICE_LINK=/etc/rc.d/S99outdoor-backup
STOP_LINK=/etc/rc.d/K10outdoor-backup
PACKAGE_INFO=/usr/lib/opkg/info
TEST_ROOT="${TEST_EVIDENCE:?}/runtime"
CASES=0
ASSERTIONS=0
FAILED=0
EXPECTED_CASES=12
EXPECTED_ASSERTIONS=72

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILED=$((FAILED + 1))
}

begin_case() {
    CASES=$((CASES + 1))
    printf 'CASE %s: %s\n' "$1" "$2"
}

assert_equal() {
    actual=$1 expected=$2 message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    [ "$actual" = "$expected" ] || fail "$message (expected=[$expected], actual=[$actual])"
}

assert_success() {
    message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    "$@" || fail "$message"
}

assert_rc() {
    expected=$1 message=$2
    shift 2
    "$@"
    actual=$?
    assert_equal "$actual" "$expected" "$message"
}

assert_failure() {
    message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    "$@" && fail "$message (unexpected success)"
}

assert_path_absent() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "$2"
}

assert_path_exists() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ -e "$1" ] || [ -L "$1" ] || fail "$2"
}

extract_package_script() {
    block_name=$1 output=$2
    awk -v block="define Package/outdoor-backup/$block_name" '
        $0 == block {
            definitions += 1
            in_block = 1
            next
        }
        in_block && $0 == "endef" {
            in_block = 0
            next
        }
        in_block {
            gsub(/\$\$/, "$")
            print
            lines += 1
        }
        END { exit (definitions == 1 && !in_block && lines > 0) ? 0 : 1 }
    ' "$MAKEFILE" > "$output" || return 1
    chmod 700 "$output"
}

install_fixed_wrappers() {
    cp "$TEST_EVIDENCE/upstream/functions.sh" /lib/functions.sh || return 1
    cp "$TEST_EVIDENCE/upstream/rc.common" /etc/rc.common || return 1
    chmod 755 /etc/rc.common
}

install_fixture() {
    rm -rf /opt/outdoor-backup /etc/init.d/outdoor-backup /etc/rc.d/S99outdoor-backup \
        /etc/rc.d/K10outdoor-backup /etc/config/outdoor-backup "$RUNTIME" "$PACKAGE_INFO/outdoor-backup."*
    mkdir -p /opt/outdoor-backup /etc/init.d /etc/rc.d /etc/config /etc/hotplug.d/block \
        "$PACKAGE_INFO" "$TEST_ROOT" || return 1
    rm -rf "$TEST_ROOT/bin"
    rm -f "$TEST_ROOT/controller.calls" "$TEST_ROOT/logger.calls"
    cp -R "$REPO_ROOT/files/opt/outdoor-backup/." /opt/outdoor-backup/ || return 1
    chmod 755 /opt/outdoor-backup/scripts/*.sh || return 1
    cp "$SOURCE_INIT" "$INIT" || return 1
    cp "$REPO_ROOT/files/etc/config/outdoor-backup" /etc/config/outdoor-backup || return 1
    cp "$REPO_ROOT/files/etc/hotplug.d/block/90-outdoor-backup" /etc/hotplug.d/block/90-outdoor-backup || return 1
    chmod 755 "$INIT"
    printf '%s\n' /etc/init.d/outdoor-backup > "$PACKAGE_INFO/outdoor-backup.list"
    extract_package_script postinst "$PACKAGE_INFO/outdoor-backup.postinst-pkg" || return 1
    extract_package_script prerm "$PACKAGE_INFO/outdoor-backup.prerm-pkg" || return 1
}

run_init() {
    action=$1
    /bin/ash /etc/rc.common "$INIT" "$action"
}

run_default_postinst() {
    PKG_UPGRADE=${1:-0} pkgname=outdoor-backup /bin/ash -c '. /lib/functions.sh; default_postinst outdoor-backup'
}

run_default_prerm() {
    PKG_UPGRADE=${1:-0} pkgname=outdoor-backup /bin/ash -c '. /lib/functions.sh; default_prerm outdoor-backup'
}

state_text() {
    [ -f "$RUNTIME/state" ] && awk '{print}' "$RUNTIME/state" || printf '%s' absent
}

install_controller_double() {
    double_rc=$1
    cat > "$CONTROL" <<EOF
#!/bin/ash
printf '%s\\n' "\$1" >> "${TEST_ROOT}/controller.calls"
exit $double_rc
EOF
    chmod 700 "$CONTROL"
}

install_recording_controller() {
    mv "$CONTROL" "$CONTROL.real" || return 1
    cat > "$CONTROL" <<'EOF'
#!/bin/ash
printf '%s\n' "$1" >> "${TEST_CONTROLLER_LOG:?}"
exec /opt/outdoor-backup/scripts/service-control.sh.real "$@"
EOF
    chmod 700 "$CONTROL"
}

install_logger_double() {
    mkdir -p "$TEST_ROOT/bin" || return 1
    cat > "$TEST_ROOT/bin/logger" <<'EOF'
#!/bin/ash
printf '%s\n' "$*" >> "${TEST_LOGGER_LOG:?}"
EOF
    chmod 700 "$TEST_ROOT/bin/logger"
}

clear_action_logs() {
    rm -f "$TEST_ROOT/controller.calls" "$TEST_ROOT/logger.calls"
}

run_init_logged() {
    init_path=$1 action=$2
    TEST_LOGGER_LOG="$TEST_ROOT/logger.calls" TEST_CONTROLLER_LOG="$TEST_ROOT/controller.calls" \
        PATH="$TEST_ROOT/bin:$PATH" /bin/ash /etc/rc.common "$init_path" "$action"
}

run_init_logged_current() {
    run_init_logged "$INIT" "$1"
}

assert_failed_entry() {
    action=$1 expected_rc=$2 label=$3
    clear_action_logs
    install_controller_double "$expected_rc" || return 1
    assert_rc "$expected_rc" "$label returns exact controller rc" run_init_logged_current "$action"
    assert_equal "$(awk '{print}' "$TEST_ROOT/controller.calls")" "$action" \
        "$label invokes only its controller action"
    assert_path_absent "$TEST_ROOT/logger.calls" "$label writes no success logger call"
}

write_init_variant() {
    variant_kind=$1 variant_path=$2
    case $variant_kind in
        swallow-start)
            awk '
                $0 == "\t[ \"$controller_rc\" -eq 0 ] || return \"$controller_rc\"" && !done {
                    print "\treturn 0"
                    done = 1
                    next
                }
                { print }
                END { exit done ? 0 : 1 }
            ' "$INIT" > "$variant_path"
            ;;
        early-start-log)
            awk '
                $0 == "\tcontroller_run \"$controller_action\"" && !done {
                    print "\tlogger -t outdoor-backup '\''Service enabled - SD cards will be backed up automatically'\'' || :"
                    done = 1
                }
                { print }
                END { exit done ? 0 : 1 }
            ' "$INIT" > "$variant_path"
            ;;
        reload-controller)
            awk '
                $0 == "\tlogger -t outdoor-backup '\''Configuration reloaded'\''" && !done {
                    print "\tcontroller_run start"
                    done = 1
                }
                { print }
                END { exit done ? 0 : 1 }
            ' "$INIT" > "$variant_path"
            ;;
        *) return 1 ;;
    esac
    chmod 700 "$variant_path"
}

case_start_failure_forwarding() {
    begin_case L01 'start forwards busy and nonstandard controller failures without success logs'
    install_fixture || { fail 'L01 fixture setup failed'; return; }
    install_logger_double || { fail 'L01 logger fixture setup failed'; return; }
    assert_failed_entry start 2 'L01 start busy'
    assert_failed_entry start 73 'L01 start nonstandard error'
}

case_stop_restart_failure_forwarding() {
    begin_case L02 'stop and restart forward failures without success logs or follow-up starts'
    install_fixture || { fail 'L02 fixture setup failed'; return; }
    install_logger_double || { fail 'L02 logger fixture setup failed'; return; }
    assert_failed_entry stop 2 'L02 stop busy'
    assert_failed_entry stop 73 'L02 stop nonstandard error'
    assert_failed_entry restart 2 'L02 restart busy'
    assert_failed_entry restart 73 'L02 restart nonstandard error'
}

case_reload_is_nonlifecycle() {
    begin_case L11 'reload logs configuration reload without controller, state, or enablement changes'
    install_fixture || { fail 'L11 fixture setup failed'; return; }
    install_logger_double || { fail 'L11 logger fixture setup failed'; return; }
    mkdir -p "$RUNTIME"
    printf '%s' 'stopped:41' > "$RUNTIME/state"
    clear_action_logs
    assert_rc 0 'L11 reload returns zero' run_init_logged_current reload
    assert_path_absent "$TEST_ROOT/controller.calls" 'L11 reload never invokes controller'
    assert_equal "$(state_text)" 'stopped:41' 'L11 reload leaves runtime state unchanged'
    assert_path_absent "$SERVICE_LINK" 'L11 reload leaves disabled service disabled'
    assert_equal "$(awk '{print}' "$TEST_ROOT/logger.calls")" \
        '-t outdoor-backup Configuration reloaded' 'L11 reload emits only its configuration log'
}

case_private_mutant_oracles() {
    begin_case L12 'private init mutants are rejected by forwarding, logger, and reload behavior oracles'
    install_fixture || { fail 'L12 fixture setup failed'; return; }
    install_logger_double || { fail 'L12 logger fixture setup failed'; return; }

    swallow_variant="$TEST_ROOT/swallow-start.init"
    write_init_variant swallow-start "$swallow_variant" || { fail 'L12 swallow mutant creation failed'; return; }
    clear_action_logs
    install_controller_double 73 || return
    run_init_logged "$swallow_variant" start
    swallow_rc=$?
    assert_equal "$swallow_rc" 0 'L12 swallow mutant exposes false start success'
    assert_failure 'L12 exact start-rc oracle rejects swallow mutant' test "$swallow_rc" -eq 73

    early_log_variant="$TEST_ROOT/early-start-log.init"
    write_init_variant early-start-log "$early_log_variant" || { fail 'L12 early-log mutant creation failed'; return; }
    clear_action_logs
    install_controller_double 73 || return
    assert_rc 73 'L12 early-log mutant retains controller failure for logger oracle' \
        run_init_logged "$early_log_variant" start
    assert_path_exists "$TEST_ROOT/logger.calls" 'L12 early-log mutant writes forbidden success logger call'
    assert_failure 'L12 no-success-log oracle rejects early-log mutant' \
        test ! -e "$TEST_ROOT/logger.calls"

    install_fixture || { fail 'L12 reload mutant fixture reset failed'; return; }
    install_logger_double || { fail 'L12 reload mutant logger setup failed'; return; }
    reload_variant="$TEST_ROOT/reload-controller.init"
    write_init_variant reload-controller "$reload_variant" || { fail 'L12 reload mutant creation failed'; return; }
    clear_action_logs
    mkdir -p "$RUNTIME"
    printf '%s' 'stopped:55' > "$RUNTIME/state"
    install_recording_controller || { fail 'L12 recording controller setup failed'; return; }
    assert_rc 0 'L12 reload-controller mutant completes its illicit start' \
        run_init_logged "$reload_variant" reload
    assert_equal "$(awk '{print}' "$TEST_ROOT/controller.calls")" start \
        'L12 reload-controller mutant invokes controller start'
    assert_equal "$(state_text)" 'running:56' 'L12 reload-controller mutant changes state'
    assert_failure 'L12 no-controller-call oracle rejects reload mutant' \
        test ! -e "$TEST_ROOT/controller.calls"
    assert_failure 'L12 state-stability oracle rejects reload mutant' \
        test "$(state_text)" = 'stopped:55'
}

case_real_stop_and_restart() {
    begin_case L03 'real controller stop and restart preserve the quiescent state and create one new epoch'
    install_fixture || { fail 'L03 fixture setup failed'; return; }
    ln -s ../init.d/outdoor-backup "$SERVICE_LINK"
    mkdir -p "$RUNTIME"
    printf '%s' 'running:4' > "$RUNTIME/state"
    assert_rc 0 'L03 real stop succeeds without active work' run_init stop
    assert_equal "$(state_text)" 'stopped:4' 'L03 real stop preserves generation'
    assert_rc 0 'L03 real restart succeeds without active work' run_init restart
    assert_equal "$(state_text)" 'running:5' 'L03 real restart opens exactly the next generation'
    assert_path_absent "$BUSINESS_LOCK" 'L03 real lifecycle does not invent a business lock'
}

case_default_postinst_initial_and_enabled_upgrade() {
    begin_case L04 'full pinned default_postinst enables initial install and restarts an enabled upgrade'
    install_fixture || { fail 'L04 fixture setup failed'; return; }
    assert_rc 0 'L04 normal default_postinst succeeds' run_default_postinst 0
    assert_path_exists "$SERVICE_LINK" 'L04 initial wrapper enables START99'
    assert_path_exists "$STOP_LINK" 'L04 initial wrapper enables STOP10'
    assert_path_exists /opt/outdoor-backup/conf/aliases.json 'L04 custom postinst retains aliases initialization'
    mkdir -p "$RUNTIME"
    printf '%s' 'running:8' > "$RUNTIME/state"
    assert_rc 0 'L04 enabled upgrade default_postinst succeeds' run_default_postinst 1
    assert_path_exists "$SERVICE_LINK" 'L04 enabled upgrade remains enabled'
    assert_equal "$(state_text)" 'running:9' 'L04 enabled upgrade uses restart and advances epoch'
}

case_disabled_upgrade_and_admin_start() {
    begin_case L05 'full disabled upgrade stays stopped while explicit administrator start remains available'
    install_fixture || { fail 'L05 fixture setup failed'; return; }
    mkdir -p "$RUNTIME"
    printf '%s' 'stopped:12' > "$RUNTIME/state"
    assert_rc 0 'L05 disabled upgrade default_postinst is a no-op success' run_default_postinst 1
    assert_path_absent "$SERVICE_LINK" 'L05 disabled upgrade does not enable service'
    assert_equal "$(state_text)" 'stopped:12' 'L05 disabled upgrade does not reopen a stopped generation'
    assert_rc 0 'L05 explicit start outside upgrade succeeds while disabled' run_init start
    assert_equal "$(state_text)" 'running:13' 'L05 administrator start creates next generation'
}

case_default_prerm_remove_and_upgrade() {
    begin_case L06 'full pinned default_prerm stops both paths but disables only normal removal'
    install_fixture || { fail 'L06 fixture setup failed'; return; }
    ln -s ../init.d/outdoor-backup "$SERVICE_LINK"
    ln -s ../init.d/outdoor-backup "$STOP_LINK"
    mkdir -p "$RUNTIME" /mnt/ssd/SDMirrors
    printf '%s' 'running:20' > "$RUNTIME/state"
    printf '%s' preserved > /mnt/ssd/SDMirrors/sentinel
    assert_rc 0 'L06 normal default_prerm succeeds' run_default_prerm 0
    assert_path_absent "$SERVICE_LINK" 'L06 normal removal default loop disables service'
    assert_equal "$(state_text)" 'stopped:20' 'L06 normal removal stops service'
    assert_equal "$(awk '{print}' /mnt/ssd/SDMirrors/sentinel)" preserved 'L06 removal preserves backup data'
    ln -s ../init.d/outdoor-backup "$SERVICE_LINK"
    ln -s ../init.d/outdoor-backup "$STOP_LINK"
    printf '%s' 'running:21' > "$RUNTIME/state"
    assert_rc 0 'L06 upgrade default_prerm succeeds' run_default_prerm 1
    assert_path_exists "$SERVICE_LINK" 'L06 upgrade default loop keeps enablement'
    assert_equal "$(state_text)" 'stopped:21' 'L06 upgrade stops service'
}

case_prerm_preserves_custom_failure() {
    begin_case L07 'full default_prerm keeps custom controller failure despite its later default loop'
    install_fixture || { fail 'L07 fixture setup failed'; return; }
    ln -s ../init.d/outdoor-backup "$SERVICE_LINK"
    ln -s ../init.d/outdoor-backup "$STOP_LINK"
    install_controller_double 73
    assert_rc 73 'L07 wrapper preserves exact custom stop error' run_default_prerm 0
    assert_path_absent "$SERVICE_LINK" 'L07 default loop may disable after failed custom prerm'
    assert_equal "$(awk 'END {print NR}' "$TEST_ROOT/controller.calls")" 2 \
        'L07 custom and default stop calls are both visible, but final rc is preserved'
}

case_prerm_real_residual_lock() {
    begin_case L08 'real residual business lock makes full prerm fail without deleting lock or data'
    install_fixture || { fail 'L08 fixture setup failed'; return; }
    ln -s ../init.d/outdoor-backup "$SERVICE_LINK"
    ln -s ../init.d/outdoor-backup "$STOP_LINK"
    mkdir -p "$RUNTIME" "${BUSINESS_LOCK%/*}" /mnt/ssd/SDMirrors
    printf '%s' 'running:31' > "$RUNTIME/state"
    printf '%s' residue > "$BUSINESS_LOCK"
    printf '%s' preserved > /mnt/ssd/SDMirrors/sentinel
    assert_rc 1 'L08 real residual lock preserves controller failure through wrapper' run_default_prerm 0
    assert_path_exists "$BUSINESS_LOCK" 'L08 prerm never deletes the business lock'
    assert_equal "$(awk '{print}' "$BUSINESS_LOCK")" residue 'L08 business lock content remains intact'
    assert_equal "$(awk '{print}' /mnt/ssd/SDMirrors/sentinel)" preserved 'L08 prerm preserves backup data'
    assert_equal "$(state_text)" 'stopped:31' 'L08 failure leaves the service closed'
}

case_staged_prerm_skips_controller() {
    begin_case L09 'staged custom prerm exits before any controller invocation'
    install_fixture || { fail 'L09 fixture setup failed'; return; }
    install_controller_double 73
    assert_rc 0 'L09 staged custom prerm returns its IPKG_INSTROOT early success' \
        /bin/ash -c 'IPKG_INSTROOT="$1" /bin/ash "$2"' ash "$TEST_ROOT/staging" \
        "$PACKAGE_INFO/outdoor-backup.prerm-pkg"
    assert_path_absent "$TEST_ROOT/controller.calls" 'L09 staged prerm must not invoke controller'
}

case_package_metadata_contract() {
    begin_case L10 'Makefile release and BusyBox flock dependencies cover the delivered lifecycle scripts'
    assert_success 'L10 package release is exactly 11' \
        grep -F -x -q 'PKG_RELEASE:=11' "$MAKEFILE"
    assert_success 'L09 custom BusyBox declares flock Kconfig' \
        grep -F -q '+@BUSYBOX_CUSTOM:BUSYBOX_CONFIG_FLOCK' "$MAKEFILE"
    assert_success 'L09 default BusyBox declares flock capability' \
        grep -F -q '+@!BUSYBOX_CUSTOM:BUSYBOX_DEFAULT_FLOCK' "$MAKEFILE"
    assert_success 'L09 wildcard installation includes controller and state library' \
        /bin/ash -c 'grep -F -q "\$(INSTALL_BIN) ./files/opt/outdoor-backup/scripts/*.sh \$(1)/opt/outdoor-backup/scripts/" "$1" && test -f "$2/service-control.sh" && test -f "$2/service-state.sh"' \
        ash "$MAKEFILE" "$SOURCE_SCRIPTS"
}

main() {
    install_fixed_wrappers || { printf '%s\n' 'FAIL: cannot install exact pinned wrappers' >&2; exit 1; }
    trap 'rm -rf /opt/outdoor-backup /etc/init.d/outdoor-backup /etc/rc.d/S99outdoor-backup /etc/rc.d/K10outdoor-backup /etc/config/outdoor-backup /var/run/outdoor-backup /mnt/ssd/SDMirrors' EXIT INT TERM
    case_start_failure_forwarding
    case_stop_restart_failure_forwarding
    case_reload_is_nonlifecycle
    case_private_mutant_oracles
    case_real_stop_and_restart
    case_default_postinst_initial_and_enabled_upgrade
    case_disabled_upgrade_and_admin_start
    case_default_prerm_remove_and_upgrade
    case_prerm_preserves_custom_failure
    case_prerm_real_residual_lock
    case_staged_prerm_skips_controller
    case_package_metadata_contract
    assert_equal "$CASES" "$EXPECTED_CASES" 'all required lifecycle cases executed'
    assert_equal "$ASSERTIONS" "$EXPECTED_ASSERTIONS" 'all required lifecycle assertions executed exactly'
    printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
    [ "$FAILED" -eq 0 ]
}

main "$@"

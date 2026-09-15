#!/bin/sh
# BDD regression tests for the LuCI menu/ACL group contract.
# The delivered JSON and package recipe are checked directly in the pinned
# OpenWrt rootfs, where jsonfilter is available and jq is intentionally absent.
set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${IN_OPENWRT_TEST:-}" != "1" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 \
        -e IN_OPENWRT_TEST=1 \
        -v "$REPO_ROOT:/src:ro" \
        "$IMAGE@$IMAGE_DIGEST" /bin/ash /src/test-luci-acl.sh
fi

REPO_ROOT=/src
ACL_JSON="$REPO_ROOT/luci-app-outdoor-backup/root/usr/share/rpcd/acl.d/outdoor-backup.json"
MENU_JSON="$REPO_ROOT/luci-app-outdoor-backup/root/usr/share/luci/menu.d/luci-app-outdoor-backup.json"
MAKEFILE="$REPO_ROOT/luci-app-outdoor-backup/Makefile"
FIXTURE_FILE=
POSTINST_FIXTURE_FILE=
COMMENTED_POSTINST_FIXTURE_FILE=
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

assert_success_nonempty_stdout() {
    message=$1
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    output=$("$@" 2>/dev/null) || { fail "$message"; return; }
    if [ -z "$output" ]; then
        fail "$message (empty extraction)"
    fi
}

assert_file_contains() {
    needle=$1
    file=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! grep -F -q -- "$needle" "$file"; then
        fail "$message (missing=[$needle])"
    fi
}

assert_file_lacks_regex() {
    pattern=$1
    file=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if grep -E -q -- "$pattern" "$file"; then
        fail "$message (unexpected-match=[$pattern])"
    fi
}

assert_file_contains_regex() {
    pattern=$1
    file=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! grep -E -q -- "$pattern" "$file"; then
        fail "$message (missing-match=[$pattern])"
    fi
}

assert_active_contains() {
    needle=$1
    file=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! grep -v -E '^[[:space:]]*#' "$file" | grep -F -q -- "$needle"; then
        fail "$message (missing-active=[$needle])"
    fi
}

assert_active_lacks() {
    needle=$1
    file=$2
    message=$3
    ASSERTIONS=$((ASSERTIONS + 1))
    if grep -v -E '^[[:space:]]*#' "$file" | grep -F -q -- "$needle"; then
        fail "$message (unexpected-active-match=[$needle])"
    fi
}

extract_postinst() {
    if ! awk '
        $0 == "define Package/luci-app-outdoor-backup/postinst" {
            definitions += 1
            if (in_block) {
                invalid = 1
            }
            in_block = 1
            next
        }
        in_block && $0 == "endef" {
            if (lines == 0) {
                invalid = 1
            }
            in_block = 0
            next
        }
        in_block {
            print
            lines += 1
            if ($0 ~ /[^[:space:]]/) {
                nonempty = 1
            }
        }
        END {
            if (definitions != 1 || in_block || invalid || !nonempty) {
                exit 1
            }
        }
    ' "$MAKEFILE" > "$POSTINST_FIXTURE_FILE"; then
        printf '%s\n' 'FAIL: Makefile postinst definition is not exactly one non-empty block' >&2
        exit 1
    fi
}

case_l01_both_json_files_parse() {
    begin_case L01 'ACL and menu JSON parse with jsonfilter'
    assert_success 'L01 ACL JSON parses' jsonfilter -i "$ACL_JSON" -e '@'
    assert_success 'L01 menu JSON parses' jsonfilter -i "$MENU_JSON" -e '@'
}

case_l02_menu_acl_dependencies_resolve() {
    begin_case L02 'every menu ACL dependency resolves to an ACL group'
    dependencies=$(jsonfilter -i "$MENU_JSON" -e '@.*.depends.acl[*]' 2>/dev/null)
    ASSERTIONS=$((ASSERTIONS + 1))
    if [ -z "$dependencies" ]; then
        fail 'L02 menu depends.acl extraction returned no elements'
        return
    fi
    while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        assert_success_nonempty_stdout "L02 ACL group exists: $dependency" \
            jsonfilter -i "$ACL_JSON" -e "@[\"$dependency\"]"
    done <<EOF
$dependencies
EOF
}

case_l03_new_acl_group_exists() {
    begin_case L03 'new luci-app-outdoor-backup ACL group exists'
    assert_success 'L03 new ACL group is present' \
        jsonfilter -i "$ACL_JSON" -e '@["luci-app-outdoor-backup"]'
}

case_l04_old_acl_group_is_absent() {
    begin_case L04 'old outdoor-backup ACL group is absent'
    assert_failure 'L04 old ACL group is absent' \
        jsonfilter -i "$ACL_JSON" -e '@["outdoor-backup"]'
}

case_l05_makefile_installs_source_menu() {
    begin_case L05 'Makefile installs the checked-in menu source without echo bypass'
    assert_file_contains \
        '$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-outdoor-backup.json' \
        "$MAKEFILE" 'L05 Makefile installs the checked-in menu source'
    menu_redirect_pattern='> *\$\(1\)/usr/share/luci/menu\.d'
    assert_file_lacks_regex \
        "$menu_redirect_pattern" \
        "$MAKEFILE" 'L05 Makefile has no menu.d redirection'
    FIXTURE_FILE=${TMPDIR:-/tmp}/test-luci-acl-menu-redirect.$$
    printf '%s\n' "echo '{}' > \$(1)/usr/share/luci/menu.d/x.json" >"$FIXTURE_FILE"
    assert_file_contains_regex \
        "$menu_redirect_pattern" \
        "$FIXTURE_FILE" 'L05 redirect pattern matches echo bypass fixture'
}

case_l06_postinst_flushes_luci_caches() {
    begin_case L06 'package postinst flushes stale LuCI caches'
    POSTINST_FIXTURE_FILE=${TMPDIR:-/tmp}/test-luci-acl-postinst.$$
    extract_postinst
    assert_active_contains \
        'rm -f /tmp/luci-indexcache.*' "$POSTINST_FIXTURE_FILE" \
        'L06 postinst removes the LuCI index cache'
    assert_active_contains \
        'rpcd reload' "$POSTINST_FIXTURE_FILE" \
        'L06 postinst reloads rpcd'
    assert_active_contains \
        'IPKG_INSTROOT' "$POSTINST_FIXTURE_FILE" \
        'L06 postinst guards on IPKG_INSTROOT'

    COMMENTED_POSTINST_FIXTURE_FILE=${TMPDIR:-/tmp}/test-luci-acl-postinst-commented.$$
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' '# rm -f /tmp/luci-indexcache.*'
        printf '%s\n' '#/etc/init.d/rpcd reload'
        printf '%s\n' '  # IPKG_INSTROOT guard commented out too'
    } >"$COMMENTED_POSTINST_FIXTURE_FILE"
    assert_active_lacks \
        'rm -f /tmp/luci-indexcache.*' "$COMMENTED_POSTINST_FIXTURE_FILE" \
        'L06 self-check: commented index-cache line must not read as active'
    assert_active_lacks \
        'rpcd reload' "$COMMENTED_POSTINST_FIXTURE_FILE" \
        'L06 self-check: commented rpcd reload must not read as active'
    assert_active_lacks \
        'IPKG_INSTROOT' "$COMMENTED_POSTINST_FIXTURE_FILE" \
        'L06 self-check: commented IPKG_INSTROOT guard must not read as active'
}

cleanup() {
    if [ -n "$FIXTURE_FILE" ]; then
        rm -f -- "$FIXTURE_FILE"
    fi
    if [ -n "$POSTINST_FIXTURE_FILE" ]; then
        rm -f -- "$POSTINST_FIXTURE_FILE"
    fi
    if [ -n "$COMMENTED_POSTINST_FIXTURE_FILE" ]; then
        rm -f -- "$COMMENTED_POSTINST_FIXTURE_FILE"
    fi
}

main() {
    trap cleanup EXIT INT TERM
    case_l01_both_json_files_parse
    case_l02_menu_acl_dependencies_resolve
    case_l03_new_acl_group_exists
    case_l04_old_acl_group_is_absent
    case_l05_makefile_installs_source_menu
    case_l06_postinst_flushes_luci_caches
    if [ "$CASES" -ne 6 ]; then
        fail "all required LuCI ACL cases executed (expected=6, actual=$CASES)"
    fi
    if [ "$FAILED" -ne 0 ]; then
        printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
        exit 1
    fi
    printf 'cases=%s assertions=%s failed=0\n' "$CASES" "$ASSERTIONS"
}

main "$@"

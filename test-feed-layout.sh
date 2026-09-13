#!/bin/sh
# BDD contract for OpenWrt feed discovery and the core package's runtime sources.

set -u

REPO_ROOT=${REPO_ROOT:-/src}
CORE_MAKEFILE="$REPO_ROOT/outdoor-backup/Makefile"
LUCI_MAKEFILE="$REPO_ROOT/luci-app-outdoor-backup/Makefile"
ROOT_MAKEFILE="$REPO_ROOT/Makefile"
CORE_FILES="$REPO_ROOT/outdoor-backup/files"
ROOT_FILES="$REPO_ROOT/files"
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

assert_file() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ -f "$1" ] || fail "$2 (missing file: $1)"
}

assert_absent() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "$2 (present path: $1)"
}

assert_grep() {
    ASSERTIONS=$((ASSERTIONS + 1))
    grep -F -x -q "$1" "$2" || fail "$3"
}

assert_symlink_target() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ] || fail "$3"
}

assert_resolved_directory() {
    ASSERTIONS=$((ASSERTIONS + 1))
    [ -d "$1" ] && [ -d "$2" ] || fail "$3"
}

assert_contains() {
    ASSERTIONS=$((ASSERTIONS + 1))
    grep -F -q "$1" "$2" || fail "$3"
}

case_l01_core_recipe_is_a_feed_package() {
    begin_case L01 'core package recipe resides in the standard feed subdirectory'
    assert_file "$CORE_MAKEFILE" 'L01 core recipe is missing from outdoor-backup/'
    # shellcheck disable=SC2016 # The Make expression is the required literal recipe token.
    assert_grep '$(eval $(call BuildPackage,outdoor-backup))' "$CORE_MAKEFILE" \
        'L01 core recipe does not declare the outdoor-backup package'
}

case_l02_luci_recipe_is_a_feed_package() {
    begin_case L02 'LuCI package recipe remains a valid feed subdirectory package'
    assert_file "$LUCI_MAKEFILE" 'L02 LuCI recipe is missing from luci-app-outdoor-backup/'
    # shellcheck disable=SC2016 # The Make expression is the required literal recipe token.
    assert_grep '$(eval $(call BuildPackage,luci-app-outdoor-backup))' "$LUCI_MAKEFILE" \
        'L02 LuCI recipe does not declare the luci-app-outdoor-backup package'
}

case_l03_root_has_no_scannable_recipe() {
    begin_case L03 'feed root contains no package Makefile for scan.mk to truncate'
    assert_absent "$ROOT_MAKEFILE" 'L03 feed root still exposes a package Makefile'
}

case_l04_core_files_are_the_single_runtime_source() {
    begin_case L04 'core recipe resolves files through one relative symlink to root runtime sources'
    assert_symlink_target "$CORE_FILES" '../files' \
        'L04 outdoor-backup/files is not the required ../files symlink'
    assert_resolved_directory "$CORE_FILES" "$ROOT_FILES" \
        'L04 core files symlink does not resolve to the root runtime source tree'
    assert_file "$CORE_FILES/opt/outdoor-backup/scripts/backup-manager.sh" \
        'L04 core files symlink does not expose the runtime script tree'
}

case_l05_install_sources_exist_at_recipe_relative_paths() {
    begin_case L05 'all key Makefile installation inputs exist below canonical recipe-relative files/'
    assert_file "$CORE_FILES/opt/outdoor-backup/conf/backup.conf" \
        'L05 configuration install source is missing'
    assert_file "$CORE_FILES/etc/hotplug.d/block/90-outdoor-backup" \
        'L05 hotplug install source is missing'
    assert_file "$CORE_FILES/etc/init.d/outdoor-backup" \
        'L05 init install source is missing'
    # shellcheck disable=SC2016 # The Make install macro is intentionally searched literally.
    assert_contains '$(INSTALL_BIN) ./files/opt/outdoor-backup/scripts/*.sh $(1)/opt/outdoor-backup/scripts/' \
        "$CORE_MAKEFILE" 'L05 core recipe no longer installs its recipe-relative scripts'
}

main() {
    [ -d "$REPO_ROOT" ] || {
        printf 'FAIL: repository root is unavailable: %s\n' "$REPO_ROOT" >&2
        exit 1
    }

    case_l01_core_recipe_is_a_feed_package
    case_l02_luci_recipe_is_a_feed_package
    case_l03_root_has_no_scannable_recipe
    case_l04_core_files_are_the_single_runtime_source
    case_l05_install_sources_exist_at_recipe_relative_paths

    ASSERTIONS=$((ASSERTIONS + 1))
    if [ "$CASES" -ne 5 ]; then
        fail "all required cases executed (expected=5, actual=$CASES)"
    fi
    if [ "$ASSERTIONS" -ne 13 ]; then
        fail "all required assertions executed (expected=13, actual=$ASSERTIONS)"
    fi
    printf 'cases=%s assertions=%s failed=%s\n' "$CASES" "$ASSERTIONS" "$FAILED"
    [ "$FAILED" -eq 0 ]
}

main "$@"

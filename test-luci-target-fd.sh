#!/bin/ash
# Exercise real FD inheritance through LuCI target discovery and target_open.
set -u

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 --network bridge \
        -v "$REPO_ROOT:/src:ro" "$IMAGE@$IMAGE_DIGEST" \
        /bin/ash /src/test-luci-target-fd.sh --inside
fi

fail_setup() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

mkdir -p /var/lock || fail_setup 'cannot create OpenWrt package lock directory'
opkg update >/dev/null || fail_setup 'cannot refresh OpenWrt package metadata'
opkg install lua luci-compat uci libuci-lua >/dev/null || \
    fail_setup 'cannot install Lua and LuCI dependencies'

TEST_ROOT=/opt/outdoor-backup/scripts
TEST_DIR="$TEST_ROOT/target-fd-$$"
SENTINEL="$TEST_DIR/fd-sentinel"
LUA_TEST="$TEST_DIR/target-fd-test.lua"
OPEN_TEST="$TEST_DIR/target-open-test.sh"
NON_TARGET="$TEST_DIR/not-a-mounted-target"
OCCUPIED_RESULT="$TEST_DIR/occupied.result"
CLOSED_RESULT="$TEST_DIR/closed.result"
OPEN_RESULT="$TEST_DIR/open.result"

mkdir -p "$NON_TARGET" || fail_setup 'cannot create guest-only target directory'
printf '%s\n' 'FD 9 sentinel' > "$SENTINEL" || fail_setup 'cannot create guest-only FD sentinel'

cat > /opt/outdoor-backup/scripts/target-list.sh <<'PROBE'
#!/bin/ash
if [ -e "/proc/$$/fd/9" ]; then
    printf '%s\n' '{"targets":[],"current":{"target_mount":"/mnt/current","backup_root":"/mnt/current/SDMirrors"}}'
else
    printf '%s\n' '{"targets":[{"device":"/dev/sdb1","uuid":"FD-TEST-UUID","mount":"/mnt/fd-test","fstype":"ext4"}],"current":{"target_mount":"/mnt/current","backup_root":"/mnt/current/SDMirrors"}}'
fi
PROBE
chmod 755 /opt/outdoor-backup/scripts/target-list.sh || fail_setup 'cannot make guest probe executable'

cat > "$LUA_TEST" <<'LUA'
local test_case = assert(arg[1], "missing test case")
local sentinel = arg[2] or ""
local result_path = assert(arg[3], "missing result path")
local nixio_fs = require "nixio.fs"
local target = assert(loadfile("/src/luci-app-outdoor-backup/luasrc/model/outdoor-backup/target.lua"))()
local cases, assertions, failed = 0, 0, 0

local function begin(id, description)
    cases = cases + 1
    print("CASE " .. id .. ": " .. description)
end

local function check(condition, message)
    assertions = assertions + 1
    if condition then
        print("PASS: " .. message)
    else
        io.stderr:write("FAIL: " .. message .. "\n")
        failed = failed + 1
    end
end

if test_case == "occupied" then
    begin("F01", "occupied parent FD remains visible around real io.popen")
    local before = nixio_fs.readlink("/proc/self/fd/9")
    local document = target.list()
    local after = nixio_fs.readlink("/proc/self/fd/9")
    check(before == sentinel, "occupied parent FD 9 points to the sentinel before list()")
    check(document and document.targets and #document.targets == 1,
        "occupied parent FD still discovers exactly one candidate")
    check(after == before, "occupied parent FD 9 is unchanged after list()")
elseif test_case == "closed" then
    begin("F02", "closed parent FD stays absent around real io.popen")
    local before = nixio_fs.readlink("/proc/self/fd/9")
    local document = target.list()
    local after = nixio_fs.readlink("/proc/self/fd/9")
    check(before == nil, "closed parent FD 9 is absent before list()")
    check(document and document.targets and #document.targets == 1,
        "closed parent FD discovers exactly one candidate")
    check(after == nil, "closed parent FD 9 remains absent after list()")
else
    io.stderr:write("FAIL: unknown test case: " .. test_case .. "\n")
    os.exit(2)
end

if cases ~= 1 then
    io.stderr:write(string.format("FAIL: Lua case count expected=1 actual=%d\n", cases))
    failed = failed + 1
end
if assertions ~= 3 then
    io.stderr:write(string.format("FAIL: Lua assertion count expected=3 actual=%d\n", assertions))
    failed = failed + 1
end
local result = assert(io.open(result_path, "w"), "cannot write Lua test result")
result:write(string.format("%d %d %d\n", cases, assertions, failed))
result:close()
print(string.format("CASE_RESULT %s cases=%d assertions=%d failed=%d", test_case, cases, assertions, failed))
os.exit(failed == 0 and 0 or 1)
LUA

cat > "$OPEN_TEST" <<'OPEN_TEST_SCRIPT'
#!/bin/ash
set -u
sentinel=$1
target_dir=$2
result_path=$3

fail_setup() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 2
}

exec 9<"$sentinel" || fail_setup 'cannot open guest FD sentinel on descriptor 9'
. /src/files/opt/outdoor-backup/scripts/target.sh || fail_setup 'cannot source delivered target.sh'

cases=1
assertions=0
failed=0
check() {
    description=$1
    shift
    assertions=$((assertions + 1))
    if "$@"; then
        printf 'PASS: %s\n' "$description"
    else
        printf 'FAIL: %s\n' "$description" >&2
        failed=$((failed + 1))
    fi
}

if target_open "$target_dir"; then
    target_open_rc=0
else
    target_open_rc=$?
fi
fd9_link=$(readlink "/proc/$$/fd/9" 2>/dev/null || :)
check 'target_open refuses a non-root directory when FD 9 is occupied' test "$target_open_rc" -ne 0
check 'target_open rejection preserves the original FD 9 sentinel link' test "$fd9_link" = "$sentinel"

printf '%s %s %s\n' "$cases" "$assertions" "$failed" > "$result_path" || \
    fail_setup 'cannot write target_open test result'
printf 'CASE_RESULT target_open cases=%s assertions=%s failed=%s\n' "$cases" "$assertions" "$failed"
[ "$failed" -eq 0 ]
OPEN_TEST_SCRIPT
chmod 755 "$OPEN_TEST" || fail_setup 'cannot make guest target_open test executable'

cases=0
assertions=0
failed=0
begin_case() {
    cases=$((cases + 1))
    printf 'CASE %s: %s\n' "$1" "$2"
}

record_result() {
    result_path=$1
    expected_assertions=$2
    result_name=$3
    if [ ! -r "$result_path" ]; then
        printf 'FAIL: %s result file is missing\n' "$result_name" >&2
        failed=$((failed + 1))
        return
    fi
    IFS=' ' read -r result_cases result_assertions result_failed < "$result_path" || {
        printf 'FAIL: %s result file is unreadable\n' "$result_name" >&2
        failed=$((failed + 1))
        return
    }
    for count in "$result_cases" "$result_assertions" "$result_failed"; do
        case $count in
            ''|*[!0-9]*)
                printf 'FAIL: %s result contains a nonnumeric count\n' "$result_name" >&2
                failed=$((failed + 1))
                return
                ;;
        esac
    done
    if [ "$result_cases" -ne 1 ]; then
        printf 'FAIL: %s case count expected=1 actual=%s\n' "$result_name" "$result_cases" >&2
        failed=$((failed + 1))
    fi
    if [ "$result_assertions" -ne "$expected_assertions" ]; then
        printf 'FAIL: %s assertion count expected=%s actual=%s\n' \
            "$result_name" "$expected_assertions" "$result_assertions" >&2
        failed=$((failed + 1))
    fi
    assertions=$((assertions + result_assertions))
    failed=$((failed + result_failed))
}

begin_case F01 'occupied parent FD is tested through real io.popen'
# Expand positional parameters in the guest ash, not in this parent shell.
# shellcheck disable=SC2016
if /bin/ash -c 'exec 9<"$1" || exit 2; exec lua "$2" occupied "$1" "$3"' \
    target-fd-occupied "$SENTINEL" "$LUA_TEST" "$OCCUPIED_RESULT"; then
    occupied_rc=0
else
    occupied_rc=$?
fi
printf 'CHILD_EXIT occupied rc=%s\n' "$occupied_rc"
record_result "$OCCUPIED_RESULT" 3 occupied

begin_case F02 'closed parent FD is tested through real io.popen'
# Expand positional parameters in the guest ash, not in this parent shell.
# shellcheck disable=SC2016
if /bin/ash -c 'exec 9>&- || exit 2; exec lua "$1" closed "" "$2"' \
    target-fd-closed "$LUA_TEST" "$CLOSED_RESULT"; then
    closed_rc=0
else
    closed_rc=$?
fi
printf 'CHILD_EXIT closed rc=%s\n' "$closed_rc"
record_result "$CLOSED_RESULT" 3 closed

begin_case F03 'target_open refuses an occupied FD 9 without closing it'
if /bin/ash "$OPEN_TEST" "$SENTINEL" "$NON_TARGET" "$OPEN_RESULT"; then
    open_rc=0
else
    open_rc=$?
fi
printf 'CHILD_EXIT target_open rc=%s\n' "$open_rc"
record_result "$OPEN_RESULT" 2 target_open

if [ "$cases" -ne 3 ]; then
    printf 'FAIL: total case count expected=3 actual=%s\n' "$cases" >&2
    failed=$((failed + 1))
fi
if [ "$assertions" -ne 8 ]; then
    printf 'FAIL: total assertion count expected=8 actual=%s\n' "$assertions" >&2
    failed=$((failed + 1))
fi
if [ "$failed" -ne 0 ]; then
    printf 'cases=%s assertions=%s failed=%s\n' "$cases" "$assertions" "$failed"
    exit 1
fi
printf 'cases=%s assertions=%s failed=0\n' "$cases" "$assertions"

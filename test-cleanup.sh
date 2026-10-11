#!/bin/bash
# Given/When/Then cleanup suite. One exclusively owned mktemp fixture; no real media.
# Run inside an isolated Linux/OpenWrt guest with bash, jq, mount and flock.
set -u
REPO=$(dirname "$(readlink -f "$0")")
SCRIPTS="$REPO/files/opt/outdoor-backup/scripts"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/outdoor-cleanup.XXXXXX") || exit 1
MOUNTS=()
finish() {
    local path
    for path in "${MOUNTS[@]}"; do umount "$path" 2>/dev/null || :; done
    rm -rf -- "$TEST_ROOT"
}
trap finish EXIT
SID=11111111-1111-4111-8111-111111111111
SID2=22222222-2222-4222-8222-222222222222
RAN=0 PASSED=0 FAILED=0 ASSERTIONS=0
check() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if ! "$@"; then printf 'ASSERTION FAILED (line %s): %s\n' "${BASH_LINENO[0]}" "$*" >&2; return 1; fi
}
# Setup actual manager/modules and real tmpfs FD9 anchor; only block hardware is synthetic.
setup() {
    BASE="$TEST_ROOT/case-$RAN"
    mkdir -p "$BASE/scripts" "$BASE/conf" "$BASE/target" "$BASE/uci" "$BASE/bin" "$BASE/runtime" "$BASE/var/lock" || return 1
    cp "$SCRIPTS/"*.sh "$BASE/scripts/" || return 1
    mount -t tmpfs tmpfs "$BASE/target" || return 1
    MOUNTS+=("$BASE/target")
    ROOT="$BASE/target/SDMirrors"
    mkdir -p "$ROOT/$SID" "$ROOT/$SID2" "$ROOT/.card-identities" "$BASE/sys/dev/block" "$BASE/sys/class/block" "$BASE/sys/devices/sda/sda1" "$BASE/sys/devices/sdb/sdb1" || return 1
    printf sentinel > "$ROOT/$SID/media.bin"
    printf second > "$ROOT/$SID2/media.bin"
    printf identity > "$ROOT/.card-identities/history.json"
    printf '{"version":"1.0","aliases":{"%s":{"alias":"<中文>"}}}\n' "$SID" > "$BASE/conf/aliases.json"
    printf 'running:1' > "$BASE/runtime/state"
    printf '1 0 8:1 / / rw - ext4 /dev/sda1 rw\n' > "$BASE/system-mountinfo"
    local mm
    mm=$(awk -v path="$BASE/target" '$5 == path {print $3}' /proc/self/mountinfo) || return 1
    for node in sda sdb; do
        printf 'DEVNAME=%s\n' "$node" > "$BASE/sys/devices/$node/uevent"
    done
    printf 'DEVNAME=sda1\n' > "$BASE/sys/devices/sda/sda1/uevent"
    printf 'DEVNAME=sdb1\n' > "$BASE/sys/devices/sdb/sdb1/uevent"
    printf '8:1\n' > "$BASE/sys/devices/sda/sda1/dev"
    printf '%s\n' "$mm" > "$BASE/sys/devices/sdb/sdb1/dev"
    printf 1 > "$BASE/sys/devices/sda/sda1/partition"
    printf 1 > "$BASE/sys/devices/sdb/sdb1/partition"
    ln -s "$BASE/sys/devices/sda/sda1" "$BASE/sys/dev/block/8:1"
    ln -s "$BASE/sys/devices/sdb/sdb1" "$BASE/sys/dev/block/$mm"
    cat > "$BASE/bin/block" <<'BLOCK'
#!/bin/sh
[ "$#" = 2 ] && [ "$1" = info ] && [ "$2" = /dev/sdb1 ] || exit 1
printf '/dev/sdb1: UUID="%s" TYPE="ext4"\n' "${CLEANUP_BLOCK_UUID:-target-uuid}"
BLOCK
    chmod +x "$BASE/bin/block"
    cat > "$BASE/bin/rm" <<'WRITER'
#!/bin/sh
case "$*" in */fd/9/*) printf '%s\0' "$@" >> "$CLEANUP_BASE/media-writer-argv" ;; esac
exec /bin/rm "$@"
WRITER
    chmod +x "$BASE/bin/rm"
    export CLEANUP_BASE="$BASE"
    config mirror "$ROOT"
    export UCI_CONFIG_DIR="$BASE/uci" OUTDOOR_BACKUP_SERVICE_DIR="$BASE/runtime" TARGET_SYSFS_ROOT="$BASE/sys" TARGET_MOUNTINFO_FILE="$BASE/system-mountinfo"
    export PATH="$BASE/bin:$ORIGINAL_PATH"
    unset CLEANUP_BLOCK_UUID
    check "$BASE/bin/block" info /dev/sdb1 >/dev/null
}
config() {
    printf 'ENABLED=1\nBACKUP_LAYOUT=%s\nBACKUP_ROOT="%s"\nLIBRARY_ROOT="%s/target/MediaLibrary"\nTARGET_MOUNT="%s/target"\nTARGET_UUID=target-uuid\nMOUNT_POINT="%s/source"\n' "$1" "$2" "$BASE" "$BASE" "$BASE" > "$BASE/conf/backup.conf"
}
invoke() {
    /bin/sh "$BASE/scripts/backup-manager.sh" "$@" > "$BASE/out" 2> "$BASE/err"
    RC=$?
}
reject() {
    invoke "$@"
    check test "$RC" -ne 0 || return 1
    check test "$(< "$ROOT/$SID/media.bin")" = sentinel || return 1
    check test ! -e "$BASE/source" || return 1
    check test ! -e "$BASE/var/status.json" || return 1
    check test ! -e "$BASE/log/backup.log" || return 1
    check test ! -e "$BASE/var/lock/backup.lock" || return 1
    check test ! -e "$BASE/media-writer-argv" || return 1
}
case_no_force() {
    /bin/sh "$BASE/scripts/cleanup-all.sh" "$ROOT" 0 > "$BASE/out" 2> "$BASE/err"; RC=$?
    check test "$RC" = 1 || return 1
    check grep -Fq 'force_required' "$BASE/err" || return 1
    check test "$(< "$ROOT/$SID/media.bin")" = sentinel || return 1
    check test ! -e "$BASE/log" || return 1
    check jq -e '.aliases | length == 1' "$BASE/conf/aliases.json" >/dev/null || return 1
}
case_cli() {
    local args
    for args in 'extra' 'invalid-keep' 'duplicate-force'; do
        case "$args" in
            extra) set -- --force "$ROOT" 1 extra ;;
            invalid-keep) set -- --force "$ROOT" 2 ;;
            duplicate-force) set -- --force --force "$ROOT" ;;
        esac
        /bin/sh "$BASE/scripts/cleanup-all.sh" "$@" > "$BASE/out" 2> "$BASE/err"; RC=$?
        check test "$RC" = 1 || return 1
    done
    check test "$(< "$ROOT/$SID/media.bin")" = sentinel
}
# Force cannot grant authority to a bucket, source UUID, target mount or foreign root.
case_force_paths() {
    local path
    for path in "$BASE/target" "$ROOT/$SID" "$BASE/target/MediaLibrary/2026/20261011/$SID" "$BASE/other"; do
        /bin/sh "$BASE/scripts/cleanup-all.sh" --force "$path" 1 > "$BASE/out" 2> "$BASE/err"; RC=$?
        check test "$RC" = 2 || return 1
        check test ! -e "$BASE/media-writer-argv" || return 1
        check test "$(< "$ROOT/$SID/media.bin")" = sentinel || return 1
    done
}
case_root_symlink() {
    mv "$ROOT" "$BASE/target/real"
    ln -s "$BASE/target/real" "$ROOT"
    reject cleanup "$ROOT" 1 && check test "$RC" = 2
}
case_ancestor_symlink() {
    ln -s "$BASE/target" "$BASE/target/linked"
    config mirror "$BASE/target/linked/SDMirrors"
    reject cleanup "$BASE/target/linked/SDMirrors" 1 && check test "$RC" = 2
}
case_roots_contain() {
    config mirror "$ROOT"
    printf 'LIBRARY_ROOT="%s/inside"\n' "$ROOT" >> "$BASE/conf/backup.conf"
    reject cleanup "$ROOT" 1 || return 1
    config mirror "$ROOT"
    printf 'LIBRARY_ROOT="%s/target"\n' "$BASE" >> "$BASE/conf/backup.conf"
    reject cleanup-preview "$ROOT"
}
case_no_force_missing() {
    rm "$BASE/conf/aliases.json"
    /bin/sh "$BASE/scripts/cleanup-all.sh" "$BASE/target/Absent" 0 > "$BASE/out" 2> "$BASE/err"; RC=$?
    check test "$RC" = 1 && check test ! -e "$BASE/target/Absent" && check test ! -e "$BASE/conf/aliases.json" && check test ! -e "$BASE/var/lock/backup.lock"
}
case_alias_corrupt() { printf broken > "$BASE/conf/aliases.json"; reject cleanup "$ROOT" 0 && check test "$RC" = 3; }
case_alias_newline() {
    jq --arg sid "$SID" '.aliases[$sid].alias="<中文>\n"' "$BASE/conf/aliases.json" > "$BASE/alias-new"
    mv "$BASE/alias-new" "$BASE/conf/aliases.json"
    invoke cleanup-preview "$ROOT"
    check test "$RC" = 0 && check jq -e --arg sid "$SID" '[.cards[]|select(.uuid==$sid)][0].display_name == "<中文>\n"' "$BASE/out" >/dev/null
}
case_preview_stale() {
    invoke cleanup-preview "$ROOT"
    check test "$RC" = 0 || return 1
    mkdir "$ROOT/$SID2/.outdoor-backup"
    reject cleanup "$ROOT" 1 && check test "$RC" = 4
}
case_date() { config date "$ROOT"; reject cleanup "$ROOT" 1 && check grep -Fq dateunsupported "$BASE/err"; }
case_force_date() {
    config date "$ROOT"
    /bin/sh "$BASE/scripts/cleanup-all.sh" --force "$ROOT" 1 > "$BASE/out" 2> "$BASE/err"; RC=$?
    check test "$RC" = 4 && check test "$(< "$ROOT/$SID/media.bin")" = sentinel
}
case_ancestor() { mkdir "$BASE/target/.outdoor-backup"; reject cleanup "$ROOT" 1 && check grep -Fq dateunsupported "$BASE/err"; }
case_marker() { ln -s nowhere "$ROOT/$SID2/.outdoor-backup"; reject cleanup "$ROOT" 0 && check grep -Fq dateunsupported "$BASE/err"; }
case_routes() { mkdir -p "$ROOT/$SID2/deep/routes"; reject cleanup "$ROOT" 1 && check grep -Fq dateunsupported "$BASE/err"; }
case_library() { printf broken > "$ROOT/$SID2/library.json"; reject cleanup "$ROOT" 1 && check grep -Fq dateunsupported "$BASE/err"; }
case_hidden_date() { mkdir -p "$ROOT/$SID2/.hidden/deep/.outdoor-backup"; reject cleanup-preview "$ROOT" && check grep -Fq dateunsupported "$BASE/err"; }
case_symlink() { ln -s "$ROOT/$SID" "$ROOT/$SID2/link"; reject cleanup "$ROOT" 1; }
case_fifo() { mkfifo "$ROOT/$SID2/fifo"; reject cleanup-preview "$ROOT"; }
case_wrong_root() { reject cleanup "$BASE/target" 1 && check grep -Fq badroot "$BASE/err"; }
case_other_root() { reject cleanup "$ROOT/$SID" 1 && check grep -Fq badroot "$BASE/err"; }
case_bucket() { reject cleanup "$BASE/target/MediaLibrary/2026/20261011/$SID" 1; }
case_missing() { config mirror "$BASE/target/Absent"; reject cleanup "$BASE/target/Absent" 1 && check test ! -e "$BASE/target/Absent"; }
case_nested_ancestor() {
    mkdir -p "$ROOT/nested/$SID"
    printf survive > "$ROOT/nested/$SID/file"
    config mirror "$ROOT/nested"
    mkdir "$ROOT/.outdoor-backup"
    reject cleanup "$ROOT/nested" 1
}
case_uuid_mismatch() { export CLEANUP_BLOCK_UUID=wrong-uuid; reject cleanup "$ROOT" 1; }
case_system_disk() { cp "$BASE/sys/devices/sdb/sdb1/dev" "$BASE/sys/devices/sda/sda1/dev"; reject cleanup "$ROOT" 1; }
case_submount() {
    mkdir "$ROOT/$SID2/mounted"
    mount -t tmpfs tmpfs "$ROOT/$SID2/mounted" || return 1
    MOUNTS=("$ROOT/$SID2/mounted" "${MOUNTS[@]}")
    reject cleanup "$ROOT" 1
}
case_unmounted() { umount "$BASE/target" || return 1; invoke cleanup "$ROOT" 1; check test "$RC" -ne 0; }
case_readfailure() {
    cat > "$BASE/bin/ls" <<'FAIL'
#!/bin/sh
printf attempted > "$CLEANUP_BASE/read-attempted"
exit 17
FAIL
    chmod +x "$BASE/bin/ls"
    export CLEANUP_BASE="$BASE"
    reject cleanup "$ROOT" 1 && check test "$RC" = 3 && check test -f "$BASE/read-attempted"
}
case_hidden() {
    mkdir -p "$ROOT/$SID/.keep" "$ROOT/$SID/visible/deep" "$ROOT/invalid"
    printf keep > "$ROOT/$SID/.keep/file"
    printf hidden > "$ROOT/$SID/.hidden"
    printf delete > "$ROOT/$SID/visible/deep/.nested-hidden"
    printf keep > "$ROOT/invalid/file"
    printf 'line\nname' > "$ROOT/$SID/line
name"
    invoke cleanup-preview "$ROOT"
    check test "$RC" = 0 || return 1
    check jq -e --arg root "$ROOT" --arg sid "$SID" '
        (keys | sort) == (["version","layout","backup_root","target_uuid","cards","total_size_bytes","total_cards"] | sort) and
        .version == 1 and .layout == "mirror" and .backup_root == $root and .target_uuid == "target-uuid" and
        .total_cards == 2 and .total_size_bytes == ([.cards[].size_bytes] | add) and
        all(.cards[]; (keys | sort) == (["uuid","display_name","size_bytes","path"] | sort) and
          (.uuid | type) == "string" and (.display_name | type) == "string" and (.size_bytes >= 0) and .path == ($root + "/" + .uuid)) and
        ([.cards[] | select(.uuid == $sid)][0].display_name == "<中文>")' "$BASE/out" >/dev/null || return 1
    check test -f "$ROOT/$SID/media.bin" || return 1
    cp "$BASE/conf/aliases.json" "$BASE/before"
    /bin/sh "$BASE/scripts/cleanup-all.sh" --force "$ROOT" 1 > "$BASE/out" 2> "$BASE/err"; RC=$?
    check test "$RC" = 0 || return 1
    check test ! -e "$ROOT/$SID/media.bin" || return 1
    check test ! -e "$ROOT/$SID/visible" || return 1
    check test ! -e "$ROOT/$SID/line
name" || return 1
    check test -d "$ROOT/$SID" || return 1
    check test -f "$ROOT/$SID/.hidden" || return 1
    check test -f "$ROOT/$SID/.keep/file" || return 1
    check test -f "$ROOT/invalid/file" || return 1
    check test -f "$ROOT/.card-identities/history.json" || return 1
    check cmp -s "$BASE/before" "$BASE/conf/aliases.json" || return 1
    # Independent NUL argv oracle: no hidden or identity item reaches rm.
    check jq -eRs --arg sid "$SID" --arg sid2 "$SID2" '
        split(([0]|implode))[:-1] as $args |
        ($args | length) == 12 and
        all(range(0;12;3); $args[.] == "-rf" and $args[.+1] == "--") and
        ([range(2;12;3) as $slot | $args[$slot] | split("/fd/9/SDMirrors/")[1]] | sort) ==
        ([$sid+"/media.bin", $sid+"/visible", $sid+"/line\nname", $sid2+"/media.bin"] | sort)
        ' "$BASE/media-writer-argv" >/dev/null || return 1
    invoke cleanup-preview "$ROOT"
    check jq -e '.total_size_bytes == 0 and .total_cards == 2' "$BASE/out" >/dev/null
}
case_clear_alias() {
    invoke cleanup "$ROOT" 0
    check test "$RC" = 0 && check jq -e '.version == "1.0" and .aliases == {}' "$BASE/conf/aliases.json" >/dev/null && check test -f "$ROOT/.card-identities/history.json"
}
case_rm_failure() {
    cat > "$BASE/bin/rm" <<'RM'
#!/bin/sh
case "$*" in *media.bin*) printf attempted > "$CLEANUP_BASE/rm-attempted"; exit 19 ;; esac
exec /bin/rm "$@"
RM
    chmod +x "$BASE/bin/rm"
    export CLEANUP_BASE="$BASE"
    reject cleanup "$ROOT" 1 && check test "$RC" = 3 && check test -f "$BASE/rm-attempted" && check grep -Fq failure "$BASE/err"
}
case_alias_symlink() { rm "$BASE/conf/aliases.json"; ln -s "$ROOT/$SID/media.bin" "$BASE/conf/aliases.json"; reject cleanup "$ROOT" 0; }
case_raw_arity() {
    reject cleanup-preview "$ROOT" extra || return 1
    reject cleanup "$ROOT" || return 1
    reject cleanup "$ROOT" 2
}
case_stopped() { printf stopped:1 > "$BASE/runtime/state"; reject cleanup "$ROOT" 1 && check grep -Fq busy "$BASE/err"; }
case_owner_argv() {
    local action root
    . "$BASE/scripts/target-device.sh"
    . "$BASE/scripts/owner-event.sh"
    for action in cleanup cleanup-preview; do
        printf '%s\0' /bin/sh "$BASE/scripts/backup-manager.sh" "$action" "$ROOT" > "$BASE/argv"
        [ "$action" != cleanup ] || printf '%s\0' 1 >> "$BASE/argv"
        check owner_event_cmdline_matches_stop "$BASE/argv" "$BASE/scripts/backup-manager.sh" || return 1
        owner_event_cmdline_matches "$BASE/argv" "$BASE/scripts/backup-manager.sh" sdc1 /devices/pci/block/sdc/sdc1 2; local match_rc=$?
        check test "$match_rc" -ne 0 || return 1
        printf '%s\0' extra >> "$BASE/argv"
        owner_event_cmdline_matches_stop "$BASE/argv" "$BASE/scripts/backup-manager.sh"; match_rc=$?
        check test "$match_rc" -ne 0 || return 1
    done
    for root in / /tmp/../bad /tmp//bad /tmp/trailing/ relative; do
        printf '%s\0' /bin/sh "$BASE/scripts/backup-manager.sh" cleanup "$root" 1 > "$BASE/argv"
        owner_event_cmdline_matches_stop "$BASE/argv" "$BASE/scripts/backup-manager.sh"; match_rc=$?
        check test "$match_rc" -ne 0 || return 1
    done
    printf '%s\0' /bin/sh "$BASE/scripts/backup-manager.sh" cleanup "$ROOT" 2 > "$BASE/argv"
    owner_event_cmdline_matches_stop "$BASE/argv" "$BASE/scripts/backup-manager.sh"; match_rc=$?
    check test "$match_rc" -ne 0 || return 1
    printf '%s\0' /bin/sh /tmp/not-manager cleanup "$ROOT" 1 > "$BASE/argv"
    owner_event_cmdline_matches_stop "$BASE/argv" "$BASE/scripts/backup-manager.sh"; match_rc=$?
    check test "$match_rc" -ne 0 || return 1
    printf '%s\0' /bin/sh "$BASE/scripts/backup-manager.sh" arbitrary "$ROOT" 1 > "$BASE/argv"
    owner_event_cmdline_matches_stop "$BASE/argv" "$BASE/scripts/backup-manager.sh"; match_rc=$?
    check test "$match_rc" -ne 0
}
case_stop_live() {
    cat > "$BASE/bin/rm" <<'RM'
#!/bin/sh
case "$*" in *media.bin*) printf running > "$CLEANUP_BASE/rm-started"; sleep 2; printf '%s\n' "$*" >> "$CLEANUP_BASE/writers" ;; esac
exec /bin/rm "$@"
RM
    chmod +x "$BASE/bin/rm"
    export CLEANUP_BASE="$BASE"
    /bin/sh "$BASE/scripts/backup-manager.sh" cleanup "$ROOT" 1 > "$BASE/out" 2> "$BASE/err" &
    local pid=$! iteration=0
    while [ ! -f "$BASE/rm-started" ] && [ "$iteration" -lt 10 ]; do sleep 1; iteration=$((iteration + 1)); done
    check test -f "$BASE/rm-started" || { kill -TERM "$pid" 2>/dev/null; wait "$pid"; return 1; }
    printf 'LIVE_ARGV='; jq -Rs 'split(([0]|implode))' "/proc/$pid/cmdline"
    /bin/sh "$BASE/scripts/backup-manager.sh" remove sdc1 /devices/pci/block/sdc/sdc1 2 > "$BASE/remove-out" 2> "$BASE/remove-err"; local remove_rc=$?
    check test "$remove_rc" = 0 || return 1
    check grep -Fq 'owner argv or event identity does not match' "$BASE/remove-err" || return 1
    check kill -0 "$pid" || return 1
    /bin/sh "$BASE/scripts/service-control.sh" stop > "$BASE/stop-out" 2> "$BASE/stop-err"; local stop_rc=$?
    wait "$pid"; RC=$?
    check test "$stop_rc" = 0 || return 1
    check grep -Fq 'requested stop from proven owner' "$BASE/stop-err" || return 1
    check test "$RC" = 143 || return 1
    check test "$(wc -l < "$BASE/writers")" = 1 || return 1
    check test -f "$ROOT/$SID2/media.bin" || return 1
    check test ! -L "$BASE/var/lock/backup.lock" || return 1
    check grep -Fq cancelled "$BASE/err"
}
case_competition() {
    cat > "$BASE/bin/du" <<'DU'
#!/bin/sh
printf ready > "$CLEANUP_BASE/du-started"
sleep 2
exec /usr/bin/du "$@"
DU
    # BusyBox installs du in /usr/bin on the supported guest.
    chmod +x "$BASE/bin/du"
    export CLEANUP_BASE="$BASE"
    /bin/sh "$BASE/scripts/backup-manager.sh" cleanup-preview "$ROOT" > "$BASE/first" 2> "$BASE/first-err" &
    local first=$! iteration=0
    while [ ! -f "$BASE/du-started" ] && [ "$iteration" -lt 10 ]; do sleep 1; iteration=$((iteration + 1)); done
    check test -f "$BASE/du-started" || { kill -TERM "$first" 2>/dev/null; wait "$first"; return 1; }
    /bin/sh "$BASE/scripts/backup-manager.sh" cleanup "$ROOT" 1 > "$BASE/second" 2> "$BASE/second-err" &
    local second=$!
    sleep 1
    check test -f "$ROOT/$SID/media.bin" || return 1
    /bin/sh "$BASE/scripts/service-control.sh" stop > "$BASE/stop-out" 2> "$BASE/stop-err"; local stop_rc=$?
    wait "$first"; local first_rc=$?
    wait "$second"; local second_rc=$?
    check test "$stop_rc" = 0 && check test "$first_rc" = 143 && check test "$second_rc" = 143 && check test -f "$ROOT/$SID/media.bin"
}
ORIGINAL_PATH=$PATH
for tool in jq mount flock bash; do command -v "$tool" >/dev/null || { printf 'BLOCKED missing %s\n' "$tool"; exit 1; }; done
CASES=(no_force cli date force_date ancestor marker routes library hidden_date symlink fifo wrong_root other_root bucket missing nested_ancestor uuid_mismatch system_disk submount unmounted readfailure hidden clear_alias rm_failure alias_symlink raw_arity stopped owner_argv stop_live competition force_paths root_symlink ancestor_symlink roots_contain no_force_missing alias_corrupt alias_newline preview_stale)
for name in "${CASES[@]}"; do
    RAN=$((RAN + 1))
    if setup && "case_$name"; then
        PASSED=$((PASSED + 1)); printf 'PASS %s\n' "$name"
    else
        FAILED=$((FAILED + 1)); printf 'FAIL %s\n' "$name"
        for diagnostic in err first-err second-err stop-err; do
            [ ! -f "$BASE/$diagnostic" ] || printf '%s\n' "$(< "$BASE/$diagnostic")"
        done
    fi
    PATH=$ORIGINAL_PATH
    unset CLEANUP_BASE
 done
printf 'SCENARIOS_RUN=%s EXPECTED_SCENARIOS=%s TESTS_PASSED=%s TESTS_FAILED=%s ASSERTIONS=%s EXPECTED_ASSERTIONS=340\n' "$RAN" "${#CASES[@]}" "$PASSED" "$FAILED" "$ASSERTIONS"
[ "$RAN" -eq 38 ] && [ "$PASSED" -eq 38 ] && [ "$FAILED" -eq 0 ] && [ "$ASSERTIONS" -eq 340 ]

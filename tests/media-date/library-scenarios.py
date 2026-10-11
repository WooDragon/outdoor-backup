#!/usr/bin/env python3
"""Executed Given/When/Then synthetic cases, not a scenario registry."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(sys.argv[1])
SCRIPTS = ROOT / 'files/opt/outdoor-backup/scripts'
SID = '11111111-1111-4111-8111-111111111111'
LID = '22222222-2222-4222-8222-222222222222'
OTHER = '33333333-3333-4333-8333-333333333333'
ran = passed = failed = assertions = 0


def library(**kw):
    return dict(version=1, library_id=LID, layout='date', parser_profile='media-date-v1', archive_offset_minutes=480, **kw)


def routes(nonempty=False, source=SID):
    entries = {}
    if nonempty:
        entries['old.bin'] = dict(group_anchor='old.bin', recording_identity=None, bucket='Undated', date_reason='no_capture_date', target_relpath=f'Undated/{source}/old.bin')
    return dict(version=1, library_id=LID, source_id=source, entries=entries)


def check(ok, msg):
    global assertions
    assertions += 1
    if not ok:
        raise AssertionError(msg)


def run_case(name, setup=None, action='media_date_prepare', success=True, error=None, after=None, shell_extra=''):
    global ran, passed, failed
    ran += 1
    if not success and error is None:
        expected = {'G02':'unknown_nonempty_library', 'G03':'unknown_nonempty_library', 'G04':'invalid_library', 'G05':'library_policy_changed', 'G07':'unsupported_filesystem', 'G10':'namespace_not_empty', 'G13':'tool_failed', 'G14':'invalid_probe', 'G15':'cancelled', 'G16':'cancelled', 'G17':'owner_lost', 'G21':'invalid_library_root', 'G22':'source_not_primary'}
        error = expected.get(name[:3])
        if name.startswith('G09'):
            error = 'routes_missing' if 'route=None' in name else ('identity_missing' if 'identity=None' in name else 'invalid_identity')
        if name.startswith(('G12','G19')):
            error = 'post_sync_failed' if 'FAIL_POST_SYNC' in name else ('rename_failed' if 'FAIL_RENAME' in name else 'pre_sync_failed')
    with tempfile.TemporaryDirectory(prefix='outdoor-library-synthetic-') as temp:
        base = pathlib.Path(temp).resolve()
        (base / 'target').mkdir()
        (base / 'source').mkdir()
        (base / 'var').mkdir()
        (base / 'source/current.bin').write_bytes(b'current')
        root = base / 'target/MediaLibrary'
        root.mkdir()
        if setup:
            setup(base, root)
        harness = f'''#!/bin/sh
BASE_DIR='{base}'
SCRIPT_DIR='{SCRIPTS}'
TARGET_MOUNT='{base}/target'
TARGET_MOUNT_PATH=$TARGET_MOUNT
LIBRARY_ROOT=$TARGET_MOUNT/MediaLibrary
TARGET_FD_ROOT=$TARGET_MOUNT
TARGET_FS_TYPE=ext4
MOUNT_POINT='{base}/source'
SD_UUID={SID}
SOURCE_FS_UUID=abcd-1234
BACKUP_MODE=PRIMARY
ARCHIVE_OFFSET_MINUTES=480
BACKUP_CANCEL_CODE=0
export LIBRARY_TEST_LIB='{ROOT}/files/opt/outdoor-backup/lib'
. "$SCRIPT_DIR/target.sh"
. "$SCRIPT_DIR/library-layout.sh"
. "$SCRIPT_DIR/card-identity.sh"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"
lock_is_owned_by_self() {{ [ "${{LOST_OWNER:-0}}" = 0 ]; }}
check_cancel_request() {{ [ "$BACKUP_CANCEL_CODE" = 0 ] || return "$BACKUP_CANCEL_CODE"; }}
target_anchor_healthy() {{ [ "${{LOST_ANCHOR:-0}}" = 0 ]; }}
transfer_process_run() {{
    printf '%s\n' "launch:$*" >> "$BASE_DIR/events"
    "$@"
    result=$?
    if [ "${{CANCEL_AFTER:-0}}" = 1 ]; then BACKUP_CANCEL_CODE=143; fi
    return "$result"
}}
sync() {{ printf '%s\n' sync >> "$BASE_DIR/events"; [ "${{FAIL_SYNC:-0}}" = 0 ]; }}
mv() {{ printf '%s\n' rename "rename-path:$*" >> "$BASE_DIR/events"; [ "${{FAIL_RENAME:-0}}" = 0 ] || return 1; command mv "$@"; if [ "${{FAIL_POST_SYNC:-0}}" = 1 ]; then FAIL_SYNC=1; fi; }}
card_identity_bind_original() {{ :; }}
. "$SCRIPT_DIR/media-date.sh"
media_date_helper() {{ media_date_run "$MEDIA_DATE_WORK/helper.json" perl '{ROOT}/tests/media-date/library-helper.pl' "$@"; }}
# APFS host cannot model ext4. Orchestration seam only, never a production flag.
# Loaded modules redefine this function during prepare, so inject at helper probe.
media_date_helper() {{
    if [ "$1" = probe ] && [ "${{REAL_CAPABILITY:-0}}" = 0 ]; then
        media_date_probe_filesystem() {{
            [ "${{CAPABILITY_FAILURE:-0}}" = 0 ] || {{ media_date_fail filesystem_capability_failed; return 1; }}
            case "$TARGET_FS_TYPE" in ext4|f2fs) media_date_guard ;; *) media_date_fail unsupported_filesystem ;; esac
        }}
    fi
    if [ "$1" = namespace-empty ] && [ "${{NAMESPACE_FAILURE:-0}}" = 1 ]; then
        media_date_run "$MEDIA_DATE_WORK/helper.json" /usr/bin/false
        return "$?"
    fi
    media_date_run "$MEDIA_DATE_WORK/helper.json" perl '{ROOT}/tests/media-date/library-helper.pl' "$@"
}}
{shell_extra}
{action}
rc=$?
printf '%s\n' "rc=$rc error=${{MEDIA_DATE_ERROR:-}} phase=${{MEDIA_DATE_PHASE:-}} work=${{MEDIA_DATE_WORK:-}} replaced=${{MEDIA_DATE_REPLACED_DIR:-}} bytes=${{MEDIA_DATE_SOURCE_BYTES_TOTAL:-}} count=${{MEDIA_DATE_REPLACED_COUNT:-}}" > "$BASE_DIR/outcome"
exit 0
'''
        harness_path = base / 'harness.sh'
        harness_path.write_text(harness)
        process = subprocess.run(['/bin/sh', str(harness_path)], text=True, capture_output=True)
        try:
            check(process.returncode == 0, f'harness failed {process.stderr}')
            outcome = (base / 'outcome').read_text()
            rc = int(outcome.split()[0].split('=')[1])
            check((rc == 0) == success, f'unexpected {outcome}; stderr={process.stderr}')
            if error:
                check(f'error={error}' in outcome, f'expected {error}: {outcome}')
            if after:
                after(base, root, outcome)
            passed += 1
            print(f'PASS {name}', flush=True)
        except Exception as exc:
            failed += 1
            print(f'FAIL {name}: {exc}', flush=True)


def existing(identity=None, route=None):
    def setup(base, root):
        meta = root / '.outdoor-backup'
        (meta / 'routes').mkdir(parents=True)
        (meta / 'library.json').write_text(json.dumps(library()))
        if route is not None:
            (meta / 'routes' / f'{SID}.json').write_text(json.dumps(routes(route)))
        if identity is not None:
            (root / '.card-identities').mkdir()
            (root / '.card-identities' / f'{SID}.json').write_text(json.dumps(dict(version=1, sd_uuid=SID, fs_uuid=identity)))
    return setup


def no_claim(base, root, outcome):
    check(not (root / '.card-identities' / f'{SID}.json').exists(), 'identity published on rejected initialization')


def initialized(base, root, outcome):
    check((root / '.outdoor-backup/library.json').is_file(), 'library not published')
    check((root / '.outdoor-backup/routes' / f'{SID}.json').is_file(), 'empty route not published')
    check((root / '.card-identities' / f'{SID}.json').is_file(), 'identity not claimed')
    events = (base / 'events').read_text().splitlines()
    check(events.count('rename') >= 3, 'missing library/route/identity publication')
    route_publish = next(i for i,e in enumerate(events) if e.startswith('rename-path:') and f'/routes/{SID}.json' in e)
    identity_publish = next(i for i,e in enumerate(events) if e.startswith('rename-path:') and f'/.card-identities/{SID}.json' in e)
    check(route_publish < identity_publish, 'identity claimed before empty route')
    check('sync' in events[route_publish + 1:identity_publish], 'empty route not post-synced before claim')
    check('sync' in events[:route_publish], 'empty route not pre-synced before rename')
    work = pathlib.Path(outcome.split('work=')[1].split()[0])
    check(work.stat().st_mode & 0o777 == 0o700, 'work permissions')


run_case('G01 missing library initializes empty root', after=initialized)
run_case('G02 unknown nonempty root refused', setup=lambda b,r:(r/'foreign').write_text('keep'), success=False, after=no_claim)
run_case('G03 residual routes without library refused', setup=lambda b,r:(r/'.outdoor-backup/routes').mkdir(parents=True), success=False, after=no_claim)
for label, text in [('empty',''), ('corrupt','{'), ('duplicate','{"version":1,"version":1}'), ('unknown','{"version":2}')]:
    def setup(b,r,text=text):
        existing()(b,r)
        (r/'.outdoor-backup/library.json').write_text(text)
    run_case(f'G04 library {label} refused', setup, success=False, after=no_claim)
run_case('G05 immutable offset refused', existing('abcd-1234', False), success=False, shell_extra='ARCHIVE_OFFSET_MINUTES=0')
run_case('G06 absent offset reads existing policy', existing('abcd-1234', False), shell_extra='ARCHIVE_OFFSET_MINUTES=')
run_case('G07 unsupported filesystem', success=False, shell_extra='TARGET_FS_TYPE=tmpfs', after=no_claim)
run_case('G08 capability failure before marker', success=False, shell_extra='CAPABILITY_FAILURE=1', error='filesystem_capability_failed', after=no_claim)
for identity, route, ok in [(None,None,True),(None,False,True),('abcd-1234',False,True),('abcd-1234',True,True),('abcd-1234',None,False),(None,True,False),('wrong',False,False)]:
    run_case(f'G09 admission identity={identity} route={route}', existing(identity,route), success=ok)
for space in ['Undated', 'date', 'partial', 'replaced']:
    def occupied(b,r,space=space):
        existing('abcd-1234',False)(b,r)
        path = {'Undated':f'Undated/{SID}', 'date':f'2026/20261010/{SID}', 'partial':f'Undated/{SID}/.rsync-partial', 'replaced':f'.outdoor-backup/replaced/old/Undated/{SID}'}[space]
        (r/path).mkdir(parents=True)
    run_case(f'G10 empty route occupied {space}', occupied, success=False)
def other_source(b,r):
    existing()(b,r)
    (r/f'Undated/{OTHER}').mkdir(parents=True)
run_case('G11 other source does not block registration', other_source)
for failure in ['FAIL_SYNC=1','FAIL_RENAME=1','FAIL_POST_SYNC=1']:
    run_case(f'G12 empty route publication {failure}', existing(), success=False, shell_extra=failure, after=no_claim)
run_case('G13 missing tool fails before metadata', success=False, shell_extra='media_date_helper() { media_date_run "$MEDIA_DATE_WORK/helper.json" /nonexistent/helper "$@"; }', after=no_claim)
for output in ['{', '{"version":2}', '{"version":1,"version":1}']:
    run_case(f'G14 malformed probe {output}', success=False, shell_extra=f'''media_date_helper() {{ printf '%s' '{output}' > "$MEDIA_DATE_WORK/helper.json"; }}''', after=no_claim)
run_case('G15 cancel before launch', success=False, shell_extra='BACKUP_CANCEL_CODE=143', after=no_claim)
run_case('G16 cancel after return', success=False, shell_extra='CANCEL_AFTER=1', after=no_claim)
run_case('G17 owner lost before launch', success=False, shell_extra='LOST_OWNER=1', after=no_claim)
run_case('G18 planner current files all in view', existing('abcd-1234',True), action='media_date_prepare && media_date_plan', after=lambda b,r,o: check((pathlib.Path(o.split('work=')[1].split()[0])/f'view/Undated/{SID}/current.bin').is_symlink(), 'current file excluded by registered history'))
for failure in ['FAIL_SYNC=1','FAIL_RENAME=1','FAIL_POST_SYNC=1']:
    def retained_route(b,r,o,failure=failure):
        entries=json.loads((r/'.outdoor-backup/routes'/f'{SID}.json').read_text())['entries']
        check('old.bin' in entries, 'historical mapping lost')
        check(('current.bin' in entries) == ('FAIL_POST_SYNC' in failure), 'pre-rename failure replaced old route or post-rename failure rolled back')
        check('phase=planning' in o, 'failed publication became ready')
    run_case(f'G19 candidate publication {failure}', existing('abcd-1234',True), action=f'media_date_prepare && {{ {failure}; media_date_plan; }}', success=False, after=retained_route)
run_case('G20 cleanup preserves library', action='media_date_prepare && media_date_cleanup', after=lambda b,r,o: check((r/'.outdoor-backup/library.json').exists(), 'cleanup removed library'))
run_case('G21 nested date root refused', success=False, shell_extra='LIBRARY_ROOT=$TARGET_MOUNT/nested/MediaLibrary')
run_case('G22 source REPLICA refused', success=False, shell_extra='BACKUP_MODE=REPLICA', after=no_claim)
run_case('G23 namespace checking failure refused', existing(None,False), success=False, shell_extra='NAMESPACE_FAILURE=1', error='namespace_not_empty')
run_case('G24 finish counts unusual paths', action=f'''media_date_prepare && media_date_plan && printf x > "$MEDIA_DATE_REPLACED_DIR/new
line" && media_date_finish_counts''', after=lambda b,r,o: check('count=1' in o, 'newline filename count incorrect'))
run_case('G25 independent target date entry accepts own marker', existing(), action='target_prepare_date_root "$LIBRARY_ROOT"')
# Independent oracle for the host synthetic directory, not target qualification.
with tempfile.TemporaryDirectory(prefix='outdoor-library-oracle-') as oracle:
    names = [pathlib.Path(oracle)/n for n in ['Case','case','é','é']]
    for index,path in enumerate(names):
        path.write_text(str(index))
    host_distinct = len({path.stat().st_ino for path in names}) == 4 and all(path.read_text() == str(i) for i,path in enumerate(names))
run_case('G26 actual host filesystem probe matches independent oracle', shell_extra='REAL_CAPABILITY=1', success=host_distinct, error=None if host_distinct else 'filesystem_capability_failed', after=initialized if host_distinct else no_claim)
for identity in [None, 'abcd-1234']:
    for route in [None, False]:
        if identity and route is None:
            continue
        def occupied_first(b,r,identity=identity,route=route):
            existing(identity,route)(b,r)
            (r/f'Undated/{SID}').mkdir(parents=True)
        run_case(f'G27 first state occupied identity={identity} route={route}', occupied_first, success=False, error='namespace_not_empty')
def nonempty_namespace(b,r):
    existing('abcd-1234',True)(b,r)
    (r/f'Undated/{SID}').mkdir(parents=True)
    (r/f'Undated/{SID}/old.bin').write_text('old')
run_case('G28 registered nonempty namespace allowed', nonempty_namespace, action='media_date_prepare && media_date_plan', after=lambda b,r,o: check('old.bin' in json.loads((r/'.outdoor-backup/routes'/f'{SID}.json').read_text())['entries'], 'deleted source history lost'))
for kind in ['duplicate','unknown','wrong-library','link']:
    def bad_route(b,r,kind=kind):
        existing('abcd-1234',False)(b,r)
        path=r/'.outdoor-backup/routes'/f'{SID}.json'
        if kind == 'link':
            path.unlink(); path.symlink_to(b/'foreign')
        elif kind == 'duplicate':
            path.write_text('{"version":1,"version":1}')
        else:
            value=routes(); value['version' if kind == 'unknown' else 'library_id']=2 if kind == 'unknown' else OTHER
            path.write_text(json.dumps(value))
    run_case(f'G29 invalid route {kind}', bad_route, success=False, error='invalid_routes')
def duplicate_identity(b,r):
    existing('abcd-1234',False)(b,r)
    (r/'.card-identities'/f'{SID}.json').write_text(f'{{"version":1,"version":1,"sd_uuid":"{SID}","fs_uuid":"abcd-1234"}}')
run_case('G30 duplicate identity strict refusal', duplicate_identity, success=False, error='invalid_identity')
run_case('G31 candidate temp creation fails', existing('abcd-1234',True), action='media_date_prepare && { mktemp() { return 1; }; media_date_plan; }', success=False, error='candidate_temp_failed')
for failure in ['LOST_OWNER=1','TRANSFER_PROCESS_PID=123']:
    run_case(f'G32 cleanup refuses {failure}', action=f'media_date_prepare && {{ {failure}; media_date_cleanup; }}', success=False, error='cleanup_owner_lost' if failure.startswith('LOST') else 'cleanup_runner_active', after=lambda b,r,o: check(pathlib.Path(o.split('work=')[1].split()[0]).exists(), 'unsafe cleanup deleted work'))
run_case('G33 cleanup preserves prior error and resets exports', action='media_date_prepare && { MEDIA_DATE_ERROR=sentinel; media_date_cleanup; }', after=lambda b,r,o: check('error=sentinel phase= work= replaced= bytes= count=' in o, 'cleanup erased error or retained exports'))
run_case('G34 cancel prevents a new launch', action='media_date_prepare && { BACKUP_CANCEL_CODE=143; media_date_plan; }', success=False, error='cancelled', after=lambda b,r,o: check(not any(' plan ' in e for e in (b/'events').read_text().splitlines()), 'planner launched after cancel'))
run_case('G35 mirror still refuses existing date marker', existing(), action='target_prepare_root "$LIBRARY_ROOT"', success=False)
# Candidate/result fault injection at the synthetic runner boundary, not JSON files
# asserted without execution. Actual planner still constructs the view and history.
for mutation in ['.version=2', '.outputs.view="foreign"', '.files_total="1"', '.warnings=[{source_relpath:"current.bin",code:"foreign"}]', '.routes_total=999']:
    extra=f'''transfer_process_run() {{
        printf '%s\\n' "launch:$*" >> "$BASE_DIR/events"
        "$@" > "$BASE_DIR/raw.json"
        result=$?
        if [ "$2" = '{ROOT}/tests/media-date/library-helper.pl' ] && [ "$3" = plan ] && [ "$result" = 0 ]; then
            jq '{mutation}' "$BASE_DIR/raw.json"
        else
            command cp "$BASE_DIR/raw.json" "$BASE_DIR/emitted.json"
            while IFS= read -r line; do printf '%s\\n' "$line"; done < "$BASE_DIR/emitted.json"
        fi
        return "$result"
    }}'''
    run_case(f'G36 strict result rejects {mutation}', existing('abcd-1234',True), action='media_date_prepare && media_date_plan', success=False, error='invalid_result', shell_extra=extra)
def unknown_profile(b,r):
    existing()(b,r)
    value=library(); value['parser_profile']='media-date-v2'
    (r/'.outdoor-backup/library.json').write_text(json.dumps(value))
run_case('G37 unknown complete policy profile rejected', unknown_profile, success=False, error='invalid_library', after=no_claim)
run_case('G38 absent direct root created', setup=lambda b,r:r.rmdir(), after=initialized)
run_case('G39 marked target ancestor rejected', setup=lambda b,r:(b/'target/.outdoor-backup').mkdir(), success=False, error='invalid_library_root', after=no_claim)
run_case('G40 cleanup refuses changed work inode', action='media_date_prepare && { mv "$MEDIA_DATE_WORK" "$BASE_DIR/var/saved"; mkdir -m 700 "$MEDIA_DATE_WORK"; media_date_cleanup; }', success=False, error='cleanup_work_changed')
# stdout and on-disk result agree here, so independent view/stat count validation
# (not merely comparing the two JSON files) must reject the bogus byte count.
extra=f'''transfer_process_run() {{
    "$@" > "$BASE_DIR/raw.json"
    result=$?
    if [ "$2" = '{ROOT}/tests/media-date/library-helper.pl' ] && [ "$3" = plan ] && [ "$result" = 0 ]; then
        jq '.source_bytes_total=999' "$BASE_DIR/raw.json" > "$4.fake"
        jq -r '.work_dir' "$4" > "$BASE_DIR/work-path"
        IFS= read -r work < "$BASE_DIR/work-path"
        command cp "$4.fake" "$work/result.json"
        while IFS= read -r line; do printf '%s\\n' "$line"; done < "$4.fake"
    else
        while IFS= read -r line; do printf '%s\\n' "$line"; done < "$BASE_DIR/raw.json"
    fi
    return "$result"
}}'''
run_case('G41 agreed result still checked against view counts', existing('abcd-1234',True), action='media_date_prepare && media_date_plan', success=False, error='invalid_result', shell_extra=extra)
run_case('G42 cancellation during route validation preserves 143', existing('abcd-1234',True), action='media_date_prepare && { CANCEL_AFTER=1; media_date_plan; }', success=False, error='cancelled', after=lambda b,r,o:check('rc=143' in o, 'sticky cancel exit masked'))
run_case('G43 cancelled owner can cleanup after drain', action='media_date_prepare && { MEDIA_DATE_ERROR=cancelled; BACKUP_CANCEL_CODE=143; media_date_cleanup; }', after=lambda b,r,o:check('error=cancelled phase= work=' in o, 'cancelled cleanup failed to reset work'))
run_case('G44 symlink marker refused', setup=lambda b,r:(r/'.outdoor-backup').symlink_to(b/'foreign'), success=False, error='invalid_metadata_directory', after=no_claim)
for assignment, reason in [('SD_UUID=invalid','invalid_source_id'),('SOURCE_FS_UUID=ABCD-1234','invalid_source_uuid')]:
    run_case(f'G45 invalid caller identifier {assignment}', success=False, shell_extra=assignment, error=reason, after=no_claim)
check(ran == 74, f'expected 74 cases, got {ran}')
print(f'ran={ran} passed={passed} failed={failed} blocked=2 assertions={assertions}; synthetic only; blocked=OpenWrt-toolchain,ext4/f2fs-target', flush=True)
sys.exit(1 if failed else 0)

#!/usr/bin/env python3
"""Given/When/Then: delivered manager/modules, synthetic devices and transport.
No production algorithm is copied. Real route/result/task validators run. Capability
and media transport doubles are explicitly not ext4/btrfs or real-rsync acceptance.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(sys.argv[1]).resolve()
arguments = sys.argv[2:]
INSIDE = bool(arguments and arguments[0] == '--inside')
if INSIDE:
    arguments.pop(0)
if len(arguments) > 1 or any(arg.startswith('--') for arg in arguments):
    sys.exit('usage: lifecycle-scenarios.py ROOT [--inside] [RESULT_JSON]')
if INSIDE:
    # Native entry never shells out to Docker, even with a stale host harness env.
    if sys.platform != 'linux' or not pathlib.Path('/proc/self/cmdline').read_bytes():
        sys.exit('FAIL: native lifecycle requires actual Linux /proc')
    for tool in ('perl', 'jq', 'rsync', 'setsid', 'flock'):
        if not shutil.which(tool):
            sys.exit(f'FAIL: native lifecycle missing required tool: {tool}')
SCRIPTS = ROOT / 'files/opt/outdoor-backup/scripts'
SID = '11111111-1111-4111-8111-111111111111'
LID = '22222222-2222-4222-8222-222222222222'
ran = passed = failed = assertions = blocked = 0
results = []

def check(condition, message):
    global assertions
    assertions += 1
    if not condition:
        raise AssertionError(message)

def execute_fixture(base, args, env):
    """Run host sh or an explicitly owned guest; all writes are disposable evidence."""
    guest = None if INSIDE else os.environ.get('LIFECYCLE_GUEST')
    if not guest:
        return subprocess.run(['/bin/sh', str(base/'scripts/backup-manager.sh'), *args], env=env, capture_output=True, text=True, timeout=35)
    owner = subprocess.check_output(['docker','inspect','--format','{{index .Config.Labels "outdoor-backup.lifecycle.owner"}}',guest],text=True).strip()
    if owner != '20261011-current-dispatch':
        raise RuntimeError('guest ownership is not this dispatch')
    destination = '/evidence/lifecycle-case'
    for path in [*list((base/'scripts').glob('*.sh')), base/'conf/backup.conf']:
        path.write_text(path.read_text().replace(str(base),destination).replace(str(ROOT),'/src'))
    subprocess.run(['docker','exec',guest,'mkdir','-p',destination],check=True)
    subprocess.run(['docker','cp',str(base)+'/.',guest+':'+destination],check=True,capture_output=True)
    keys = ('LIFECYCLE_FAILURE','LIBRARY_TEST_LIB','UCI_CONFIG_DIR','STATUS_MV')
    values = [key+'='+env[key].replace(str(base),destination).replace(str(ROOT),'/src') for key in keys if key in env]
    command = ['docker','exec',guest,'env','PATH='+destination+'/bin:/usr/sbin:/usr/bin:/sbin:/bin',*values,'/bin/sh',destination+'/scripts/backup-manager.sh',*args]
    proc = subprocess.run(command,capture_output=True,text=True,timeout=60)
    subprocess.run(['docker','cp',guest+':'+destination+'/.',str(base)],check=True,capture_output=True)
    # Only fixture snapshots/traces are normalized for the independent host oracle.
    for path in [base/'events',base/'var/status.json',*list((base/'snapshots').glob('*.json'))]:
        if path.exists():
            path.write_text(path.read_text().replace(destination,str(base)))
    subprocess.run(['docker','exec',guest,'rm','-rf',destination],check=True)
    return proc


def run_case(name, action='add', layout='date', comparison='quick', failure='', config='primary', expected=True, after=None, argv=None, existing='new', enabled=1):
    global ran, passed, failed, blocked
    if os.environ.get('LIFECYCLE_CASE') and name != os.environ['LIFECYCLE_CASE']:
        return
    if failure in ('cancel-live','stop-live') and not (INSIDE or os.environ.get('LIFECYCLE_GUEST')):
        blocked += 1
        results.append(dict(case=name,status='blocked',reason='Linux proc/session runner requires owned OpenWrt guest'))
        print(f'BLOCKED {name}: requires owned OpenWrt guest',flush=True)
        return
    ran += 1
    with tempfile.TemporaryDirectory(prefix='outdoor-lifecycle-owned-') as tmp:
        base = pathlib.Path(tmp).resolve()
        scripts = base / 'scripts'
        shutil.copytree(SCRIPTS, scripts)
        shutil.copytree(ROOT / 'files/opt/outdoor-backup/lib', base / 'lib')
        for child in ('var', 'conf', 'source', 'target', 'bin'):
            (base / child).mkdir()
        source = base / 'source'
        (source / 'new\n中文\t.bin').write_bytes(b'media')
        card = source / 'FieldBackup.conf'
        if config != 'absent':
            card.write_text(f'SD_UUID="{SID}"\nBACKUP_MODE="' + ('REPLICA' if config == 'replica' else 'PRIMARY') + '"\n' + ('bad = "data"\n' if config == 'invalid' else ''))
        original = card.read_bytes() if card.exists() else None
        library = base / 'target/MediaLibrary'
        if existing != 'new':
            (library / '.outdoor-backup/routes').mkdir(parents=True)
            (library / '.outdoor-backup/library.json').write_text(json.dumps(dict(version=1,library_id=LID,layout='date',parser_profile='media-date-v1',archive_offset_minutes=480)))
            if existing != 'missing-route':
                (library / '.outdoor-backup/routes' / f'{SID}.json').write_text(json.dumps(dict(version=1,library_id=LID,source_id=SID,entries={})))
            if existing in ('missing-route', 'empty-occupied', 'policy'):
                (library / '.card-identities').mkdir()
                (library / '.card-identities' / f'{SID}.json').write_text(json.dumps(dict(version=1,sd_uuid=SID,fs_uuid='abcd-1234')))
            if existing == 'empty-occupied':
                (library / f'Undated/{SID}').mkdir(parents=True)
            if existing == 'other-source':
                (library / 'Undated/33333333-3333-4333-8333-333333333333').mkdir(parents=True)
        conf = f'''BACKUP_LAYOUT={layout}
TARGET_MOUNT='{base}/target'
TARGET_UUID=target-uuid
BACKUP_ROOT='{base}/target/SDMirrors'
LIBRARY_ROOT='{library}'
MOUNT_POINT='{source}'
ARCHIVE_OFFSET_MINUTES={0 if existing == 'policy' else 480}
MIN_FREE_SPACE=0
ENABLED={enabled}
LED_RED=none
LED_GREEN=none
LED_GREEN2=none
LED_GREEN3=none
'''
        (base / 'conf/backup.conf').write_text(conf)
        env = os.environ.copy()
        env.update(LIFECYCLE_BASE=str(base), LIFECYCLE_FAILURE=failure, LIBRARY_TEST_LIB=str(base / 'lib'), UCI_CONFIG_DIR=str(base / 'no-uci'), PATH=str(base / 'bin') + ':' + env['PATH'])
        # Event trace is bounded fixture input; arbitrary transfer argv are separately
        # recorded as NUL bytes and decoded by Python, never shell word-split.
        seam = '''
lc_event() { printf '%s\n' "$1" >> "$BASE_DIR/events"; }
log_info() { lc_event "info:$1"; }
log_error() { lc_event "error:$1"; }
log_warn() { lc_event "warning:$1"; }
log_debug() { :; }
led_state_progress() { :; }
led_state_complete() { lc_event led-complete; }
led_state_reset_idle() { :; }
led_state_error() { :; }
led_state_unconfigured() { :; }
led_state_cancelled_operator() { :; }
led_state_cancelled_lease() { :; }
get_available_space_mb() { lc_event "space:$1"; if [ "$LIFECYCLE_FAILURE" = space ]; then printf unknown; else printf 99999; fi; }
update_alias_last_seen() { lc_event alias; }
get_display_name() { printf TestCard; }
generate_uuid() { printf '44444444-4444-4444-8444-444444444444'; }
mountpoint() { [ -e "$BASE_DIR/mounted" ]; }
mount() { lc_event "mount:$4"; touch "$BASE_DIR/mounted"; }
umount() { lc_event unmount; rm -f "$BASE_DIR/mounted"; }
sync() {
    lc_event sync
    if [ "$LIFECYCLE_FAILURE" = route-presync ] && [ "$LC_CANDIDATE_STAGED" = 1 ]; then lc_event inject:route-presync; return 1; fi
    [ "$LIFECYCLE_FAILURE" != cleanup-sync ] || [ "$LC_TRANSFER_DONE" != 1 ]
}
cp() {
    case "$1" in */routes.json)
        LC_CANDIDATE_STAGED=1
        if [ "$LIFECYCLE_FAILURE" = route-write ]; then lc_event inject:route-write; return 1; fi
        ;;
    esac
    command cp "$@"
}
mv() {
    case "$2" in */routes/*.json)
        lc_event route-publish
        LC_ROUTE_PUBLISH_COUNT=$((LC_ROUTE_PUBLISH_COUNT + 1))
        if [ "$LIFECYCLE_FAILURE" = route-rename ] && [ "$LC_ROUTE_PUBLISH_COUNT" = 2 ]; then lc_event inject:route-rename; return 1; fi
        command mv "$@" || return 1
        if [ "$LIFECYCLE_FAILURE" = route-sync ] && [ "$LC_ROUTE_PUBLISH_COUNT" = 2 ]; then lc_event inject:route-sync; LIFECYCLE_FAILURE=cleanup-sync; LC_TRANSFER_DONE=1; fi
        ;; */.card-identities/*.json) lc_event identity-publish; command mv "$@" ;; *) command mv "$@" ;; esac
}
rm() {
    case "$*" in *media-date.*) lc_event view-cleanup; if [ -f "${MEDIA_DATE_WORK:-}/stderr.log" ]; then cp "$MEDIA_DATE_WORK/stderr.log" "$BASE_DIR/helper-errors"; fi; [ "$LIFECYCLE_FAILURE" != cleanup ] || return 1 ;; esac
    command rm "$@"
}
LC_TRANSFER_DONE=0
LC_ROUTE_PUBLISH_COUNT=0
LC_CANDIDATE_STAGED=0
'''
        with (scripts / 'common.sh').open('a') as file:
            file.write(seam)
        with (scripts / 'service-state.sh').open('a') as file:
            file.write('''
service_lease_acquire() { [ "$LIFECYCLE_FAILURE" != admission ]; }
service_lease_current() { [ "$LIFECYCLE_FAILURE" != lease ] && [ ! -e "$BASE_DIR/lease-stopped" ]; }
service_lease_release() { :; }
''')
        with (scripts / 'target-device.sh').open('a') as file:
            file.write('''
target_device_validate() { [ "$LIFECYCLE_FAILURE" != target-final ] || [ "${LC_TRANSFER_DONE:-0}" != 1 ]; }
''')
        with (scripts / 'target.sh').open('a') as file:
            file.write('''
target_open() { TARGET_MOUNT_PATH=$1; TARGET_FD_ROOT=$1; TARGET_DEVICE=8:2; TARGET_FS_TYPE=ext4; TARGET_FD_OPEN=1; }
target_anchor_healthy() { [ "$LIFECYCLE_FAILURE" != anchor ] || [ "${LC_TRANSFER_DONE:-0}" != 1 ]; }
target_close() { :; }
''')
        with (scripts / 'source-identity.sh').open('a') as file:
            file.write('''
source_identity_read() { printf '{"filesystem_uuid":"abcd-1234"}'; }
source_identity_matches() { :; }
source_identity_snapshot_major_minor() { printf 8:1; }
source_identity_major_minor_is_mounted() { return 1; }
''')
        with (scripts / 'card-identity.sh').open('a') as file:
            file.write('''
card_identity_read_source_uuid() { if [ "$LIFECYCLE_FAILURE" = source-uuid ]; then printf changed; else printf abcd-1234; fi; }
''')
        # Adapter uses the delivered planner and strict validators with synthetic
        # metadata. Runtime module stays unchanged; runner consumes exact argv.
        helper = ROOT / 'tests/media-date/library-helper.pl'
        with (scripts / 'transfer-process.sh').open('a') as file:
            file.write(f'''
transfer_process_run() {{
    printf '%s\\0' "$@" >> "$BASE_DIR/argv.nul"
    lc_event "reader:$1"
    TRANSFER_PROCESS_PID=fixture-active
    transfer_process_observe
    case "$1:$2" in
        perl:*/media-date-plan.pl)
            shift 2
            if [ "$1" = probe ]; then media_date_probe_filesystem() {{ media_date_guard; }}; fi
            if [ "$1" = plan ] && [ "$LIFECYCLE_FAILURE" = planner ]; then lc_event inject:planner; rc=1
            else perl '{helper}' "$@"; rc=$?; fi
            if [ "$1" = plan ] && [ "$LIFECYCLE_FAILURE" = cancel ]; then record_cancel 143; fi
            if [ "$1" = plan ] && [ "$LIFECYCLE_FAILURE" = stop ]; then LIFECYCLE_FAILURE=lease; fi
            ;;
        rsync:*)
            lc_event actual-transfer
            LC_TRANSFER_DONE=1
            if [ "$LIFECYCLE_FAILURE" = transfer ]; then rc=23
            else "$@"; rc=$?; fi
            ;;
        *)
            if [ "$5" = counts ] && [ "$LIFECYCLE_FAILURE" = counts ]; then lc_event inject:counts; rc=1
            else "$@"; rc=$?; fi
            ;;
    esac
    TRANSFER_PROCESS_PID=
    lc_event drain
    return "$rc"
}}
''')
        if failure in ('cancel-live','stop-live'):
            process_script=scripts/'transfer-process.sh'
            process_script.write_text(process_script.read_text().replace('transfer_process_run() {','lc_actual_process_run() {',1)+f'''
transfer_process_run() {{
    printf '%s\\0' "$@" >> "$BASE_DIR/argv.nul"
    lc_event "reader:$1"
    case "$1:$2:$3" in
        perl:*/media-date-plan.pl:plan)
            mkdir -p "$MEDIA_DATE_WORK/view"
            . "$SCRIPT_DIR/owner-event.sh"
            cp "/proc/$$/cmdline" "$BASE_DIR/owner-cmdline.nul"
            lc_event "owner-path:$SCRIPT_DIR/backup-manager.sh"
            owner_event_cmdline_matches_stop "/proc/$$/cmdline" "$SCRIPT_DIR/backup-manager.sh" || return 1
            lc_event owner-argv-proven
            lc_actual_process_run /bin/sh '{ROOT}/tests/media-date/lifecycle-reader.sh' "$BASE_DIR" "$MEDIA_DATE_WORK/view" "$$" "$LIFECYCLE_FAILURE"
            rc=$?
            ;;
        perl:*/media-date-plan.pl:*)
            shift 2
            if [ "$1" = probe ]; then media_date_probe_filesystem() {{ media_date_guard; }}; fi
            lc_actual_process_run perl '{helper}' "$@"
            rc=$?
            ;;
        *) lc_actual_process_run "$@"; rc=$? ;;
    esac
    lc_event drain
    return "$rc"
}}
''')
        status_script = scripts / 'status.sh'
        status_script.write_text(status_script.read_text().replace('write_status() {', 'lc_write_status_actual() {') + '''
write_status() {
    lc_event "status:$1:argc:$#"
    if [ "$1" = completed ] && [ "$LIFECYCLE_FAILURE" = terminal-status ]; then lc_event inject:terminal-status; return 1; fi
    lc_write_status_actual "$@" || return 1
    mkdir -p "$BASE_DIR/snapshots"
    cp "$STATUS_FILE" "$BASE_DIR/snapshots/$(find "$BASE_DIR/snapshots" -type f | wc -l).json"
}
''')
        if failure not in ('cancel-live','stop-live'):
            (base / 'bin/setsid').write_text('#!/bin/sh\nexit 0\n')
        (base / 'bin/uuidgen').write_text(f'#!/bin/sh\nprintf "%s\\n" {LID}\n')
        (base / 'bin/rsync').write_text('''#!/bin/sh
for arg do
 case "$arg" in --log-file=*) log=${arg#--log-file=} ;; esac
done
: > "$log" || exit 1
printf '%s\n' 'Number of regular files transferred: 1' 'Total transferred file size: 5'
''')
        for path in (base / 'bin').iterdir():
            path.chmod(0o755)
        if failure == 'status':
            (base / 'bin/fail-status').write_text('#!/bin/sh\nexit 1\n')
            (base / 'bin/fail-status').chmod(0o755)
            env['STATUS_MV'] = str(base / 'bin/fail-status')
        if failure == 'summary':
            # Deny only manager append, not rsync log creation: shell function
            # appends fail through a non-regular log after the runner returns.
            with (scripts / 'transfer-process.sh').open('a') as file:
                file.write('''
lc_original_runner() { :; }
''')
            # Inject at cleanup's sync, after actual transfer; no algorithm copy.
            with (scripts / 'common.sh').open('a') as file:
                file.write('''
sync() { lc_event sync; if [ "$LC_TRANSFER_DONE" = 1 ]; then command rm -f "$BACKUP_LOG_FILE"; mkdir "$BACKUP_LOG_FILE"; fi; }
''')
        args = argv if argv is not None else [action, 'sda1', '/devices/pci/block/sda/sda1'] + ([comparison] if action == 'manual' else [])
        proc = execute_fixture(base, args, env)
        events = (base / 'events').read_text().splitlines() if (base / 'events').exists() else []
        status = json.loads((base / 'var/status.json').read_text()) if (base / 'var/status.json').exists() else None
        context = dict(base=base, library=library, source=source, events=events, status=status, original=original, proc=proc, existing=existing, env=env, args=args)
        try:
            check((proc.returncode == 0) == expected, f'rc={proc.returncode}; stderr={proc.stderr}; helper={(base/"helper-errors").read_text() if (base/"helper-errors").exists() else ""}; events={events}')
            if action == 'initialize' or not expected:
                check(not status or not any(item['status'] == 'completed' for item in status['history']), 'false completed')
            if failure in ('transfer','cleanup-sync','summary','target-final','anchor','counts','cleanup'):
                check('actual-transfer' in events, f'{failure} injection not reached after actual transfer')
            if failure in ('planner','route-write','route-presync','route-rename','route-sync','counts','terminal-status'):
                check(f'inject:{failure}' in events, f'{failure} injection never executed')
            if failure == 'status':
                check('status:running:argc:17' in events, 'status failure not reached')
            if after:
                after(context)
            passed += 1
            results.append(dict(case=name,status='passed',exit=proc.returncode,
                                real_drain=failure in ('cancel-live','stop-live'),
                                events=events if failure in ('cancel-live','stop-live') else []))
            print(f'PASS {name}', flush=True)
        except Exception as exc:
            failed += 1
            results.append(dict(case=name,status='failed',reason=str(exc),exit=proc.returncode,events=events,stderr=proc.stderr,owner_argv=(base/'owner-cmdline.nul').read_bytes().decode().split('\0') if (base/'owner-cmdline.nul').exists() else [],helper=(base/'helper-errors').read_text() if (base/'helper-errors').exists() else ''))
            print(f'FAIL {name}: {exc}', flush=True)

def no_transfer(ctx):
    check('actual-transfer' not in ctx['events'], 'unexpected rsync')

def no_rw(ctx):
    check('mount:rw' not in ctx['events'], 'unexpected RW source')

def completed(ctx):
    check(ctx['events'].count('actual-transfer') == 1, 'not exactly one actual transfer')
    check(ctx['status']['history'][0]['status'] == 'completed', 'missing completed')
    task = ctx['status']['history'][0]['task']
    check(task['layout'] == 'date' and task['phase'] == 'finalizing', 'wrong terminal task')
    check(task['archive']['files_total'] == 1 and task['archive']['undated_total'] == 1, 'result file counts not consumed')
    check(task['warnings'] == [dict(code='no_capture_date',count=1)], 'warning aggregation failed')
    check(ctx['status']['history'][0]['backup_path'] == str(ctx['library']), 'FD leaked as display path')
    check(ctx['events'].index('identity-publish') < ctx['events'].index('alias'), 'alias before identity admission')
    if ctx['existing'] == 'new':
        check(ctx['events'].index('route-publish') < ctx['events'].index('identity-publish'), 'route-first claim ordering')
    else:
        check((ctx['library']/'.outdoor-backup/routes'/f'{SID}.json').exists(), 'missing admitted pre-existing empty route')
    check(not list((ctx['base']/'var').glob('media-date.*')), 'private view not cleaned')
    check(ctx['events'].index('view-cleanup') < ctx['events'].index('unmount'), 'source unmounted before view cleanup')
    no_rw(ctx)
    snapshots=[json.loads(p.read_text()) for p in sorted((ctx['base']/'snapshots').glob('*.json'),key=lambda p:int(p.stem))]
    current=[s['current_backup'] for s in snapshots if s['current_backup']]
    check([c['task']['phase'] for c in current] == ['planning','transferring','finalizing'], 'incorrect phase progression or planner progress publication')
    check(all(value is None for value in current[0]['task']['archive'].values()), 'planning fabricated archive counts')
    check(current[0]['live_progress']['entries_total'] is None and not current[0]['live_progress']['files_known'], 'planning fabricated rsync observation')
    check(all(e.endswith('argc:17') for e in ctx['events'] if e.startswith('status:')), 'date status not seventeenth argument')
    log = next((ctx['library']/'.logs').glob('*.log')).read_text()
    check('Comparison Mode:' in log and 'size/mtime' in log and 'not a capacity guarantee' in log, 'missing comparison/risk boundary')

def absent(ctx):
    no_rw(ctx); no_transfer(ctx)
    check(not (ctx['source']/'FieldBackup.conf').exists(), 'auto initialized date card')
    check(not ctx['library'].exists(), 'date created before source admission')
    check(any('source_not_initialized' in event for event in ctx['events']), 'missing source_not_initialized')

def initialized(ctx):
    no_transfer(ctx)
    check((ctx['source']/'FieldBackup.conf').exists(), 'no config')
    check(not ctx['library'].exists(), 'initialization registered date library')
    check(not (ctx['base']/'target/SDMirrors').exists(), 'initialization created mirror')
    check('alias' not in ctx['events'], 'initialization updated alias')
    check('led-complete' not in ctx['events'], 'initialization shown as backup complete')
    check(ctx['status'] is None, 'initialization used media backup status writer')

def cancelled(ctx):
    no_transfer(ctx)
    check(ctx['proc'].returncode == 143, 'lost sticky cancel')
    check(any(e.startswith('error:') for e in ctx['events']), 'no failure outcome')
    check(not list((ctx['base']/'var').glob('media-date.*')), 'cancel left private work')
    check(ctx['events'].index('view-cleanup') > max(i for i,e in enumerate(ctx['events']) if e == 'drain'), 'cleanup before drain')
    # No new counts/helper reader after planning cancellation.
    check(ctx['events'][ctx['events'].index('view-cleanup')-1] != 'reader:perl', 'count reader after cancel')

def comparison_check(mode):
    def verify(ctx):
        completed(ctx)
        check(ctx['status']['history'][0]['task']['comparison_mode'] == mode, 'mode not frozen')
        argv=(ctx['base']/'argv.nul').read_bytes().split(b'\0')
        check((b'--checksum' in argv) == (mode == 'checksum'), 'wrong rsync comparison argv')
    return verify

def recovered(ctx):
    route = ctx['library']/'.outdoor-backup/routes'/f'{SID}.json'
    first_route = route.read_bytes()
    check(json.loads(first_route)['entries'], 'candidate not retained after publication')
    env=ctx['env'].copy()
    env['LIFECYCLE_FAILURE']=''
    proc=execute_fixture(ctx['base'],ctx['args'],env)
    check(proc.returncode == 0, f'recovery failed: {proc.stderr}')
    check(route.read_bytes() == first_route, 'recovery changed fixed route')
    snapshot=json.loads((ctx['base']/'var/status.json').read_text())
    check(snapshot['history'][0]['status']=='completed', 'recovery not completed')
    raw=(ctx['base']/'argv.nul').read_bytes().split(b'\0')
    check(b'--ignore-existing' not in raw and b'--delete' not in raw,'recovery unsafe argv')

run_case('M25 failed transfer route retained then retry',failure='transfer',expected=False,after=recovered)
run_case('M48 post-rename sync failure retained then retry',failure='route-sync',expected=False,after=recovered)
run_case('M37 date complete single transfer task', after=completed)
run_case('M45 date SOURCE_NOT_INITIALIZED', config='absent', expected=False, after=absent)
run_case('M45 mirror blank provisions and transfers',layout='mirror',config='absent',after=lambda c:check(c['events'].count('actual-transfer')==1,'mirror regression'))
run_case('initialize blank no library or backup',action='initialize',config='absent',after=initialized)
run_case('initialize configured never overwrites',action='initialize',after=lambda c:(initialized(c),check((c['source']/'FieldBackup.conf').read_bytes()==c['original'],'config overwritten')))
for cfg in ('replica','invalid'):
    run_case(f'M45 date {cfg} rejects',config=cfg,expected=False,after=lambda c:(no_rw(c),no_transfer(c)))
run_case('SOURCE UUID mismatch precedes date writes',failure='source-uuid',expected=False,after=lambda c:(no_transfer(c),check(not c['library'].exists(),'source mismatch wrote library')))
for fail in ('planner','route-write','route-presync','route-rename','route-sync','space'):
    run_case(f'M24/M48 {fail} no transfer',failure=fail,expected=False,after=no_transfer)
for fail in ('transfer','cleanup-sync','summary','target-final','anchor','status','terminal-status','counts','cleanup'):
    run_case(f'M27/M30 {fail} no completed',failure=fail,expected=False)
for fail in ('cancel','stop'):
    run_case(f'M28/M29 {fail} planning drain',failure=fail,expected=False,after=cancelled)
def live_cancelled(ctx):
    cancelled(ctx)
    check('owner-argv-proven' in ctx['events'], 'actual owner NUL argv not proven')
    check('child-view-retained' in ctx['events'] and 'child-view-deleted-too-early' not in ctx['events'], 'view deleted while reader alive')
    check(ctx['events'].index('child-view-retained') < ctx['events'].index('view-cleanup'), 'cleanup did not wait for child')

run_case('M28 real process-group TERM planning drain',failure='cancel-live',expected=False,after=live_cancelled)
run_case('M29 real process-group stop planning drain',action='manual',comparison='checksum',failure='stop-live',expected=False,after=live_cancelled)
run_case('M29 service admission closed',failure='admission',expected=False,after=no_transfer)
run_case('M43 other source route first claim',existing='other-source',after=completed)
for state in ('missing-route','empty-occupied','policy'):
    run_case(f'M26/M44 {state} rejected',existing=state,expected=False,after=no_transfer)
def manual_then_auto(ctx):
    comparison_check('checksum')(ctx)
    before=(ctx['base']/'conf/backup.conf').read_bytes()
    env=ctx['env'].copy()
    proc=execute_fixture(ctx['base'],['add','sda1','/devices/pci/block/sda/sda1'],env)
    check(proc.returncode==0,f'auto after manual failed: {proc.stderr}')
    status=json.loads((ctx['base']/'var/status.json').read_text())
    check(status['history'][0]['task']['comparison_mode']=='quick','manual changed next automatic mode')
    check((ctx['base']/'conf/backup.conf').read_bytes()==before,'task persisted comparison config')

run_case('M50 manual checksum then same-card automatic quick',action='manual',comparison='checksum',after=manual_then_auto)
run_case('M50 next automatic quick',after=comparison_check('quick'))
run_case('M50 manual quick',action='manual',after=comparison_check('quick'))
run_case('M50 mirror checksum explicitly unsupported',action='manual',layout='mirror',comparison='checksum',expected=False,after=no_transfer)
for args in (['manual','sda1','/devices/pci/sda1','other'],['manual','sda1','/devices/pci/sda1'],['initialize','sda1','/devices/pci/sda1','extra'],['manual','sda1','/devices/../sda1','quick'],['initialize','sda1','relative'],['manual','../sda1','/devices/pci/sda1','quick']):
    run_case('strict argv '+repr(args),argv=args,expected=False,after=no_transfer)
run_case('disabled add has no date writes',enabled=0,after=lambda c:(no_transfer(c),check(not c['library'].exists(),'disabled created root')))
run_case('legacy remove fast path',argv=['remove','sda1','/devices/pci/sda1'],after=no_transfer)
run_case('four-arg remove fast path',argv=['remove','sda1','/devices/pci/sda1','42'],after=no_transfer)
run_case('four-arg automatic add retains sequence and quick',argv=['add','sda1','/devices/pci/sda1','41'],after=comparison_check('quick'))
run_case('disabled four-arg add preserves fast path',argv=['add','sda1','/devices/pci/sda1','invalid-seq'],enabled=0,after=no_transfer)
run_case('disabled manual still validates path',argv=['manual','sda1','/devices/../sda1','quick'],enabled=0,expected=False,after=no_transfer)

print(f'ran={ran} passed={passed} failed={failed} blocked={blocked} assertions={assertions}',flush=True)
output = dict(kind='linux-native-synthetic-with-real-drain' if INSIDE else 'openwrt-synthetic-with-real-drain' if os.environ.get('LIFECYCLE_GUEST') else 'host-synthetic-not-filesystem-acceptance',ran=ran,passed=passed,failed=failed,blocked=blocked,assertions=assertions,cases=results)
if arguments:
    pathlib.Path(arguments[0]).write_text(json.dumps(output,ensure_ascii=False,indent=2)+'\n')
expected_cases = 1 if os.environ.get('LIFECYCLE_CASE') else 50
if ran + blocked != expected_cases:
    print(f'case count gate: expected {expected_cases} ran {ran}',flush=True)
    sys.exit(1)
sys.exit(1 if failed or blocked else 0)

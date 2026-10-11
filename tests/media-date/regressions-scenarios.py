#!/usr/bin/env python3
"""Concrete F1-F4/F8 inputs; real source, CLI bytes, private temporary fixtures."""
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(sys.argv[1])
S = ROOT / 'files/opt/outdoor-backup/scripts'
SID = '11111111-1111-4111-8111-111111111111'
LID = '22222222-2222-4222-8222-222222222222'
ran = passed = failed = 0


def case(name, fn):
    global ran, passed, failed
    ran += 1
    try:
        with tempfile.TemporaryDirectory(prefix='ob-regressions-') as temp:
            fn(pathlib.Path(temp))
        passed += 1
        print('PASS ' + name, flush=True)
    except Exception as exc:
        failed += 1
        print('FAIL ' + name + ': ' + str(exc), flush=True)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def shell(text):
    return subprocess.run(['/bin/sh', '-c', text], capture_output=True, text=True)


def config_case(base, extra='', uci=None, default=False, ok=True):
    conf = base / 'legacy'
    conf.write_text('BACKUP_ROOT=/mnt/ssd/MediaLibrary\n' + extra)
    config_dir = base / 'uci'
    config_dir.mkdir()
    if uci is not None:
        (config_dir / 'outdoor-backup').write_text("config outdoor-backup 'config'\n" + uci)
    result = shell(f'UCI_CONFIG_DIR={config_dir}; . {S}/config.sh; '
                   f'config_load {ROOT / "files/opt/outdoor-backup/conf/backup.conf" if default else conf} && '
                   'printf "layout=%s root=%s library=%s" "$BACKUP_LAYOUT" "$BACKUP_ROOT" "$LIBRARY_ROOT"')
    require((result.returncode == 0) == ok, result.stdout + result.stderr)
    if ok:
        require('layout=mirror' in result.stdout, result.stdout)


case('F1 old legacy without date fields accepts MediaLibrary mirror', lambda b: config_case(b))
case('F1 packaged defaults overridden by UCI mirror root', lambda b: config_case(b, default=True, uci="option backup_root '/mnt/ssd/MediaLibrary'\n"))
case('F1 explicit legacy library overlap rejected', lambda b: config_case(b, 'LIBRARY_ROOT=/mnt/ssd/MediaLibrary\n', ok=False))
case('F1 explicit UCI library overlap rejected', lambda b: config_case(b, uci="option library_root '/mnt/ssd/MediaLibrary'\n", ok=False))
case('F1 UCI overrides overlapping legacy library with disjoint root', lambda b: config_case(b, 'LIBRARY_ROOT=/mnt/ssd/MediaLibrary\n', uci="option library_root '/mnt/ssd/DateLibrary'\n"))
case('F1 date default overlap rejected', lambda b: config_case(b, 'BACKUP_LAYOUT=date\n', ok=False))


def marked(base):
    root = base / 'MediaLibrary'
    (root / '.outdoor-backup').mkdir(parents=True)
    result = shell(f'. {S}/library-layout.sh; library_layout_mirror_admit {root}')
    require(result.returncode != 0, 'marked date admitted as mirror')


case('F1 actual date marker still blocks mirror', marked)


def initialize(base, bad=False):
    root = base / 'library'
    work = base / 'work'
    root.mkdir(); work.mkdir(mode=0o700)
    binpath = base / 'bin'; binpath.mkdir()
    # No fake uuidgen: only actual guest utilities, kernel UUID fallback.
    for name in ['cat', 'tr', 'jq', 'perl', 'cmp', 'mktemp', 'cp', 'mv', 'rm']:
        found = subprocess.run(['/bin/sh', '-c', 'command -v ' + name], capture_output=True, text=True)
        require(found.returncode == 0, 'missing ' + name)
        (binpath / name).symlink_to(found.stdout.strip())
    override = 'generate_uuid() { printf invalid; }' if bad else ''
    result = shell(f'''
SCRIPT_DIR={S}; BASE_DIR={base}; TARGET_BACKUP_ROOT={root}; MEDIA_DATE_WORK={work}
MEDIA_DATE_LIBRARY_JSON={root}/.outdoor-backup/library.json; ARCHIVE_OFFSET_MINUTES=480
. "$SCRIPT_DIR/common.sh"; . "$SCRIPT_DIR/config.sh"; . "$SCRIPT_DIR/card-identity.sh"
. "$SCRIPT_DIR/library-layout.sh"; . "$SCRIPT_DIR/media-date.sh"
. "$SCRIPT_DIR/media-date-tools.sh"; . "$SCRIPT_DIR/media-date-publication.sh"
media_date_guard() {{ return 0; }}
transfer_process_run() {{ "$@"; }}
media_date_directory() {{ /bin/mkdir -p "$TARGET_BACKUP_ROOT/$1"; }}
sync() {{ return 0; }}
media_date_write_tools || exit 9
PATH={binpath}; export PATH
command -v uuidgen && exit 8
[ -r /proc/sys/kernel/random/uuid ] || exit 7
{override}
media_date_initialize; rc=$?
printf 'rc=%s error=%s\n' "$rc" "$MEDIA_DATE_ERROR"
exit "$rc"
''')
    require((result.returncode == 0) != bad, result.stdout + result.stderr)
    if not bad:
        obj = json.loads((root / '.outdoor-backup/library.json').read_text())
        require(len(obj['library_id']) == 36 and obj['layout'] == 'date', str(obj))
    else:
        require(not (root / '.outdoor-backup/library.json').exists(), 'invalid ID published')


case('F2 initialize without uuidgen uses real kernel UUID', lambda b: initialize(b))
case('F2 invalid generator ID fails before publication', lambda b: initialize(b, True))


def helper(*args):
    return subprocess.run([b'perl', os.fsencode(S / 'media-date-plan.pl'), *[os.fsencode(a) for a in args]], capture_output=True)


def cli_namespace(base, occupied=False):
    root = base / '中文库'
    root.mkdir()
    if occupied:
        (root / 'Undated' / SID).mkdir(parents=True)
    result = helper('namespace-empty', root, SID)
    require((result.returncode == 0) != occupied, repr(result.stdout + result.stderr))
    if occupied:
        require(json.loads(result.stdout) == {'version': 1, 'error': 'namespace_occupied'}, repr(result.stdout))
    else:
        require(json.loads(result.stdout) == {'version': 1, 'source_id': SID, 'empty': True}, repr(result.stdout))


case('F3 raw UTF8 namespace argv empty root', lambda b: cli_namespace(b))
case('F3 raw UTF8 namespace argv observes occupied actual bytes', lambda b: cli_namespace(b, True))


def nonutf(base):
    raw = os.fsencode(base) + b'/\xff'
    os.mkdir(raw)
    result = helper('namespace-empty', raw, SID)
    require(result.returncode != 0, 'non UTF8 argv accepted')
    require(not result.stdout or json.loads(result.stdout)['error'] == 'tool_failed', repr(result.stdout))


case('F3 non UTF8 argv fails closed', nonutf)


def plan_input(base):
    source = base / '中文来源'; root = base / '中文库'; work = base / '中文工作'
    for path in (source, root, work):
        path.mkdir(mode=0o700)
    (source / '照片.bin').write_bytes(b'concrete-bytes')
    routes = root / '路由.json'
    routes.write_text(json.dumps(dict(version=1, library_id=LID, source_id=SID, entries={})))
    request = base / '请求.json'
    request.write_text(json.dumps(dict(version=1, source_root=str(source), library_root=str(root), source_id=SID,
        library=dict(version=1, library_id=LID, layout='date', parser_profile='media-date-v1', archive_offset_minutes=480),
        route_file=str(routes), work_dir=str(work)), ensure_ascii=False))
    return source, root, work, routes, request


def plan_case(base, fault=None):
    source, root, work, routes, request = plan_input(base)
    if fault == 'foreign_target':
        (root / 'Undated' / SID).mkdir(parents=True)
        (root / 'Undated' / SID / '照片.bin').write_bytes(b'private-foreign')
    elif fault == 'invalid_routes_entries':
        obj = json.loads(routes.read_text()); obj['entries'] = []; routes.write_text(json.dumps(obj))
    result = helper('plan', request)
    if fault:
        require(result.returncode != 0, 'planner accepted ' + fault)
        require(json.loads(result.stdout) == dict(version=1, error=fault), repr(result.stdout + result.stderr))
        require(not (work / 'view').exists(), 'failed planning created view')
    else:
        require(result.returncode == 0, repr(result.stderr))
        view = work / 'view' / 'Undated' / SID / '照片.bin'
        require(view.is_symlink() and os.readlink(view) == str(source / '照片.bin'), 'mojibake link bytes')
        require(view.read_bytes() == b'concrete-bytes', 'wrong link bytes')
        require(json.loads(result.stdout)['files_total'] == 1, 'success schema changed')


case('F3 actual CLI request source/library/work UTF8 paths', lambda b: plan_case(b))
for error in ['foreign_target', 'invalid_routes_entries']:
    case('F4 actual helper controlled ' + error, lambda b, e=error: plan_case(b, e))


def read_json_cli(base, command):
    source, root, work, routes, request = plan_input(base)
    path = routes if command == 'validate-routes' else root / '库政策.json'
    if command == 'validate-library':
        path.write_text(json.dumps(json.loads(request.read_text())['library']))
    args = [command, path] + ([LID, SID] if command == 'validate-routes' else [])
    result = helper(*args)
    require(result.returncode == 0 and json.loads(result.stdout) == json.loads(path.read_text()), repr(result.stderr))


for command in ['validate-library', 'validate-routes']:
    case('F3 raw UTF8 readJSON argv ' + command, lambda b, c=command: read_json_cli(b, c))


def error_case(base, payload, expected):
    work = base / 'work'; work.mkdir(mode=0o700)
    output = work / 'helper.json'
    result = shell(f'''
SCRIPT_DIR={S}; MEDIA_DATE_WORK={work}; MEDIA_DATE_OWNED_WORK={work}
MEDIA_DATE_WORK_TOKEN=$(perl -e 'my @s=lstat($ARGV[0]); print join(":",@s[0,1,4])' {work})
. "$SCRIPT_DIR/media-date.sh"
media_date_guard() {{ return 0; }}
lock_is_owned_by_self() {{ return 0; }}
transfer_process_run() {{ printf '%s\n' {shlex.quote(payload)}; printf '%s\n' PRIVATE_GPS_SERIAL >&2; return 1; }}
media_date_helper plan ignored; rc=$?
[ "$rc" != 0 ] || exit 9
[ -f "$MEDIA_DATE_WORK/stderr.log" ] || exit 8
media_date_cleanup || exit 7
. "$SCRIPT_DIR/manager-date.sh"
MANAGER_DATE_PHASE=finalizing; BACKUP_COMPARISON_MODE=quick
write_status() {{ printf '%s\n%s\n' "${{14}}" "${{17}}" > {base}/public-state; }}
manager_date_status failed "$MEDIA_DATE_ERROR" || exit 6
printf '%s' "$MEDIA_DATE_ERROR"
''')
    require(result.returncode == 0, result.stderr)
    require(result.stdout == expected and 'PRIVATE' not in result.stdout, repr(result.stdout))
    state = (base / 'public-state').read_text()
    require(state.splitlines()[0] == expected and 'PRIVATE' not in state and '"metadata"' not in state, state)
    require(not work.exists(), 'stderr/work survived cleanup')


for error in ['source_slot_reused', 'reclassification_required', 'foreign_target', 'invalid_routes_entries', 'invalid_metadata_schema']:
    case('F4 bounded code survives cleanup ' + error, lambda b, e=error: error_case(b, json.dumps(dict(error=e, version=1), separators=(',', ':')), e))
for label, payload in [('unknown', '{"error":"PRIVATE_GPS_SERIAL","version":1}'),
                       ('extra', '{"error":"source_slot_reused","metadata":"PRIVATE_GPS_SERIAL","version":1}'),
                       ('duplicate', '{"error":"source_slot_reused","version":1,"version":1}'),
                       ('noncanonical', '{ "error":"source_slot_reused", "version":1 }'),
                       ('invalid', '{'), ('wrong-version', '{"error":"source_slot_reused","version":2}')]:
    case('F4 reject ' + label, lambda b, p=payload: error_case(b, p, 'tool_failed'))


def manager_symlink(base):
    scripts = base / 'scripts'; scripts.mkdir()
    (scripts / 'backup-manager.sh').symlink_to(S / 'backup-manager.sh')
    # Disabled legacy config must be read through original invocation tree.
    conf = base / 'conf'; conf.mkdir()
    (conf / 'backup.conf').write_text('ENABLED=0\n')
    (scripts / 'config.sh').symlink_to(S / 'config.sh')
    uci = base / 'uci'; uci.mkdir()
    env = dict(os.environ, UCI_CONFIG_DIR=str(uci))
    result = subprocess.run(['/bin/sh', str(scripts / 'backup-manager.sh'), 'add', 'sda1', '/devices/fake'], env=env, capture_output=True, text=True)
    require(result.returncode == 0, result.stdout + result.stderr)


case('F8 symlink manager reads fixture config not source config', manager_symlink)


def actual_refusal(base, error):
    source, root, work, routes, request = plan_input(base)
    (source / '照片.bin').unlink()
    if error == 'source_slot_reused':
        path = source / 'clip.xml'
        path.write_text('<?xml version="1.0" encoding="UTF-8"?><NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.00">'
                        '<TargetMaterial umidRef="' + '2' * 64 + '"/>'
                        '<CreationDate value="2026-08-08T12:00:00+08:00"/></NonRealTimeMeta>')
        # Real ExifTool first produces a validated identity; alter historical
        # signature, not the provider output/schema, to represent another slot.
        first = helper('plan', request)
        require(first.returncode == 0, repr(first.stderr))
        history = json.loads((work / 'routes.json').read_text())
        identity = history['entries']['clip.xml']['recording_identity']
        require(identity and 'sony_umid_sha256' in identity['signatures'], 'real XML UMID not extracted')
        identity['signatures']['sony_umid_sha256'] = '0' * 64
        routes.write_text(json.dumps(history))
        new_work = base / '第二次工作'; new_work.mkdir(mode=0o700)
        obj = json.loads(request.read_text()); obj['work_dir'] = str(new_work)
        request.write_text(json.dumps(obj, ensure_ascii=False))
        work = new_work
    else:
        for name in ['clip.mp4', 'clip.srt']:
            (source / name).write_bytes(b'synthetic ordinary source bytes')
        history = json.loads(routes.read_text())
        for name, bucket in [('clip.mp4', '2026/20260808'), ('clip.srt', 'Undated')]:
            history['entries'][name] = dict(group_anchor=name, recording_identity=None,
                bucket=bucket, date_reason='no_capture_date', target_relpath=f'{bucket}/{SID}/{name}')
        routes.write_text(json.dumps(history))
    # Run actual helper via actual manager orchestration, observing the only
    # public status call and proving transfer is not invoked after nonzero.
    result = shell(f'''
SCRIPT_DIR={S}; MEDIA_DATE_WORK={work}; MEDIA_DATE_OWNED_WORK={work}
MEDIA_DATE_WORK_TOKEN=$(perl -e 'my @s=lstat($ARGV[0]); print join(":",@s[0,1,4])' {work})
. "$SCRIPT_DIR/media-date.sh"; . "$SCRIPT_DIR/manager-date.sh"
media_date_guard() {{ return 0; }}
lock_is_owned_by_self() {{ return 0; }}
check_cancel_request() {{ return 0; }}
transfer_process_run() {{ "$@"; }}
get_display_name() {{ printf synthetic; }}
backup_status_begin() {{ return 0; }}
update_alias_last_seen() {{ return 0; }}
media_date_prepare() {{ return 0; }}
media_date_plan() {{ media_date_helper plan {request}; }}
backup_transfer_date() {{ printf transfer > {base}/unexpected-transfer; }}
write_status() {{ printf '%s\n%s\n' "${{14}}" "${{17}}" > {base}/public-state; }}
perform_date_backup; rc=$?
[ "$rc" != 0 ] || exit 9
manager_date_cleanup || exit 8
manager_date_status failed "$ERROR_TYPE" || exit 7
printf '%s' "$ERROR_TYPE"
''')
    require(result.returncode == 0 and result.stdout == error, repr(result.stdout + result.stderr))
    state = (base / 'public-state').read_text()
    require(state.splitlines()[0] == error and 'umid' not in state and 'signatures' not in state, state)
    require(not work.exists() and not (base / 'unexpected-transfer').exists(), 'work survived or transfer invoked')


for error in ['source_slot_reused', 'reclassification_required']:
    case('F4 real helper + manager status after cleanup ' + error, lambda b, e=error: actual_refusal(b, e))


def cbi(base):
    result = subprocess.run(['lua', str(ROOT / 'tests/media-date/regressions-cbi.lua'), str(ROOT)], capture_output=True, text=True)
    require(result.returncode == 0 and 'ran=7 passed=7 failed=0' in result.stdout, result.stdout + result.stderr)
    print(result.stdout, end='')


case('F1 actual CBI intent partition (7 validator cases)', cbi)


def disabled_manager(base, action, comparison=None):
    """Run delivered manager with disabled date config; require lazy, inert exit."""
    scripts = base / 'scripts'; scripts.mkdir()
    for script in S.iterdir():
        if script.is_file():
            (scripts / script.name).symlink_to(script)
    conf = base / 'conf'; conf.mkdir()
    source = base / 'source'; source.mkdir()
    (source / 'clip.bin').write_bytes(b'unchanged-source')
    target = base / 'target'; target.mkdir()
    uci = base / 'uci'; uci.mkdir()
    service = base / 'service'; service.mkdir(mode=0o700)
    (service / 'state').write_text('stopped:1')
    (conf / 'backup.conf').write_text(
        f'ENABLED=0\nBACKUP_LAYOUT=date\nMOUNT_POINT={source}\n'
        f'TARGET_MOUNT={target}\nTARGET_UUID=fixture-target\n'
        f'BACKUP_ROOT={target}/SDMirrors\nLIBRARY_ROOT={target}/MediaLibrary\n'
        'ARCHIVE_OFFSET_MINUTES=480\n'
        "LED_GREEN=''\nLED_GREEN2=''\nLED_GREEN3=''\nLED_RED=''\n")
    # File absence detects even same-value publications; trace detects transient
    # mount/runner activity, which a final content comparison cannot establish.
    before = {str(p.relative_to(base)): (p.lstat().st_mode, p.lstat().st_mtime_ns,
              p.read_bytes() if p.is_file() and not p.is_symlink() else None)
              for p in base.rglob('*')}
    env = dict(os.environ, UCI_CONFIG_DIR=str(uci), OUTDOOR_BACKUP_SERVICE_DIR=str(service))
    argv = ['/bin/sh', '-x', str(scripts / 'backup-manager.sh'), action,
            'sda1', '/devices/platform/fixture/block/sda/sda1']
    if comparison is not None:
        argv.append(comparison)
    result = subprocess.run(argv, env=env, capture_output=True, text=True)
    expected = 0 if action == 'add' else 5
    diagnostic = (f'outdoor-backup: backup disabled; ignoring add event for sda1'
                  if action == 'add' else f'outdoor-backup: backup disabled; refusing {action} action')
    require(result.returncode == expected, f'expected rc{expected}, got rc{result.returncode}: {result.stderr}')
    require(diagnostic in result.stderr.splitlines(), result.stderr)
    require('+ config_validate_layout' in result.stderr, 'real config validation not reached')
    if action != 'add':
        require('+ manager_admin_validate ' in result.stderr, 'real lexical validation not reached')
    else:
        for module in ['target-device.sh', 'manager-admin.sh', 'owner-event.sh']:
            require(f'. {scripts}/{module}' not in result.stderr, 'disabled add lost lazy exit: ' + module)
    for module in ['common.sh', 'service-state.sh', 'target.sh', 'source-identity.sh',
                   'card-identity.sh', 'status.sh', 'transfer-process.sh', 'backup-transfer.sh']:
        require(f'. {scripts}/{module}' not in result.stderr, 'unexpected lifecycle module: ' + module)
    for command in ['mount', 'umount', 'rsync', 'setsid', 'transfer_process_run', 'owner_event_cancel']:
        require(not any(line.startswith('+ ' + command + ' ') for line in result.stderr.splitlines()),
                'unexpected source/transfer/owner activity: ' + command)
    after = {str(p.relative_to(base)): (p.lstat().st_mode, p.lstat().st_mtime_ns,
             p.read_bytes() if p.is_file() and not p.is_symlink() else None)
             for p in base.rglob('*')}
    require(after == before, 'card config/route/identity/alias/status/target or runtime state changed')


case('A1 disabled date add remains successful lazy no-op', lambda b: disabled_manager(b, 'add'))
case('A1 disabled date initialize refuses without side effects', lambda b: disabled_manager(b, 'initialize'))
case('A1 disabled date manual quick refuses without side effects', lambda b: disabled_manager(b, 'manual', 'quick'))
case('A1 disabled date manual checksum refuses without side effects', lambda b: disabled_manager(b, 'manual', 'checksum'))
require(ran == 36, f'expected 36, got {ran}')
print(f'ran={ran} passed={passed} failed={failed}; real helper/modules; temporary fixtures only', flush=True)
sys.exit(1 if failed else 0)

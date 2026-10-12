#!/usr/bin/env python3
"""Interface scenarios load delivered shell modules; no real devices or media."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import shutil

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'files/opt/outdoor-backup/scripts'
RAN = PASSED = FAILED = ASSERTIONS = 0


def shell(module, body, *args):
    """Source the actual inert module, preserving each argv slot."""
    if not (SCRIPTS / module).is_file():
        raise AssertionError('delivered module missing: ' + module)
    return subprocess.run(['/bin/sh', '-c', '. "$1"; shift; ' + body,
                           'scenario', str(SCRIPTS / module), *map(str, args)],
                          capture_output=True, text=True)


def check(condition, reason):
    global ASSERTIONS
    ASSERTIONS += 1
    if not condition:
        raise AssertionError(reason)


def case(name, function):
    global RAN, PASSED, FAILED
    RAN += 1
    try:
        function()
    except Exception as error:
        FAILED += 1
        print(f'CASE {name} failed: {error}')
    else:
        PASSED += 1
        print(f'CASE {name} passed')


with tempfile.TemporaryDirectory(prefix='media-date-manager-') as tmp:
    # macOS /var is a symlink; production rejects symbolic ancestors deliberately.
    base = Path(tmp).resolve()
    os.environ['UCI_CONFIG_DIR'] = str(base / 'no-uci')

    def config_case(text, accepted, expected=None):
        legacy = base / 'backup.conf'
        legacy.write_text(text)
        result = shell('config.sh', 'config_load "$1" || exit 1; '
                       'printf "%s\\n" "$BACKUP_LAYOUT" "$LIBRARY_ROOT" "$BACKUP_ROOT"', legacy)
        check((result.returncode == 0) == accepted, result.stderr)
        if expected:
            check(result.stdout.splitlines() == expected, result.stdout)

    case('M50 default mirror preserves empty library intent', lambda: config_case(
        'TARGET_MOUNT="/fixture/target"\n', True,
        ['mirror', '', '/fixture/target/SDMirrors']))
    case('M33 date dynamic library root', lambda: config_case(
        'BACKUP_LAYOUT=date\nTARGET_MOUNT="/fixture/target"\nARCHIVE_OFFSET_MINUTES=480\n', True,
        ['date', '/fixture/target/MediaLibrary', '/fixture/target/SDMirrors']))
    for name, text in [
        ('layout', 'BACKUP_LAYOUT=guess\n'),
        ('same', 'LIBRARY_ROOT="/mnt/ssd/SDMirrors"\n'),
        ('ancestor', 'LIBRARY_ROOT="/mnt/ssd"\n'),
        ('descendant', 'LIBRARY_ROOT="/mnt/ssd/SDMirrors/date"\n'),
        ('date nested', 'BACKUP_LAYOUT=date\nLIBRARY_ROOT="/mnt/ssd/a/b"\n'),
        ('source overlap', 'LIBRARY_ROOT="/mnt/sdcard/library"\n')]:
        case('M33 reject ' + name, lambda text=text: config_case(text, False))

    manager = str(SCRIPTS / 'backup-manager.sh')
    cmdline = base / 'cmdline'

    def owner_case(argv, stop, remove=False):
        cmdline.write_bytes(b'\0'.join(str(a).encode() for a in argv) + b'\0')
        result = shell('owner-event.sh', 'owner_event_cmdline_matches_stop "$1" "$2"',
                       cmdline, manager)
        check((result.returncode == 0) == stop, result.stderr)
        result = shell('owner-event.sh',
                       'owner_event_cmdline_matches "$1" "$2" sda1 /devices/usb/sda/sda1 11',
                       cmdline, manager)
        check((result.returncode == 0) == remove, result.stderr)

    for comparison in ('quick', 'checksum'):
        case('M29 stop manual ' + comparison, lambda comparison=comparison: owner_case(
            ['/bin/sh', manager, 'manual', 'sda1', '/devices/usb/sda/sda1', comparison], True))
    case('M29 stop initialize', lambda: owner_case(
        ['/bin/ash', manager, 'initialize', 'sda1', '/devices/usb/sda/sda1'], True))
    case('M29 add/remove compatibility', lambda: owner_case(
        ['/bin/sh', manager, 'add', 'sda1', '/devices/usb/sda/sda1', '10'], True, True))
    for name, argv in [
        ('comparison', ['/bin/sh', manager, 'manual', 'sda1', '/devices/usb/sda/sda1', '10']),
        ('devpath', ['/bin/sh', manager, 'initialize', 'sda1', '/devices/../sda1']),
        ('extra slot', ['/bin/sh', manager, 'initialize', 'sda1', '/devices/usb/sda/sda1', 'quick']),
        ('script', ['/bin/sh', '/foreign/backup-manager.sh', 'manual', 'sda1', '/devices/usb/sda/sda1', 'quick']),
        ('NUL safe newline', ['/bin/sh', manager, 'manual', 'sda1', '/devices/usb/\nsda1', 'quick'])]:
        case('M29 reject ' + name, lambda argv=argv: owner_case(argv, False))

    def layout_case(kind):
        root = base / ('layout-' + kind)
        root.mkdir()
        child = root / 'mirror'
        if kind != 'empty':
            state = root / '.outdoor-backup'
            state.mkdir()
            if kind == 'marker':
                (state / 'library.json').write_text('{}')
            elif kind == 'routes':
                (state / 'routes').mkdir()
            else:
                (state / 'library.json').symlink_to(root / 'missing')
        result = shell('library-layout.sh', 'library_layout_mirror_admit "$1"', child)
        check((result.returncode == 0) == (kind == 'empty'), result.stderr)
        check(not child.exists(), 'read-only admission created root')

    for kind in ('empty', 'marker', 'routes', 'dangling'):
        case('M33 ancestor ' + kind, lambda kind=kind: layout_case(kind))

    def task_case(change=None, accepted=True):
        task = {'version': 1, 'layout': 'date', 'phase': 'planning',
                'comparison_mode': 'quick',
                'archive': {'files_total': None, 'routes_total': None,
                            'excluded_total': None, 'undated_total': None},
                'warnings': [], 'replaced': {'files_count': None, 'path': None}}
        if change:
            change(task)
        result = shell('status.sh', 'status_task "$1"', json.dumps(task))
        check(result.returncode == (0 if accepted else 1), result.stderr)
        if accepted:
            check(json.loads(result.stdout) == task, result.stdout)

    case('M37 planning counts unknown', lambda: task_case())
    case('M37 strict task keys', lambda: task_case(lambda task: task.update(GPS='private'), False))
    case('M50 invalid comparison task', lambda: task_case(lambda task: task.update(comparison_mode='auto'), False))
    case('M37 strict task version', lambda: task_case(lambda task: task.update(version=2), False))
    case('M37 warning whitelist', lambda: task_case(lambda task: task.update(warnings=[{'code': 'rawUMID', 'count': 1}]), False))

    def status_publication():
        snapshot = base / 'status.json'
        task = {'version': 1, 'layout': 'date', 'phase': 'planning',
                'comparison_mode': 'quick', 'archive': {'files_total': None,
                'routes_total': None, 'excluded_total': None, 'undated_total': None},
                'warnings': [], 'replaced': {'files_count': None, 'path': None}}
        body = 'STATUS_FILE=$1; write_status "$2" id name sda1 0 0 0 0 0 0 0 "$3" "$3" "" "$3" null "$4"'
        result = shell('status.sh', body, snapshot, 'running', base, json.dumps(task))
        check(result.returncode == 0, result.stderr)
        check(json.loads(snapshot.read_text())['current_backup']['task'] == task, 'task not persisted')
        task['phase'] = 'finalizing'
        result = shell('status.sh', body, snapshot, 'completed', base, json.dumps(task))
        check(result.returncode == 0, result.stderr)
        check(json.loads(snapshot.read_text())['history'][0]['task'] == task, 'terminal task absent')
        before = snapshot.read_bytes()
        task['GPS'] = 'must not serialize'
        result = shell('status.sh', body, snapshot, 'running', base, json.dumps(task))
        check(result.returncode != 0, 'invalid task published')
        check(snapshot.read_bytes() == before, 'invalid task replaced prior snapshot')

    case('M37 task atomic publication', status_publication)

    def date_missing_helper():
        """Run delivered manager/lease/owner/runner; fake only removable hardware.

        Missing helper is injected after copying the complete runtime. The probe
        wrapper checks real ownership and FD9 before delegating to the real runner.
        """
        runtime = base / 'runtime'
        shutil.copytree(ROOT / 'files/opt/outdoor-backup', runtime)
        scripts = runtime / 'scripts'
        for child in ('source', 'target', 'service', 'bin', 'var'):
            (runtime / child).mkdir(exist_ok=True)
        sid = '11111111-1111-4111-8111-111111111111'
        source = runtime / 'source'
        card = source / 'FieldBackup.conf'
        card.write_text(f'SD_UUID="{sid}"\nBACKUP_MODE="PRIMARY"\n')
        original_card = card.read_bytes()
        library = runtime / 'target/MediaLibrary'
        (runtime / 'service/state').write_text('running:7\n')
        (runtime / 'conf/backup.conf').write_text(f'''BACKUP_LAYOUT=date
TARGET_MOUNT='{runtime}/target'
TARGET_UUID=target-uuid
BACKUP_ROOT='{runtime}/target/SDMirrors'
LIBRARY_ROOT='{library}'
MOUNT_POINT='{source}'
ARCHIVE_OFFSET_MINUTES=480
MIN_FREE_SPACE=0
LED_RED=''
LED_GREEN=''
LED_GREEN2=''
LED_GREEN3=''
''')

        def append_fixture(name, text):
            """Add hardware observation seams only to the disposable copied file."""
            with (scripts / name).open('a') as fixture:
                fixture.write('\n' + text)

        # The mount double validates exact source/mode; it never mounts a device.
        append_fixture('common.sh', '''
contract_event() { printf '%s\\n' "$1" >> "$BASE_DIR/events"; }
log_info() { contract_event "info:$1"; }
log_error() { contract_event "error:$1"; }
log_warn() { contract_event "warning:$1"; }
log_debug() { :; }
mountpoint() { [ -f "$BASE_DIR/mounted" ]; }
mount() {
    [ "$#" = 6 ] && [ "$1" = -t ] && [ "$3" = -o ] &&
        [ "$4" = ro ] && [ "$5" = /dev/sda1 ] && [ "$6" = "$BASE_DIR/source" ] || return 1
    contract_event source-mounted-ro
    touch "$BASE_DIR/mounted"
}
umount() {
    [ "$1" = "$BASE_DIR/source" ] || return 1
    contract_event source-unmounted
    rm -f "$BASE_DIR/mounted"
}
sync() { :; }
''')
        # A real directory FD is opened. ext4/device metadata is synthetic, not
        # evidence of filesystem capability (the helper probe fails before that).
        append_fixture('target.sh', '''
target_open() {
    [ "$1" = "$BASE_DIR/target" ] || return 1
    exec 9<"$1" || return 1
    TARGET_FD_OPEN=1
    TARGET_FD_ROOT="/proc/$$/fd/9"
    TARGET_MOUNT_PATH=$1
    TARGET_DEVICE=8:2
    TARGET_FS_TYPE=ext4
}
target_anchor_healthy() {
    [ "${TARGET_FD_OPEN:-0}" = 1 ] &&
        [ "$(readlink "/proc/$$/fd/9")" = "$BASE_DIR/target" ]
}
''')
        append_fixture('target-device.sh', '''
target_device_validate() {
    [ "$#" = 3 ] && [ "$1" = 8:2 ] && [ "$2" = target-uuid ] && [ "$3" = sda1 ]
}
''')
        snapshot = json.dumps(dict(devname='sda1', node='/sys/devices/usb/sda/sda1',
                                   major_minor='8:1', filesystem_uuid='abcd-1234', diskseq='1'),
                              separators=(',', ':'))
        check(json.loads(snapshot)['diskseq'] == '1', 'snapshot diskseq must be a decimal string')
        (runtime / 'source-snapshot.json').write_text(snapshot + '\n')
        append_fixture('source-identity.sh', '''
source_identity_read() {
    [ "$#" = 1 ] && [ "$1" = sda1 ] || return 1
    printf '%s\\n' source-snapshot-read >> "$BASE_DIR/events"
    cat "$BASE_DIR/source-snapshot.json"
}
source_identity_matches() {
    [ "$#" = 2 ] && [ "$1" = sda1 ] &&
        [ "$2" = "$(cat "$BASE_DIR/source-snapshot.json")" ] || return 1
    printf '%s\\n' source-snapshot-matched >> "$BASE_DIR/events"
}
source_identity_major_minor_is_mounted() {
    [ "$#" = 1 ] && [ "$1" = 8:1 ] || return 2
    return 1
}
''')
        append_fixture('card-identity.sh', '''
card_identity_read_source_uuid() {
    [ "$#" = 1 ] && [ "$1" = /dev/sda1 ] && [ -f "$BASE_DIR/mounted" ] || return 1
    printf '%s\\n' source-uuid-consumed >> "$BASE_DIR/events"
    printf abcd-1234
}
''')
        # Wrap, do not replace, the delivered private process runner algorithm.
        runner = scripts / 'transfer-process.sh'
        runner.write_text(runner.read_text().replace('transfer_process_run() {',
                          'contract_actual_process_run() {', 1))
        append_fixture('transfer-process.sh', '''
transfer_process_run() {
    [ "$#" = 3 ] && [ "$1" = perl ] &&
        [ "$2" = "$SCRIPT_DIR/media-date-plan.pl" ] && [ "$3" = probe ] || return 97
    lock_is_owned_by_self && service_lease_current && target_anchor_healthy &&
        [ "$SOURCE_MOUNTED" = 1 ] && [ "$BACKUP_MODE" = PRIMARY ] &&
        [ "$SOURCE_FS_UUID" = abcd-1234 ] || return 98
    contract_event helper-probe-prerequisites-proven
    contract_actual_process_run "$@"
    contract_helper_rc=$?
    contract_event "helper-probe-rc:$contract_helper_rc"
    cat "$MEDIA_DATE_WORK/stderr.log" > "$BASE_DIR/helper-error"
    return "$contract_helper_rc"
}
''')
        # Sentinel would expose an unintended actual rsync launch independently
        # of the probe-only wrapper; absence is not merely an unchanged counter.
        rsync = runtime / 'bin/rsync'
        rsync.write_text('#!/bin/sh\nprintf "actual-rsync\\n" >> "$CONTRACT_EVENTS"\nexit 99\n')
        rsync.chmod(0o755)
        check((scripts / 'media-date-plan.pl').is_file(), 'helper absent before injection')
        (scripts / 'media-date-plan.pl').unlink()
        env = os.environ.copy()
        env.update(OUTDOOR_BACKUP_SERVICE_DIR=str(runtime / 'service'),
                   OUTDOOR_BACKUP_SERVICE_GENERATION='7', UCI_CONFIG_DIR=str(base / 'no-uci'),
                   CONTRACT_EVENTS=str(runtime / 'events'),
                   PATH=str(runtime / 'bin') + ':' + env['PATH'])
        result = subprocess.run(['/bin/sh', str(scripts / 'backup-manager.sh'), 'add',
                                 'sda1', '/devices/usb/sda/sda1', '10'], env=env,
                                capture_output=True, text=True, timeout=35)
        check(result.returncode == 1, result.stderr)
        events = (runtime / 'events').read_text().splitlines()
        check(events.count('helper-probe-prerequisites-proven') == 1, repr(events))
        check('helper-probe-rc:2' in events, repr(events))
        check("Can't open perl script" in (runtime / 'helper-error').read_text(), 'wrong helper failure')
        status = json.loads((runtime / 'var/status.json').read_text())['history'][0]
        # status_merge_history deliberately maps the failed phase to "error".
        check(status['status'] == 'error' and status['error_message'] == 'tool_failed', repr(status))
        check('source-mounted-ro' in events and 'source-uuid-consumed' in events, repr(events))
        check(events.index('source-uuid-consumed') < events.index('helper-probe-prerequisites-proven'),
              'probe preceded consumed source identity')
        check('actual-rsync' not in events, repr(events))
        formal_json = list(library.rglob('*.json'))
        check(not formal_json, 'formal library/route/identity published')
        check(not (library / '.card-identities').exists(), 'identity directory created')
        check(not list((runtime / 'var').glob('media-date.*')), 'private work not cleaned')
        check(card.read_bytes() == original_card, 'source card modified')
        evidence = dict(manager_rc=result.returncode, helper_rc=2, events=events, history=status,
                        formal_json=[str(path) for path in formal_json],
                        helper_error=(runtime / 'helper-error').read_text(),
                        source_card_unchanged=card.read_bytes() == original_card)
        if os.environ.get('TEST_EVIDENCE'):
            (Path(os.environ['TEST_EVIDENCE']) / 'manager-m34-effects.json').write_text(
                json.dumps(evidence, ensure_ascii=False) + '\n')
        print('M34 evidence probe=1 helper_rc=2 error=tool_failed rsync=0 formal_json=0')

    case('M34 missing helper refuses after admitted date prerequisites', date_missing_helper)

    def offset_boundaries():
        for value, accepted in [('-841', False), ('-840', True), ('-839', True),
                                ('0', True), ('839', True), ('840', True),
                                ('841', False), ('', False), ('1.5', False),
                                ('TZ', False), ('--1', False), ('-0', False)]:
            result = shell('config.sh', 'config_valid_archive_offset "$1"', value)
            check((result.returncode == 0) == accepted, 'offset ' + repr(value))

    case('M33 explicit fixed offset boundaries', offset_boundaries)

    def legacy_status_calls():
        snapshot = base / 'legacy-status.json'
        for extra in ('', ' null'):
            result = shell('status.sh', 'STATUS_FILE=$1; write_status running id name sda1 '
                           '0 0 0 0 0 0 0 "$2" "$2" "" "$2"' + extra, snapshot, base)
            check(result.returncode == 0, result.stderr)
            check('task' not in json.loads(snapshot.read_text())['current_backup'],
                  'legacy status gained a task')

    case('M37 legacy 15 and 16 parameters', legacy_status_calls)

print(f'ran={RAN} passed={PASSED} failed={FAILED} blocked=0 assertions={ASSERTIONS}')
if RAN != 30 or FAILED:
    raise SystemExit(1)

#!/usr/bin/env python3
"""Actual OpenWrt rsync partitions; synthetic files, never disks or NAS.
Given real CLI-produced view/routes, When delivered helper+runner execute,
Then assert bytes, counts, retained content and actual diagnostics independently.
Admission functions are explicit synthetic seams, not owner/FD acceptance.
"""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'files/opt/outdoor-backup/scripts'
EVIDENCE = Path(os.environ.get('TEST_EVIDENCE', '/evidence')) / 'rsync-actual'
EVIDENCE.mkdir(parents=True, exist_ok=True)
SOURCE_ID = '11111111-1111-4111-8111-111111111111'
LIBRARY_ID = '22222222-2222-4222-8222-222222222222'
RAN = PASSED = FAILED = BLOCKED = ASSERTIONS = 0


def check(condition, reason):
    """Count each actually evaluated oracle; raise on false."""
    global ASSERTIONS
    ASSERTIONS += 1
    if not condition:
        raise AssertionError(reason)


def command(argv, **options):
    """Record exact command arrays before executing real guest commands."""
    with (EVIDENCE / 'commands.jsonl').open('a') as log:
        log.write(json.dumps(argv, ensure_ascii=True) + '\n')
    return subprocess.run(argv, capture_output=True, **options)


class Fixture:
    """One owned synthetic source/library and metadata-only route history."""
    def __init__(self, name, library_parent=None):
        self.base = Path(tempfile.mkdtemp(prefix='rsync-date-', dir='/tmp'))
        self.source = self.base / 'source'
        self.source.mkdir()
        self.library = (Path(library_parent) / self.base.name if library_parent else self.base / 'library')
        self.library.mkdir()
        (self.base / 'var').mkdir()
        self.route = self.base / 'history.json'
        self.route.write_text(json.dumps(dict(version=1, library_id=LIBRARY_ID,
                                              source_id=SOURCE_ID, entries={})))
        self.policy = dict(version=1, library_id=LIBRARY_ID, layout='date',
                           parser_profile='media-date-v1', archive_offset_minutes=480)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        observer = self.bin / 'rsync'
        observer.write_bytes((ROOT / 'tests/media-date/rsync-observe.sh').read_bytes())
        observer.chmod(0o700)
        self.evidence = EVIDENCE / name
        self.evidence.mkdir(exist_ok=True)
        self.serial = 0

    def put(self, name='clip.bin', data=b'original'):
        """Create tiny synthetic source, with stable whole-second mtime."""
        path = self.source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        os.utime(path, (1700000000, 1700000000))
        return path

    def plan(self):
        """Execute actual Perl CLI via delivered runner; publish synthetic history."""
        self.serial += 1
        self.work = self.base / ('work' + str(self.serial))
        self.work.mkdir(mode=0o700)
        request = dict(version=1, source_root=str(self.source), library_root=str(self.library),
                       source_id=SOURCE_ID, library=self.policy, route_file=str(self.route), work_dir=str(self.work))
        request_file = self.base / 'request.json'
        request_file.write_text(json.dumps(request))
        result = command(['/bin/ash', '-c', '. "$1/transfer-process.sh"; transfer_process_run perl "$1/media-date-plan.pl" plan "$2"',
                          'plan', str(SCRIPTS), str(request_file)])
        (self.evidence / ('plan-' + str(self.serial) + '.stdout')).write_bytes(result.stdout)
        (self.evidence / ('plan-' + str(self.serial) + '.stderr')).write_bytes(result.stderr)
        check(result.returncode == 0, 'real planner failed: ' + repr(result.stderr))
        self.routes = json.loads((self.work / 'routes.json').read_bytes())
        self.route.write_bytes((self.work / 'routes.json').read_bytes())
        return self.work / 'view'

    def target(self, name='clip.bin'):
        return self.library / self.routes['entries'][name]['target_relpath']

    def launch(self, mode='quick', fault='', interrupt=False):
        """Call actual backup_transfer_date; observer copies no media."""
        run = self.evidence / ('run-' + str(self.serial) + '-' + mode + '-' + str(time.monotonic_ns()))
        run.mkdir()
        replaced = self.library / '.outdoor-backup/replaced' / run.name
        replaced.mkdir(parents=True)
        log = self.library / 'log space\n真实\t.log'
        argv = ['/bin/ash', str(ROOT / 'tests/media-date/rsync-run.sh'), str(ROOT), str(self.base),
                str(self.work), str(self.library), mode, str(replaced), str(log)]
        env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                   RSYNC_EVIDENCE=str(run), RSYNC_FAULT=fault)
        if fault == 'backup-permission':
            # Guest UID 65534 can write library/temp/log, but not the root-owned
            # backup job. This is actual EACCES, not a simulated rsync exit code.
            for path in [self.base, run, *self.base.rglob('*')]:
                if not path.is_symlink():
                    path.chmod(0o777 if path.is_dir() else 0o666)
                    if path != replaced:
                        os.chown(path, 65534, 65534)
            (self.bin / 'rsync').chmod(0o755)
            replaced.chmod(0o555)
            log.touch()
            log.chmod(0o666)
            (self.base / 'result').unlink(missing_ok=True)
        if not interrupt:
            result = command(argv, env=env, **({'preexec_fn': lambda: os.setuid(65534)} if fault == 'backup-permission' else {}))
        else:
            result = self.interrupt(argv, env, run)
        return self.record(result, run, mode, fault, log, replaced)

    def interrupt(self, argv, env, run):
        """Send SIGINT only to this launch's recorded, verified actual rsync PID."""
        with (EVIDENCE / 'commands.jsonl').open('a') as record:
            record.write(json.dumps(argv) + '\n')
        process = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if (run / 'pid').exists() and list(self.library.rglob('.clip.bin.*')):
                break
            time.sleep(0.05)
        pid = int((run / 'pid').read_text())
        check(b'/usr/bin/rsync' in Path('/proc/' + str(pid) + '/cmdline').read_bytes(), 'fault PID must be owned real rsync')
        time.sleep(1)
        os.kill(pid, signal.SIGINT)
        stdout, stderr = process.communicate(timeout=30)
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)

    def record(self, result, run, mode, fault, log, replaced):
        """Assert observed actual argv and preserve helper results after drain."""
        (run / 'driver.stdout').write_bytes(result.stdout)
        (run / 'driver.stderr').write_bytes(result.stderr)
        stats = (self.base / 'result').read_text().strip()
        (run / 'result').write_text(stats + '\n')
        observed = (run / 'argv.nul').read_bytes().split(b'\0')
        check(observed[-1] == b'', 'argv must be NUL terminated')
        observed = observed[:-1]
        check(observed[-2:] == [os.fsencode(str(self.work / 'view') + '/'), os.fsencode(str(self.library) + '/')], 'whole view/library argv preserved')
        check((b'--checksum' in observed) == (mode == 'checksum'), 'real mode option')
        check(not any(arg in observed for arg in (b'--delete', b'--ignore-existing', b'--inplace', b'--append', b'--no-whole-file')), 'forbidden options absent')
        check((run / 'invocations').read_text().splitlines() == ['actual-rsync'], 'one actual media invocation (capability probes excluded)')
        check(os.fsencode('--log-file=' + str(log)) in observed, 'LF/tab/Chinese log path is one exact argv')
        effective = (run / 'effective-argv.nul').read_bytes().split(b'\0')[:-1]
        check(effective == [b'/usr/bin/rsync'] + ([b'--bwlimit=128'] if fault == 'slow' else []) + observed, 'observer executes actual binary unchanged except explicit interruption rate limit')
        files = int(re.search(r' files=(\d+)', stats)[1])
        error = stats.split(' error=')[1]
        return result.returncode, files, replaced, error, run

    def retained(self, replaced):
        return [path for path in replaced.rglob('*') if path.is_file()]

    def close(self):
        shutil.rmtree(self.base)
        if self.library.exists():
            shutil.rmtree(self.library)


def case(name, behavior):
    """Execute one declared behavior partition and expose honest case counts."""
    global RAN, PASSED, FAILED
    RAN += 1
    try:
        behavior()
    except Exception as error:
        FAILED += 1
        print('CASE ' + name + ' FAILED ' + repr(error), flush=True)
    else:
        PASSED += 1
        print('CASE ' + name + ' PASSED', flush=True)


def initial():
    fixture = Fixture('M01-three-days')
    try:
        for day in (8, 9, 10):
            fixture.put(f'day{day}.xml', (f'<?xml version="1.0" encoding="UTF-8"?>\n<NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20"><CreationDate value="2026-08-{day:02d}T12:00:00+08:00"/></NonRealTimeMeta>').encode())
        fixture.plan()
        buckets = {entry['bucket'] for entry in fixture.routes['entries'].values()}
        check(buckets == {'2026/20260808', '2026/20260809', '2026/20260810'}, 'real whitelist must route three days')
        rc, files, replaced, _, _ = fixture.launch()
        check(rc == 0 and files == 3, 'three files, one real sync')
        for name in fixture.routes['entries']:
            check(fixture.target(name).read_bytes() == (fixture.source / name).read_bytes(), 'date bytes exact')
            check(not fixture.target(name).is_symlink(), 'final leaf ordinary')
        check(not fixture.retained(replaced), 'initial run no replaced')
        check(not (fixture.library / 'SDMirrors').exists(), 'no second mirror')
    finally:
        fixture.close()


def incremental(mode, action):
    fixture = Fixture('M02-' + mode + '-' + action)
    try:
        fixture.put()
        fixture.plan()
        check(fixture.launch(mode)[0] == 0, 'baseline copy')
        old_inode = fixture.target().stat().st_ino
        if action == 'add':
            fixture.put('new.bin', b'new')
        if action == 'delete':
            (fixture.source / 'clip.bin').unlink()
        fixture.plan()
        rc, files, replaced, _, _ = fixture.launch(mode)
        check(rc == 0 and files == (1 if action == 'add' else 0), 'incremental transfer count')
        check(fixture.target().read_bytes() == b'original', 'deleted or unchanged old bytes preserved')
        check(fixture.target().stat().st_ino == old_inode, 'existing file inode not replaced')
        check(not fixture.retained(replaced), 'no unnecessary replaced')
        if action == 'add':
            check(fixture.target('new.bin').read_bytes() == b'new', 'only added file copied')
    finally:
        fixture.close()


def change(mode, mtime_only=False):
    fixture = Fixture(('M17-' if mtime_only else 'M16-') + mode)
    try:
        source = fixture.put(data=b'oldbytes')
        fixture.plan()
        check(fixture.launch(mode)[0] == 0, 'baseline copy')
        if mtime_only:
            os.utime(source, (1700000010, 1700000010))
        else:
            source.write_bytes(b'newbytes')
            os.utime(source, (1700000000, 1700000000))
        fixture.plan()
        rc, files, replaced, _, _ = fixture.launch(mode)
        updating = (mode == 'quick') if mtime_only else (mode == 'checksum')
        check(rc == 0 and files == int(updating), 'mode update rule')
        check(fixture.target().read_bytes() == (b'oldbytes' if mtime_only or mode == 'quick' else b'newbytes'), 'final bytes')
        retained = fixture.retained(replaced)
        check(len(retained) == int(updating), 'retained count')
        if updating:
            check(retained[0].read_bytes() == b'oldbytes', 'old bytes protected')
        if mtime_only:
            check(int(fixture.target().stat().st_mtime) == 1700000010, 'mtime updated including checksum attributes-only')
        fixture.plan()
        rc, files, replaced, _, _ = fixture.launch(mode)
        check(rc == 0 and files == 0 and not fixture.retained(replaced), 'fully unchanged rerun no replaced')
    finally:
        fixture.close()


def names():
    fixture = Fixture('M20-M36-names')
    try:
        names = ['space name.bin', '中文.bin', 'real\nLF.bin', 'real\ttab.bin', '-minus.bin', 'A.bin', 'a.bin', 'é.bin', 'é.bin']
        for index, name in enumerate(names):
            fixture.put(name, ('bytes-' + str(index)).encode())
        fixture.plan()
        rc, files, _, _, _ = fixture.launch()
        check(rc == 0 and files == len(names), 'all distinct Linux names transferred')
        for name in names:
            check(fixture.target(name).read_bytes() == (fixture.source / name).read_bytes(), 'name bytes exact ' + repr(name))
            check(not fixture.target(name).is_symlink(), 'ordinary target ' + repr(name))
    finally:
        fixture.close()


def broken():
    fixture = Fixture('M27-broken')
    try:
        source = fixture.put()
        fixture.plan()
        source.unlink()
        rc, _, _, error, run = fixture.launch()
        check(rc == 23 and error == 'rsync', 'actual exit 23 broken link without ENOSPC is not classified full')
        check(not fixture.target().exists(), 'route does not prove completed')
        check(b'link' in (run / 'stderr').read_bytes(), 'actual broken-link diagnostic')
        fixture.put()
        fixture.plan()
        rc, files, _, _, _ = fixture.launch()
        check(rc == 0 and files == 1 and fixture.target().read_bytes() == b'original', 'rerun route not skipped')
    finally:
        fixture.close()


def partial():
    fixture = Fixture('M25-partial')
    try:
        fixture.put(data=b'synthetic' * 262144)
        fixture.plan()
        rc, _, _, _, _ = fixture.launch(fault='slow', interrupt=True)
        check(rc != 0, 'interrupted actual rsync nonzero')
        check(not fixture.target().exists(), 'incomplete media not formal')
        partials = list(fixture.library.rglob('.rsync-partial/clip.bin'))
        check(len(partials) == 1 and 0 < partials[0].stat().st_size < (fixture.source / 'clip.bin').stat().st_size, 'partial isolated')
        fixture.plan()
        rc, files, _, _, _ = fixture.launch()
        check(rc == 0 and files == 1, 'whole-file rerun completes')
        check(fixture.target().read_bytes() == (fixture.source / 'clip.bin').read_bytes(), 'resumed final bytes exact')
        check(not list(fixture.library.rglob('.rsync-partial/clip.bin')), 'completed partial removed')
    finally:
        fixture.close()


def backup_failure():
    fixture = Fixture('M31-backup-dir-failure')
    try:
        source = fixture.put()
        fixture.plan()
        check(fixture.launch()[0] == 0, 'baseline')
        source.write_bytes(b'changed-and-longer')
        fixture.plan()
        rc, _, _, error, run = fixture.launch(fault='backup-permission')
        check(rc != 0 and error == 'rsync', 'backup EACCES nonzero without ENOSPC is not classified full')
        check(fixture.target().read_bytes() == b'original', 'backup failure old formal bytes protected')
        check(b'Permission denied' in (run / 'stderr').read_bytes(), 'real backup-dir diagnostic')
    finally:
        fixture.close()


def enospc():
    fixture = Fixture('M31-ENOSPC', '/dev/shm')
    filler = Path('/dev/shm') / (fixture.base.name + '-filler')
    try:
        source = fixture.put()
        fixture.plan()
        check(fixture.launch()[0] == 0, 'baseline on owned guest tmpfs')
        source.write_bytes(b'new-data' * 262144)
        fixture.plan()
        available = shutil.disk_usage('/dev/shm').free
        with filler.open('wb') as stream:
            remaining = max(0, available - 131072)
            while remaining:
                block = min(remaining, 65536)
                stream.write(b'x' * block)
                remaining -= block
        rc, _, replaced, error, run = fixture.launch()
        check(rc != 0 and error == 'no_space', 'actual ENOSPC classified from diagnostic')
        check(b'No space left on device' in (run / 'stderr').read_bytes(), 'actual tmpfs ENOSPC')
        protected = [fixture.target()] + fixture.retained(replaced)
        check(any(path.exists() and path.read_bytes() == b'original' for path in protected), 'old content protected formal or replaced')
    finally:
        filler.unlink(missing_ok=True)
        fixture.close()


def main():
    global BLOCKED
    if not Path('/etc/openwrt_release').exists() or not Path('/.dockerenv').exists():
        print('BLOCKED: requires owned OpenWrt guest; ran=0 passed=0 failed=0 blocked=14 assertions=0')
        return 2
    for name, argv in [('rsync', ['/usr/bin/rsync', '--version']), ('perl', ['perl', '-v']),
                       ('moduleload', ['perl', '-MImage::ExifTool', '-MStorable', '-MJSON::PP', '-MDigest::SHA', '-e', 'print "ExifTool=$Image::ExifTool::VERSION JSON=$JSON::PP::VERSION Storable=$Storable::VERSION\\n"'])]:
        result = command(argv)
        (EVIDENCE / (name + '.txt')).write_bytes(result.stdout + result.stderr)
        if result.returncode:
            print('BLOCKED: actual dependency ' + name, flush=True)
            print('ran=0 passed=0 failed=0 blocked=14 assertions=0')
            return 2
    case('M01 three-date real XML CLI/view/single rsync', initial)
    for mode in ('quick', 'checksum'):
        case('M02/M49 unchanged ' + mode, lambda mode=mode: incremental(mode, 'unchanged'))
    case('M02 added only', lambda: incremental('quick', 'add'))
    case('M02 deleted source preserved', lambda: incremental('quick', 'delete'))
    for mode in ('quick', 'checksum'):
        case('M16 same-size-mtime changed ' + mode, lambda mode=mode: change(mode))
        case('M17 mtime-only ' + mode, lambda mode=mode: change(mode, True))
    case('M20/M36 Linux names bytes and NUL argv', names)
    case('M27 broken view link rerun', broken)
    case('M25 partial isolation rerun', partial)
    case('M31 backup-dir failure not full', backup_failure)
    case('M31 actual tmpfs ENOSPC old bytes protected', enospc)
    print(f'ran={RAN} passed={PASSED} failed={FAILED} blocked={BLOCKED} assertions={ASSERTIONS}', flush=True)
    print('G3 PARTIAL: source-module provider, synthetic Linux filesystem only; no IPK/real card/SSD/performance/I-O proof')
    return int(FAILED != 0 or RAN != 14)


if __name__ == '__main__':
    raise SystemExit(main())

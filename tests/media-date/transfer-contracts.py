#!/usr/bin/env python3
"""NUL-safe argv oracle for delivered transfer profile, not actual rsync acceptance."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'files/opt/outdoor-backup/scripts/backup-transfer.sh'
RAN = PASSED = FAILED = ASSERTIONS = 0
with tempfile.TemporaryDirectory(prefix='media-date-transfer-') as tmp:
    base = Path(tmp).resolve()
    (base / 'var').mkdir()
    view = base / 'work/view'
    view.mkdir(parents=True)
    library = base / 'library'
    library.mkdir()
    replaced = library / '.outdoor-backup/replaced/job-1'
    replaced.mkdir(parents=True)
    log = library / 'log with space\nnewline'
    argv_file = base / 'argv'

    def run(comparison):
        # Runner double is explicitly argv-only. It never reads or copies media.
        body = '''
. "$1"
BASE_DIR=$2
BACKUP_CANCEL_CODE=0
MEDIA_DATE_WORK="$2/work"
TARGET_BACKUP_ROOT="$2/library"
MEDIA_DATE_REPLACED_DIR="$2/library/.outdoor-backup/replaced/job-1"
TARGET_FD_ROOT="$2"
BACKUP_LOG_FILE=$5
setsid() { :; }
lock_is_owned_by_self() { return 0; }
target_anchor_healthy() { return 0; }
check_cancel_request() { return 0; }
transfer_process_run() {
    printf '%s\\0' "$@" > "$BASE_DIR/argv"
    printf '%s\\n' 'Number of regular files transferred: 2' 'Total transferred file size: 9 bytes'
}
if [ "$6" = mirror ]; then
    backup_transfer "$3/" "$4/" "$5"
else
    backup_transfer_date "$3" "$4" "$5" "$6" "$7"
fi
'''
        argv_file.unlink(missing_ok=True)
        result = subprocess.run(['/bin/sh', '-c', body, 'scenario', str(SCRIPT), str(base),
                                 str(view), str(library), str(log), comparison, str(replaced)],
                                capture_output=True, text=True)
        return result, argv_file.read_bytes().split(b'\0')[:-1] if argv_file.exists() else []

    for mode in ('quick', 'checksum', 'invalid', 'mirror'):
        RAN += 1
        try:
            result, argv = run(mode)
            ASSERTIONS += 1
            assert result.returncode == (2 if mode == 'invalid' else 0), result.stderr
            if mode == 'invalid':
                ASSERTIONS += 1
                assert not argv, 'invalid comparison launched runner'
            else:
                expected = [b'rsync', b'-aL', b'--prune-empty-dirs', b'--partial-dir=.rsync-partial',
                            b'--backup', ('--backup-dir=' + str(replaced)).encode(), b'--stats',
                            b'--info=progress2', b'--outbuf=L', ('--log-file=' + str(log)).encode()]
                if mode == 'mirror':
                    expected = [b'rsync', b'--archive', b'--recursive', b'--times',
                                b'--prune-empty-dirs', b'--partial', b'--stats',
                                b'--info=progress2', b'--outbuf=L',
                                ('--log-file=' + str(log)).encode(),
                                b'--exclude=FieldBackup.conf', b'--exclude=.Trash*',
                                b'--exclude=.Spotlight*', b'--exclude=.fseventsd',
                                b'--exclude=System Volume Information', b'--exclude=$RECYCLE.BIN']
                if mode == 'checksum':
                    expected.append(b'--checksum')
                expected += [(str(view) + '/').encode(), (str(library) + '/').encode()]
                ASSERTIONS += 1
                assert argv == expected, (argv, expected)
        except Exception as error:
            FAILED += 1
            print(f'CASE M49/M50 exact argv {mode} failed: {error}')
        else:
            PASSED += 1
            print(f'CASE M49/M50 exact argv {mode} passed')

print(f'ran={RAN} passed={PASSED} failed={FAILED} blocked=0 assertions={ASSERTIONS}')
print('NOT RUN: actual rsync M01/M16/M17/M25/M31/M49; argv double is not copy evidence')
if RAN != 4 or FAILED:
    raise SystemExit(1)

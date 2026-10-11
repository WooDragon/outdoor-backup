#!/usr/bin/env python3
"""Synthetic-only executable acceptance scenarios; runs delivered CLI/modules."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'files/opt/outdoor-backup/scripts/media-date-plan.pl'
LIB = ROOT / 'files/opt/outdoor-backup/lib'
UUID = '11111111-2222-4333-8444-555555555555'
SOURCE = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
LIBRARY = dict(version=1, library_id=UUID, layout='date', parser_profile='media-date-v1', archive_offset_minutes=480)
ENV = os.environ.copy()


def cli(*args):
    return subprocess.run(['perl', str(HELPER), *map(str, args)], env=ENV, capture_output=True)


def module(code, *args):
    p = subprocess.run(['perl', '-I' + str(LIB), '-e', code, *map(str, args)], env=ENV, capture_output=True)
    if p.returncode:
        raise AssertionError(p.stderr.decode(errors='replace'))
    return json.loads(p.stdout)


class Scenarios(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='media-date-synthetic-')
        self.root = Path(self.tmp.name).resolve()
        self.source = self.root / 'source'
        self.library = self.root / 'library'
        self.work = self.root / 'work'
        for p in (self.source, self.library, self.work):
            p.mkdir(mode=0o700)
        self.route = self.root / 'snapshot.json'
        self.route.write_text(json.dumps(dict(version=1, library_id=UUID, source_id=SOURCE, entries={})))

    def tearDown(self):
        self.tmp.cleanup()

    def request(self):
        return dict(version=1, source_root=str(self.source), library_root=str(self.library), source_id=SOURCE,
                    library=LIBRARY, route_file=str(self.route), work_dir=str(self.work))

    def plan(self):
        req = self.root / 'request.json'
        req.write_text(json.dumps(self.request()))
        # Exact Linux mountinfo parser is exercised with synthetic namespace data.
        # CLI has no override: non-Linux CLI must fail closed, not pretend dev proves no bind mounts.
        return module('use OutdoorBackup::MediaDate::Planner; use OutdoorBackup::MediaDate::JSON; '
                      'my $r=OutdoorBackup::MediaDate::JSON::read_json($ARGV[0]); '
                      'my $m="1 0 8:1 / $r->{source_root} ro - ext4 /dev/synthetic ro\\n"; '
                      'print OutdoorBackup::MediaDate::JSON::encode_json('
                      'OutdoorBackup::MediaDate::Planner::plan($r, mountinfo=>$m));', req)

    def file(self, name, data=b'synthetic'):
        p = self.source / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        return p

    def entry(self, name, bucket='Undated', identity=None):
        return dict(group_anchor=name, recording_identity=identity, bucket=bucket,
                    date_reason='no_capture_date', target_relpath=f'{bucket}/{SOURCE}/{name}')

    def history(self, entries):
        self.route.write_text(json.dumps(dict(version=1, library_id=UUID, source_id=SOURCE, entries=entries)))

    def test_M34_probe_real_modules(self):
        p = cli('probe')
        self.assertEqual(p.returncode, 0, p.stderr)
        value = json.loads(p.stdout)
        self.assertEqual(value['version'], 1)
        self.assertIn('Image::ExifTool', value['modules'])
        self.assertEqual(value['parser_profile'], 'media-date-v1')

    def test_M23_library_strict_partitions(self):
        path = self.root / 'library.json'
        good = json.dumps(LIBRARY)
        path.write_text(good)
        self.assertEqual(json.loads(cli('validate-library', path).stdout), LIBRARY)
        bad = [good[:-1] + ',"version":1}', good.replace('"version": 1', '"version": "1"'),
               good.replace('480', '841'), good.replace('480', '-841'), good.replace('480', '1.5'),
               good.replace('media-date-v1', 'media-date-v2'), good[:-1] + ',"extra":0}',
               good.replace('"version": 1', '"version": true'), good.replace(UUID, UUID.replace('1', 'G', 1)),
               '{"version":1,"version":2}', '[]', '{}', good + ' null']
        for raw in bad:
            with self.subTest(raw=raw):
                path.write_text(raw)
                self.assertNotEqual(cli('validate-library', path).returncode, 0)
        for offset in (-840, -839, 839, 840):
            path.write_text(json.dumps(dict(LIBRARY, archive_offset_minutes=offset)))
            self.assertEqual(cli('validate-library', path).returncode, 0)

    def test_M23_uppercase_library_uuid_roundtrip(self):
        """Uppercase hex is valid and must survive the delivered CLI unchanged."""
        path = self.root / 'library.json'
        library = dict(LIBRARY, library_id='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'.upper())
        path.write_text(json.dumps(library))
        result = cli('validate-library', path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), library)

    def test_M23_routes_schema_and_prefix(self):
        self.history({'A': self.entry('A')})
        self.assertEqual(cli('validate-routes', self.route, UUID, SOURCE).returncode, 0)
        for name in ('../x', 'a//b', '/x', '.', 'a/.rsync-partial/b'):
            self.history({name: self.entry(name)})
            self.assertNotEqual(cli('validate-routes', self.route, UUID, SOURCE).returncode, 0)
        self.history({'A': self.entry('A'), 'A/B': self.entry('A/B')})
        self.assertNotEqual(cli('validate-routes', self.route, UUID, SOURCE).returncode, 0)
        self.history({'A': dict(self.entry('A'), target_relpath='Undated/x/A')})
        self.assertNotEqual(cli('validate-routes', self.route, UUID, SOURCE).returncode, 0)

    def test_M02_M20_M22_all_current_and_historical(self):
        names = ['未知/file\n\t-name.dat', '-leading', 'a space', 'one', 'two']
        for name in names:
            self.file(name)
        self.file('.Trash-1/skip')
        self.file('DCIM/FieldBackup.conf')
        self.history({'deleted': self.entry('deleted'), names[0]: self.entry(names[0])})
        result = self.plan()
        self.assertEqual(result['files_total'], len(names))
        self.assertEqual(result['excluded_total'], 2)
        routes = json.loads((self.work / 'routes.json').read_text())
        self.assertEqual(set(routes['entries']), set(names + ['deleted']))
        for name in names:
            view = self.work / 'view' / f'Undated/{SOURCE}/{name}'
            self.assertTrue(view.is_symlink())
            self.assertEqual(view.read_bytes(), b'synthetic')
        self.assertFalse((self.work / 'view' / f'Undated/{SOURCE}/deleted').exists())
        self.assertEqual(json.loads((self.work / 'result.json').read_text()), result)
        self.assertEqual(set(result), {'version', 'parser_profile', 'library_id', 'source_id', 'files_total',
                                      'source_bytes_total', 'routes_total', 'excluded_total', 'undated_total', 'warnings', 'outputs'})
        self.assertEqual(result['outputs'], {'view': 'view', 'routes': 'routes.json', 'result': 'result.json'})
        self.assertEqual(set(self.library.iterdir()), set())
        self.assertEqual(set(json.loads(self.route.read_text())['entries']), {'deleted', names[0]})

    def test_M21_symlink_fifo_partial(self):
        for kind in ('symlink', 'fifo', 'partial'):
            with self.subTest(kind=kind):
                if kind == 'symlink':
                    (self.source / 'bad').symlink_to('/etc/passwd')
                elif kind == 'fifo':
                    os.mkfifo(self.source / 'bad')
                elif kind == 'partial':
                    self.file('.rsync-partial/file')
                with self.assertRaises(AssertionError):
                    self.plan()
                for p in self.source.iterdir():
                    if p.is_dir():
                        (p / 'file').unlink()
                        p.rmdir()
                    else:
                        p.unlink()

    def test_M19_M42_foreign_leaf_parent_and_history(self):
        self.file('A/B')
        self.history({'A': self.entry('A')})
        with self.assertRaisesRegex(AssertionError, 'target_prefix_collision'):
            self.plan()
        self.history({})
        parent = self.library / f'Undated/{SOURCE}/A'
        parent.parent.mkdir(parents=True)
        parent.write_bytes(b'foreign')
        with self.assertRaisesRegex(AssertionError, 'target_component_conflict'):
            self.plan()
        parent.unlink()
        parent.mkdir()
        (parent / 'B').write_bytes(b'foreign')
        with self.assertRaisesRegex(AssertionError, 'foreign_target'):
            self.plan()

    def test_M44_namespace_including_replaced_partial_directory(self):
        self.assertEqual(cli('namespace-empty', self.library, SOURCE).returncode, 0)
        for relative in (f'2026/20260809/{SOURCE}', f'Undated/{SOURCE}',
                         f'.outdoor-backup/replaced/job-1/2026/20260809/{SOURCE}'):
            p = self.library / relative
            p.mkdir(parents=True)
            self.assertNotEqual(cli('namespace-empty', self.library, SOURCE).returncode, 0)
            p.rmdir()

    def test_M34_plan_cli_mountinfo_boundary(self):
        req = self.root / 'request.json'
        req.write_text(json.dumps(self.request()))
        p = cli('plan', req)
        if os.path.exists('/proc/self/mountinfo'):
            self.assertEqual(p.returncode, 0, p.stderr)
        else:
            self.assertNotEqual(p.returncode, 0)
            self.assertIn(b'mountinfo_unavailable', p.stderr)

    def test_M04_real_xml_independent(self):
        self.file('clip.xml', (ROOT / 'tests/media-date/fixtures/sony.xml').read_bytes())
        result = self.plan()
        routes = json.loads((self.work / 'routes.json').read_text())
        entry = routes['entries']['clip.xml']
        self.assertEqual(entry['bucket'], '2026/20260809')
        self.assertNotIn('060A2B34', json.dumps(routes))
        self.assertNotIn('serial', json.dumps(result).lower())

    def test_M35_xml_boundary(self):
        xml = (ROOT / 'tests/media-date/fixtures/sony.xml').read_bytes()
        for size in (8 * 1024 * 1024 - 1, 8 * 1024 * 1024, 8 * 1024 * 1024 + 1):
            with self.subTest(size=size):
                self.file('clip.xml', xml + b' ' * (size - len(xml)))
                value = module('use OutdoorBackup::MediaDate::Extractor; use OutdoorBackup::MediaDate::JSON; '
                               'print OutdoorBackup::MediaDate::JSON::encode_json('
                               'OutdoorBackup::MediaDate::Extractor->new->extract($ARGV[0]));', self.source / 'clip.xml')
                self.assertEqual(bool(value['dates']), size <= 8 * 1024 * 1024)
                if size > 8 * 1024 * 1024:
                    self.assertIn('xml_too_large', value['warnings'])


    def test_M23_nested_duplicate_and_anchor_integrity(self):
        raw = '{"version":1,"library_id":"' + UUID + '","source_id":"' + SOURCE + '","entries":{"a":{},"\\u0061":{}}}'
        self.route.write_text(raw)
        self.assertNotEqual(cli('validate-routes', self.route, UUID, SOURCE).returncode, 0)
        first = dict(self.entry('a'), group_anchor='b')
        second = self.entry('b', '2026/20260809')
        self.history({'a': first, 'b': second})
        p = cli('validate-routes', self.route, UUID, SOURCE)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(b'invalid_group_anchor', p.stderr)

    def test_M19_history_reverse_and_actual_symlink(self):
        self.file('A')
        self.history({'A/B': self.entry('A/B')})
        with self.assertRaisesRegex(AssertionError, 'target_prefix_collision'):
            self.plan()
        self.history({})
        p = self.library / f'Undated/{SOURCE}'
        p.parent.mkdir()
        p.symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(AssertionError, 'target_component_conflict'):
            self.plan()

    def test_M22_bad_xml_and_all_actual_exclusions(self):
        self.file('bad.xml', b'<NonRealTimeMeta><broken')
        for name in ('FieldBackup.conf', '.Trash-item', '.Spotlight-V100', '.fseventsd',
                     'System Volume Information', '$RECYCLE.BIN'):
            self.file(name + '/excluded')
        result = self.plan()
        self.assertEqual(result['files_total'], 1)
        self.assertEqual(result['excluded_total'], 6)
        self.assertEqual(result['undated_total'], 1)
        transfer = (ROOT / 'files/opt/outdoor-backup/scripts/backup-transfer.sh').read_text()
        self.assertEqual(transfer.count('--exclude='), 6)
        for name in ('.Trash*', '.Spotlight*', '.fseventsd', 'System Volume Information'):
            self.assertIn('--exclude="' + name + '"', transfer)
        self.assertIn('--exclude="${CONFIG_FILE:-FieldBackup.conf}"', transfer)
        self.assertIn('--exclude="\\$RECYCLE.BIN"', transfer)

    def test_M23_request_exact_private_outputs_and_missing_route(self):
        req = self.root / 'request.json'
        for request in (dict(self.request(), extra='unsafe'), dict(self.request(), version=2),
                        dict(self.request(), route_file=str(self.root / 'missing'))):
            req.write_text(json.dumps(request))
            self.assertNotEqual(cli('plan', req).returncode, 0)
        self.work.chmod(0o755)
        req.write_text(json.dumps(self.request()))
        p = cli('plan', req)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(b'work_directory_not_private', p.stderr)
        self.work.chmod(0o700)
        (self.work / 'routes.json').write_text('sentinel')
        p = cli('plan', req)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual((self.work / 'routes.json').read_text(), 'sentinel')

    def test_M21_actual_nonutf8_filesystem(self):
        try:
            fd = os.open(os.fsencode(self.source) + b'/bad\xff', os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
        except OSError as error:
            self.skipTest(f'BLOCKED source filesystem cannot represent nonUTF8 bytes: {error.errno}')
        with self.assertRaises(AssertionError):
            self.plan()

    def test_M36_actual_case_unicode_filesystem(self):
        for name in ('A', 'a', 'é', 'é'):
            try:
                fd = os.open(self.source / name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                os.close(fd)
            except FileExistsError:
                self.skipTest('BLOCKED filesystem aliases case or Unicode names; target ext4/btrfs required')
        self.assertEqual(self.plan()['files_total'], 4)

    def test_M35_routes_size_boundary(self):
        base = self.route.read_bytes()
        for size in (64 * 1024 * 1024 - 1, 64 * 1024 * 1024, 64 * 1024 * 1024 + 1):
            with self.subTest(size=size):
                self.route.write_bytes(base + b' ' * (size - len(base)))
                p = cli('validate-routes', self.route, UUID, SOURCE)
                self.assertEqual(p.returncode == 0, size <= 64 * 1024 * 1024, p.stderr)

    def test_M35_source_count_boundary(self):
        for index in range(49999):
            (self.source / f'f{index:05}').touch()
        code = ('use OutdoorBackup::MediaDate::Scan; use OutdoorBackup::MediaDate::JSON; '
                'my $m="1 0 8:1 / $ARGV[0] ro - ext4 x ro\\n"; '
                'my $s=OutdoorBackup::MediaDate::Scan::scan($ARGV[0],mountinfo=>$m); '
                'print OutdoorBackup::MediaDate::JSON::encode_json({count=>scalar keys %{$s->{files}}});')
        self.assertEqual(module(code, self.source)['count'], 49999)
        (self.source / 'f49999').touch()
        self.assertEqual(module(code, self.source)['count'], 50000)
        (self.source / 'f50000').touch()
        with self.assertRaisesRegex(AssertionError, 'source_count_limit'):
            module(code, self.source)

    def test_M03_real_exif_api(self):
        import struct
        # Minimal little-endian uncompressed 1x1 TIFF generated from scratch.
        fields = [(256, 3, 1, 1), (257, 3, 1, 1), (258, 3, 1, 8), (259, 3, 1, 1),
                  (262, 3, 1, 1), (273, 4, 1, 122), (278, 4, 1, 1), (279, 4, 1, 1), (277, 3, 1, 1)]
        header = b'II' + struct.pack('<HIH', 42, 8, len(fields))
        body = b''.join(struct.pack('<HHII', *field) for field in fields) + struct.pack('<I', 0) + b'\x7f'
        path = self.file('photo.tif', header + body)
        value = module('use Image::ExifTool; use OutdoorBackup::MediaDate::Extractor; use OutdoorBackup::MediaDate::JSON; '
                       'my $e=Image::ExifTool->new; '
                       '$e->SetNewValue("DateTimeOriginal","2026:08:08 23:59:59"); '
                       '$e->SetNewValue("OffsetTimeOriginal","+09:00"); $e->SetNewValue("SubSecTimeOriginal","123"); '
                       '$e->WriteInfo($ARGV[0]) or die "synthetic EXIF write failed"; '
                       'print OutdoorBackup::MediaDate::JSON::encode_json('
                       'OutdoorBackup::MediaDate::Extractor->new->extract($ARGV[0]));', path)
        self.assertEqual(value['dates'][0]['value'], '2026:08:08 23:59:59.123+09:00')
        result = self.plan()
        self.assertEqual(result['undated_total'], 0)

    def test_M04_real_embedded_xml(self):
        import struct
        def atom(tag, data):
            return struct.pack('>I', 8 + len(data)) + tag + data
        xml = (ROOT / 'tests/media-date/fixtures/sony.xml').read_bytes()
        path = self.file('clip.mp4', atom(b'ftyp', b'isom\x00\x00\x00\x00isom') + atom(b'moov', atom(b'meta', atom(b'xml ', xml))))
        value = module('use OutdoorBackup::MediaDate::Extractor; use OutdoorBackup::MediaDate::JSON; '
                       'print OutdoorBackup::MediaDate::JSON::encode_json('
                       'OutdoorBackup::MediaDate::Extractor->new->extract($ARGV[0]));', path)
        self.assertEqual(value['dates'][0]['value'], '2026:08:09 00:30:00+09:00')
        self.assertTrue(value['umid'])


if __name__ == '__main__':
    unittest.main(verbosity=2)

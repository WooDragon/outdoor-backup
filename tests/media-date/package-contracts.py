#!/usr/bin/env python3
"""Recipe/install fixtures only: execute delivered install macros, not an SDK/IPK build."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / 'outdoor-backup/Makefile'
LUCI = ROOT / 'luci-app-outdoor-backup/Makefile'
OPTIONAL = 'outdoor-backup-media-date'
DEPS = {'outdoor-backup', 'exiftool', 'perl', 'perlbase-essential',
        'perlbase-findbin', 'perlbase-json-pp', 'perlbase-digest',
        'perlbase-encode', 'perlbase-fcntl', 'perlbase-time', 'perlbase-cwd', 'perlbase-b', 'perlbase-storable'}


def block(text, name):
    """Extract one actual Make definition; missing or duplicate definitions fail."""
    values = re.findall(r'^define ' + re.escape(name) + r'\n(.*?)^endef$', text, re.M | re.S)
    if len(values) != 1:
        raise AssertionError(f'expected one {name}, found {len(values)}')
    return values[0]


def install(recipe, package, stage, temporary):
    """Expand only three installation macros; unknown Make constructs fail closed.

    This intentionally does not emulate BuildPackage, dependency resolution or IPK.
    """
    script = block(recipe.read_text(), f'Package/{package}/install')
    macros = {'$(1)': str(stage), '$(INSTALL_DIR)': 'install -d -m0755',
              '$(INSTALL_BIN)': 'install -m0755', '$(INSTALL_DATA)': 'install -m0644'}
    for token, value in macros.items():
        script = script.replace(token, value)
    if '$(' in script:
        raise AssertionError('unsupported Make construct in install fixture')
    result = subprocess.run(['/bin/sh', '-eu', '-c', script], cwd=recipe.parent,
                            capture_output=True, text=True)
    if result.returncode:
        raise AssertionError(f'install fixture failed: {result.stdout}\n{result.stderr}')


class Contracts(unittest.TestCase):
    """Given the feed, require optional ownership and mirror-only compatibility."""
    def test_three_discoverable_packages(self):
        packages = []
        for recipe in (CORE, LUCI):
            packages += re.findall(r'^\$\(eval \$\(call BuildPackage,([^,)]+)\)\)$', recipe.read_text(), re.M)
        self.assertCountEqual(packages, ['outdoor-backup', OPTIONAL, 'luci-app-outdoor-backup'])
        self.assertFalse((ROOT / 'Makefile').exists())

    def test_canonical_source(self):
        self.assertTrue((ROOT / 'outdoor-backup/files').is_symlink())
        self.assertEqual(os.readlink(ROOT / 'outdoor-backup/files'), '../files')
        self.assertEqual((ROOT / 'outdoor-backup/files').resolve(), ROOT / 'files')

    def test_core_has_no_perl_dependency(self):
        definition = block(CORE.read_text(), 'Package/outdoor-backup')
        self.assertNotRegex(definition, r'\+[^\s]*(?:perl|exiftool|media-date)')

    def test_optional_dependencies(self):
        definition = block(CORE.read_text(), f'Package/{OPTIONAL}')
        dependencies = set(re.findall(r'\+([a-z0-9-]+)', definition))
        self.assertEqual(dependencies, DEPS)
        self.assertNotIn('DEFAULT:=y', definition)

    def test_fixed_target_module_proof_and_transitive_closure(self):
        proof = json.loads((ROOT / 'tests/media-date/package-target-proof.json').read_text())
        self.assertEqual(proof['commit'], '97af13986bcb1efa6fdcc85af9589dd5640b6e63')
        for name, source in proof['sources'].items():
            data = (ROOT / 'tests/media-date' / ('package-' + name)).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), source['sha256'])
        text = (ROOT / 'tests/media-date/package-perlbase.mk').read_text()
        for package in proof['transitive_dependencies']:
            if package == 'perl':
                continue
            definition = block(text, 'Package/' + package)
            declared = {'perl', *re.findall(r'\+(perlbase-[a-z0-9-]+)', definition)}
            self.assertEqual(declared, set(proof['package_dependencies'][package]))
            self.assertTrue(declared <= set(proof['transitive_dependencies']))
        self.assertEqual(set(proof['direct_dependencies']), DEPS - {'outdoor-backup', 'exiftool', 'perl'})
        modules = [ROOT / 'files/opt/outdoor-backup/scripts/media-date-plan.pl',
                   *sorted((ROOT / 'files/opt/outdoor-backup/lib/OutdoorBackup/MediaDate').glob('*.pm'))]
        for source in modules:
            for name in re.findall(r'^use ([A-Za-z][A-Za-z0-9_:]*)', source.read_text(), re.M):
                if name.startswith('OutdoorBackup::') or name in ('strict', 'warnings', 'lib', 'Image::ExifTool'):
                    continue
                self.assertIn(proof['module_owners'][name], proof['transitive_dependencies'])
        self.assertEqual(proof['provider']['version'], '13.59')
        self.assertEqual(proof['provider']['commit'], 'f6d7cbfe57b4727ff1eee542e8957ac19e219c07')

    def test_function_versions(self):
        version = re.search(r'^PKG_VERSION:=(.+)$', CORE.read_text(), re.M).group(1)
        self.assertEqual(version, '1.5.0')
        self.assertEqual(re.search(r'^PKG_VERSION:=(.+)$', LUCI.read_text(), re.M).group(1), '1.2.0')
        self.assertNotIn('VERSION:=', block(CORE.read_text(), f'Package/{OPTIONAL}'))

    def test_core_install_owns_only_lazy_shell(self):
        with tempfile.TemporaryDirectory(prefix='ob-package-fixture-') as tmp:
            temporary = Path(tmp)
            stage = temporary / 'root'
            install(CORE, 'outdoor-backup', stage, temporary)
            scripts = stage / 'opt/outdoor-backup/scripts'
            self.assertEqual(sorted(p.name for p in scripts.iterdir()),
                             sorted(p.name for p in (ROOT / 'files/opt/outdoor-backup/scripts').glob('*.sh')))
            self.assertFalse((scripts / 'media-date-plan.pl').exists())
            self.assertFalse((stage / 'opt/outdoor-backup/lib').exists())
            self.assertTrue((scripts / 'media-date.sh').is_file())
            self.assertTrue((scripts / 'media-date-tools.sh').is_file())
            self.assertTrue((scripts / 'media-date-publication.sh').is_file())

    def test_optional_install_exact_source_and_modes(self):
        with tempfile.TemporaryDirectory(prefix='ob-package-fixture-') as tmp:
            temporary = Path(tmp)
            stage = temporary / 'root'
            install(CORE, OPTIONAL, stage, temporary)
            sources = [ROOT / 'files/opt/outdoor-backup/scripts/media-date-plan.pl',
                       *sorted((ROOT / 'files/opt/outdoor-backup/lib/OutdoorBackup/MediaDate').glob('*.pm'))]
            self.assertEqual(len(sources), 10)
            installed = [p for p in stage.rglob('*') if p.is_file()]
            self.assertEqual({p.relative_to(stage).as_posix() for p in installed},
                             {p.relative_to(ROOT / 'files').as_posix() for p in sources})
            for source in sources:
                target = stage / source.relative_to(ROOT / 'files')
                self.assertEqual(target.read_bytes(), source.read_bytes())
                self.assertEqual(target.stat().st_mode & 0o777, 0o755 if source.suffix == '.pl' else 0o644)

    def test_luci_install_has_new_helpers_without_optional_dependency(self):
        self.assertNotIn('+outdoor-backup-media-date', block(LUCI.read_text(), 'Package/luci-app-outdoor-backup'))
        with tempfile.TemporaryDirectory(prefix='ob-package-fixture-') as tmp:
            temporary = Path(tmp)
            stage = temporary / 'root'
            install(LUCI, 'luci-app-outdoor-backup', stage, temporary)
            for name in ('media.lua', 'security.lua'):
                target = stage / 'usr/lib/lua/luci/model/outdoor-backup' / name
                self.assertEqual(target.read_bytes(), (LUCI.parent / 'luasrc/model/outdoor-backup' / name).read_bytes())


if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Contracts)
    if suite.countTestCases() != 9:
        raise SystemExit('incomplete package scenario registry')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    failures = len(result.failures) + len(result.errors)
    print(f'RECIPE FIXTURES ONLY cases={result.testsRun} passed={result.testsRun-failures} failed={failures}; SDK/IPK/G3=not-executed')
    raise SystemExit(0 if result.wasSuccessful() and result.testsRun == 9 else 1)

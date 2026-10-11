#!/usr/bin/env python3
"""Read-only delivered helper suites; reports real counts to guest evidence only."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent


def run_tap(name, expected):
    """Execute a delivered Perl suite and require its plan and actual TAP count."""
    result = subprocess.run(['perl', str(HERE / name)], capture_output=True, text=True)
    output = result.stdout + result.stderr
    print(output, end='')
    ran = len(re.findall(r'^(?:not )?ok \d+', output, re.M))
    failed = len(re.findall(r'^not ok \d+', output, re.M))
    complete = bool(re.search(r'^1\.\.' + str(expected) + r'$', output, re.M))
    print(f'helper suite={name} cases={ran} passed={ran-failed} failed={failed}')
    return result.returncode == 0 and ran == expected and failed == 0 and complete


def main():
    """Load the actual Python scenario class, never rewrite its implementation."""
    spec = importlib.util.spec_from_file_location('helper_scenarios', HERE / 'scenarios.py')
    scenarios = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scenarios)
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(scenarios.Scenarios)
    if suite.countTestCases() != 21:
        raise SystemExit('incomplete helper integration registry')
    semantic = run_tap('semantic-scenarios.pl', 84)
    uuid = run_tap('uuid-scenarios.pl', 4)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    failures = len(result.failures) + len(result.errors)
    counts = dict(cases=result.testsRun, passed=result.testsRun-failures-len(result.skipped),
                  failed=failures, blocked=len(result.skipped))
    print('helper integration ' + json.dumps(counts))
    evidence = Path(os.environ.get('TEST_EVIDENCE', '/evidence'))
    (evidence / 'helper-counts.json').write_text(json.dumps(counts) + '\n')
    return 0 if semantic and uuid and result.wasSuccessful() and not result.skipped and result.testsRun == 21 else 1


if __name__ == '__main__':
    raise SystemExit(main())

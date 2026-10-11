#!/usr/bin/env python3
"""Run exactly this helper bag, retaining TAP and actual unittest accounting."""
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('media_date_scenarios', HERE / 'scenarios.py')
scenarios = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scenarios)

command = ['perl', str(HERE / 'semantic-scenarios.pl')]
semantic = subprocess.run(command, capture_output=True, env=os.environ.copy())
tap = (semantic.stdout + semantic.stderr).decode('utf-8', errors='replace')
(HERE / 'semantic-final.log').write_text('COMMAND ' + json.dumps(command) + '\n' + tap)
ran = len(re.findall(r'^(?:not )?ok \d+', tap, re.MULTILINE))
failed = len(re.findall(r'^not ok \d+', tap, re.MULTILINE))
complete = semantic.returncode == 0 and ran == 84 and re.search(r'^1\.\.84$', tap, re.MULTILINE)

suite = unittest.defaultTestLoader.loadTestsFromTestCase(scenarios.Scenarios)
if suite.countTestCases() != 20:
    raise RuntimeError(f'Incomplete scenario registry: expected 20, got {suite.countTestCases()}')
stream = io.StringIO()
result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
(HERE / 'integration-final.log').write_text('COMMAND loaded scenarios.py via unittest (delivered CLI/modules)\n' + stream.getvalue())
account = dict(semantic=dict(ran=ran, passed=ran-failed, failed=failed,
                            exit=semantic.returncode, complete=bool(complete)),
               integration=dict(ran=result.testsRun,
                                passed=result.testsRun-len(result.failures)-len(result.errors)-len(result.skipped),
                                failed=len(result.failures)+len(result.errors), blocked=len(result.skipped)),
               blocked=[dict(test=str(test), reason=reason) for test, reason in result.skipped])
(HERE / 'final-counts.json').write_text(json.dumps(account, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(account, ensure_ascii=False, indent=2))
if not complete or not result.wasSuccessful() or result.testsRun != 20:
    sys.exit(1)

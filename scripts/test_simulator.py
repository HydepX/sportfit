#!/usr/bin/env python3
"""Select an installed iPhone simulator without pinning a disappearing model."""
import json
import os
import subprocess
import hashlib
from pathlib import Path
import re

available = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
candidates = [device for runtime, devices in available['devices'].items() if 'iOS' in runtime
              for device in devices if device.get('isAvailable') and 'iPhone' in device['name']]
if not candidates:
    raise SystemExit('No available iPhone simulator')
device = candidates[0]
subprocess.run([
    'xcodebuild', '-project', 'SportFit.xcodeproj', '-scheme', 'SportFit',
    '-configuration', 'Release', '-destination', f"platform=iOS Simulator,id={device['udid']}",
    '-derivedDataPath', os.path.join(os.environ.get('RUNNER_TEMP', '/tmp'), 'SportFitTests'),
    '-resultBundlePath', os.path.join(os.environ.get('RUNNER_TEMP', '/tmp'), 'SportFitTests.xcresult'),
    'CODE_SIGNING_ALLOWED=NO', 'ENABLE_DEBUG_DYLIB=NO', 'ENABLE_TESTABILITY=YES',
    'CURRENT_PROJECT_VERSION=' + os.environ.get('GITHUB_RUN_NUMBER', '2'),
    'SPORTFIT_BUILD_COMMIT=' + os.environ.get('GITHUB_SHA', 'local'), 'test'
], check=True)

summary = json.loads(subprocess.check_output([
    'xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path',
    os.path.join(os.environ.get('RUNNER_TEMP', '/tmp'), 'SportFitTests.xcresult')
]))
expected_tests = sum(len(re.findall(r'func\s+test\w+\s*\(', path.read_text()))
                     for folder in ('Tests/iOS', 'Tests/UI') for path in Path(folder).glob('*.swift'))
if summary.get('passedTests', 0) != expected_tests or summary.get('failedTests', 0) != 0 or summary.get('skippedTests', 0) != 0:
    raise SystemExit(f"Unexpected simulator test result counts: {summary}")
print(f"Verified {summary['totalTestCount']} simulator tests executed")

# Exercise the OS installation path without deleting the data container. This
# complements the old-JSON -> SQLite migration and backup tests; it is not an
# AltServer provisioning test on the user's physical iPhone.
bundle = 'com.hydepx.sportfit'
subprocess.run(['xcrun', 'simctl', 'terminate', device['udid'], bundle], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', device['udid'], bundle, 'data'], text=True).strip())
documents = container / 'Documents'
probe = documents / 'sportfit-upgrade-probe.txt'
probe.write_text('Synthetic simulator installation preservation probe')
before = {str(path.relative_to(documents)): hashlib.sha256(path.read_bytes()).hexdigest()
          for path in documents.rglob('*') if path.is_file()}
app = Path(os.environ.get('RUNNER_TEMP', '/tmp')) / 'SportFitTests/Build/Products/Release-iphonesimulator/SportFit.app'
subprocess.run(['xcrun', 'simctl', 'install', device['udid'], str(app)], check=True)
after_container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', device['udid'], bundle, 'data'], text=True).strip())
after = {str(path.relative_to(after_container / 'Documents')): hashlib.sha256(path.read_bytes()).hexdigest()
         for path in (after_container / 'Documents').rglob('*') if path.is_file()}
if before != after:
    raise SystemExit('Simulator reinstallation changed the data container')
subprocess.run(['xcrun', 'simctl', 'launch', device['udid'], bundle], check=True)
print(f'Verified simulator reinstallation preserves {len(before)} document files, including saved workouts and backups')

#!/usr/bin/env python3
"""Select an installed iPhone simulator without pinning a disappearing model."""
import json
import os
import subprocess
import hashlib
from pathlib import Path
import re
import sqlite3
import time
import uuid
from datetime import datetime

available = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
candidates = [(device, runtime) for runtime, devices in available['devices'].items() if 'iOS' in runtime
              for device in devices if device.get('isAvailable') and 'iPhone' in device['name']]
if not candidates:
    raise SystemExit('No available iPhone simulator')
device, runtime = candidates[0]
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

# Xcode may run tests on clones and shut the selected device down afterwards.
# Use an isolated simulator for a real install/migrate/reinstall sequence.
bundle = 'com.hydepx.sportfit'
app = Path(os.environ.get('RUNNER_TEMP', '/tmp')) / 'SportFitTests/Build/Products/Release-iphonesimulator/SportFit.app'
upgrade_device = subprocess.check_output([
    'xcrun', 'simctl', 'create', 'SportFit Upgrade Verification', device['deviceTypeIdentifier'], runtime
], text=True).strip()
subprocess.run(['xcrun', 'simctl', 'boot', upgrade_device], check=True)
subprocess.run(['xcrun', 'simctl', 'bootstatus', upgrade_device, '-b'], check=True)
subprocess.run(['xcrun', 'simctl', 'install', upgrade_device, str(app)], check=True)
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', upgrade_device, bundle, 'data'], text=True).strip())
documents = container / 'Documents'
documents.mkdir(exist_ok=True)
reference = time.time() - 120 - 978307200  # Date Foundation seconds since 2001.
workout_id = str(uuid.uuid4()).upper()
fixture = {
    'id': workout_id, 'date': datetime.now().astimezone().date().isoformat(),
    'programId': 'simulator-upgrade-probe', 'title': 'Synthetic upgrade verification',
    'startedAt': reference, 'finishedAt': reference + 60, 'durationSeconds': 60,
    'finishedEarly': True, 'movements': [{
        'id': str(uuid.uuid4()).upper(), 'sourceId': 'press_floor', 'exerciseId': 'press_floor',
        'title': 'Synthetic fixture', 'isTimed': False, 'target': 'Test fixture', 'skipped': False,
        'sets': [{'id': str(uuid.uuid4()).upper(), 'reps': 4, 'weightKg': 0, 'completedAt': reference + 30}]
    }]
}
(documents / 'workout_history.v1.json').write_text(json.dumps([fixture]))
(documents / 'sportfit-upgrade-probe.txt').write_text('Synthetic simulator installation preservation probe')
subprocess.run(['xcrun', 'simctl', 'launch', upgrade_device, bundle], check=True)

def migrated(folder):
    database = folder / 'workout_history.sqlite'
    if not database.exists():
        return False
    try:
        connection = sqlite3.connect(f'file:{database}?mode=ro', uri=True, timeout=1)
        try:
            rows = connection.execute('SELECT id,payload,sha256 FROM workouts').fetchall()
            return (len(rows) == 1 and rows[0][0] == workout_id
                    and hashlib.sha256(rows[0][1]).hexdigest() == rows[0][2]
                    and json.loads(rows[0][1])['movements'][0]['sets'][0]['reps'] == 4)
        finally:
            connection.close()
    except sqlite3.DatabaseError:
        return False

deadline = time.monotonic() + 45
while time.monotonic() < deadline:
    if migrated(documents) and list((documents / 'Backups').glob('sportfit-auto-*.json')):
        break
    time.sleep(0.25)
else:
    raise SystemExit('App did not migrate the legacy fixture and create a local backup')
subprocess.run(['xcrun', 'simctl', 'terminate', upgrade_device, bundle], check=True)
before = {str(path.relative_to(documents)): hashlib.sha256(path.read_bytes()).hexdigest()
          for path in documents.rglob('*') if path.is_file()}
subprocess.run(['xcrun', 'simctl', 'install', upgrade_device, str(app)], check=True)
after_container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', upgrade_device, bundle, 'data'], text=True).strip())
after_documents = after_container / 'Documents'
after = {str(path.relative_to(after_documents)): hashlib.sha256(path.read_bytes()).hexdigest()
         for path in after_documents.rglob('*') if path.is_file()}
if before != after or not migrated(after_documents):
    raise SystemExit('Simulator reinstallation changed stored history or backup files')
subprocess.run(['xcrun', 'simctl', 'launch', upgrade_device, bundle], check=True)
print(f'Verified simulator reinstallation preserves {len(before)} document files, a migrated workout and local backup')
subprocess.run(['xcrun', 'simctl', 'shutdown', upgrade_device], check=True)
subprocess.run(['xcrun', 'simctl', 'delete', upgrade_device], check=True)

#!/usr/bin/env python3
"""Select an installed iPhone simulator without pinning a disappearing model."""
import json
import os
import subprocess

available = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
candidates = [device for runtime, devices in available['devices'].items() if 'iOS' in runtime
              for device in devices if device.get('isAvailable') and 'iPhone' in device['name']]
if not candidates:
    raise SystemExit('No available iPhone simulator')
device = candidates[0]
subprocess.run([
    'xcodebuild', '-project', 'SportFit.xcodeproj', '-scheme', 'SportFit',
    '-configuration', 'Debug', '-destination', f"platform=iOS Simulator,id={device['udid']}",
    '-derivedDataPath', os.path.join(os.environ.get('RUNNER_TEMP', '/tmp'), 'SportFitTests'),
    '-resultBundlePath', os.path.join(os.environ.get('RUNNER_TEMP', '/tmp'), 'SportFitTests.xcresult'),
    'CODE_SIGNING_ALLOWED=NO', 'test'
], check=True)

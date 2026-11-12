#!/usr/bin/env python3
"""Check the actual iPhone archive, not just a successful zip invocation."""
import json
import plistlib
import sys
import struct
import zipfile


def verify(path, healthkit=False, expected_commit=None):
    with zipfile.ZipFile(path) as archive:
        bad = archive.testzip()
        if bad:
            raise ValueError(f"Corrupt ZIP member: {bad}")
        names = archive.namelist()
        apps = {n.split('/')[1] for n in names if n.startswith('Payload/') and len(n.split('/')) > 2}
        if apps != {'SportFit.app'}:
            raise ValueError(f"Unexpected applications: {apps}")
        base = 'Payload/SportFit.app/'
        info = plistlib.loads(archive.read(base + 'Info.plist'))
        enabled = info.get('SportFitHealthKitEnabled')
        if not isinstance(enabled, bool) or enabled != healthkit:
            raise ValueError('Unexpected HealthKit build variant')
        if expected_commit is not None and info.get('SportFitBuildCommit') != expected_commit:
            raise ValueError('Unexpected build commit')
        if healthkit and not info.get('NSHealthShareUsageDescription'):
            raise ValueError('Missing HealthKit read purpose string')
        if info.get('CFBundleIdentifier') != 'com.hydepx.sportfit':
            raise ValueError('Incorrect bundle identifier')
        if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
            raise ValueError('Expected a physical-device build')
        if float(info.get('MinimumOSVersion', '0')) < 17:
            raise ValueError('Unexpected deployment target')
        executable = info.get('CFBundleExecutable')
        if not executable:
            raise ValueError('Missing application executable')
        binary = archive.read(base + executable)
        if len(binary) < 8 or struct.unpack('<II', binary[:8]) != (0xFEEDFACF, 0x0100000C):
            raise ValueError('Expected a 64-bit ARM Mach-O executable')
        catalog = json.loads(archive.read(base + 'exercises.v1.json'))
        program = json.loads(archive.read(base + 'program_12w.v1.json'))
        ids = [entry['id'] for entry in catalog['exercises']]
        if len(ids) != 53 or len(set(ids)) != 53:
            raise ValueError('Invalid bundled catalog')
        references = {eid for phase in program['phases'] for day in phase['days'] for eid in day['exercise_ids']}
        if not references <= set(ids):
            raise ValueError('Unknown bundled exercise IDs')
        exact = json.loads(archive.read(base + 'program_12w_with_sets.v2.json'))
        if exact.get('schema_version') != '2.0.0' or exact.get('session_count') != len(exact.get('sessions', [])) or not exact.get('sessions'):
            raise ValueError('Missing precise workout sessions')
        for session in exact['sessions']:
            for item in session['items']:
                if item['exercise_id'] not in ids or item['sets'] < 1:
                    raise ValueError('Invalid precise assignment')
                field = 'target_seconds' if item['mode'] == 'duration' else 'target_reps'
                if item.get(field, 0) < 1:
                    raise ValueError('Missing precise target')
        if any(n.endswith('embedded.mobileprovision') for n in names):
            raise ValueError('Expected an unsigned archive without a provisioning profile')
    print('OK: physical-iPhone IPA, executable, Info.plist, 53 IDs, bundled program and ZIP integrity')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('path')
    parser.add_argument('--healthkit', action='store_true')
    parser.add_argument('--expected-commit')
    args = parser.parse_args()
    verify(args.path, healthkit=args.healthkit, expected_commit=args.expected_commit)

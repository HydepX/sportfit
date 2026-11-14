#!/usr/bin/env python3
"""Check the actual iPhone archive, not just a successful zip invocation."""
import json
import plistlib
import sys
import struct
import zipfile


def verify_executable(binary):
    if len(binary) < 32:
        raise ValueError('Truncated Mach-O header')
    magic, cpu, _, filetype, commands, command_bytes, _, _ = struct.unpack_from('<8I', binary)
    if (magic, cpu, filetype) != (0xFEEDFACF, 0x0100000C, 2):
        raise ValueError('Expected an ARM64 Mach-O application executable')
    end = 32 + command_bytes
    if end > len(binary) or commands > command_bytes // 8:
        raise ValueError('Truncated Mach-O commands')
    offset = 32
    platform = None
    for _ in range(commands):
        if offset + 8 > end:
            raise ValueError('Truncated Mach-O command')
        command, size = struct.unpack_from('<II', binary, offset)
        if size < 8 or size % 8 or offset + size > end:
            raise ValueError('Invalid Mach-O command size')
        if command == 0x32:  # LC_BUILD_VERSION: 2 = iOS device, 7 = iOS Simulator.
            if size < 24:
                raise ValueError('Truncated Mach-O build version')
            platform = struct.unpack_from('<I', binary, offset + 8)[0]
        if command == 0x2C:  # LC_ENCRYPTION_INFO_64
            if size < 24 or struct.unpack_from('<I', binary, offset + 16)[0] != 0:
                raise ValueError('Encrypted executable cannot be re-signed for AltStore')
        offset += size
    if offset != end or platform != 2:
        raise ValueError('Expected an iOS device binary, regardless of Info.plist platform')


def verify(path, healthkit=False, expected_commit=None, release=False):
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
        verify_executable(binary)
        if release and any(n.endswith(('.debug.dylib', '/__preview.dylib')) for n in names):
            raise ValueError('Expected a Release archive without Xcode debug/preview libraries')
        catalog = json.loads(archive.read(base + 'exercises.v1.json'))
        program = json.loads(archive.read(base + 'program_12w.v1.json'))
        ids = [entry['id'] for entry in catalog['exercises']]
        if len(ids) != len(set(ids)) or catalog['exercise_count'] != len(ids):
            raise ValueError('Invalid bundled catalog')
        active = {entry['id'] for entry in catalog['exercises'] if not entry.get('retired')}
        exact = json.loads(archive.read(base + 'program_12w_with_sets.v2.json'))
        if program != exact or exact.get('program_id') != 'sportfit_12w_2026q4':
            raise ValueError('Old or inconsistent default plan remains in archive')
        if len(active) != 36 or exact.get('exercise_count') != 36 or len(exact.get('sessions', [])) != 48:
            raise ValueError('Invalid new workbook program')
        if sum(len(s['items']) for s in exact['sessions']) != 624:
            raise ValueError('Workbook assignments were changed')
        for session in exact['sessions']:
            for item in session['items']:
                if item['exercise_id'] not in active or item['sets'] < 1:
                    raise ValueError('Invalid assignment or retired exercise in new plan')
                field = 'target_seconds' if item['mode'] in ['duration', 'duration_per_side'] else 'target_reps'
                if item.get(field, 0) < 1: raise ValueError('Missing precise target')
        photos = [e['media']['photo'] for e in catalog['exercises'] if e.get('media', {}).get('photo') and not e.get('retired')]
        for photo in photos:
            asset = base + 'media/' + photo['asset']
            if asset not in names:
                raise ValueError('Missing original technique collage: ' + photo['asset'])
            data = archive.read(asset)
            if not (data.startswith(b'\x89PNG\r\n\x1a\n') or data.startswith(b'\xff\xd8\xff')):
                raise ValueError('Invalid technique image: ' + photo['asset'])
        if any(n.endswith('embedded.mobileprovision') for n in names):
            raise ValueError('Expected an unsigned archive without a provisioning profile')
    print('OK: physical-iPhone IPA, ARM64 iOS executable, Info.plist, 36 current IDs, 48 workouts / 624 assignments, technique collages and ZIP integrity')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('path')
    parser.add_argument('--healthkit', action='store_true')
    parser.add_argument('--expected-commit')
    parser.add_argument('--release', action='store_true')
    args = parser.parse_args()
    verify(args.path, healthkit=args.healthkit, expected_commit=args.expected_commit, release=args.release)

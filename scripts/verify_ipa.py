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
    print('OK: physical-iPhone IPA, ARM64 iOS executable, Info.plist, 53 IDs, bundled program and ZIP integrity')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('path')
    parser.add_argument('--healthkit', action='store_true')
    parser.add_argument('--expected-commit')
    parser.add_argument('--release', action='store_true')
    args = parser.parse_args()
    verify(args.path, healthkit=args.healthkit, expected_commit=args.expected_commit, release=args.release)

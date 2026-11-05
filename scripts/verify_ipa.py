#!/usr/bin/env python3
"""Check the actual iPhone archive, not just a successful zip invocation."""
import json
import plistlib
import sys
import struct
import zipfile


def verify(path):
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
        if any(n.endswith('embedded.mobileprovision') for n in names):
            raise ValueError('Expected an unsigned archive without a provisioning profile')
    print('OK: physical-iPhone IPA, executable, Info.plist, 53 IDs, bundled program and ZIP integrity')


if __name__ == '__main__':
    verify(sys.argv[1])

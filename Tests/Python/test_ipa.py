import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import struct
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('verify_ipa', ROOT / 'scripts/verify_ipa.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ArchiveTests(unittest.TestCase):
    def make(self, path, platform='iPhoneOS', include_catalog=True):
        with zipfile.ZipFile(path, 'w') as archive:
            base = 'Payload/SportFit.app/'
            archive.writestr(base + 'Info.plist', plistlib.dumps({
                'CFBundleIdentifier': 'com.hydepx.sportfit',
                'CFBundleSupportedPlatforms': [platform], 'MinimumOSVersion': '17.0',
                'CFBundleExecutable': 'SportFit'
            }))
            archive.writestr(base + 'SportFit', struct.pack('<II', 0xFEEDFACF, 0x0100000C) + b'fixture')
            if include_catalog:
                archive.write(ROOT / 'SportFit/Resources/Data/exercises.v1.json', base + 'exercises.v1.json')
            archive.write(ROOT / 'SportFit/Resources/Data/program_12w.v1.json', base + 'program_12w.v1.json')
            archive.write(ROOT / 'SportFit/Resources/Data/program_12w_with_sets.v2.json', base + 'program_12w_with_sets.v2.json')

    def test_valid_archive_structure(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'fixture.ipa'
            self.make(path)
            module.verify(path)

    def test_rejects_simulator_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'fixture.ipa'
            self.make(path, platform='iPhoneSimulator')
            with self.assertRaises(ValueError):
                module.verify(path)

    def test_rejects_missing_resources(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'fixture.ipa'
            self.make(path, include_catalog=False)
            with self.assertRaises(KeyError):
                module.verify(path)

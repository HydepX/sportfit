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
    def make(self, path, platform='iPhoneOS', include_catalog=True, healthkit=False):
        with zipfile.ZipFile(path, 'w') as archive:
            base = 'Payload/SportFit.app/'
            archive.writestr(base + 'Info.plist', plistlib.dumps({
                'CFBundleIdentifier': 'com.hydepx.sportfit',
                'CFBundleSupportedPlatforms': [platform], 'MinimumOSVersion': '17.0',
                'CFBundleExecutable': 'SportFit', 'SportFitHealthKitEnabled': healthkit,
                'SportFitBuildCommit': 'test-commit', 'NSHealthShareUsageDescription': 'Test read-only purpose'
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

    def test_rejects_healthkit_trial_as_standard(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'fixture.ipa'
            self.make(path, healthkit=True)
            with self.assertRaises(ValueError):
                module.verify(path)

    def test_accepts_explicit_healthkit_variant(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'fixture.ipa'
            self.make(path, healthkit=True)
            module.verify(path, healthkit=True)

    def test_rejects_standard_when_trial_requested(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'fixture.ipa'
            self.make(path)
            with self.assertRaises(ValueError):
                module.verify(path, healthkit=True)
    def test_rejects_artifact_from_another_commit(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'fixture.ipa'
            self.make(path)
            with self.assertRaises(ValueError):
                module.verify(path, expected_commit='another-commit')
            module.verify(path, expected_commit='test-commit')

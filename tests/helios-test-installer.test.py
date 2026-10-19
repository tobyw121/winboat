import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('installer', ROOT / 'scripts/helios/prepare-test-installer.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class TestHistoricalInstaller(unittest.TestCase):
    def setUp(self):
        payload = b'fixture-header-and-body'
        self.exe = b'MZ' + b'\0' * 126 + payload + struct.pack('<QQQ', 128, len(payload), 6) + hashlib.sha256(payload).digest() + b'HLIOSET2'
        self.source = b'{}'
        provenance = dict(repository='tobyw121/winboat', winboatCommit='a' * 40,
                          sourceSnapshot='b' * 40, sourceLockSha256=hashlib.sha256(self.source).hexdigest(), workflow='build.yml')
        self.receipt = dict(provenance, sha256=hashlib.sha256(self.exe).hexdigest(), revision='c' * 40)
        self.lock = dict(guestRevision='c' * 40, bundledInstaller=dict(sha256=self.receipt['sha256'], provenance=provenance))

    def test_tampered_bundle_and_provenance_are_rejected(self):
        installer.verify(self.exe, self.receipt, self.lock, self.source)
        for exe, receipt, source in [(self.exe + b'x', self.receipt, self.source),
                                     (self.exe, dict(self.receipt, repository='other'), self.source),
                                     (self.exe, self.receipt, b'changed')]:
            with self.assertRaises(ValueError): installer.verify(exe, receipt, self.lock, source)

    def test_export_is_separate_repeatable_and_never_overwrites_modified_files(self):
        files = {'helios/stack.lock.json': json.dumps(self.lock).encode(),
                 'resources/helios/helios-build.json': json.dumps(self.receipt).encode(),
                 'resources/helios/HeliosSetup.exe': self.exe, 'helios/source.lock.json': self.source}
        with tempfile.TemporaryDirectory() as directory, patch.object(installer, 'ROOT', Path(directory)), \
                patch.object(installer, 'historical_file', side_effect=lambda commit, name: files[name]):
            folder = installer.prepare('22.22.294.0')
            self.assertEqual(installer.prepare('22.22.294.0'), folder)
            self.assertFalse((Path(directory) / 'resources').exists())
            (folder / 'HeliosSetup.exe').write_bytes(b'changed')
            with self.assertRaises(ValueError): installer.prepare('22.22.294.0')
            self.assertEqual((folder / 'HeliosSetup.exe').read_bytes(), b'changed')


if __name__ == '__main__': unittest.main()

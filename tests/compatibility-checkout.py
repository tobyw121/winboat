"""Checksum-locked patches must survive Git's Windows checkout conversion."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CompatibilityCheckout(unittest.TestCase):
    def test_patch_bytes_survive_autocrlf_checkout(self):
        manifest = json.loads((ROOT / 'helios/compatibility/proton-ge.lock.json').read_text())
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'source'
            source.mkdir()
            shutil.copyfile(ROOT / '.gitattributes', source / '.gitattributes')
            for patch in manifest['patches']:
                relative = Path('helios/compatibility') / patch['file']
                destination = source / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / relative, destination)
            subprocess.run(['git', 'init', '-q', str(source)], check=True)
            subprocess.run(['git', '-C', str(source), '-c', 'core.autocrlf=false', 'add', '.'], check=True)
            for setting in ('true', 'input', 'false'):
                output = Path(temporary) / setting
                subprocess.run(['git', '-C', str(source), '-c', 'core.autocrlf=' + setting,
                                'checkout-index', '--all', '--prefix=' + output.as_posix() + '/'], check=True)
                for patch in manifest['patches']:
                    checked_out = output / 'helios/compatibility' / patch['file']
                    with self.subTest(autocrlf=setting, patch=patch['file']):
                        self.assertEqual(hashlib.sha256(checked_out.read_bytes()).hexdigest(), patch['sha256'])


if __name__ == '__main__':
    unittest.main()

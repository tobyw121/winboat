"""Real pinned AME/Atlas payloads inside a synthetic Windows WIM, not a Windows run.
Usage inside the Atlas utility image: python3 tests/atlas-original-assets.test.py WIZARD PLAYBOOK
"""
import hashlib
import importlib.util
from pathlib import Path
import shutil
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('media_tests', Path(__file__).with_name('atlas-iso.test.py'))
media_tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media_tests)


class OriginalAssetsTest(unittest.TestCase):
    def test_shim_and_service_targets_exist_with_original_payloads(self):
        fixture = media_tests.MediaTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        patch.stopall()  # Exercise the real hash-checked resource/ZIP extraction.
        for source, name in zip(ASSETS, ['AME-Beta-v0.8.4.exe', 'AtlasPlaybook.apbx']):
            shutil.copyfile(source, fixture.media / name)
        media_tests.inject.inject(fixture.tree, fixture.media)
        from ame_assets import OOBE_HASHES
        for path, identity in [
            ('/ProgramData/AME/OOBE/AME.Client.exe', 'AME.Client.exe'),
            ('/ProgramData/AME/OOBE/OOBE.exe', 'AME.Client.exe'),
            ('/Windows/System32/oobe/msoobe.exe', 'oobe_shim.exe'),
        ]:
            self.assertEqual(hashlib.sha256(fixture.read(fixture.wim, 2, path)).hexdigest(), OOBE_HASHES[identity])
        self.assertIn(b'<Version>0.5.0</Version>', fixture.read(fixture.wim, 2, '/ProgramData/AME/OOBE/Playbook/playbook.conf'))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    ASSETS = [Path(p).resolve(strict=True) for p in sys.argv[1:]]
    unittest.main(argv=[sys.argv[0]], verbosity=2)

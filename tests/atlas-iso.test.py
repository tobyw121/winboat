"""Real WIM/ESD and hive I/O; synthetic Windows executables, never a Windows ISO."""
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'resources/atlas-tools'))
import inject
from offline_registry import Hive
from ame_assets import OPTIONS

ANSWER = '''<unattend xmlns="urn:schemas-microsoft-com:unattend">
<settings pass="windowsPE"><component name="Microsoft-Windows-Setup">
<ImageInstall><OSImage><InstallFrom><MetaData><Key>/IMAGE/NAME</Key><Value>Windows 11 Home</Value></MetaData></InstallFrom>
<InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo></OSImage></ImageInstall>
</component></settings><settings pass="oobeSystem"><component name="Microsoft-Windows-Shell-Setup">
<UserAccounts/><AutoLogon/><OOBE><SkipMachineOOBE>true</SkipMachineOOBE><SkipUserOOBE>true</SkipUserOOBE><HideEULAPage>true</HideEULAPage></OOBE>
<FirstLogonCommands><SynchronousCommand><CommandLine>cmd /C C:\\OEM\\install.bat</CommandLine></SynchronousCommand>
<SynchronousCommand><CommandLine>keep-custom-command</CommandLine></SynchronousCommand></FirstLogonCommands>
</component></settings></unattend>'''


class MediaTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='winboat-custom-iso-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tree = self.root / 'custom-iso-copy'
        self.sources = self.tree / 'sources'
        self.media = self.root / 'media'
        self.source = self.root / 'windows'
        self.config = self.source / 'Windows/System32/config'
        for folder in [self.sources, self.media, self.config]:
            folder.mkdir(parents=True)
        for name in ['SYSTEM', 'SOFTWARE']:
            shutil.copyfile(REPO / 'tests/fixtures/hivex/minimal.hive', self.config / name)
        hive = Hive(self.config / 'SOFTWARE')
        hive.set('Microsoft\\Windows Defender\\Features', 'TamperProtection', 5)
        hive.commit()
        # Real Windows media uses lowercase "oobe"; Linux wimlib defaults differ.
        oobe = self.source / 'Windows/System32/oobe'
        oobe.mkdir()
        (oobe / 'msoobe.exe').write_bytes(b'MZ-original-Windows-OOBE-fixture')
        setup = self.source / 'Windows/Setup/Scripts'
        setup.mkdir(parents=True)
        (setup / 'SetupComplete.cmd').write_bytes(b'@echo preserve-custom-WIM-hook\r\n')
        self.wim = self.sources / 'install.wim'
        self.run_wim('capture', self.source, self.wim, 'Windows 11 Home')
        self.run_wim('append', self.source, self.wim, 'Windows 11 Pro')
        for index, edition in [(1, 'Core'), (2, 'Professional')]:
            self.run_wim('info', self.wim, index, f'--image-property=WINDOWS/EDITIONID={edition}',
                         '--image-property=WINDOWS/ARCH=9', '--image-property=WINDOWS/VERSION/BUILD=26200')
        self.boot_source = self.root / 'boot'
        (self.boot_source / 'Windows/System32/config').mkdir(parents=True)
        shutil.copyfile(self.config / 'SYSTEM', self.boot_source / 'Windows/System32/config/SYSTEM')
        self.boot = self.sources / 'boot.wim'
        self.run_wim('capture', self.boot_source, self.boot, 'WinPE')
        for name in ['autounattend.xml', 'autounattend.dat']:
            (self.boot_source / name).write_text(ANSWER)
        self.run_wim('append', self.boot_source, self.boot, 'Windows Setup')
        (self.tree / 'autounattend.xml').write_text(ANSWER)
        self.set_mode('iso')
        (self.media / 'oobe-credentials.json').write_text(json.dumps({'username': 'testuser', 'password': 'secret<&'}))
        (self.media / 'AtlasPlaybook.apbx').write_bytes(b'playbook archive fixture')
        copied_media = self.sources / '$OEM$' / '$1' / 'OEM' / 'atlas'
        copied_media.mkdir(parents=True)
        for name in ['AME-Beta-v0.8.4.exe', 'AtlasPlaybook.apbx', 'oobe-credentials.json']:
            (copied_media / name).write_bytes(b'disposable OEM copy fixture')
        # Only release PE/ZIP decoding is substituted; hive/WIM tools are real.
        def oobe_fixture(wizard, folder):
            for name in ['AME.Client.exe', 'oobe_shim.exe']:
                (folder / name).write_bytes(b'MZ-' + name.encode() + b'-fixture')
        def playbook_fixture(archive, folder):
            folder.mkdir()
            return ET.fromstring('<Playbook><Name>AtlasOS</Name><Username>Atlas</Username><Version>0.5.0</Version><UniqueId>00000000-0000-4000-6174-6c6173203a33</UniqueId></Playbook>')
        for name, substitute in [('extract_oobe', oobe_fixture), ('extract_playbook', playbook_fixture)]:
            context = patch.object(inject, name, substitute)
            context.start()
            self.addCleanup(context.stop)

    def run_wim(self, *args):
        return subprocess.run(['wimlib-imagex', *map(str, args)], check=True, capture_output=True).stdout

    def set_mode(self, mode):
        (self.media / 'atlas.json').write_text(json.dumps({'mode': mode, 'username': 'testuser',
            'release': '0.5.0-hotfix', 'waitForHelios': True, 'options': OPTIONS}))

    def read(self, wim, index, name):
        return self.run_wim('extract', wim, index, name, '--to-stdout')

    def hive_value(self, wim, index, hive_name, path, name):
        folder = self.root / f'read-{hive_name}'
        folder.mkdir(exist_ok=True)
        hive = inject.extract(wim, index, f'/Windows/System32/config/{hive_name}', folder)
        return Hive(hive).get(path, name)

    def assert_answer(self, data, ame):
        xml = ET.fromstring(data)
        ns = {'u': inject.NS}
        self.assertEqual(xml.findtext('.//u:InstallFrom/u:MetaData/u:Key', namespaces=ns), '/IMAGE/INDEX')
        self.assertEqual(xml.findtext('.//u:InstallFrom/u:MetaData/u:Value', namespaces=ns), '2')
        self.assertEqual(xml.findtext('.//u:InstallTo/u:PartitionID', namespaces=ns), '3')
        self.assertEqual(xml.findtext('.//u:OOBE/u:HideEULAPage', namespaces=ns), 'true')
        self.assertEqual(xml.find('.//u:UserAccounts', ns) is None, ame)
        self.assertEqual(xml.find('.//u:AutoLogon', ns) is None, ame)
        commands = [c.text for c in xml.findall('.//u:CommandLine', ns)]
        self.assertIn('keep-custom-command', commands)
        self.assertEqual(any('install.bat' in c for c in commands), not ame)

    def test_custom_multiedition_iso_oobe_and_offline_registry(self):
        original_home = self.read(self.wim, 1, '/Windows/System32/config/SOFTWARE')
        inject.inject(self.tree, self.media)
        self.assertEqual(original_home, self.read(self.wim, 1, '/Windows/System32/config/SOFTWARE'))
        self.assertEqual(self.read(self.wim, 2, '/Windows/System32/oobe/msoobeext.exe'), b'MZ-original-Windows-OOBE-fixture')
        self.assertEqual(self.read(self.wim, 2, '/Windows/System32/oobe/msoobe.exe'), b'MZ-oobe_shim.exe-fixture')
        for name in ['AME.Client.exe', 'OOBE.exe']:
            self.assertEqual(self.read(self.wim, 2, f'/ProgramData/AME/OOBE/{name}'), b'MZ-AME.Client.exe-fixture')
        self.assertEqual(self.read(self.wim, 2, '/Windows/Setup/Scripts/WinBoatOriginalSetupComplete.cmd'), b'@echo preserve-custom-WIM-hook\r\n')
        self.assertIn(b'WinBoatOriginalSetupComplete.cmd', self.read(self.wim, 2, '/Windows/Setup/Scripts/SetupComplete.cmd'))
        self.assertEqual(list((self.sources / '$OEM$' / '$1' / 'OEM' / 'atlas').iterdir()), [])
        self.assertTrue((self.media / 'oobe-credentials.json').exists())
        self.assertEqual(self.hive_value(self.wim, 2, 'SYSTEM', 'ControlSet001\\Services\\ameoobe', 'Start'), (4, struct.pack('<I', 2)))
        self.assertEqual(self.hive_value(self.wim, 2, 'SOFTWARE', 'Microsoft\\Windows Defender\\Features', 'TamperProtection'), (4, struct.pack('<I', 4)))
        backup = json.loads(self.read(self.wim, 2, '/ProgramData/WinBoat/Atlas/security-backup.json'))
        self.assertEqual(backup[-1]['originalBytes'], [5, 0, 0, 0])
        self.assertEqual(self.hive_value(self.boot, 2, 'SYSTEM', 'Setup\\LabConfig', 'BypassTPMCheck'), (4, struct.pack('<I', 1)))
        self.assert_answer(self.read(self.boot, 2, '/autounattend.xml'), True)
        self.assert_answer((self.tree / 'autounattend.xml').read_bytes(), True)
        config = ET.fromstring(self.read(self.wim, 2, '/ProgramData/AME/OOBE/oobe.conf'))
        self.assertEqual(config.findtext('Username'), 'testuser')
        self.assertEqual(config.findtext('Password'), 'secret<&')
        self.assertEqual([n.text for n in config.findall('Options/string')], OPTIONS)
        marker = json.loads((self.tree / 'winboat-atlas-iso.json').read_text())
        self.assertFalse(marker['playbookApplied'])
        self.assertEqual(marker['offlineDismPackages'], [])
        with self.assertRaisesRegex(ValueError, 'already been injected'):
            inject.inject(self.tree, self.media)

    def test_custom_live_iso_selects_pro_and_preserves_standard_oobe(self):
        self.set_mode('live')
        original = hashlib.sha256(self.wim.read_bytes()).digest()
        inject.inject(self.tree, self.media)
        self.assertEqual(hashlib.sha256(self.wim.read_bytes()).digest(), original)
        self.assert_answer(self.read(self.boot, 2, '/autounattend.dat'), False)
        self.assertFalse((self.tree / 'winboat-atlas-iso.json').exists())

    def test_windows_path_case_and_extracted_hive_names(self):
        for old, new in [('/Windows', '/windows'), ('/windows/System32', '/windows/system32'),
                         ('/windows/system32/config/SOFTWARE', '/windows/system32/config/software'),
                         ('/windows/system32/oobe/msoobe.exe', '/windows/system32/oobe/MSOOBE.EXE')]:
            self.run_wim('update', self.wim, 2, '--command', f'rename {old} {new}')
        inject.inject(self.tree, self.media)
        # Read actual stored paths without the injector's case-insensitive lookup.
        paths = self.run_wim('dir', self.wim, 2).decode().splitlines()
        paths = [p.casefold() for p in paths if p.startswith('/')]
        self.assertEqual(len(paths), len(set(paths)), 'Duplicate Windows directories/files differ only by case')
        self.assertIn('/windows/system32/oobe/msoobeext.exe', paths)
        self.assertEqual(self.hive_value(self.wim, 2, 'SOFTWARE', 'Microsoft\\Windows Defender\\Features', 'TamperProtection'), (4, struct.pack('<I', 4)))

    def test_missing_oobe_fails_before_changing_the_image_or_loading_ame(self):
        self.run_wim('update', self.wim, 2, '--command', 'delete /Windows/System32/oobe/msoobe.exe')
        original = self.wim.read_bytes()
        with patch.object(inject, 'extract_oobe', side_effect=AssertionError('Must validate Windows first')):
            with self.assertRaisesRegex(ValueError, 'index 2.*apply after installation'):
                inject.inject(self.tree, self.media)
        self.assertEqual(self.wim.read_bytes(), original)
        # The post-install option can still prepare this medium without replacing OOBE.
        self.set_mode('live')
        inject.inject(self.tree, self.media)

    def test_custom_esd_conversion_preserves_other_editions(self):
        self.run_wim('export', self.wim, 'all', self.sources / 'install.esd', '--compress=LZMS', '--solid')
        self.wim.unlink()
        inject.inject(self.tree, self.media)
        self.assertFalse((self.sources / 'install.esd').exists())
        self.assertEqual(len(inject.images(self.wim).findall('IMAGE')), 2)
        self.assert_answer(self.read(self.boot, 2, '/autounattend.xml'), True)

    def test_unsupported_custom_build_rejected_before_changes_in_both_modes(self):
        self.run_wim('info', self.wim, 2, '--image-property=WINDOWS/VERSION/BUILD=22000')
        original = self.wim.read_bytes()
        for mode in ['iso', 'live']:
            self.set_mode(mode)
            with self.assertRaisesRegex(ValueError, 'Windows 11 Pro'):
                inject.inject(self.tree, self.media)
            self.assertEqual(self.wim.read_bytes(), original)

    def test_custom_oem_hook_conflict_rejected(self):
        hook = self.sources / '$OEM$' / '$$' / 'Setup/Scripts/SetupComplete.cmd'
        hook.parent.mkdir(parents=True)
        hook.write_text('original custom hook')
        with self.assertRaisesRegex(ValueError, 'SetupComplete.cmd conflicts'):
            inject.inject(self.tree, self.media)
        self.assertEqual(hook.read_text(), 'original custom hook')


if __name__ == '__main__':
    unittest.main(verbosity=2)

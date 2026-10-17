"""Targeted handoff edits and offline selection; no Windows execution."""
from pathlib import Path
import struct
import sys
import types
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'resources/atlas-tools'))
try:
    import hivex
except ImportError:
    sys.modules['hivex'] = types.ModuleType('hivex')
import inject
import offline_registry as registry

class HandoffTests(unittest.TestCase):
    def test_only_complete_known_dockur_commands_are_removed(self):
        known = 'powershell.exe -ExecutionPolicy Unrestricted -NoLogo -NoProfile -NonInteractive set-localuser -name "Docker" -passwordneverexpires 1'
        self.assertTrue(inject.dockur_handoff_command(known, ['Docker']))
        self.assertFalse(inject.dockur_handoff_command(known, ['OtherUser']))
        self.assertTrue(inject.dockur_handoff_command(r'cmd /C if exist "C:\OEM\install.bat" start "Install" "cmd /C C:\OEM\install.bat"', []))
        for command in [r'echo C:\OEM\install.bat', r'cmd /C C:\OEM\install.bat & custom-action', known + '; custom-action']:
            self.assertFalse(inject.dockur_handoff_command(command, ['Docker']))

    def test_custom_commands_remain_and_live_mode_is_unchanged(self):
        ns = inject.NS
        xml = f'''<unattend xmlns="{ns}"><settings pass="windowsPE"><component name="Microsoft-Windows-Setup"><ImageInstall><OSImage/></ImageInstall></component></settings>
        <settings pass="oobeSystem"><component name="Microsoft-Windows-Shell-Setup"><UserAccounts><LocalAccounts><LocalAccount><Name>Docker</Name></LocalAccount></LocalAccounts></UserAccounts>
        <FirstLogonCommands><SynchronousCommand><CommandLine>powershell.exe -ExecutionPolicy Unrestricted -NoLogo -NoProfile -NonInteractive set-localuser -name "Docker" -passwordneverexpires 1</CommandLine></SynchronousCommand><SynchronousCommand><CommandLine>cmd /C C:\\OEM\\install.bat</CommandLine></SynchronousCommand><SynchronousCommand><CommandLine>custom-action</CommandLine></SynchronousCommand></FirstLogonCommands></component></settings></unattend>'''
        for ame in [False, True]:
            with tempfile.TemporaryDirectory() as temp:
                answer = Path(temp) / 'answer.xml'; answer.write_text(xml)
                inject.amend_answer(answer, '2', ame)
                commands = [n.text for n in ET.parse(answer).findall(f'.//{{{ns}}}CommandLine')]
                self.assertEqual(commands, ['custom-action'] if ame else ['powershell.exe -ExecutionPolicy Unrestricted -NoLogo -NoProfile -NonInteractive set-localuser -name "Docker" -passwordneverexpires 1', r'cmd /C C:\OEM\install.bat', 'custom-action'])

class FakeHive:
    def __init__(self, select=None, nodes=()):
        self.select = select or {}; self.nodes = nodes; self.writes = []
    def get(self, path, name): return self.select.get(name) if path == 'Select' else None
    def node(self, path): return 1 if path in self.nodes else None
    def set(self, *args): self.writes.append(args)
    def commit(self): pass

class ControlSetTests(unittest.TestCase):
    def test_boot_selected_sets_receive_service(self):
        system = FakeHive({'Default': (4, struct.pack('<I', 2)), 'Current': (4, struct.pack('<I', 1))}, {'ControlSet001','ControlSet002'})
        with patch.object(registry, 'Hive', side_effect=lambda obj: obj):
            registry.prepare_install(FakeHive(), system)
        for name in ['ControlSet001','ControlSet002']:
            self.assertIn((name + r'\Services\ameoobe', 'Start', 2), system.writes)
        self.assertEqual(registry.selected_control_sets(FakeHive(nodes={'ControlSet001'})), ['ControlSet001'])

    def test_missing_malformed_and_nonexistent_control_sets_are_rejected(self):
        for select, nodes in [({}, set()), ({'Default': (4, struct.pack('<I', 2))}, {'ControlSet001'}), ({'Current': (1,b'1')}, {'ControlSet001'}), ({'Default': (4,struct.pack('<I',0))}, {'ControlSet000'})]:
            with self.subTest(select=select):
                with self.assertRaises(ValueError): registry.selected_control_sets(FakeHive(select,nodes))

if __name__ == '__main__': unittest.main()

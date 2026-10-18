import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('rescue', ROOT / 'scripts/helios/rescue-graphics.py')
rescue = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rescue)


class HostRescue(unittest.TestCase):
    def test_changed_storage_cannot_boot_a_different_windows_disk(self):
        config = {'services': {'windows': {'volumes': [{'type': 'bind', 'source': '/disk', 'target': '/storage'}]}}}
        rescue.validate_running_storage(config, 'windows', [{'Type': 'bind', 'Source': '/disk', 'Destination': '/storage'}])
        with self.assertRaisesRegex(RuntimeError, 'differs'):
            rescue.validate_running_storage(config, 'windows', [{'Type': 'bind', 'Source': '/another-disk', 'Destination': '/storage'}])
        config['services']['windows']['volumes'][0].update(type='volume', source='windows')
        config['volumes'] = {'windows': {'name': 'project_windows'}}
        rescue.validate_running_storage(config, 'windows', [{'Type': 'volume', 'Name': 'project_windows', 'Destination': '/storage'}])

    def test_real_display_script_needs_no_gpu_or_bus_and_attaches_no_helios(self):
        command = ['bash', '-c', 'HELIOS=1; HELIOS_REVISION=test; HELIOS_RESCUE=1; '
                   'RENDERNODE=/missing; HELIOS_DISPLAY=dbus; VNC_PORT=5900; WSS_PORT=5700; '
                   'source "$1"; printf "%s\\n" "$DISPLAY" "$DISPLAY_OPTS"', 'rescue', str(ROOT / 'helios/host/display.sh')]
        result = subprocess.run(command, check=True, text=True, capture_output=True).stdout
        self.assertIn('-display none -vga std -vnc :0,websocket=5700', result)
        self.assertNotIn('virtio-gpu', result)
        self.assertNotIn('egl-headless', result)
        self.assertNotIn('-display dbus', result)

    def test_only_graphics_override_can_change(self):
        original = {'services': {'windows': {'image': 'winboat/helios:pin', 'environment': {'HELIOS': '1', 'PASSWORD': 'private'},
                    'volumes': [{'type': 'bind', 'source': '/existing/windows', 'target': '/storage'}],
                    'ports': ['127.0.0.1:8006:8006'], 'devices': ['/dev/kvm:/dev/kvm']}}}
        candidate = copy.deepcopy(original)
        candidate['services']['windows']['environment'].update(HELIOS_RESCUE='1', HELIOS_DISPLAY='novnc')
        candidate['services']['windows']['volumes'].append({'target': '/run/display.sh', 'source': '/private/display.sh', 'read_only': True})
        rescue.validate_rescue_config(original, candidate, 'windows')
        for key, value in [('image', 'different'), ('ports', []), ('devices', []), ('volumes', [])]:
            changed = copy.deepcopy(candidate)
            changed['services']['windows'][key] = value
            with self.assertRaisesRegex(RuntimeError, 'unrelated'):
                rescue.validate_rescue_config(original, changed, 'windows')
        missing = copy.deepcopy(original)
        missing['services']['windows']['volumes'] = []
        with self.assertRaisesRegex(RuntimeError, 'storage'):
            rescue.validate_rescue_config(missing, candidate, 'windows')


if __name__ == '__main__':
    unittest.main()

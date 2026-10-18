"""Test capture against real QEMU while its primary QMP client stays connected."""
import importlib.util
import json
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts/helios' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


monitor = load('capture_monitor', 'capture-display-monitor.py')
host = load('capture_host', 'capture-displays.py')


def port():
    with socket.socket() as free:
        free.bind(('127.0.0.1', 0))
        return free.getsockname()[1]


class CaptureTest(unittest.TestCase):
    def test_fragmented_telnet_negotiation(self):
        class Connection:
            def __init__(self):
                self.sent = []

            def sendall(self, data):
                self.sent.append(data)

        client = monitor.Monitor.__new__(monitor.Monitor)
        client.connection = Connection()
        client.telnet = True
        client.state = 'text'
        client.negotiation = None
        raw = b'hello\xff\xfb\x01\xff\xfd\x03\xff\xfa\x05hidden\xff\xf0(qemu) '
        result = b''.join(client.decode(bytes([value])) for value in raw)
        self.assertEqual(result, b'hello(qemu) ')
        self.assertEqual(client.connection.sent, [b'\xff\xfe\x01', b'\xff\xfc\x03'])
        with self.assertRaises(ValueError):
            monitor.capture('not-a-safe-filename')

    def test_real_capture_with_primary_qmp_occupied(self):
        executable = shutil.which('qemu-system-x86_64')
        self.assertIsNotNone(executable, 'Install qemu-system-x86 to run this integration test.')
        qmp_port, hmp_port = port(), port()
        while qmp_port == hmp_port:
            hmp_port = port()
        with tempfile.TemporaryDirectory(prefix='winboat-capture-test-') as temporary:
            root = Path(temporary)
            with (root / 'qemu.log').open('w+') as log:
                process = subprocess.Popen([executable, '-accel', 'tcg', '-machine', 'pc', '-m', '128M',
                    '-vga', 'none', '-device', 'VGA,id=helios-bootstrap',
                    '-device', 'virtio-gpu-pci,id=heliosgpu', '-display', 'none', '-no-reboot',
                    '-qmp', f'tcp:127.0.0.1:{qmp_port},server=on,wait=off',
                    '-monitor', f'telnet:127.0.0.1:{hmp_port},server=on,wait=off'], stdout=log, stderr=log)
                token = uuid.uuid4().hex
                try:
                    deadline = time.monotonic()+10
                    while True:
                        try:
                            primary = socket.create_connection(('127.0.0.1', qmp_port), timeout=1)
                            break
                        except OSError:
                            if time.monotonic() >= deadline or process.poll() is not None:
                                log.seek(0)
                                self.fail(log.read())
                            time.sleep(0.05)
                    with primary, primary.makefile('rb') as stream:
                        primary.settimeout(3)
                        self.assertIn('QMP', json.loads(stream.readline()))
                        primary.sendall(b'{"execute":"qmp_capabilities","id":"original"}\n')
                        self.assertEqual(json.loads(stream.readline())['id'], 'original')
                        address = f'telnet:127.0.0.1:{hmp_port},server=on,wait=off'
                        with patch.object(monitor, 'monitor_address', return_value=address):
                            captured = monitor.capture(token, 0)
                        for label in ['vga', 'helios', 'helios-after']:
                            self.assertIn('remote', captured[label], captured)
                            self.assertTrue(Path(captured[label]['remote']).read_bytes().startswith(b'\x89PNG\r\n\x1a\n'))
                        restored = monitor.Monitor(address)
                        try:
                            restored.prompt()
                            for event, state in captured['trace'].items():
                                if state['initial'] == 0:
                                    reply = restored.command('info trace-events '+event)
                                    self.assertRegex(reply, re.escape(event)+r'\s*:\s*state\s+0')
                        finally:
                            restored.connection.close()
                        ports = {'7149/tcp': [{'HostIp': '127.0.0.1', 'HostPort': str(qmp_port)}]}
                        with patch.object(host, 'docker', return_value=json.dumps(ports)):
                            failed = host.capture('fixture', root / 'occupied', 'qmp')
                        self.assertIn('occupied', failed['errors']['qmp'])
                        self.assertTrue((root / 'occupied/results.json').is_file())
                        primary.sendall(b'{"execute":"query-status","id":"still-original"}\n')
                        while True:
                            reply = json.loads(stream.readline())
                            if reply.get('id') == 'still-original':
                                self.assertTrue(reply['return']['running'])
                                break
                finally:
                    process.terminate()
                    process.wait(timeout=5)
                    for label in ['vga', 'helios', 'helios-after']:
                        Path('/tmp/winboat-display-'+token+'-'+label+'.png').unlink(missing_ok=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)

"""Exercise the host recorder against a real, disposable QEMU/TCG container."""
import importlib.util
import json
from pathlib import Path
import socket
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('recorder', ROOT / 'scripts/helios/diagnose-vm.py')
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)


class DiagnosticsTest(unittest.TestCase):
    def test_actual_qmp_event_and_volatile_log_capture(self):
        name = f'winboat-recorder-test-{uuid.uuid4().hex[:10]}'
        with socket.socket() as free:
            free.bind(('127.0.0.1', 0))
            port = free.getsockname()[1]
        with tempfile.TemporaryDirectory(prefix='winboat-recorder-') as temporary:
            output = Path(temporary) / 'capture'
            # No Windows, GPU, KVM or VM volumes. timeout ends only this fixture.
            command = ('set -e; mkdir -p /run/shm; echo synthetic-stderr >&2; echo volatile-fixture >/run/shm/qemu.out; '
                       'for attempt in 1 2 3; do timeout 3 nc -l -N 7149 </dev/null || true; done; '
                       'exec timeout -s TERM 12 qemu-system-x86_64 '
                       '-machine q35,accel=tcg -m 128M -nodefaults -display none -S '
                       '-qmp tcp:0.0.0.0:7149,server=on,wait=off -D /run/shm/qemu.log')
            recorder.docker('create', '--name', name, '--network', 'bridge',
                            '-p', f'127.0.0.1:{port}:7149', '--entrypoint', 'bash',
                            'winboat/helios:d82ce565ac79', '-c', command, timeout=30)
            try:
                state = recorder.capture(name, 40, output)
                self.assertEqual(state['state']['ExitCode'], 124, (output / 'docker.log').read_text())
                self.assertEqual((output / 'qemu.out').read_text(), 'volatile-fixture\n')
                self.assertIn('synthetic-stderr', (output / 'docker.log').read_text())
                messages = [json.loads(line) for line in (output / 'qmp.jsonl').read_text().splitlines()]
                self.assertTrue(any('before QMP was ready' in m.get('diagnostic', '') for m in messages), messages)
                self.assertTrue(any(m.get('event') == 'SHUTDOWN' and m['data']['reason'] == 'host-signal' for m in messages), messages)
                self.assertTrue(any(m.get('id') == 'initial-status' and m['return']['status'] == 'prelaunch' for m in messages), messages)
                self.assertNotIn('Config', json.loads((output / 'initial-state.json').read_text()))
            finally:
                recorder.docker('rm', '-f', name, timeout=30)


if __name__ == '__main__':
    unittest.main(verbosity=2)

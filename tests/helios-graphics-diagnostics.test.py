import contextlib
import importlib.util
import io
import json
import pathlib
import unittest
from types import SimpleNamespace
import urllib.error
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('graphics', ROOT / 'scripts/helios/diagnose-graphics.py')
graphics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(graphics)

class Opener:
    def __init__(self): self.urls = []
    def open(self, url, timeout):
        assert timeout == 20
        self.urls.append(url)
        if url.endswith('/version'): return contextlib.closing(io.BytesIO(b'{"version":"test"}'))
        if url.endswith('/graphics/diagnostics'):
            return contextlib.closing(io.BytesIO(json.dumps({'driver':{'application':{'rejectedFeatures':[{'feature':'timelineSemaphore'}]}}}).encode()))
        return contextlib.closing(io.BytesIO(b'x' * 131073))

class TestGraphicsCollector(unittest.TestCase):
    def test_old_host_runtime_is_reported_separately_from_guest_driver(self):
        inspect='"winboat/helios:test"\n"sha256:abc"\n"running"\n'
        with patch.object(graphics.subprocess, 'check_output', side_effect=[inspect, 'glvnd-v4\ndbus-v8\n']), \
             patch.object(graphics.subprocess, 'run', side_effect=[SimpleNamespace(stdout='',stderr=''), SimpleNamespace(stdout='{"backend":"dbus","issues":[]}')]):
            result=graphics.collect_host('WinBoat')
        self.assertEqual(result['runtimeVersion'], 'glvnd-v4')
        self.assertFalse(result['runtimeMatches'])
        self.assertEqual(result['qemuBackend']['backend'], 'dbus')

    def test_transport_contract_errors_are_numeric_and_bounded(self):
        log = ('password=secret command=private\n'
               'qemu: OPTIMAL DMA-BUF shape mismatch required=4587520 fd_size=4096000\n'
               'qemu: glEGLImageTargetTexture2DOES failed: 0x502\n'
               'qemu: EGL DMA-BUF import failed for fourcc=0x34325241 modifier=0x00ffffffffffffff\n'
               'vkr: invalid device-local memory accounting: release=2048 used=0\n')
        events = graphics.parse_transport_errors(log)
        self.assertEqual(events[0], {'kind': 'buffer-size-mismatch', 'requiredBytes': 4587520, 'bufferBytes': 4096000})
        self.assertEqual(len(events), 4)
        self.assertNotIn('secret', json.dumps(events))
        self.assertEqual(len(graphics.parse_transport_errors(log * 100)), 32)
        self.assertEqual(graphics.parse_transport_errors('no unique Vulkan device matches DRM render node 226:128'),
                         [{'kind':'device-selection-mismatch','drmMajor':226,'drmMinor':128}])

    def test_failed_api_keeps_its_structured_reason(self):
        class Failed:
            def open(self, url, timeout):
                raise urllib.error.HTTPError(url, 503, 'Unavailable', {}, io.BytesIO(b'{"message":"Missing installed manifest"}'))
        with patch.object(graphics.subprocess, 'check_output', return_value='127.0.0.1:41000\n'):
            result = graphics.collect('WinBoat', Failed())
        self.assertEqual(result['graphics/helios']['response']['message'], 'Missing installed manifest')
        self.assertEqual(result['graphics/helios']['httpStatus'], 503)

    def test_only_reads_local_api_and_retains_partial_failures(self):
        opener = Opener()
        with patch.object(graphics.subprocess, 'check_output', return_value='[::]:41000\n') as docker:
            result = graphics.collect('WinBoat', opener)
        docker.assert_called_once_with(['docker','port','WinBoat','7148/tcp'], text=True)
        self.assertEqual(result['version']['version'], 'test')
        self.assertEqual(result['graphics/diagnostics']['driver']['application']['rejectedFeatures'][0]['feature'], 'timelineSemaphore')
        self.assertIn('128 KiB', result['graphics/helios']['error'])
        self.assertTrue(all(url.startswith('http://127.0.0.1:41000/') for url in opener.urls))
    def test_no_published_api_does_not_start_or_stop_vm(self):
        with patch.object(graphics.subprocess, 'check_output', return_value=''):
            with self.assertRaisesRegex(RuntimeError, 'not published'): graphics.collect('WinBoat', Opener())

if __name__ == '__main__': unittest.main()

import contextlib
import importlib.util
import io
import json
import pathlib
import unittest
import tempfile
import shutil
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
        slow=any(url.endswith('/'+endpoint) for endpoint in ('graphics/diagnostics','graphics/diagnostics/journals','graphics/diagnostics/runtime'))
        assert timeout == (20 if slow else 3)
        self.urls.append(url)
        if url.endswith('/version'): return contextlib.closing(io.BytesIO(b'{"version":"test"}'))
        if url.endswith('/graphics/diagnostics'):
            return contextlib.closing(io.BytesIO(json.dumps({'driver':{'application':{'rejectedFeatures':[{'feature':'timelineSemaphore'}]}}}).encode()))
        return contextlib.closing(io.BytesIO(b'x' * 131073))

class TestGraphicsCollector(unittest.TestCase):
    def test_packaged_collector_finds_its_adjacent_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=pathlib.Path(temporary)/'resources'
            tools=root/'graphics-tools';tools.mkdir(parents=True)
            for name in ('diagnose-graphics.py','inspect-qemu-backend.py','graphics-correlation.py'):
                shutil.copyfile(ROOT/'scripts/helios'/name,tools/name)
            (root/'helios').mkdir()
            (root/'helios/helios-build.json').write_text('{"sha256":"packaged-pin"}')
            packaged_spec=importlib.util.spec_from_file_location('packaged_graphics',tools/'diagnose-graphics.py')
            packaged=importlib.util.module_from_spec(packaged_spec);packaged_spec.loader.exec_module(packaged)
            with patch.object(packaged.subprocess,'check_output',side_effect=['"image"\n"sha256:abc"\n"running"\n','glvnd-v12\ndbus-v9\n','{"ready":true,"devices":[]}']), \
                 patch.object(packaged.subprocess,'run',side_effect=[SimpleNamespace(stdout='',stderr=''),SimpleNamespace(stdout='{}')]):
                result=packaged.collect_host('WinBoat')
            self.assertEqual(result['bundledInstaller']['sha256'],'packaged-pin')
            self.assertEqual(result['runtimeVersion'],'glvnd-v12')
            self.assertNotIn('runtimeError',result)
    def test_wire_trace_retains_only_fixed_tokens(self):
        row=graphics.parse_frame_metrics('frame-wire peer='+('a'*32)+' serial=9 stage=receive method=UpdateDMABUF monotonic_us=100')[0]
        self.assertEqual(row['serial'],9);self.assertEqual(row['peer'],'a'*32)
        self.assertEqual(graphics.parse_frame_metrics('frame-wire peer=PRIVATE serial=9 stage=receive method=UpdateDMABUF'),[])

    def test_frame_metrics_are_fixed_fields_and_do_not_invent_fps(self):
        text='dbus: frame-ack source=4 sequence=8 wait_us=123 success=1 in_flight=1 transport=copy\n'
        text+='helios_vulkan_capture ino 99 seq 8 publish 1 1280x800 submit_ns 100 wait_ns 200 cpu_ns 300\n'
        text+='PRIVATE-PATH SECRET\n'
        result=graphics.parse_frame_metrics(text)
        self.assertEqual(len(result),2)
        self.assertEqual(result[0]['waitMicroseconds'],123)
        self.assertEqual(result[1]['cpuNanoseconds'],300)
        self.assertEqual(graphics.parse_transport_errors('import-held source=4 ino=99 attempts=2 delay_ns=500000000')[0]['kind'],'import-backoff')
        self.assertNotIn('PRIVATE',json.dumps(result))
        self.assertEqual(graphics.parse_frame_metrics('frame-ack source=4 sequence=1 wait_us=-1 success=1 in_flight=1 transport=copy'),[])
    def test_export_import_contracts_keep_only_numeric_fields(self):
        lines=('dmabuf-contract export ino=99 allocated=16777216 blob=16777216 fd_bytes=16777216 memory_type=2 fd_type=1\n'
               'dmabuf-contract import source=1 ino=99 bytes=16777216 required=4587520 alignment=4096 width=1280 height=800 stride=5120 format=44 tiling=0 modifier=72057594037927935 usage=23 flags=8 image_bits=3 fd_bits=3')
        rows=graphics.parse_frame_metrics(lines)
        self.assertEqual([r['kind'] for r in rows],['dmabuf-export','dmabuf-import'])
        self.assertEqual(rows[1]['requiredBytes'],4587520)
        self.assertEqual(rows[0]['allocationBytes'],16777216)

    def test_resource_identity_budget_and_live_heap(self):
        self.assertEqual(graphics.parse_transport_errors('vram-budget refused: release=0 requested=4096 used=6000 cap=7000')[0]['limitBytes'],7000)
        log=('resource-create id=5 source=2 ino=8 imported=40 snapshot=50 staging=60 owned_total=110 peak=120\n'
             'resource-frame id=5 source=2 ino=8 sequence=9 published=1\n'
             'resource-release id=5 source=2 ino=8 imported=40 owned=110 remaining=0 peak=120\n'
             'frame-region source=2 x=1 y=2 width=3 height=4 bytes=48 partial=1\n'
             'frame-ack source=2 sequence=9 wait_us=7 success=1 in_flight=1 transport=dmabuf inode=8')
        rows=graphics.parse_frame_metrics(log)
        self.assertEqual(len(rows),5)
        self.assertEqual(rows[0]['ownedBytes'],110)
        self.assertEqual(rows[-1]['inode'],8)
        self.assertEqual(graphics.parse_transport_errors('budget-rejected requested=90 owned=110 limit=160')[0]['limitBytes'],160)
        with patch.object(graphics.subprocess,'check_output',return_value='{"ready":true,"devices":[]}') as run:
            self.assertTrue(graphics.collect_gpu_heap('WinBoat','/dev/dri/renderD128')['observation']['ready'])
            run.assert_called_once()
        with patch.object(graphics.subprocess,'check_output') as run:
            self.assertIn('error',graphics.collect_gpu_heap('WinBoat','/private/path'))
            run.assert_not_called()

    def test_old_host_runtime_is_reported_separately_from_guest_driver(self):
        inspect='"winboat/helios:test"\n"sha256:abc"\n"running"\n'
        with patch.object(graphics.subprocess, 'check_output', side_effect=[inspect, 'glvnd-v4\ndbus-v8\n',OSError('old runtime')]), \
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
    def test_sample_capture_uses_cached_status_and_collects_slow_reports_once(self):
        class Capture:
            def __init__(self): self.urls = []
            def open(self, url, timeout):
                self.urls.append(url)
                return contextlib.closing(io.BytesIO(b'{"sampleAgeMs":42}'))
        opener = Capture()
        sleeps = []
        with patch.object(graphics.subprocess, 'check_output', return_value='127.0.0.1:41000\n'):
            result = graphics.collect('WinBoat', opener, samples=3, interval=2, sleeper=sleeps.append)
        self.assertEqual(sleeps, [2, 2])
        self.assertEqual(len(result['capture']['observations']), 3)
        self.assertEqual(sum(url.endswith('/graphics/adapters') for url in opener.urls), 3)
        for endpoint in ('graphics/history', 'graphics/diagnostics/journals', 'graphics/diagnostics/runtime'):
            self.assertEqual(sum(url.endswith('/' + endpoint) for url in opener.urls), 1)
        with self.assertRaises(ValueError): graphics.collect('WinBoat', samples=13)
        with self.assertRaises(ValueError): graphics.collect('WinBoat', interval=0)

    def test_no_published_api_does_not_start_or_stop_vm(self):
        with patch.object(graphics.subprocess, 'check_output', return_value=''):
            with self.assertRaisesRegex(RuntimeError, 'not published'): graphics.collect('WinBoat', Opener())

if __name__ == '__main__': unittest.main()

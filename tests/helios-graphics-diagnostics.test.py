import contextlib
import importlib.util
import io
import json
import pathlib
import unittest
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

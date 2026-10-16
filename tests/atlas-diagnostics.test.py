#!/usr/bin/env python3
"""Check guest-update payload preservation and rejection of incomplete updates."""
import importlib.util
import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('atlas_diagnostics', ROOT / 'scripts/atlas/diagnose-vm.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class UpdatePayloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.oem = self.root / 'oem'
        for name in ['nssm.exe', 'scripts/update.ps1', 'helios/HeliosSetup.exe',
                     'atlas/oobe-credentials.json', 'atlas/AtlasPlaybook.apbx',
                     'atlas/AME-Beta-v0.8.4.exe', '.winboat-hardware/private.json',
                     'winboat_guest_server.exe']:
            path = self.oem / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'original-payload')
        (self.oem / 'atlas/atlas.json').write_text(json.dumps({'mode': 'iso', 'waitForHelios': True}))
        self.executable = self.root / 'new.exe'
        self.executable.write_bytes(b'new-service')
        self.archive = self.root / 'update.zip'

    def build(self):
        helper.create_update(self.oem, self.executable, self.archive)

    def test_preserve_runtime_without_install_credentials(self):
        self.build()
        with zipfile.ZipFile(self.archive) as archive:
            names = set(archive.namelist())
            self.assertEqual(archive.read('helios/HeliosSetup.exe'), b'original-payload')
            self.assertEqual(archive.read('nssm.exe'), b'original-payload')
            self.assertEqual(archive.read('winboat_guest_server.exe'), b'new-service')
            self.assertIn('atlas/atlas.json', names)
            self.assertEqual(archive.read('scripts/Get-AtlasDiagnostics.ps1'),
                             (ROOT / 'guest_server/scripts/Get-AtlasDiagnostics.ps1').read_bytes())
            for name in ['atlas/oobe-credentials.json', 'atlas/AtlasPlaybook.apbx',
                         'atlas/AME-Beta-v0.8.4.exe', '.winboat-hardware/private.json']:
                self.assertNotIn(name, names)
        self.assertEqual(self.archive.stat().st_mode & 0o777, 0o600)

    def test_missing_pending_helios_installer_rejected(self):
        (self.oem / 'helios/HeliosSetup.exe').unlink()
        with self.assertRaisesRegex(RuntimeError, 'Helios bundle is missing'):
            self.build()

    def test_missing_service_manager_rejected(self):
        (self.oem / 'nssm.exe').unlink()
        with self.assertRaisesRegex(RuntimeError, 'OEM runtime is missing'):
            self.build()

    def test_symlink_rejected(self):
        (self.oem / 'linked-secret').symlink_to(self.executable)
        with self.assertRaisesRegex(RuntimeError, 'Symlink'):
            self.build()

    def test_unexpected_provisioning_mode_rejected(self):
        (self.oem / 'atlas/atlas.json').write_text(json.dumps({'mode': 'cli'}))
        with self.assertRaisesRegex(RuntimeError, 'ISO/OOBE mode'):
            self.build()

    def test_guest_redirect_rejected_before_upload_replay(self):
        request = urllib.request.Request('http://127.0.0.1:7148/update', data=b'payload')
        with self.assertRaisesRegex(RuntimeError, 'redirected'):
            helper.NoRedirect().redirect_request(request, None, 307, '', {}, 'https://example.com/')

    def test_read_only_collection_from_guest_api(self):
        requests = []
        class GuestAPI(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                data = {'/version': {'version': 'test'}, '/provisioning/atlas': {'status': 'waiting'},
                        '/provisioning/atlas/diagnostics': {'service': [{'State': 'Stopped'}], 'startup': ['WNF Wait']}}
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(data[self.path]).encode())
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), GuestAPI)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f'http://127.0.0.1:{server.server_port}'
            with patch.object(helper, 'endpoint_and_oem', return_value=(base, self.oem)), \
                 patch.object(helper.Path, 'home', return_value=self.root), \
                 patch('sys.argv', ['diagnose-vm.py']), contextlib.redirect_stdout(io.StringIO()):
                helper.main()
            output, = (self.root / '.winboat/diagnostics').glob('atlas-*.json')
            result = json.loads(output.read_text())
            self.assertEqual(result['startup'], ['WNF Wait'])
            self.assertEqual(result['atlasStatus']['status'], 'waiting')
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(requests, ['/version', '/provisioning/atlas/diagnostics', '/provisioning/atlas'])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Collect Atlas diagnostics; --update-guest installs the fixed guest-service collector first."""
import argparse
import datetime as dt
import json
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[2]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise RuntimeError('The local guest API unexpectedly redirected; update cancelled.')


def docker(*args):
    return subprocess.check_output(['docker', *args], text=True)


def endpoint_and_oem(container):
    template = '{{json .HostConfig.PortBindings}}\n{{json .Mounts}}'
    ports, mounts = map(json.loads, docker('inspect', '--format', template, container).splitlines())
    port = int(ports['7148/tcp'][0]['HostPort'])
    if not 1 <= port <= 65535:
        raise RuntimeError('Invalid published guest port.')
    oem = next(Path(m['Source']) for m in mounts if m['Destination'] == '/oem' and m['Type'] == 'bind')
    return f'http://127.0.0.1:{port}', oem


def create_update(oem, executable, archive):
    # The legacy updater replaces Program Files/WinBoat. Preserve its OEM runtime
    # payloads too, especially the Helios installer needed after Atlas finishes.
    if not (oem / 'nssm.exe').is_file() or not (oem / 'scripts/update.ps1').is_file():
        raise RuntimeError('The original OEM runtime is missing; refusing a partial guest update.')
    conf = json.loads((oem / 'atlas/atlas.json').read_text())
    if conf['mode'] != 'iso':
        raise RuntimeError('This update helper is for the selected AME ISO/OOBE mode.')
    if conf['waitForHelios'] and not (oem / 'helios/HeliosSetup.exe').is_file():
        raise RuntimeError('The original Helios bundle is missing; guest was not updated.')
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
        for source in oem.rglob('*'):
            relative = source.relative_to(oem)
            if source.is_symlink():
                raise RuntimeError('Symlink in OEM runtime; guest was not updated.')
            if not source.is_file() or any(p.startswith('.') for p in relative.parts):
                continue
            if source.suffix in {'.go', '.sum', '.mod'} or relative.name in {
                'winboat_guest_server.exe', 'winboat_guest_server.zip', 'oobe-credentials.json',
                'AME-Beta-v0.8.4.exe', 'AtlasPlaybook.apbx',
            }:
                continue
            # Replace the script directory completely from the matching source.
            if relative.parts[0] != 'scripts':
                output.write(source, relative.as_posix())
        for source in (ROOT / 'guest_server/scripts').rglob('*'):
            if source.is_file():
                output.write(source, 'scripts/' + source.relative_to(ROOT / 'guest_server/scripts').as_posix())
        output.write(executable, 'winboat_guest_server.exe')
    archive.chmod(0o600)


def wait_for_guest_update(get, commit, collector_hash, timeout=120):
    """An accepted upload is not completion: the old service remains up briefly."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            version = get('/version')
            if version.get('commit_hash') == commit:
                diagnostics = get('/provisioning/atlas/diagnostics')
                if diagnostics.get('diagnosticsVersion') == 2 and diagnostics.get('collectorHash') == collector_hash:
                    return version, diagnostics
        except (OSError, ValueError):
            pass  # Expected while the updater stops and replaces the guest service.
        if time.monotonic() >= deadline:
            raise RuntimeError('Guest upload was accepted, but the expected service/collector did not become active within '
                               f'{timeout} seconds. Update completion is unconfirmed; the VM was not stopped.')
        time.sleep(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', default='WinBoat')
    parser.add_argument('--update-guest', action='store_true')
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument('--recover-oobe', action='store_true',
                        help='Repair verified setup-account access and REBOOT Windows into OOBE using Sysprep; no password reset')
    actions.add_argument('--launch-ame-ui', action='store_true',
                        help='Start the pinned AME client as the existing signed-in defaultuser0 console user; no Windows reboot')
    args = parser.parse_args()
    base, oem = endpoint_and_oem(args.container)
    # This opener only talks to the local published guest port, never a proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    def get(path):
        with opener.open(base + path, timeout=25) as response:
            return json.load(response)
    print('Windows guest:', json.dumps(get('/version')), flush=True)
    diagnostics = None
    if args.update_guest:
        print('Building the guest-service collector. Windows/AME will keep running.', flush=True)
        with tempfile.TemporaryDirectory(prefix='winboat-atlas-diagnostics-') as temporary:
            temporary = Path(temporary)
            commit = subprocess.check_output(['git', 'rev-parse', '--short=12', 'HEAD'], cwd=ROOT, text=True).strip()
            command = ['docker', 'buildx', 'build', '--progress', 'plain', '-f', 'scripts/atlas/Dockerfile',
                       '--build-arg', f'WINBOAT_BUILD_COMMIT={commit}', '--output', f'type=local,dest={temporary}/out']
            ca = os.environ.get('HELIOS_PROXY_CA')
            if not ca and os.environ.get('CODEX_PROXY_CERT'):
                ca = '/etc/ssl/certs/ca-certificates.crt'
            if ca:
                command += ['--secret', f'id=proxy_ca,src={ca}']
            subprocess.run([*command, '.'], cwd=ROOT, check=True)
            archive = temporary / 'update.zip'
            create_update(oem, temporary / 'out/winboat_guest_server.exe', archive)
            with zipfile.ZipFile(archive) as payload:
                collector_hash = hashlib.sha256(payload.read('scripts/Get-AtlasDiagnostics.ps1')).hexdigest()
            boundary = 'winboat-' + uuid.uuid4().hex
            body = (f'--{boundary}\r\nContent-Disposition: form-data; name="updateFile"; filename="update.zip"\r\n'
                    'Content-Type: application/zip\r\n\r\n').encode() + archive.read_bytes() + f'\r\n--{boundary}--\r\n'.encode()
            request = urllib.request.Request(base + '/update', data=body,
                headers={'Content-Type': f'multipart/form-data; boundary={boundary}'})
            with opener.open(request, timeout=60) as response:
                if json.load(response).get('status') != 'updating':
                    raise RuntimeError('The guest rejected its service update.')
            print('Guest service update accepted; waiting for diagnostics (VM stays running)...', flush=True)
            version, diagnostics = wait_for_guest_update(get, commit, collector_hash)
            print('Verified updated guest and matching collector:', version['commit_hash'], flush=True)
    try:
        if diagnostics is None:
            diagnostics = get('/provisioning/atlas/diagnostics')
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise RuntimeError('Run again with --update-guest to install the fixed diagnostic collector.') from error
        raise
    diagnostics['atlasStatus'] = get('/provisioning/atlas')
    try:
        diagnostics['recoveryStatus'] = get('/provisioning/atlas/recovery')
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    folder = Path.home() / '.winboat/diagnostics'
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    output = folder / (dt.datetime.now().strftime('atlas-%Y%m%d-%H%M%S-%f') + '.json')
    with output.open('x', encoding='utf-8') as stream:
        output.chmod(0o600)
        json.dump(diagnostics, stream, indent=2)
    print(json.dumps(diagnostics, indent=2))
    print(f'Recording: {output}')
    if args.recover_oobe or args.launch_ame_ui:
        route, operation = ('recovery', 'restart-oobe') if args.recover_oobe else ('launch-ui', 'launch-ame-ui')
        message = 'Windows will REBOOT' if args.recover_oobe else 'Only the AME service and its UI will start; Windows stays running'
        print(f'Requesting guarded AME action. {message}; passwords are not reset.', flush=True)
        request = urllib.request.Request(base + '/provisioning/atlas/' + route, data=b'',
            headers={'X-WinBoat-Recovery': operation}, method='POST')
        try:
            with opener.open(request, timeout=100) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                raise RuntimeError('Install the recovery service with --update-guest first.') from error
            result = json.load(error)
            print(json.dumps(result, indent=2), flush=True)
            raise RuntimeError(result.get('message', result.get('error', 'Recovery was refused.'))) from error
        print(json.dumps(result, indent=2))
        print('Watch the Windows console. Run this helper again without an action flag to inspect diagnostics.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, StopIteration, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Atlas diagnostics failed: {error}')

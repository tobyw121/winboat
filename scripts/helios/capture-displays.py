#!/usr/bin/env python3
"""Capture QEMU outputs directly, independently of the GTK Local Desktop viewer."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.request
import uuid
import zipfile


def docker(*args):
    return subprocess.run(['docker', *args], check=True, capture_output=True,
                          text=True, timeout=15).stdout


def guest_snapshot(container, target):
    snapshot = {}
    try:
        ports = json.loads(docker('inspect', '--format', '{{json .NetworkSettings.Ports}}', container)) or {}
        bindings = ports.get('7148/tcp') or []
        if not bindings:
            raise RuntimeError('Guest API port is not published.')
        binding = bindings[0]
        address = binding.get('HostIp') or '127.0.0.1'
        if address not in ('127.0.0.1', '0.0.0.0', '::', '::1'):
            raise RuntimeError('Guest API capture requires a loopback endpoint.')
        address = '[::1]' if address in ('::', '::1') else '127.0.0.1'
        base = 'http://'+address+':'+str(int(binding['HostPort']))
        for endpoint in ['version', 'graphics/adapters', 'graphics/diagnostics', 'graphics/helios']:
            try:
                with urllib.request.urlopen(base+'/'+endpoint, timeout=4) as response:
                    data = response.read(65537)
                    if len(data) > 65536:
                        raise ValueError('Guest diagnostic response exceeded the limit.')
                    snapshot[endpoint] = json.loads(data)
            except (OSError, ValueError) as error:
                snapshot[endpoint] = {'error': type(error).__name__}
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        snapshot['error'] = str(error)
    target.write_text(json.dumps(snapshot, indent=2))
    target.chmod(0o600)


def capture_qmp(container, output):
    # Inspect only port bindings; the full environment contains credentials.
    ports = json.loads(docker('inspect', '--format', '{{json .NetworkSettings.Ports}}', container)) or {}
    bindings = ports.get('7149/tcp') or []
    if not bindings or not bindings[0].get('HostPort'):
        raise RuntimeError('The QMP port (7149/tcp) is not published.')
    endpoint = bindings[0]
    host = endpoint.get('HostIp') or '127.0.0.1'
    host = {'0.0.0.0': '127.0.0.1', '::': '::1'}.get(host, host)
    if host not in ('127.0.0.1', '::1'):
        raise RuntimeError('Capture requires a QMP port reachable over loopback.')
    results = {}
    with socket.create_connection((host, int(endpoint['HostPort'])), timeout=5) as connection:
        connection.settimeout(5)
        stream = connection.makefile('rb')

        def receive():
            line = stream.readline(1048577)
            if not line or len(line) > 1048576:
                raise RuntimeError('QMP connection closed or response exceeded the limit.')
            return json.loads(line)

        try:
            greeting = receive()
        except socket.timeout as error:
            raise RuntimeError('QMP is occupied by another client (such as WinBoat). Use the HMP capture transport.') from error
        if 'QMP' not in greeting:
            raise RuntimeError('The published port did not return a QMP greeting.')

        def command(name, arguments=None):
            identity = uuid.uuid4().hex
            connection.sendall((json.dumps({'execute': name, 'arguments': arguments or {}, 'id': identity})+'\n').encode())
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                response = receive()
                if response.get('id') == identity:
                    return response
            raise RuntimeError('QMP command timed out.')

        response = command('qmp_capabilities')
        if 'error' in response:
            raise RuntimeError('QMP capability negotiation failed.')
        for label, device in [('vga', 'helios-bootstrap'), ('helios', 'heliosgpu')]:
            remote = '/tmp/winboat-display-'+uuid.uuid4().hex+'.png'
            try:
                response = command('screendump', {'filename': remote, 'device': device, 'head': 0, 'format': 'png'})
                if 'error' in response:
                    results[label] = response['error']
                    continue
                target = output / (label+'.png')
                docker('cp', container+':'+remote, str(target))
                target.chmod(0o600)
                results[label] = {'file': target.name}
            finally:
                docker('exec', container, 'rm', '-f', '--', remote)
    return results


def capture_hmp(container, output, trace_seconds=10):
    token = uuid.uuid4().hex
    helper = Path(__file__).with_name('capture-display-monitor.py').read_text()
    results = {}
    started = dt.datetime.now(dt.timezone.utc).isoformat()
    try:
        process = subprocess.run(['docker', 'exec', '-i', container, 'python3', '-', token, str(trace_seconds)],
                                 input=helper, text=True, capture_output=True, timeout=75)
        response = json.loads(process.stdout)
        if process.returncode or 'error' in response:
            raise RuntimeError(response.get('error', 'Container HMP capture failed.'))
        results['trace'] = response['trace']
        for label in ['vga', 'helios', 'helios-after']:
            item = response[label]
            if 'remote' not in item:
                results[label] = item
                continue
            expected = '/tmp/winboat-display-'+token+'-'+label+'.png'
            if item['remote'] != expected:
                raise RuntimeError('Unexpected capture filename.')
            target = output / (label+'.png')
            docker('cp', container+':'+expected, str(target))
            target.chmod(0o600)
            results[label] = {'file': target.name}
        logs = subprocess.run(['docker', 'logs', '--since', started, '--tail', '2000', container],
                              text=True, capture_output=True, check=True, timeout=15)
        trace = output / 'qemu-trace.log'
        trace.write_text(logs.stdout+logs.stderr)
        trace.chmod(0o600)
        # Dockur may redirect QEMU's debug/trace sink to /run/shm rather
        # than Docker stderr. Preserve bounded tails instead of treating an
        # empty docker log as proof that the GPU produced no updates.
        for name in ['qemu.log', 'qemu.out']:
            try:
                content = docker('exec', container, 'tail', '-c', '262144', '/run/shm/'+name)
                saved = output / name
                saved.write_text(content)
                saved.chmod(0o600)
            except (OSError, subprocess.SubprocessError):
                pass
    finally:
        for label in ['vga', 'helios', 'helios-after']:
            docker('exec', container, 'rm', '-f', '--', '/tmp/winboat-display-'+token+'-'+label+'.png')
    return results


def capture(container, output, transport='auto', trace_seconds=10):
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    try:
        image = docker('inspect', '--format', '{{.Image}}', container).strip()
        labels = json.loads(docker('image', 'inspect', '--format', '{{json .Config.Labels}}', image)) or {}
        identity = {'imageId': image, 'labels': {key:value for key,value in labels.items() if key.startswith('org.winboat.')}}
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        identity = {'error': type(error).__name__}
    (output / 'host.json').write_text(json.dumps(identity, indent=2))
    (output / 'host.json').chmod(0o600)
    guest_snapshot(container, output / 'guest-before.json')
    results = {}
    # Dockur's HMP monitor is independent of WinBoat's persistent QMP client.
    # Existing VMs need no restart, new port mapping or graphics change.
    methods = [('hmp', capture_hmp), ('qmp', capture_qmp)] if transport == 'auto' else [
        (transport, capture_hmp if transport == 'hmp' else capture_qmp)]
    errors = {}
    for name, method in methods:
        try:
            captured = method(container, output, trace_seconds) if name == 'hmp' else method(container, output)
            results = {'transport': name, **captured}
            break
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            errors[name] = str(error)
    else:
        results = {'errors': errors}
    results['surfaceNote'] = 'QEMU screendump reads its software surface. With D-Bus/GL this may be stale; a black PNG alone does not prove a black GPU scanout. Interpret it with qemu-trace.log.'
    guest_snapshot(container, output / 'guest-after.json')
    (output / 'results.json').write_text(json.dumps(results, indent=2))
    (output / 'results.json').chmod(0o600)
    return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', default='WinBoat')
    parser.add_argument('--transport', choices=['auto', 'hmp', 'qmp'], default='auto')
    parser.add_argument('--trace-seconds', type=int, choices=range(0, 31), default=10, metavar='0..30')
    parser.add_argument('--output', type=Path, default=Path('winboat-display-'+time.strftime('%Y%m%d-%H%M%S')))
    args = parser.parse_args()
    print('Capturing displays and a short QEMU trace; leave the VM and Local Desktop running.', flush=True)
    result = capture(args.container, args.output, args.transport, args.trace_seconds)
    print(json.dumps(result, indent=2))
    print('Captures saved in:', args.output)
    archive = Path(str(args.output)+'.zip')
    with os.fdopen(os.open(archive, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
        with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED) as package:
            for file in sorted(args.output.iterdir()):
                if file.is_file():
                    package.write(file, file.name)
    print('Diagnostic archive:', archive)
    if 'errors' in result:
        raise SystemExit(1)

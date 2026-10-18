#!/usr/bin/env python3
"""Capture QEMU outputs directly, independently of the GTK Local Desktop viewer."""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import time
import uuid


def docker(*args):
    return subprocess.run(['docker', *args], check=True, capture_output=True,
                          text=True, timeout=15).stdout


def capture(container, output):
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
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    results = {}
    with socket.create_connection((host, int(endpoint['HostPort'])), timeout=5) as connection:
        connection.settimeout(5)
        stream = connection.makefile('rb')

        def receive():
            line = stream.readline(1048577)
            if not line or len(line) > 1048576:
                raise RuntimeError('QMP connection closed or response exceeded the limit.')
            return json.loads(line)

        if 'QMP' not in receive():
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
    (output / 'results.json').write_text(json.dumps(results, indent=2))
    (output / 'results.json').chmod(0o600)
    return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', default='WinBoat')
    parser.add_argument('--output', type=Path, default=Path('winboat-display-'+time.strftime('%Y%m%d-%H%M%S')))
    args = parser.parse_args()
    print(json.dumps(capture(args.container, args.output), indent=2))
    print('Captures saved in:', args.output)

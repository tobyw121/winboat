#!/usr/bin/env python3
"""Capture volatile dockur logs and read-only QMP events on the local Linux host."""
import argparse
import datetime as dt
import json
from pathlib import Path
import socket
import subprocess
import threading
import time


def docker(*args, timeout=10, include_stderr=False):
    result = subprocess.run(['docker', *args], check=True, capture_output=True,
                            text=True, encoding='utf-8', errors='replace', timeout=timeout)
    return result.stdout + (result.stderr if include_stderr else '')


def inspect(container):
    # Never export Config.Env: it contains the Windows account password.
    template = '{{json .State}}\n{{json .HostConfig.PortBindings}}\n{{json .RestartCount}}'
    state, ports, restarts = map(json.loads, docker('inspect', '--format', template, container).splitlines())
    return {'state': state, 'ports': ports or {}, 'restarts': restarts}


def save(path, content):
    path.write_text(content, encoding='utf-8')
    path.chmod(0o600)


def qmp_endpoint(ports):
    mappings = ports.get('7149/tcp') or []
    if not mappings or not mappings[0].get('HostPort'):
        return None
    mapping = mappings[0]
    host = mapping.get('HostIp') or '127.0.0.1'
    host = {'0.0.0.0': '127.0.0.1', '::': '::1'}.get(host, host)
    return host, int(mapping['HostPort'])


def capture_qmp(endpoint, output, stop, deadline):
    with output.open('w', encoding='utf-8') as log:
        output.chmod(0o600)
        def record(value):
            log.write(json.dumps({'receivedAtUtc': dt.datetime.now(dt.timezone.utc).isoformat(),
                                  **value}) + '\n')
            log.flush()
        while not stop.is_set() and time.monotonic() < deadline:
            try:
                connection = socket.create_connection(endpoint, timeout=1)
                break
            except OSError:
                stop.wait(0.25)
        else:
            record({'diagnostic': 'QMP did not become reachable'})
            return
        with connection:
            connection.settimeout(0.5)
            buffer = b''
            negotiated = False
            while not stop.is_set() and time.monotonic() < deadline:
                try:
                    data = connection.recv(65536)
                    if not data:
                        record({'diagnostic': 'QMP connection closed'})
                        return
                    buffer += data
                    while b'\n' in buffer:
                        line, buffer = buffer.split(b'\n', 1)
                        if not line.strip():
                            continue
                        message = json.loads(line)
                        record(message)
                        if 'QMP' in message:
                            connection.sendall(b'{"execute":"qmp_capabilities","id":"capabilities"}\n')
                        elif message.get('id') == 'capabilities' and not negotiated:
                            negotiated = True
                            connection.sendall(b'{"execute":"query-status","id":"initial-status"}\n')
                except socket.timeout:
                    continue
                except (OSError, ValueError) as error:
                    record({'diagnostic': str(error)})
                    return


def capture(container, duration, output):
    initial = inspect(container)
    if initial['state']['Status'] not in ['running', 'exited', 'created']:
        raise RuntimeError('Container must be running, stopped or newly created.')
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    print(f'Recordings: {output}', flush=True)
    started = dt.datetime.now(dt.timezone.utc).isoformat()
    save(output / 'initial-state.json', json.dumps(initial, indent=2))
    stop = threading.Event()
    deadline = time.monotonic() + duration
    endpoint = qmp_endpoint(initial['ports'])
    observer = None
    if endpoint:
        observer = threading.Thread(target=capture_qmp,
            args=(endpoint, output / 'qmp.jsonl', stop, deadline), daemon=True)
        observer.start()
    else:
        print('No published QMP port (7149/tcp); capturing Docker and serial logs only.', flush=True)
    try:
        if initial['state']['Status'] != 'running':
            print(f'Starting {container} and recording for up to {duration} seconds...', flush=True)
            docker('start', container, timeout=30)
        else:
            print(f'Recording the running {container} for up to {duration} seconds...', flush=True)
        state = initial
        progress = time.monotonic()
        while time.monotonic() < deadline:
            state = inspect(container)
            save(output / 'final-state.json', json.dumps(state, indent=2))
            if state['state']['Status'] != 'running':
                break
            for name in ['qemu.log', 'qemu.out', 'qemu.pty']:
                try:
                    text = docker('exec', container, 'tail', '-c', '262144', f'/run/shm/{name}', timeout=3)
                    # Retain the last nonempty snapshot if the container restarts.
                    if text:
                        save(output / name, text)
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                    pass  # Files may not exist yet, or QEMU/container just exited.
            if time.monotonic() - progress >= 10:
                print(f'Container status: {state["state"]["Status"]}; recording...', flush=True)
                progress = time.monotonic()
            stop.wait(0.5)
    finally:
        stop.set()
        if observer:
            observer.join(timeout=3)
        save(output / 'docker.log', docker('logs', '--timestamps', '--since', started, container, include_stderr=True))
    final = inspect(container)
    save(output / 'final-state.json', json.dumps(final, indent=2))
    print(f'Recordings: {output}', flush=True)
    print(f'Status={final["state"]["Status"]} Exit={final["state"]["ExitCode"]} '
          f'OOM={final["state"]["OOMKilled"]} Restarts={final["restarts"]}')
    qmp = output / 'qmp.jsonl'
    if qmp.exists():
        for line in qmp.read_text().splitlines():
            message = json.loads(line)
            if 'event' in message or 'diagnostic' in message:
                print(json.dumps(message))
    for name in ['qemu.log', 'qemu.out', 'qemu.pty', 'docker.log']:
        path = output / name
        if path.exists() and path.stat().st_size:
            print(f'\n{name} (last 4096 characters):\n{path.read_text()[-4096:]}')
    return final


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', default='WinBoat')
    parser.add_argument('--seconds', type=int, default=120)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if not 5 <= args.seconds <= 600:
        parser.error('--seconds must be between 5 and 600')
    destination = args.output or (Path.home() / '.winboat/diagnostics' /
        dt.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    try:
        capture(args.container, args.seconds, destination)
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Diagnostic capture failed: {error}\n')
    except KeyboardInterrupt:
        parser.exit(130, f'Capture interrupted. Recordings: {destination}\n')

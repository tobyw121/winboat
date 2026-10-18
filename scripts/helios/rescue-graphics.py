#!/usr/bin/env python3
"""Explicit graphics rescue: fixed guest operation or a reversible VGA-only host boot."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]


def docker_json(*args):
    return json.loads(subprocess.check_output(['docker', *args], text=True))


def guest_action(container, action):
    ports = subprocess.check_output(['docker', 'port', container, '7148/tcp'], text=True).splitlines()
    port = int(ports[0].rsplit(':', 1)[1])
    if not 1 <= port <= 65535:
        raise RuntimeError('Invalid guest API port')
    request = urllib.request.Request(f'http://127.0.0.1:{port}/graphics/rescue', data=b'', method='POST',
        headers={'X-WinBoat-Recovery': action})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise RuntimeError('Guest rescue API unavailable. Update the guest service or use --rescue-boot.') from error
        raise RuntimeError(error.read(8192).decode('utf-8', 'replace')) from error


def compose_context(container, recovery_root):
    info = docker_json('inspect', container)[0]
    labels = info['Config'].get('Labels') or {}
    project = labels.get('com.docker.compose.project', '')
    service = labels.get('com.docker.compose.service', '')
    if not re.fullmatch(r'[a-z0-9][a-z0-9_-]*', project) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', service):
        raise RuntimeError('Expected an existing Docker Compose VM')
    files = [Path(p) for p in labels.get('com.docker.compose.project.config_files', '').split(',') if p]
    owned = [p for p in files if p.name == 'compose-vga.json' and p.resolve().is_relative_to(recovery_root.resolve())]
    base = [p for p in files if p not in owned]
    if not base or any(not p.is_absolute() or not p.is_file() for p in base):
        raise RuntimeError('Original Compose files are missing; no VM changes made')
    command = ['docker', 'compose', '--project-name', project]
    for path in base:
        command += ['-f', str(path)]
    return command, service, owned, info.get('Mounts', [])


def validate_running_storage(config, service, mounts):
    configured = [v for v in config['services'][service].get('volumes', []) if v.get('target') == '/storage']
    attached = [v for v in mounts if v.get('Destination') == '/storage']
    if len(configured) != 1 or len(attached) != 1:
        raise RuntimeError('Cannot identify the existing Windows storage')
    volume, mounted = configured[0], attached[0]
    source = volume.get('source')
    if volume.get('type') == 'bind':
        matches = mounted.get('Type') == 'bind' and source == mounted.get('Source')
    else:
        name = config.get('volumes', {}).get(source, {}).get('name')
        matches = mounted.get('Type') == 'volume' and name and name == mounted.get('Name')
    if not matches:
        raise RuntimeError('Compose storage differs from the existing VM; no restart performed')


def validate_rescue_config(original, candidate, service):
    before = original['services'][service]
    after = candidate['services'][service]
    if before.get('environment', {}).get('HELIOS') != '1':
        raise RuntimeError('This is not a configured Helios VM')
    if not any(v.get('target') == '/storage' for v in before.get('volumes', [])):
        raise RuntimeError('No persistent Windows storage mount; refusing rescue boot')
    allowed = {'/run/display.sh', '/usr/bin/qemu-system-x86_64', '/usr/local/bin/qemu-system-x86_64'}
    def unchanged(value):
        value = json.loads(json.dumps(value))
        value['volumes'] = [v for v in value.get('volumes', []) if v.get('target') not in allowed]
        for key in ('HELIOS_RESCUE', 'HELIOS_DISPLAY'):
            value.get('environment', {}).pop(key, None)
        return value
    if unchanged(before) != unchanged(after):
        raise RuntimeError('Rescue override changed unrelated VM configuration')


def host_action(container, restore):
    recovery_root = Path.home() / '.winboat/recovery'
    command, service, owned, mounts = compose_context(container, recovery_root)
    original = json.loads(subprocess.check_output([*command, 'config', '--format', 'json'], text=True))
    validate_running_storage(original, service, mounts)
    if restore:
        if not owned:
            raise RuntimeError('This container is not using a managed rescue override')
    else:
        recovery_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        folder = Path(tempfile.mkdtemp(prefix='vga-', dir=recovery_root))
        mounts = []
        for source, targets in [('display.sh', ['/run/display.sh']),
                                ('qemu.sh', ['/usr/bin/qemu-system-x86_64', '/usr/local/bin/qemu-system-x86_64'])]:
            destination = folder / source
            shutil.copyfile(ROOT / 'helios/host' / source, destination)
            destination.chmod(0o755)
            mounts += [{'type': 'bind', 'source': str(destination), 'target': target, 'read_only': True} for target in targets]
        override = folder / 'compose-vga.json'
        override.write_text(json.dumps({'services': {service: {'environment': {
            'HELIOS_RESCUE': '1', 'HELIOS_DISPLAY': 'novnc'}, 'volumes': mounts}}}, indent=2) + '\n')
        override.chmod(0o600)
        candidate_command = [*command, '-f', str(override)]
        candidate = json.loads(subprocess.check_output([*candidate_command, 'config', '--format', 'json'], text=True))
        validate_rescue_config(original, candidate, service)
        command = candidate_command
    print('Restarting this VM with ' + ('its original graphics configuration.' if restore else 'VGA only; Windows storage is preserved.'), flush=True)
    subprocess.run([*command, 'up', '-d', '--no-deps', '--pull', 'never', '--force-recreate', '--timeout', '120', service], check=True)
    print('Use Browser Display. Keep WinBoat closed during rescue; --restore-host returns to the original configuration.' if not restore else
          'Original host configuration restored. A guest-disabled Helios device remains disabled until explicitly re-enabled.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', default='WinBoat')
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--disable-helios', action='store_true')
    action.add_argument('--enable-helios', action='store_true')
    action.add_argument('--rescue-boot', action='store_true', help='Restart the existing VM with VGA only, without a guest API')
    action.add_argument('--restore-host', action='store_true', help='Restart using the original Compose files')
    args = parser.parse_args()
    try:
        if args.rescue_boot or args.restore_host:
            host_action(args.container, args.restore_host)
        else:
            print(json.dumps(guest_action(args.container, 'helios-disable' if args.disable_helios else 'helios-enable'), indent=2))
    except (OSError, ValueError, KeyError, IndexError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()

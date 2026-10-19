#!/usr/bin/env python3
"""Opt-in real QEMU rescue test; no Windows disk, GPU, KVM or network is used."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(image):
    name = 'winboat-rescue-test-' + uuid.uuid4().hex
    script = ('set -e; export HELIOS_RESCUE=1 HELIOS_GPU_VENDOR=nvidia; RENDERNODE=/missing; '
              'VNC_PORT=5900; WSS_PORT=5700; source /run/display.sh; '
              'exec /usr/local/bin/qemu-system-x86_64 -machine q35,accel=tcg -m 128M '
              '-nodefaults -S -monitor none -serial none -qmp stdio $DISPLAY_OPTS')
    requests = [{'execute': 'qmp_capabilities', 'id': 'cap'}, {'execute': 'query-pci', 'id': 'pci'},
                {'execute': 'quit', 'id': 'quit'}]
    # The bind mounts use executable copies exactly like the production helper.
    with tempfile.TemporaryDirectory(prefix='helios-rescue-qemu-') as temporary:
        folder = Path(temporary)
        mounts = []
        for source, target in [('display.sh', '/run/display.sh'), ('qemu.sh', '/usr/local/bin/qemu-system-x86_64'),
                               ('performance.py','/opt/helios/performance.py')]:
            destination = folder / source
            shutil.copyfile(ROOT / 'helios/host' / source, destination)
            destination.chmod(0o755)
            mounts += ['--mount', f'type=bind,src={destination},dst={target},readonly']
        try:
            result = subprocess.run(['docker', 'run', '--rm', '-i', '--pull', 'never', '--name', name,
                '--network', 'none', '--entrypoint', 'bash', *mounts, image, '-c', script],
                input=''.join(json.dumps(request) + '\n' for request in requests),
                text=True, capture_output=True, timeout=30, check=True)
            records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
            pci = next(item['return'] for item in records if item.get('id') == 'pci')
            def devices(buses):
                for bus in buses:
                    for device in bus.get('devices', []):
                        yield device.get('id', {})
                        if 'pci_bridge' in device:
                            yield from devices([device['pci_bridge']])
            ids = list(devices(pci))
            assert any(item.get('vendor') == 0x1234 and item.get('device') == 0x1111 for item in ids), 'VGA absent'
            assert not any(item.get('vendor') == 0x1af4 and item.get('device') == 0x1050 for item in ids), 'Helios present'
            print('Live QEMU rescue passed: standard VGA, no Helios PCI, no GPU/KVM, VNC and QMP initialized.')
        finally:
            subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True, help='Existing locally built Helios image; never pulled')
    run(parser.parse_args().image)

"""Boot real OVMF with bootstrap VGA + a secondary virtio GPU, without Windows/GL."""
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

with tempfile.TemporaryDirectory(prefix='helios-bootstrap-') as directory:
    root = Path(directory)
    shutil.copy('/usr/share/OVMF/OVMF_VARS_4M.fd', root / 'vars.fd')
    with (root / 'qemu.log').open('w+') as log:
        process = subprocess.Popen(['qemu-system-x86_64', '-machine', 'q35,accel=tcg,graphics=off',
            '-m', '256M', '-nodefaults', '-display', 'none', '-vga', 'none',
            '-device', 'VGA,id=helios-bootstrap', '-device', 'virtio-gpu-pci,id=heliosgpu',
            '-drive', 'file=/usr/share/OVMF/OVMF_CODE_4M.fd,if=pflash,format=raw,readonly=on',
            '-drive', f'file={root}/vars.fd,if=pflash,format=raw',
            '-qmp', f'unix:{root}/qmp,server=on,wait=off'], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 15
            with socket.socket(socket.AF_UNIX) as connection:
                while True:
                    try:
                        connection.connect(str(root / 'qmp'))
                        break
                    except (FileNotFoundError, ConnectionRefusedError):
                        if process.poll() is not None or time.monotonic() >= deadline:
                            log.seek(0)
                            raise RuntimeError(log.read())
                        time.sleep(0.1)
                connection.settimeout(3)
                stream = connection.makefile('rwb')
                assert 'QMP' in json.loads(stream.readline())
                def command(name, **arguments):
                    stream.write(json.dumps({'execute': name, 'arguments': arguments, 'id': name}).encode() + b'\n')
                    stream.flush()
                    while True:
                        reply = json.loads(stream.readline())
                        if reply.get('id') == name:
                            assert 'error' not in reply, reply
                            return reply.get('return')
                command('qmp_capabilities')
                pci = json.dumps(command('query-pci'))
                assert 'helios-bootstrap' in pci and 'heliosgpu' in pci, pci
                time.sleep(8)  # Let OVMF initialize the first adapter's GOP.
                assert command('query-status')['running']
                command('screendump', filename=sys.argv[1])
                frame = Path(sys.argv[1]).read_bytes()
                magic, size, maximum, pixels = frame.split(b'\n', 3)
                assert magic == b'P6' and maximum == b'255'
                assert pixels != pixels[:3] * (len(pixels) // 3), 'Uniform UEFI frame'
                command('quit')
            assert process.wait(timeout=5) == 0
            print(f'OVMF console 0 captured with VGA + secondary virtio GPU: {size.decode()}.')
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)

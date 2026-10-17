"""Real QEMU GL listener regression using Mesa software rendering, no Windows/KVM.

Run inside the Helios host image with python3. D-Bus p2p isolates the GL listener
compatibility check from session-bus authentication and physical GPU support.
"""
import json
import os
import subprocess

environment = dict(os.environ, EGL_PLATFORM='surfaceless', LIBGL_ALWAYS_SOFTWARE='1')
base = ['qemu-system-x86_64', '-machine', 'q35,accel=tcg', '-m', '128M',
        '-nodefaults', '-device', 'VGA,id=helios-bootstrap',
        '-device', 'virtio-gpu-gl-pci,id=heliosgpu', '-S', '-qmp', 'stdio']
commands = '\n'.join(json.dumps({'execute': name, 'id': name}) for name in
                     ['qmp_capabilities', 'query-status', 'quit']) + '\n'


def run(display, vnc):
    return subprocess.run(base + ['-display', display] + vnc, input=commands,
                          text=True, capture_output=True, env=environment, timeout=20)


broken = run('dbus,p2p=on,gl=on', ['-vnc', ':0,websocket=5700'])
assert broken.returncode != 0 and 'Display vnc is incompatible with the GL context' in broken.stderr, broken.stderr
for display, vnc in [('dbus,p2p=on,gl=on', []), ('egl-headless', ['-vnc', ':0,websocket=5700'])]:
    result = run(display, vnc)
    assert result.returncode == 0, result.stderr
    replies = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    assert not any('error' in reply for reply in replies), replies
    assert any(reply.get('id') == 'query-status' and 'return' in reply for reply in replies), replies
    print(f'QEMU GL startup and QMP succeeded: {display}, VNC={bool(vnc)}')
print('Reproduced the old GL/VNC failure; both separate display modes start successfully.')

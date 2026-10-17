#!/usr/bin/env python3
"""Exercise the real launcher policy with a completed-installation marker.

Run in the disposable fixture container with /dev/null mapped to its render node.
No QEMU, guest disk, GL rendering or host files outside the fixture are used.
"""
import os
from pathlib import Path
import socket
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1]
revision = 'd82ce565ac792eb48da5e59f2a82a12ff221851d'
Path('/run/helios-display').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory() as temporary, socket.socket(socket.AF_UNIX) as bus:
    bus.bind('/run/helios-display/bus')
    try:
        marker = Path(temporary) / '.winboat-helios-ready'
        for ready in [False, True]:
            if ready:
                marker.write_text(revision + '\n')
            for mode in ['novnc', 'dbus']:
                for override in ['auto', '0', '1']:
                    env = {**os.environ, 'HELIOS': '1', 'HELIOS_REVISION': revision,
                           'HELIOS_DISPLAY': mode, 'HELIOS_BOOTSTRAP_DISPLAY': override,
                           'STORAGE': temporary, 'RENDERNODE': '/dev/dri/renderD128',
                           'VNC_PORT': '5900', 'WSS_PORT': '5700'}
                    output = subprocess.check_output(['bash', '-c', 'source "$1"; echo "$DISPLAY_OPTS"',
                                                      'test', str(source / 'helios/host/display.sh')], env=env, text=True)
                    expected = override == '1' or (override == 'auto' and (mode == 'dbus' or not ready))
                    assert ('-device VGA,id=helios-bootstrap' in output) == expected, (ready, mode, override, output)
        print('Actual launcher keeps VGA for Local Desktop after installation and preserves browser/explicit-override policy (12 cases).')
    finally:
        Path('/run/helios-display/bus').unlink()

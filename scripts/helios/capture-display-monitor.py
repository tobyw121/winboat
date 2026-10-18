#!/usr/bin/env python3
"""Run inside the container: capture outputs over QEMU's separate HMP monitor."""
import json
import os
from pathlib import Path
import re
import socket
import sys
import time


def monitor_address():
    monitors = []
    for command in Path('/proc').glob('[0-9]*/cmdline'):
        try:
            executable = Path(os.readlink(command.parent / 'exe')).name
            if not executable.startswith('qemu-system-'):
                continue
            args = command.read_bytes()[:262144].decode('utf-8').split('\0')
            if '-monitor' in args:
                monitors.append(args[args.index('-monitor')+1])
        except (OSError, ValueError, UnicodeError, IndexError):
            continue
    if len(monitors) != 1:
        raise RuntimeError('No unique QEMU HMP monitor found; the VM must be running.')
    return monitors[0]


class Monitor:
    def __init__(self, address):
        self.telnet = address.startswith('telnet:')
        address = address.split(',', 1)[0]
        if address.startswith('unix:'):
            self.connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.connection.settimeout(5)
            self.connection.connect(address[5:])
        elif address.startswith(('telnet:', 'tcp:')):
            host, port = address.split(':', 1)[1].rsplit(':', 1)
            host = host.strip('[]')
            if host not in ('localhost', '127.0.0.1', '::1'):
                raise RuntimeError('Only a container-local HMP monitor is supported.')
            self.connection = socket.create_connection((host, int(port)), timeout=5)
        else:
            raise RuntimeError('HMP monitor is not a local socket.')
        self.connection.settimeout(5)
        self.state = 'text'
        self.negotiation = None

    def decode(self, data):
        # Python 3.13 removed telnetlib. Handle QEMU's Telnet negotiation,
        # including control sequences split across recv calls, without enabling
        # remote options or forwarding anything as a monitor command.
        if not self.telnet:
            return data
        result = bytearray()
        for value in data:
            if self.state == 'text':
                if value == 255:
                    self.state = 'iac'
                else:
                    result.append(value)
            elif self.state == 'iac':
                if value == 255:
                    result.append(value)
                    self.state = 'text'
                elif value in (251, 252, 253, 254):
                    self.negotiation = value
                    self.state = 'option'
                elif value == 250:
                    self.state = 'sub'
                else:
                    self.state = 'text'
            elif self.state == 'option':
                if self.negotiation == 251:
                    self.connection.sendall(bytes((255, 254, value)))
                elif self.negotiation == 253:
                    self.connection.sendall(bytes((255, 252, value)))
                self.state = 'text'
            elif self.state == 'sub':
                if value == 255:
                    self.state = 'sub-iac'
            elif self.state == 'sub-iac':
                self.state = 'text' if value == 240 else 'sub'
        return bytes(result)

    def prompt(self):
        output = b''
        deadline = time.monotonic()+10
        while time.monotonic() < deadline:
            data = self.connection.recv(65536)
            if not data:
                raise RuntimeError('HMP monitor closed the connection.')
            output += self.decode(data)
            if len(output) > 1048576:
                raise RuntimeError('HMP monitor response exceeded the limit.')
            if b'(qemu)' in output:
                return re.sub(rb'\x1b\[[0-9;]*[A-Za-z]', b'', output).decode('utf-8', errors='replace')
        raise RuntimeError('HMP monitor did not return its prompt.')

    def command(self, command):
        # A CR is sufficient. CR+LF can submit an extra empty command and leave
        # a second prompt that would be mistaken for the next command's reply.
        self.connection.sendall((command+'\r').encode('ascii'))
        return self.prompt()


def capture(token, trace_seconds=10):
    if not re.fullmatch('[a-f0-9]{32}', token):
        raise ValueError('Invalid capture identity.')
    monitor = Monitor(monitor_address())
    results = {}
    enabled = []
    try:
        monitor.prompt()
        trace = {}
        for event in ['helios_scanout_blob_layout', 'virtio_gpu_cmd_set_scanout',
                      'virtio_gpu_cmd_set_scanout_blob', 'virtio_gpu_cmd_res_flush',
                      'dbus_scanout_texture', 'dbus_update_gl']:
            state = monitor.command('info trace-events '+event)
            matched = re.search(re.escape(event)+r'\s*:\s*state\s+([01])', state)
            trace[event] = {'initial': 'unavailable' if matched is None else int(matched[1]),
                            'enabledDuringCapture': matched is not None}
            if matched is not None and matched[1] == '0':
                monitor.command('trace-event '+event+' on')
                enabled.append(event)
        results['trace'] = trace
        for label, device in [('vga', 'helios-bootstrap'), ('helios', 'heliosgpu'), ('helios-after', 'heliosgpu')]:
            if label == 'helios-after':
                time.sleep(trace_seconds)
            remote = '/tmp/winboat-display-'+token+'-'+label+'.png'
            response = monitor.command('screendump '+remote+' -f png '+device+' 0')
            path = Path(remote)
            if path.is_file() and path.stat().st_size > 8:
                results[label] = {'remote': remote}
            else:
                results[label] = {'error': response[-1024:].strip()}
    finally:
        try:
            for event in enabled:
                monitor.command('trace-event '+event+' off')
        finally:
            monitor.connection.close()
    return results


if __name__ == '__main__':
    try:
        seconds = int(sys.argv[2]) if len(sys.argv) > 2 else 10
        if not 0 <= seconds <= 30:
            raise ValueError('Trace duration must be between 0 and 30 seconds.')
        print(json.dumps(capture(sys.argv[1], seconds)))
    except (OSError, RuntimeError, ValueError) as error:
        print(json.dumps({'error': str(error)}))
        sys.exit(1)

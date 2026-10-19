#!/usr/bin/env python3
"""Read-only in-container inspection; output fixed GPU configuration fields only."""
import glob
import json
import os
import re


def options(args, name):
    return [args[i + 1] for i, item in enumerate(args[:-1]) if item == name]


def properties(value):
    return dict(part.split('=', 1) for part in value.split(',')[1:] if '=' in part)


def inspect(args):
    displays = options(args, '-display')
    devices = options(args, '-device')
    gpus = [item for item in devices if item.split(',')[0] in ('virtio-gpu-gl-pci', 'virtio-vga-gl')]
    vnc = bool(options(args, '-vnc'))
    models = [item.split(',')[0] for item in displays]
    backend = models[0] if len(models) == 1 and models[0] in ('dbus', 'egl-headless', 'none') else 'unknown'
    display = properties(displays[0]) if len(displays) == 1 else {}
    gpu = properties(gpus[0]) if len(gpus) == 1 else {}
    objects = options(args, '-object')
    memory = [properties(item) for item in objects if item.startswith('memory-backend-memfd,')]
    shared = [item.get('id') for item in memory if item.get('share') == 'on']
    wired = any(properties('machine,' + item).get('memory-backend') in shared
                for item in options(args, '-machine'))
    rescue = backend == 'none' and not gpus and any(item.startswith('std') for item in options(args, '-vga'))
    issues = []
    if len(displays) != 1:
        issues.append('display-count-invalid')
    if backend == 'dbus' and vnc:
        issues.append('dbus-gl-and-vnc-incompatible')
    if backend == 'dbus' and display.get('gl') != 'on':
        issues.append('dbus-gl-not-enabled')
    if not rescue:
        if len(gpus) != 1:
            issues.append('accelerated-gpu-count-invalid')
        if gpu.get('venus') != 'on' or gpu.get('blob') != 'on':
            issues.append('venus-or-blob-not-enabled')
        if not wired:
            issues.append('shared-memfd-not-wired')
        if backend not in ('dbus', 'egl-headless'):
            issues.append('unsupported-accelerated-display')
    render_node = display.get('rendernode', '')
    if not re.fullmatch(r'/dev/dri/renderD[0-9]+', render_node):
        render_node = None
        if not rescue:
            issues.append('render-node-not-explicit')
    return {'backend': backend, 'vnc': vnc, 'gpuCount': len(gpus), 'venus': gpu.get('venus') == 'on',
            'blob': gpu.get('blob') == 'on', 'sharedMemfd': wired, 'vgaRescue': rescue,
            'renderNode': render_node, 'issues': issues,
            'scope': 'Launch configuration only; no Vulkan import or visible-frame validation'}


def collect():
    candidates = []
    for path in glob.glob('/proc/[0-9]*/cmdline'):
        try:
            with open(path, 'rb') as file:
                raw = file.read(131073)
            if len(raw) > 131072:
                continue
            args = raw.rstrip(b'\0').decode('utf-8', errors='replace').split('\0')
            if os.path.basename(args[0]) == 'qemu-system-x86_64':
                candidates.append(inspect(args))
        except (OSError, ValueError):
            continue
    return candidates[0] if len(candidates) == 1 else {'error': 'Expected exactly one QEMU process'}


if __name__ == '__main__':
    print(json.dumps(collect()))

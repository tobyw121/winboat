#!/usr/bin/env python3
"""Apply host patches to pinned QEMU and exercise their callbacks with real EGL.

Optional argument: an offline source directory containing the five files below.
Otherwise download only those files from the pinned dependency, checking hashes.
This tests real GL texture upload and callback routing, not a Windows/GPU boot.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shlex
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
HASHES = {
    'console-gl.c': 'f5c12fbc74aacf7e919b55b0a807d104235291cefab42b55bd76f1b3827bfb05',
    'dbus-console.c': 'f5528db4780d5eaf6de94a990af103f42b98528df2230d1bd89760923c501e1a',
    'dbus-display1.xml': 'b611ea1e075e8380611437ba0ca65ee77b970c435530e349fe9b5ef1998ee335',
    'dbus-listener.c': '0fc4a92892f136da84a1f021477808e58a40e621a35ebfa52b79e54bfbf20c02',
    'dbus.c': 'ff311713b5851a24ce1a5985ee19ed893c3895db4a491e24a6599d63f2fb5e68',
}


def function(source, name):
    match = re.search(r'(?:static\s+)?(?:void|bool)\s+' + name + r'\([^;]*?\)\s*\{', source)
    assert match, name
    end, depth = match.end(), 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end] + '\n'


revision = next(item['revision'] for item in json.loads((ROOT / 'helios/source.lock.json').read_text())['submodules'] if item['path'] == 'qemu-helios')
with tempfile.TemporaryDirectory(prefix='winboat-qemu-dbus-') as temporary:
    source = Path(temporary)
    (source / 'ui').mkdir()
    for name, expected in HASHES.items():
        data = (Path(sys.argv[1]) / 'ui' / name).read_bytes() if len(sys.argv) > 1 else urllib.request.urlopen(
            f'https://raw.githubusercontent.com/winboat-org/qemu-helios/{revision}/ui/{name}', timeout=30).read()
        assert hashlib.sha256(data).hexdigest() == expected, f'Pinned QEMU source mismatch: {name}'
        (source / 'ui' / name).write_bytes(data)
    original_display = (source / 'ui/dbus.c').read_text()
    subprocess.run(['git', 'init', '-q', '--template=', str(source)], check=True)
    subprocess.run(['git', '-C', str(source), 'add', 'ui'], check=True)
    for line in (ROOT / 'helios/host/patches/SHA256SUMS').read_text().splitlines():
        expected, name = line.split()
        patch = ROOT / 'helios/host/patches' / name
        assert hashlib.sha256(patch.read_bytes()).hexdigest() == expected, name
        subprocess.run(['git', '-C', str(source), 'apply', '--check', '--index', str(patch)], check=True)
        subprocess.run(['git', '-C', str(source), 'apply', '--index', str(patch)], check=True)
    print('Both host patches apply to the checksum-verified pinned QEMU sources.', flush=True)
    header = (source / 'ui/dbus-gl-context.h').read_text()
    # The standalone harness provides QEMU's types and EGL global declarations.
    header = '\n'.join(line for line in header.splitlines() if not line.startswith('#include "ui/'))
    callbacks = header + '\n'
    for name in ['surface_gl_create_texture', 'surface_gl_update_texture', 'surface_gl_destroy_texture']:
        callbacks += function((source / 'ui/console-gl.c').read_text(), name)
    for name in ['dbus_create_texture', 'dbus_update_texture', 'dbus_destroy_texture']:
        callbacks += function((source / 'ui/dbus.c').read_text(), name)
    listener = (source / 'ui/dbus-listener.c').read_text()
    for name in ['dbus_call_update_gl', 'dbus_scanout_dmabuf', 'dbus_scanout_texture', 'dbus_gl_gfx_update', 'dbus_gl_gfx_switch']:
        callbacks += function(listener, name)
    (source / 'callbacks.inc').write_text(callbacks)
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gio-2.0', 'epoxy', 'pixman-1'], text=True))
    # Prove the same real-GL harness rejects the original unbound callbacks.
    baseline = callbacks
    for name in ['dbus_create_texture', 'dbus_update_texture', 'dbus_destroy_texture']:
        baseline = baseline.replace(function(callbacks, name), function(original_display, name))
    (source / 'callbacks.inc').write_text(baseline)
    binary = source / 'test-before-fix'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                    '-I', str(source), str(ROOT / 'tests/helios-qemu-dbus.c'), *flags, '-o', str(binary)], check=True)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    before = subprocess.run([str(binary)], env={**os.environ, 'EGL_PLATFORM': 'surfaceless', 'LIBGL_ALWAYS_SOFTWARE': '1'}, capture_output=True, text=True)
    assert before.returncode < 0, ('Original callbacks unexpectedly passed', before.stdout, before.stderr)
    print('Original callbacks fail the missing-EGL-context regression as expected.', flush=True)
    (source / 'callbacks.inc').write_text(callbacks)
    for pixman in [False, True]:
        binary = source / ('test-pixman' if pixman else 'test-no-pixman')
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                        *(['-DCONFIG_PIXMAN=1'] if pixman else []), '-I', str(source),
                        str(ROOT / 'tests/helios-qemu-dbus.c'), *flags, '-o', str(binary)], check=True)
        subprocess.run([str(binary)], env={**os.environ, 'EGL_PLATFORM': 'surfaceless', 'LIBGL_ALWAYS_SOFTWARE': '1'}, check=True)

#!/usr/bin/env python3
"""Apply host patches to pinned QEMU and exercise their callbacks with real EGL.

Optional argument: an offline source directory containing the pinned files below.
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
    'vulkan-readback.c': '0b08ad67b459334087406fa9fda4ab985003998236d294db8bfab292ac1a6a8d',
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
        if name.startswith('0004-'):
            pre_native_listener = (source / 'ui/dbus-listener.c').read_text()
        subprocess.run(['git', '-C', str(source), 'apply', '--check', '--index', str(patch)], check=True)
        subprocess.run(['git', '-C', str(source), 'apply', '--index', str(patch)], check=True)
    selection_binary = source / 'test-device-selection'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(source),
                    str(ROOT / 'tests/helios-qemu-device.c'), '-o', str(selection_binary)], check=True)
    subprocess.run([str(selection_binary)], check=True)
    readback = (source / 'ui/vulkan-readback.c').read_text()
    start = readback.index('typedef struct HeliosImportFailure')
    end = readback.index('\n};', readback.index('struct HeliosVulkanReadbackCache', start)) + 3
    helper = readback.index('static HeliosImportFailure *helios_import_failure')
    helper_end = readback.index('\n}\n', helper) + 3
    (source / 'import-cache.inc').write_text(readback[start:end] + '\n' + readback[helper:helper_end])
    cache_binary = source / 'test-import-cache'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(source),
                    str(ROOT / 'tests/helios-qemu-import-cache.c'), '-o', str(cache_binary)], check=True)
    subprocess.run([str(cache_binary)], check=True)
    print('Host patches apply to the checksum-verified pinned QEMU sources.', flush=True)
    # Use QEMU's actual Error prototype: substituting a GError-taking fixture
    # previously hid a production compile failure in the native frame callback.
    error_header_path = 'include/qapi/error.h'
    error_header = (Path(sys.argv[1]) / error_header_path).read_bytes() if len(sys.argv) > 1 else urllib.request.urlopen(
        f'https://raw.githubusercontent.com/winboat-org/qemu-helios/{revision}/{error_header_path}', timeout=30).read()
    assert hashlib.sha256(error_header).hexdigest() == 'f2ef26ea43bb62243fb5217dded8fcae1ec56c8237aa97923d355307a7c0bcf3', 'Pinned QEMU error header mismatch'
    error_prototype = re.search(r'^void error_report_err\(Error \*err\);', error_header.decode(), re.M)
    assert error_prototype, 'Missing QEMU error_report_err prototype'
    header = (source / 'ui/dbus-gl-context.h').read_text()
    # The standalone harness provides QEMU's types and EGL global declarations.
    header = '\n'.join(line for line in header.splitlines() if not line.startswith('#include "ui/'))
    callbacks = 'typedef struct Error Error;\n' + error_prototype.group() + '\n' + header + '\n'
    for name in ['surface_gl_create_texture', 'surface_gl_update_texture', 'surface_gl_destroy_texture']:
        callbacks += function((source / 'ui/console-gl.c').read_text(), name)
    for name in ['dbus_create_texture', 'dbus_update_texture', 'dbus_destroy_texture']:
        callbacks += function((source / 'ui/dbus.c').read_text(), name)
    listener = (source / 'ui/dbus-listener.c').read_text()
    for name in ['dbus_helios_readback_clear', 'dbus_helios_readback_select', 'dbus_helios_frame_done', 'dbus_helios_readback_update', 'dbus_scanout_disable', 'dbus_call_update_gl', 'dbus_scanout_dmabuf', 'dbus_scanout_texture', 'dbus_release_dmabuf', 'dbus_gl_gfx_update', 'dbus_gl_gfx_switch', 'dbus_gl_refresh']:
        callbacks += function(listener, name)
    (source / 'callbacks.inc').write_text(callbacks)
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gio-2.0', 'epoxy', 'pixman-1'], text=True))
    wrong_error = callbacks.replace('error_report("dbus: failed to send Helios frame: %s", err->message);',
                                    'error_report_err(g_steal_pointer(&err));')
    assert wrong_error != callbacks
    (source / 'callbacks.inc').write_text(wrong_error)
    rejected = subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-fsyntax-only',
                               '-I', str(source), str(ROOT / 'tests/helios-qemu-dbus.c'), *flags], capture_output=True, text=True)
    assert rejected.returncode != 0 and 'incompatible' in rejected.stderr and 'error_report_err' in rejected.stderr, rejected.stderr
    print('QEMU Error prototype rejects the former GError mismatch as expected.', flush=True)
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
    # Isolate the new lifecycle regression from the older EGL-context failure:
    # keep all current callbacks but restore just the old release handler.
    original_listener = (Path(sys.argv[1]) / 'ui/dbus-listener.c').read_text() if len(sys.argv) > 1 else urllib.request.urlopen(
        f'https://raw.githubusercontent.com/winboat-org/qemu-helios/{revision}/ui/dbus-listener.c', timeout=30).read().decode()
    stale_release = callbacks.replace(function(callbacks, 'dbus_release_dmabuf'), function(original_listener, 'dbus_release_dmabuf'))
    (source / 'callbacks.inc').write_text(stale_release)
    binary = source / 'test-stale-release'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                    '-I', str(source), str(ROOT / 'tests/helios-qemu-dbus.c'), *flags, '-o', str(binary)], check=True)
    old_release = subprocess.run([str(binary)], env={**os.environ, 'EGL_PLATFORM': 'surfaceless', 'LIBGL_ALWAYS_SOFTWARE': '1'}, capture_output=True, text=True)
    assert old_release.returncode < 0 and 'disables==0' in old_release.stderr, old_release.stderr
    print('Old release callback disables the already-bound replacement as expected.', flush=True)
    missing_native = callbacks.replace(function(callbacks, 'dbus_scanout_dmabuf'), function(pre_native_listener, 'dbus_scanout_dmabuf'))
    # The unused selector is expected when reproducing the old routing.
    (source / 'callbacks.inc').write_text(missing_native)
    binary = source / 'test-missing-native-readback'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-Wno-unused-function',
                    '-I', str(source), str(ROOT / 'tests/helios-qemu-dbus.c'), *flags, '-o', str(binary)], check=True)
    missing = subprocess.run([str(binary)], env={**os.environ, 'EGL_PLATFORM': 'surfaceless', 'LIBGL_ALWAYS_SOFTWARE': '1'}, capture_output=True, text=True)
    assert missing.returncode < 0 and 'vulkan_imports==1' in missing.stderr, missing.stderr
    print('Original native scanout routing bypasses the required Vulkan classification as expected.', flush=True)
    (source / 'callbacks.inc').write_text(callbacks)
    for pixman in [False, True]:
        binary = source / ('test-pixman' if pixman else 'test-no-pixman')
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                        *(['-DCONFIG_PIXMAN=1'] if pixman else []), '-I', str(source),
                        str(ROOT / 'tests/helios-qemu-dbus.c'), *flags, '-o', str(binary)], check=True)
        subprocess.run([str(binary)], env={**os.environ, 'EGL_PLATFORM': 'surfaceless', 'LIBGL_ALWAYS_SOFTWARE': '1'}, check=True)

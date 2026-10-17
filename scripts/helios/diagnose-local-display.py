#!/usr/bin/env python3
"""Test the bundled GTK viewer on the host without starting or changing a VM."""
import argparse
import ctypes
import ctypes.util
import datetime
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def check(viewer, environment, label):
    print(f'\n--- {label} ---', flush=True)
    try:
        result = subprocess.run([str(viewer), '--check-gl'], env=environment,
                                capture_output=True, text=True, timeout=15)
    except subprocess.TimeoutExpired:
        print('GTK probe timed out; no VM was changed.', flush=True)
        return None
    print((result.stdout + result.stderr)[-16000:].strip(), flush=True)
    print(f'Exit={result.returncode}', flush=True)
    return result


def diagnose(viewer):
    environment = dict(os.environ)
    print('Viewer:', viewer.name, flush=True)
    print('X11 display present:', bool(environment.get('DISPLAY')),
          '| Wayland display present:', bool(environment.get('WAYLAND_DISPLAY')), flush=True)
    try:
        gtk = ctypes.CDLL(ctypes.util.find_library('gtk-4') or 'libgtk-4.so.1')
        print('Host GTK:', '.'.join(str(getattr(gtk, 'gtk_get_' + part + '_version')())
                                   for part in ['major', 'minor', 'micro']), flush=True)
    except OSError:
        print('Host GTK version unavailable.', flush=True)
    default = check(viewer, environment, 'Host environment, outside Electron/AppImage')
    if default is not None and 'Usage:' in default.stderr:
        raise RuntimeError('This bundled viewer has no --check-gl. Select the newly built AppImage.')
    help_result = check(viewer, dict(environment, GDK_DEBUG='help'), 'Supported host GTK debug options')
    options = '' if help_result is None else help_result.stdout + help_result.stderr
    # Try only switches advertised by this installed GTK. Settings affect these
    # short-lived probe processes, never the running application or its config.
    for flag in ['gl-egl', 'gl-glx']:
        if re.search(r'(?<![\w-])' + flag + r'(?![\w-])', options):
            check(viewer, dict(environment, GDK_DEBUG=flag), 'GTK backend: ' + flag)
        else:
            print(f'\n{flag}: not advertised by this GTK; not forced.', flush=True)
    check(viewer, dict(environment, GSK_RENDERER='cairo'), 'Cairo window compositor, GTK GL area still OpenGL')
    print('\nDiagnostics only: no persistent settings, drivers, VM or passwords were changed.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--appimage', type=Path, help='Specific built WinBoat AppImage')
    parser.add_argument('--viewer', type=Path, help='Standalone native viewer (development)')
    args = parser.parse_args()
    if args.viewer:
        diagnose(args.viewer.resolve(strict=True))
        return
    if any(os.environ.get(key) for key in ['APPDIR', 'APPIMAGE']):
        raise RuntimeError('Run this helper from your normal host terminal, outside an AppImage: ' +
                           ', '.join(key for key in ['APPDIR', 'APPIMAGE'] if os.environ.get(key)))
    images = sorted((ROOT / 'dist').glob('winboat-*.AppImage'), key=lambda image: image.stat().st_mtime)
    image = args.appimage or (images[-1] if images else None)
    if image is None:
        raise RuntimeError('No built WinBoat AppImage in dist/. Use --appimage PATH.')
    image = image.resolve(strict=True)
    print('AppImage:', image.name, '| modified:', datetime.datetime.fromtimestamp(image.stat().st_mtime).isoformat(timespec='seconds'), flush=True)
    with tempfile.TemporaryDirectory(prefix='winboat-gtk-diagnostics-') as directory:
        print('Extracting only the native viewer; the WinBoat application will not start.', flush=True)
        result = subprocess.run([str(image), '--appimage-extract', 'resources/native/winboat-helios-viewer'],
                                cwd=directory, capture_output=True, text=True, timeout=60)
        viewer = Path(directory) / 'squashfs-root/resources/native/winboat-helios-viewer'
        if result.returncode or not viewer.is_file() or viewer.is_symlink():
            raise RuntimeError('Could not extract the bundled native viewer from this AppImage.')
        diagnose(viewer)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error))

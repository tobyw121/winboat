#!/usr/bin/env python3
"""Collect bounded, read-only guest graphics diagnostics without VM clipboard use."""
import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess
import urllib.error
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise urllib.error.URLError('The local guest API unexpectedly redirected')


def parse_transport_errors(text):
    events = []
    patterns = (
        ('buffer-size-mismatch', r'OPTIMAL DMA-BUF shape mismatch required=(\d+) fd_size=(\d+)', ('requiredBytes', 'bufferBytes')),
        ('egl-image-error', r'glEGLImageTargetTexture2DOES failed: (0x[0-9a-fA-F]+)', ('glError',)),
        ('egl-import-error', r'EGL DMA-BUF import failed for fourcc=(0x[0-9a-fA-F]+) modifier=(0x[0-9a-fA-F]+)', ('fourcc', 'modifier')),
        ('memory-accounting-error', r'invalid device-local memory accounting: release=(\d+) used=(\d+)', ('releasedBytes', 'usedBytes')),
        ('device-selection-mismatch', r'no unique Vulkan device matches DRM render node (\d+):(\d+)', ('drmMajor', 'drmMinor')),
    )
    # Capture fixed numeric fields only, never arbitrary container log messages.
    for line in text.splitlines():
        for kind, pattern, names in patterns:
            match = re.search(pattern, line)
            if match:
                event = {'kind': kind}
                event.update({name: value if value.startswith('0x') else int(value)
                              for name, value in zip(names, match.groups())})
                events.append(event)
    return events[-32:]


def collect_host(container):
    result = {}
    try:
        template = '{{json .Config.Image}}\n{{json .Image}}\n{{json .State.Status}}'
        fields = subprocess.check_output(['docker', 'inspect', '--format', template, container], text=True, timeout=10).splitlines()
        result.update(zip(('image', 'imageId', 'containerState'), map(json.loads, fields)))
        logs = subprocess.run(['docker', 'logs', '--tail', '300', container], capture_output=True, text=True, timeout=10, check=True)
        result['transportErrors'] = parse_transport_errors((logs.stdout + '\n' + logs.stderr)[-262144:])
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        result['error'] = type(error).__name__ + ': host graphics details unavailable'
    root = pathlib.Path(__file__).resolve().parents[2]
    try:
        template = '{{index .Config.Labels "org.winboat.helios.runtime"}}\n{{index .Config.Labels "org.winboat.helios.display"}}'
        labels = subprocess.check_output(['docker', 'image', 'inspect', '--format', template, result['imageId']], text=True, timeout=10).splitlines()
        result['runtimeVersion'] = labels[0] if re.fullmatch(r'glvnd-v\d{1,3}', labels[0]) else None
        result['displayVersion'] = labels[1] if re.fullmatch(r'dbus-v\d{1,3}', labels[1]) else None
        expected = re.search(r"HELIOS_RUNTIME_VERSION = '(glvnd-v\d+)'", (root / 'src/shared/helios.ts').read_text())
        if expected:
            result['expectedRuntimeVersion'] = expected[1]
            result['runtimeMatches'] = result['runtimeVersion'] == expected[1]
    except (OSError, KeyError, IndexError, ValueError, subprocess.SubprocessError):
        result['runtimeError'] = 'Host runtime capability labels unavailable'
    try:
        helper = pathlib.Path(__file__).with_name('inspect-qemu-backend.py').read_text()
        process = subprocess.run(['docker', 'exec', '-i', container, 'python3', '-'], input=helper,
                                 capture_output=True, text=True, timeout=10, check=True)
        if len(process.stdout) > 8192:
            raise ValueError('Oversized backend report')
        result['qemuBackend'] = json.loads(process.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        result['qemuBackend'] = {'error': 'Running QEMU configuration unavailable'}
    try:
        receipt = json.loads((root / 'resources/helios/helios-build.json').read_text())
        result['bundledInstaller'] = {key: receipt.get(key) for key in ('sha256', 'winboatCommit', 'sourceLockSha256')}
    except (OSError, ValueError):
        result['bundleError'] = 'Local installer receipt unavailable'
    return result


def collect(container, opener=None):
    port = subprocess.check_output(['docker', 'port', container, '7148/tcp'], text=True).splitlines()
    if not port:
        raise RuntimeError('Guest API port 7148/tcp is not published')
    number = int(port[0].rsplit(':', 1)[1])
    if not 1 <= number <= 65535:
        raise RuntimeError('Invalid guest API port')
    opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    result = {'collectedAtUtc': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    for endpoint in ('version', 'graphics/diagnostics', 'graphics/helios'):
        try:
            with opener.open(f'http://127.0.0.1:{number}/{endpoint}', timeout=20) as response:
                raw = response.read(131073)
                if len(raw) > 131072:
                    raise ValueError('Response exceeds 128 KiB')
                data = json.loads(raw)
                if not isinstance(data, dict):
                    raise ValueError('Expected a JSON object')
                result[endpoint] = data
        except urllib.error.HTTPError as error:
            detail = {'error': str(error), 'httpStatus': error.code}
            try:
                raw = error.read(131073)
                if len(raw) <= 131072:
                    detail['response'] = json.loads(raw)
            except (OSError, ValueError):
                pass
            result[endpoint] = detail
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            result[endpoint] = {'error': str(error)}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', default='WinBoat')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    try:
        result = collect(args.container)
        result['host'] = collect_host(args.container)
        path = args.output or pathlib.Path.home() / '.winboat/diagnostics' / (
            'graphics-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d-%H%M%S-%f') + '.json')
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w', encoding='utf-8') as output:
            json.dump(result, output, indent=2, ensure_ascii=False)
            output.write('\n')
        print('Recording:', path)
        application = result.get('graphics/diagnostics', {}).get('driver', {}).get('application')
        if application is None:
            print('Application diagnostics unavailable; update the WinBoat guest service for feature/crash details.')
        print(json.dumps(result, indent=2, ensure_ascii=False))
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()

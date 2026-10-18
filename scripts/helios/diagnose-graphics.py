#!/usr/bin/env python3
"""Collect bounded, read-only guest graphics diagnostics without VM clipboard use."""
import argparse
import datetime
import json
import os
import pathlib
import subprocess
import urllib.error
import urllib.request


def collect(container, opener=None):
    port = subprocess.check_output(['docker', 'port', container, '7148/tcp'], text=True).splitlines()
    if not port:
        raise RuntimeError('Guest API port 7148/tcp is not published')
    number = int(port[0].rsplit(':', 1)[1])
    if not 1 <= number <= 65535:
        raise RuntimeError('Invalid guest API port')
    opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}))
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
        else:
            print(json.dumps(application, indent=2, ensure_ascii=False))
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()

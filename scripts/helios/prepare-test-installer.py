#!/usr/bin/env python3
"""Export a verified historical Helios installer without changing the bundled default."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]
VERSIONS = {
    '22.22.291.0': 'f0a662f7d81498c1cc0ee6ec52547ab396eff308',
    '22.22.294.0': '7067ad47089f1b6e1cbe0fb6303c7e6045a31cb3',
}


def historical_file(commit, name):
    return subprocess.check_output(['git', 'show', f'{commit}:{name}'], cwd=ROOT)


def verify(exe, receipt, lock, source):
    pin = lock['bundledInstaller']
    if receipt['sha256'] != pin['sha256'] or hashlib.sha256(exe).hexdigest() != pin['sha256']:
        raise ValueError('Historical installer checksum mismatch')
    expected = {key: receipt[key] for key in ('repository', 'winboatCommit', 'sourceSnapshot', 'sourceLockSha256', 'workflow')}
    if expected != pin['provenance'] or receipt['sourceLockSha256'] != hashlib.sha256(source).hexdigest():
        raise ValueError('Historical CI provenance or source-lock mismatch')
    if receipt['revision'] != lock['guestRevision'] or len(exe) < 128 or exe[:2] != b'MZ' or exe[-8:] != b'HLIOSET2':
        raise ValueError('Incomplete or incompatible historical installer')
    offset, size, header = struct.unpack_from('<QQQ', exe, len(exe) - 64)
    if offset < 64 or not 0 < header < size or offset + size != len(exe) - 64:
        raise ValueError('Invalid embedded payload bounds')
    if hashlib.sha256(exe[offset:offset + size]).digest() != exe[-40:-8]:
        raise ValueError('Historical installer payload checksum mismatch')


def prepare(version):
    commit = VERSIONS[version]
    lock = json.loads(historical_file(commit, 'helios/stack.lock.json'))
    receipt_bytes = historical_file(commit, 'resources/helios/helios-build.json')
    receipt = json.loads(receipt_bytes)
    exe = historical_file(commit, 'resources/helios/HeliosSetup.exe')
    verify(exe, receipt, lock, historical_file(commit, 'helios/source.lock.json'))
    folder = ROOT / 'dist' / ('helios-test-' + version)
    files = {'HeliosSetup.exe': exe, 'helios-build.json': receipt_bytes}
    if folder.exists():
        if folder.is_symlink() or not folder.is_dir() or any(
                (folder / name).is_symlink() or not (folder / name).is_file() or (folder / name).read_bytes() != data
                for name, data in files.items()):
            raise ValueError('Existing test directory differs; no files overwritten')
    else:
        folder.mkdir(parents=True, mode=0o700)
        for name, data in files.items():
            with (folder / name).open('xb') as output:
                output.write(data)
    return folder


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', choices=VERSIONS, default='22.22.294.0')
    args = parser.parse_args()
    try:
        folder = prepare(args.version)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\nNo VM or bundled installer changes were requested.\n')
    print('Verified test installer:', folder / 'HeliosSetup.exe')
    print('Bundled default and VM unchanged. Copy this complete installer into Windows for the explicit test.')


if __name__ == '__main__':
    main()

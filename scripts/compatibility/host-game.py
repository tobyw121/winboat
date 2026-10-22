#!/usr/bin/env python3
"""Explicit Linux-host GE-Proton/UMU launch, independent of Windows/Helios."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def regular(value):
    path = Path(value).expanduser()
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise ValueError('Expected an absolute regular file, without a final symlink')
    return path.resolve()


def proton_identity(value):
    root = Path(value).expanduser()
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():
        raise ValueError('Select an installed GE-Proton directory')
    root = root.resolve()
    version, launcher = regular(root / 'version'), regular(root / 'proton')
    if version.stat().st_size > 4096 or 'GE-Proton' not in version.read_text():
        raise ValueError('Selected runtime does not identify itself as GE-Proton')
    return {'root': str(root), 'versionSha256': digest(version), 'launcherSha256': digest(launcher)}


def validate(profile):
    required = {'schema', 'exe', 'exeSha256', 'proton', 'prefix', 'gameId', 'args', 'options'}
    if not isinstance(profile, dict) or set(profile) != required or profile['schema'] != 1:
        raise ValueError('Unknown host game profile schema')
    exe = regular(profile['exe'])
    if exe.suffix.lower() != '.exe' or digest(exe) != profile['exeSha256']:
        raise ValueError('Game executable changed; recreate its profile after updating')
    if not isinstance(profile['proton'], dict) or proton_identity(profile['proton']['root']) != profile['proton']:
        raise ValueError('GE-Proton changed; recreate the profile for this runtime')
    prefix = Path(profile['prefix'])
    if not prefix.is_absolute() or prefix.is_symlink() or prefix.resolve() != prefix:
        raise ValueError('Prefix must be a canonical absolute directory without symlinks')
    if not isinstance(profile['gameId'], str) or not re.fullmatch(r'umu-[A-Za-z0-9_.-]{1,80}', profile['gameId']):
        raise ValueError('Expected a UMU game identifier, for example umu-default')
    args = profile['args']
    if not isinstance(args, list) or len(args) > 32 or any(not isinstance(a, str) or len(a) > 2048 or any(c in a for c in '\0\r\n') for a in args):
        raise ValueError('Invalid game arguments')
    options = profile['options']
    if not isinstance(options, dict) or set(options) != {'log', 'wined3d', 'disableEsync', 'disableFsync'} or any(type(v) is not bool for v in options.values()):
        raise ValueError('Unknown compatibility option')
    return profile


def private_json(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def create(exe, proton, prefix, game_id, args):
    executable = regular(exe)
    profile = {'schema': 1, 'exe': str(executable), 'exeSha256': digest(executable),
               'proton': proton_identity(proton), 'prefix': str(Path(prefix).expanduser().absolute()),
               'gameId': game_id, 'args': args,
               'options': dict(log=False, wined3d=False, disableEsync=False, disableFsync=False)}
    return validate(profile)


def environment(profile, inherited):
    # Profiles own only these child-process settings. Never alter the user's
    # global environment, Windows registry, host GPU or active VM.
    env = dict(inherited)
    for name in ('PROTONPATH', 'WINEPREFIX', 'GAMEID', 'STORE', 'PROTON_LOG', 'PROTON_USE_WINED3D',
                 'PROTON_NO_ESYNC', 'PROTON_NO_FSYNC', 'WINEDLLOVERRIDES', 'VK_INSTANCE_LAYERS',
                 'DXVK_CONFIG_FILE', 'DXVK_FILTER_DEVICE_NAME', 'VK_ICD_FILENAMES', 'VK_DRIVER_FILES', 'PYROVEIL', 'LOW_LATENCY_LAYER'):
        env.pop(name, None)
    env.update(PROTONPATH=profile['proton']['root'], WINEPREFIX=profile['prefix'], GAMEID=profile['gameId'], PROTON_LOG_DIR=profile['prefix'])
    for option, name in {'log': 'PROTON_LOG', 'wined3d': 'PROTON_USE_WINED3D',
                         'disableEsync': 'PROTON_NO_ESYNC', 'disableFsync': 'PROTON_NO_FSYNC'}.items():
        env[name] = '1' if profile['options'][option] else '0'
    return env


def run(profile, dry_run=False):
    validate(profile)
    runner = shutil.which('umu-run')
    if not runner:
        raise ValueError('umu-run is missing; install UMU and its runtime first. Direct Proton launch is unsupported.')
    command = [str(Path(runner).resolve()), profile['exe'], *profile['args']]
    if dry_run:
        return {'command': command, 'prefix': profile['prefix'], 'runtime': profile['proton'],
                'options': profile['options'], 'scope': 'Linux host only; VM unchanged'}
    prefix = Path(profile['prefix'])
    prefix.mkdir(mode=0o700, parents=True, exist_ok=True)
    if prefix.stat().st_uid != os.getuid() or prefix.stat().st_mode & 0o077:
        raise ValueError('Use an owned, private (0700), dedicated prefix directory')
    # Lock before examining/creating the ownership marker. A second launch must
    # not mistake a partially created prefix for a complete runtime.
    fd = os.open(prefix / '.winboat-umu.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError('This prefix already has an active WinBoat launch') from error
        marker = prefix / '.winboat-umu.json'
        identity = {key: profile[key] for key in ('schema', 'exe', 'exeSha256', 'proton', 'gameId')}
        if marker.exists() or marker.is_symlink():
            if marker.is_symlink() or marker.stat().st_size > 16384 or json.loads(marker.read_text()) != identity:
                raise ValueError('Prefix belongs to a different game/runtime; select a new dedicated prefix')
        else:
            if set(p.name for p in prefix.iterdir()) != {'.winboat-umu.lock'}:
                raise ValueError('Existing prefix is unmanaged; it will not be modified')
            private_json(marker, identity)
        result = subprocess.run(command, cwd=Path(profile['exe']).parent,
                                env=environment(profile, os.environ), check=False)
        return {'exitCode': result.returncode, 'scope': 'Linux host only; VM unchanged'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    add = sub.add_parser('create')
    for flag in ('exe', 'proton', 'prefix', 'output'):
        add.add_argument('--' + flag, required=True)
    add.add_argument('--game-id', default='umu-default')
    add.add_argument('--argument', action='append', default=[])
    launch = sub.add_parser('run')
    launch.add_argument('profile')
    launch.add_argument('--dry-run', action='store_true')
    arguments = parser.parse_args()
    try:
        if arguments.action == 'create':
            profile = create(arguments.exe, arguments.proton, arguments.prefix, arguments.game_id, arguments.argument)
            private_json(Path(arguments.output).expanduser(), profile)
            print('Profile created. Edit its four boolean options for per-game A/B tests.')
        else:
            file = regular(arguments.profile)
            if file.stat().st_size > 65536:
                raise ValueError('Profile exceeds size limit')
            result = run(json.loads(file.read_text()), arguments.dry_run)
            print(json.dumps(result, indent=2))
            return result.get('exitCode', 0)
    except (OSError, ValueError, KeyError, TypeError, UnicodeError) as error:
        parser.exit(1, 'Host game launcher: ' + str(error) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())

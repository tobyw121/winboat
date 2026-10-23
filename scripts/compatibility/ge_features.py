"""Validated, per-process GE features for the Linux/UMU route only."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct

GE_REVISION = '88004a046c575af0b96131ff7b76dcd598da51ad'
RECIPES = {
    'none': {},
    'dxgi-probe-v1': {'dxgi.deferInitialFullscreen': True, 'dxgi.deferSurfaceCreation': True},
    'keep-fullscreen-v1': {'dxgi.keepFullscreenOnFocusLoss': True},
}


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def file(root, relative):
    path = root / relative
    if Path(relative).is_absolute() or '..' in Path(relative).parts or path.is_symlink() or not path.is_file() or path.stat().st_size > 134217728 or not path.resolve().is_relative_to(root):
        raise ValueError('GE asset must be a regular file inside its recorded directory')
    return path


def architecture(exe):
    with Path(exe).open('rb') as stream:
        header = stream.read(64)
        if len(header) != 64 or header[:2] != b'MZ':
            raise ValueError('GE extensions require an x86/x64 PE executable')
        offset, = struct.unpack_from('<I', header, 60)
        if offset > 1048576:
            raise ValueError('Invalid PE offset')
        stream.seek(offset); pe = stream.read(6)
    if len(pe) != 6 or pe[:4] != b'PE\0\0' or pe[4:] not in (b'\x4c\x01', b'\x64\x86'):
        raise ValueError('Unsupported PE architecture')
    return 'i386-windows' if pe[4:] == b'\x4c\x01' else 'x86_64-windows'


def config(path):
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or set(data) - {'version', 'type', 'matches', 'disabledExtensions', 'roundtripCache'} or type(data.get('version')) is not int or data.get('version') != 2 or data.get('type') != 'pyroveil':
        raise ValueError('Unsupported Pyroveil config schema')
    matches = data.get('matches')
    if not isinstance(matches, list) or not 1 <= len(matches) <= 64:
        raise ValueError('Pyroveil requires bounded shader matches')
    for match in matches:
        if not isinstance(match, dict) or set(match) - {'spirvExecutionModel', 'opStringSearch', 'action'} or match.get('action') != {'glsl-roundtrip': True} or type(match.get('action', {}).get('glsl-roundtrip')) is not bool or not ({'spirvExecutionModel', 'opStringSearch'} & set(match)):
            raise ValueError('Only targeted GLSL-roundtrip shader actions are supported')
        if 'spirvExecutionModel' in match and (type(match['spirvExecutionModel']) is not int or not 0 <= match['spirvExecutionModel'] <= 65535):
            raise ValueError('Invalid SPIR-V execution model')
        if 'opStringSearch' in match and (not isinstance(match['opStringSearch'], str) or not 1 <= len(match['opStringSearch']) <= 256 or '\0' in match['opStringSearch']):
            raise ValueError('Invalid shader string match')
    extensions = data.get('disabledExtensions', [])
    if not isinstance(extensions, list) or len(extensions) > 64 or any(not isinstance(e, str) or not re.fullmatch(r'VK_[A-Za-z0-9_]{1,100}', e) for e in extensions):
        raise ValueError('Invalid disabled extension list')
    if 'roundtripCache' in data and data['roundtripCache'] != 'cache':
        raise ValueError('Use the private relative Pyroveil cache directory named cache')
    return data


def prepare(proton, exe, recipe='none', pyroveil=None, d7vk=False):
    root = Path(proton).resolve()
    if recipe not in RECIPES:
        raise ValueError('Unknown GE recipe')
    if d7vk and recipe != 'none': raise ValueError('DXGI fullscreen recipes do not apply to D7VK')
    arch = architecture(exe)
    files = {}
    def pin(relative):
        path = file(root, relative); files[relative] = sha(path)
        return path
    launcher = pin('proton').read_text()
    if (root / 'user_settings.py').exists(): pin('user_settings.py')
    if RECIPES[recipe]:
        dxgi_file = pin('files/lib/wine/dxvk/' + arch + '/dxgi.dll')
        if architecture(dxgi_file) != arch: raise ValueError('DXGI DLL architecture mismatch')
        dxgi = dxgi_file.read_bytes()
        for option in RECIPES[recipe]:
            if option.encode() not in dxgi:
                raise ValueError('Selected GE DXGI does not implement ' + option)
    if d7vk:
        if arch != 'i386-windows' or 'PROTON_USE_D7VK' not in launcher:
            raise ValueError('Installed GE runtime does not support x86 D7VK selection')
        dll = pin('files/lib/wine/d7vk/i386-windows/ddraw.dll')
        if architecture(dll) != arch:
            raise ValueError('D7VK DLL architecture mismatch')
    pyro = None
    if pyroveil:
        directory = Path(pyroveil).expanduser().resolve()
        config_file = file(directory, 'pyroveil.json')
        if config_file.stat().st_size > 1048576 or 'PYROVEIL_CONFIG' not in launcher:
            raise ValueError('Pyroveil unavailable or config too large')
        config(config_file)
        manifests = sorted((root / 'files/share/pyroveil/implicit_layer.d').glob('*.json'))
        if not 1 <= len(manifests) <= 8:
            raise ValueError('Installed GE Pyroveil layer manifests are missing')
        for manifest in manifests:
            relative = manifest.relative_to(root).as_posix()
            layer = json.loads(pin(relative).read_text())['layer']
            if layer.get('name') != 'VK_LAYER_pyroveil' or layer.get('enable_environment') != {'PYROVEIL': '1'}:
                raise ValueError('Unexpected Pyroveil layer identity')
            library = (manifest.parent / layer['library_path']).resolve()
            if not library.is_relative_to(root):
                raise ValueError('Pyroveil library escapes GE runtime')
            binary = pin(library.relative_to(root).as_posix()).read_bytes()
            if len(binary) < 64 or binary[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', binary, 18)[0] != 62 or b'VK_LAYER_PYROVEIL_vkNegotiateLoaderLayerInterfaceVersion' not in binary:
                raise ValueError('Pyroveil layer binary/entrypoint unavailable')
        assets = {}; total = 0
        for path in sorted(directory.rglob('*')):
            if path.is_symlink(): raise ValueError('Pyroveil bundles must not contain symlinks')
            if path.is_file():
                relative = path.relative_to(directory).as_posix()
                if relative != 'pyroveil.json' and not relative.startswith('cache/'):
                    raise ValueError('Pyroveil bundle contains unrelated assets')
                total += path.stat().st_size
                if total > 67108864 or len(assets) >= 256: raise ValueError('Pyroveil bundle exceeds bounds')
                assets[relative] = sha(path)
        pyro = {'directory': str(directory), 'files': assets}
    return {'schema': 1, 'geReference': GE_REVISION, 'recipe': recipe, 'recipeSha256': hashlib.sha256(json.dumps(RECIPES[recipe], sort_keys=True).encode()).hexdigest(), 'd7vk': bool(d7vk), 'runtimeFiles': files, 'pyroveil': pyro}


def validate(features, proton, exe):
    if not isinstance(features, dict) or set(features) != {'schema', 'geReference', 'recipe', 'recipeSha256', 'd7vk', 'runtimeFiles', 'pyroveil'} or type(features['schema']) is not int or features['schema'] != 1 or type(features['d7vk']) is not bool:
        raise ValueError('Invalid GE extension profile')
    pyro = features['pyroveil']
    if pyro is not None and (not isinstance(pyro, dict) or set(pyro) != {'directory', 'files'}): raise ValueError('Invalid Pyroveil asset profile')
    expected = prepare(proton, exe, features['recipe'], pyro['directory'] if pyro else None, features['d7vk'])
    if expected != features:
        raise ValueError('GE recipe, runtime or shader assets changed; create a new profile/prefix')


def environment(features, prefix):
    env = {'DXVK_CONFIG': '; '.join(key + ' = True' for key in RECIPES[features['recipe']]),
           'PROTON_USE_D7VK': '1' if features['d7vk'] else '0'}
    if features['pyroveil']:
        pyro = features['pyroveil']; destination = Path(prefix) / '.winboat-pyroveil'
        if destination.is_symlink(): raise ValueError('Shader directory must not be a symlink')
        destination.mkdir(mode=0o700, exist_ok=True)
        for relative, checksum in pyro['files'].items():
            target = destination / relative
            for parent in [target, *target.parents]:
                if parent == destination.parent: break
                if parent.is_symlink(): raise ValueError('Shader staging path must not be a symlink')
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if target.exists():
                if not target.is_file() or sha(target) != checksum: raise ValueError('A staged shader asset changed')
            else: shutil.copyfile(Path(pyro['directory']) / relative, target)
        env.update(PYROVEIL='1', PYROVEIL_CONFIG=str(destination / 'pyroveil.json'))
    return env

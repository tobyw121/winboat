"""Extract unchanged AME OOBE binaries from the pinned official Wizard release."""
import hashlib
from pathlib import Path, PurePosixPath
import stat
import zipfile
import xml.etree.ElementTree as ET

WIZARD_SHA = 'a637f32b64e1493b315db9139065105656c84518dca20ce3b18c89750ee40c82'
PLAYBOOK_SHA = '13c4d8e7fc0ed38c37c5942ebcabf7f636389972e6de391a192ae649967602d8'
OOBE_HASHES = {
    'AME.Client.exe': '7985a9d5fb1e40cf8840f35e5ecee6332f31d9279b30dfa06ef8d2435b417af6',
    'oobe_shim.exe': 'c2b4f73bc9615e2981b9c60bb51974ed67539873dbd3d29b97258e21fa3ada7d',
}
OPTIONS = ['defender-enable', 'mitigations-default', 'auto-updates-default']


def verify(path, expected):
    with Path(path).open('rb') as source:
        if hashlib.file_digest(source, 'sha256').hexdigest() != expected:
            raise ValueError(f'Official asset SHA-256 mismatch: {Path(path).name}')


def extract_oobe(wizard, output):
    import dnfile
    verify(wizard, WIZARD_SHA)
    outer = dnfile.dnPE(str(wizard))
    try:
        data = next(r.data for r in outer.net.resources if str(r.name) ==
                    'TrustedUninstaller.GUI.resources.WizardFiles.TrustedUninstaller.Shared.dll')
        inner = dnfile.dnPE(data=data)
        try:
            for name, expected in OOBE_HASHES.items():
                payload = next(r.data for r in inner.net.resources if str(r.name) ==
                               f'TrustedUninstaller.Shared.Properties.{name}')
                if hashlib.sha256(payload).hexdigest() != expected or not payload.startswith(b'MZ'):
                    raise ValueError(f'Invalid AME OOBE resource: {name}')
                if name == 'oobe_shim.exe':
                    # This pinned shim checks this filename before starting AME;
                    # otherwise it restores Microsoft's OOBE and removes its service.
                    client_path = r'%PROGRAMDATA%\AME\OOBE\AME.Client.exe'
                    if client_path.encode('utf-16-le') not in payload:
                        raise ValueError('Unsupported AME shim client path contract')
                (Path(output) / name).write_bytes(payload)
        finally:
            inner.close()
    finally:
        outer.close()


def extract_playbook(archive, output):
    verify(archive, PLAYBOOK_SHA)
    output = Path(output)
    with zipfile.ZipFile(archive) as source:
        if sum(i.file_size for i in source.infolist()) > 1024**3:
            raise ValueError('Playbook expands beyond the supported size')
        for info in source.infolist():
            name = PurePosixPath(info.filename)
            if name.is_absolute() or '..' in name.parts or '\\' in info.filename or stat.S_ISLNK(info.external_attr >> 16):
                raise ValueError('Unsafe path in playbook archive')
            destination = output.joinpath(*name.parts)
            if info.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(source.read(info, pwd=b'malte'))
    playbook = ET.parse(output / 'playbook.conf').getroot()
    if playbook.findtext('Version') != '0.5.0' or playbook.findtext('UniqueId') != '00000000-0000-4000-6174-6c6173203a33':
        raise ValueError('Unexpected Atlas playbook identity')
    # This mirrors AME's conditional DISM package gate. Do not imitate CBS servicing on Linux.
    if 'DefenderDisabled' in [n.text for n in playbook.findall('Requirements/Requirement')]:
        raise ValueError('This playbook requires native Windows offline DISM servicing; it is not the supported Atlas profile')
    return playbook


def write_oobe_config(destination, playbook, username, password):
    root = ET.Element('OOBE')
    for key, value in {'Username': username, 'Password': password, 'AdminUserEnabled': 'false',
                       'AutoLogon': 'false', 'Verified': 'true', 'InternetRequirement': 'Force'}.items():
        ET.SubElement(root, key).text = value
    options = ET.SubElement(root, 'Options')
    for option in OPTIONS:
        ET.SubElement(options, 'string').text = option
    points = ET.SubElement(root, 'BulletPoints')
    for point in playbook.findall('OOBE/BulletPoints/BulletPoint'):
        item = ET.SubElement(points, 'BulletPoint')
        for key in ['Icon', 'Title', 'Description']:
            ET.SubElement(item, key).text = point.get(key)
    ET.SubElement(root, 'Software')
    ET.indent(root)
    ET.ElementTree(root).write(destination, encoding='utf-8', xml_declaration=True)
    Path(destination).chmod(0o600)


def write_iso_config(destination, playbook, image):
    root = ET.Element('ISO')
    for key, value in {'Name': playbook.findtext('Name'), 'Creator': playbook.findtext('Username'),
                       'UniqueId': playbook.findtext('UniqueId'), 'Version': playbook.findtext('Version'),
                       'WindowsVersion': image.findtext('WINDOWS/VERSION/BUILD'),
                       'WindowsUpdateVersion': image.findtext('WINDOWS/VERSION/SPBUILD', '0'),
                       'BitLockerDisabled': 'true', 'HardwareRequirementsDisabled': 'true',
                       'InternetRequired': 'true'}.items():
        ET.SubElement(root, key).text = value
    options = ET.SubElement(root, 'Options')
    for option in OPTIONS:
        ET.SubElement(options, 'string').text = option
    ET.ElementTree(root).write(destination, encoding='utf-8', xml_declaration=True)

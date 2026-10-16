"""AME-compatible offline preparation for the pinned Atlas Windows 11 Pro image."""
import datetime
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid
import xml.etree.ElementTree as ET
from ame_assets import extract_oobe, extract_playbook, write_oobe_config, write_iso_config, OPTIONS
from offline_registry import prepare_install, prepare_boot

NS = 'urn:schemas-microsoft-com:unattend'
ET.register_namespace('', NS)
ET.register_namespace('wcm', 'http://schemas.microsoft.com/WMIConfig/2002/State')


def command(*args, capture=False):
    result = subprocess.run(list(map(str, args)), check=True,
                            stdout=subprocess.PIPE if capture else subprocess.DEVNULL)
    return result.stdout


def update(wim, index, source, destination):
    command('wimlib-imagex', 'update', wim, index, '--check', '--command',
            f'add "{source}" "{destination}"')


def extract(wim, index, name, folder, required=True):
    result = subprocess.run(['wimlib-imagex', 'extract', str(wim), str(index), name,
                             f'--dest-dir={folder}'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if result.returncode == 49 and not required:  # WIMLIB_ERR_PATH_DOES_NOT_EXIST only
        return None
    if result.returncode:
        raise RuntimeError(f'Cannot extract {name}: {result.stderr.decode(errors="replace")}')
    return Path(folder) / Path(name).name


def images(wim):
    data = command('wimlib-imagex', 'info', wim, '--xml', capture=True)
    return ET.fromstring(data.decode('utf-16-le').lstrip('\ufeff'))


def child(folder, name):
    return next((p for p in Path(folder).iterdir() if p.name.lower() == name.lower()), None)


def amend_answer(source, index, ame=True):
    """Allow AME to create the user; preserve unrelated dockur customization."""
    xml = ET.parse(source)
    setup = xml.getroot().find(f'{{{NS}}}settings[@pass="windowsPE"]/{{{NS}}}component[@name="Microsoft-Windows-Setup"]')
    if setup is None:
        raise ValueError('Custom answer file lacks a Windows PE setup component')
    os_image = setup.find(f'{{{NS}}}ImageInstall/{{{NS}}}OSImage')
    if os_image is None:
        raise ValueError('Custom answer file lacks an OSImage installation target')
    install_from = os_image.find(f'{{{NS}}}InstallFrom')
    if install_from is None:
        install_from = ET.Element(f'{{{NS}}}InstallFrom')
        os_image.insert(0, install_from)
    if install_from.find(f'{{{NS}}}Path') is not None:
        raise ValueError('Custom answer file specifies a separate installation image')
    for metadata in install_from.findall(f'{{{NS}}}MetaData'):
        install_from.remove(metadata)
    metadata = ET.SubElement(install_from, f'{{{NS}}}MetaData',
                             {'{http://schemas.microsoft.com/WMIConfig/2002/State}action': 'add'})
    ET.SubElement(metadata, f'{{{NS}}}Key').text = '/IMAGE/INDEX'
    ET.SubElement(metadata, f'{{{NS}}}Value').text = str(index)
    for component in xml.getroot().findall(f'.//{{{NS}}}component'):
        if not ame or component.get('name') != 'Microsoft-Windows-Shell-Setup':
            continue
        for name in ['UserAccounts', 'AutoLogon']:
            for element in component.findall(f'{{{NS}}}{name}'):
                component.remove(element)
        oobe = component.find(f'{{{NS}}}OOBE')
        if oobe is not None:
            for name in ['SkipUserOOBE', 'SkipMachineOOBE']:
                for element in oobe.findall(f'{{{NS}}}{name}'):
                    oobe.remove(element)
        commands = component.find(f'{{{NS}}}FirstLogonCommands')
        if commands is not None:
            for entry in list(commands):
                if 'c:\\oem\\install.bat' in entry.findtext(f'{{{NS}}}CommandLine', '').lower():
                    commands.remove(entry)
    xml.write(source, encoding='utf-8', xml_declaration=True)


def prepare_answers(tree, boot, work, index, ame):
    answers = []
    for image in images(boot).findall('IMAGE'):
        folder = work / f'boot-{image.get("INDEX")}'
        folder.mkdir()
        for name in ['autounattend.xml', 'autounattend.dat']:
            answer = extract(boot, image.get('INDEX'), f'/{name}', folder, required=False)
            if answer:
                amend_answer(answer, index, ame)
                answers.append((image.get('INDEX'), answer, f'/{name}'))
    answer = child(tree, 'autounattend.xml')
    if answer:
        staged = work / 'autounattend.xml'
        shutil.copyfile(answer, staged)
        amend_answer(staged, index, ame)
        answers.append((None, staged, answer))
    if not answers:
        raise ValueError('An unattended Windows setup answer file is required')
    return answers


def apply_answers(answers, boot):
    for boot_index, source, destination in answers:
        if boot_index:
            update(boot, boot_index, source, destination)
        else:
            shutil.copyfile(source, destination)


def inject(tree, media):
    tree, media = Path(tree), Path(media)
    sources = child(tree, 'sources')
    if not sources:
        raise ValueError('ISO sources directory missing')
    wim = child(sources, 'install.wim') or child(sources, 'install.esd')
    if not wim:
        raise ValueError('install.wim/install.esd missing')
    selected = [image for image in images(wim).findall('IMAGE')
                if image.findtext('WINDOWS/EDITIONID') == 'Professional' and
                image.findtext('WINDOWS/ARCH') == '9' and
                image.findtext('WINDOWS/VERSION/BUILD') in ['26100', '26200']]
    if len(selected) != 1:
        raise ValueError('Atlas requires one x64 Windows 11 Pro 24H2/25H2 index')
    index = selected[0].get('INDEX')
    boot = child(sources, 'boot.wim')
    if not boot:
        raise ValueError('Windows Setup boot.wim is required for AME OOBE')
    conf = json.loads((media / 'atlas.json').read_text())
    if conf.get('mode') == 'live':
        with tempfile.TemporaryDirectory(prefix='winboat-atlas-select-') as temporary:
            answers = prepare_answers(tree, boot, Path(temporary), index, False)
            apply_answers(answers, boot)
        print(f'Validated custom/downloaded media; Windows Setup will install Pro index {index}. Atlas runs after installation.')
        return
    if conf.get('mode') != 'iso':
        raise ValueError('Unsupported Atlas installation mode')
    if (tree / 'winboat-atlas-iso.json').exists():
        raise ValueError('AME OOBE has already been injected; use a fresh Windows image')
    credentials = json.loads((media / 'oobe-credentials.json').read_text())
    if not credentials.get('password') or credentials.get('username') != conf['username']:
        raise ValueError('AME OOBE credentials are missing or inconsistent')
    panther = sources / '$OEM$' / '$$' / 'Panther'
    if (panther / 'unattend.xml').exists():
        raise ValueError('A custom Panther unattend.xml is present; refusing to overwrite it')
    if (sources / '$OEM$' / '$$' / 'Setup' / 'Scripts' / 'SetupComplete.cmd').exists():
        raise ValueError('Custom OEM SetupComplete.cmd conflicts with AME provisioning')
    with tempfile.TemporaryDirectory(prefix='winboat-ame-') as temporary:
        work = Path(temporary)
        answers = prepare_answers(tree, boot, work, index, True)
        for name in ['/ProgramData/WinBoat/Atlas/oobe-mode.json', '/Windows/System32/OOBE/msoobeext.exe']:
            if extract(wim, index, name, work, required=False):
                raise ValueError('AME OOBE has already been injected; use a fresh Windows image')
        oobe = work / 'oobe'
        oobe.mkdir()
        extract_oobe(media / 'AME-Beta-v0.8.4.exe', oobe)
        playbook = extract_playbook(media / 'AtlasPlaybook.apbx', oobe / 'Playbook')
        shutil.copyfile(media / 'AtlasPlaybook.apbx', oobe / 'playbook.apbx')
        (oobe / 'Playbook/options.txt').write_text('\n'.join(OPTIONS), encoding='utf-8')
        write_oobe_config(oobe / 'oobe.conf', playbook, credentials['username'], credentials['password'])
        if wim.suffix.lower() == '.esd':
            converted = sources / 'install.wim.partial'
            if converted.exists():
                raise ValueError('An incomplete ESD conversion exists')
            command('wimlib-imagex', 'export', wim, 'all', converted, '--compress=LZX', '--check')
            target = sources / 'install.wim'
            converted.replace(target)
            wim.unlink()
            wim = target
        original_oobe = extract(wim, index, '/Windows/System32/OOBE/msoobe.exe', work)
        if not original_oobe.read_bytes().startswith(b'MZ'):
            raise ValueError('The Windows OOBE executable is invalid')
        software = extract(wim, index, '/Windows/System32/config/SOFTWARE', work)
        system = extract(wim, index, '/Windows/System32/config/SYSTEM', work)
        backup = prepare_install(software, system)
        mode = {'mode': 'ame-oobe', 'release': conf['release'], 'instanceId': str(uuid.uuid4()),
                'createdAtUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'waitForHelios': conf['waitForHelios'], 'playbookApplied': False,
                'offlineRegistryPrepared': True, 'offlineDismPackages': [],
                'windowsDism': 'original Atlas playbook during AME OOBE'}
        (work / 'oobe-mode.json').write_text(json.dumps(mode), encoding='utf-8')
        (work / 'security-backup.json').write_text(json.dumps(backup), encoding='utf-8')
        command('wimlib-imagex', 'update', wim, index, '--check', '--command',
                'rename /Windows/System32/OOBE/msoobe.exe /Windows/System32/OOBE/msoobeext.exe')
        update(wim, index, oobe / 'oobe_shim.exe', '/Windows/System32/OOBE/msoobe.exe')
        (oobe / 'oobe_shim.exe').unlink()
        (oobe / 'AME.Client.exe').rename(oobe / 'OOBE.exe')
        update(wim, index, oobe, '/ProgramData/AME/OOBE')
        for name in ['SOFTWARE', 'SYSTEM']:
            update(wim, index, work / name, f'/Windows/System32/config/{name}')
        for name in ['oobe-mode.json', 'security-backup.json']:
            update(wim, index, work / name, f'/ProgramData/WinBoat/Atlas/{name}')
        update(wim, index, media / 'atlas.json', '/ProgramData/WinBoat/AtlasMedia/atlas.json')
        previous = extract(wim, index, '/Windows/Setup/Scripts/SetupComplete.cmd', work, required=False)
        if previous:
            update(wim, index, previous, '/Windows/Setup/Scripts/WinBoatOriginalSetupComplete.cmd')
        setup = work / 'SetupComplete.cmd'
        setup.write_bytes(b'@echo off\r\n'
                          b'if exist "%WINDIR%\\Setup\\Scripts\\WinBoatOriginalSetupComplete.cmd" '
                          b'%ComSpec% /d /c ""%WINDIR%\\Setup\\Scripts\\WinBoatOriginalSetupComplete.cmd""\r\n'
                          b'if exist "C:\\OEM\\install.bat" call "C:\\OEM\\install.bat"\r\n'
                          b'exit /b %errorlevel%\r\n')
        update(wim, index, setup, '/Windows/Setup/Scripts/SetupComplete.cmd')
        for boot_image in images(boot).findall('IMAGE'):
            boot_index = boot_image.get('INDEX')
            folder = work / f'boot-{boot_index}'
            hive = extract(boot, boot_index, '/Windows/System32/config/SYSTEM', folder)
            prepare_boot(hive)
            update(boot, boot_index, hive, '/Windows/System32/config/SYSTEM')
        apply_answers(answers, boot)
        panther.mkdir(parents=True, exist_ok=True)
        root = ET.Element(f'{{{NS}}}unattend')
        settings = ET.SubElement(root, f'{{{NS}}}settings', {'pass': 'oobeSystem'})
        for name, value_name, value in [
            ('Microsoft-Windows-SecureStartup-FilterDriver', 'PreventDeviceEncryption', 'true'),
            ('Microsoft-Windows-EnhancedStorage-Adm', 'TCGSecurityActivationDisabled', '1'),
        ]:
            component = ET.SubElement(settings, f'{{{NS}}}component', {'name': name,
                'processorArchitecture': 'amd64', 'publicKeyToken': '31bf3856ad364e35',
                'language': 'neutral', 'versionScope': 'nonSxS'})
            ET.SubElement(component, f'{{{NS}}}{value_name}').text = value
        ET.ElementTree(root).write(panther / 'unattend.xml', encoding='utf-8', xml_declaration=True)
        # Payload is already inside the selected WIM. Do not also copy the 147 MB
        # Wizard or disposable credentials into the installed OEM/Program Files trees.
        copied_media = sources / '$OEM$' / '$1' / 'OEM' / 'atlas'
        for name in ['AME-Beta-v0.8.4.exe', 'AtlasPlaybook.apbx', 'oobe-credentials.json']:
            (copied_media / name).unlink(missing_ok=True)
        (tree / 'winboat-atlas-iso.json').write_text(json.dumps(mode, indent=2), encoding='utf-8')
        write_iso_config(tree / 'iso.conf', playbook, selected[0])
        print('AME OOBE and offline registry preparation injected. Atlas is applied during Windows OOBE.')


if __name__ == '__main__':
    try:
        inject(*sys.argv[1:])
    except Exception as error:
        print(f'AME ISO injection failed: {error}', file=sys.stderr)
        sys.exit(1)

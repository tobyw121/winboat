#!/usr/bin/env python3
"""Authenticated SMB exports for explicitly configured WinBoat bind mounts."""
import ipaddress
import json
import os
from pathlib import Path
import pwd
import grp
import re
import subprocess
import sys
import tempfile

ROOT = '/winboat-shares/'
META = Path('/run/winboat-shares.json')
USER = 'winboat'


def folders():
    entries = json.loads(os.environ['WINBOAT_SHARED_FOLDERS'])
    if not isinstance(entries, list) or len(entries) > 16:
        raise ValueError('Invalid shared folder list')
    seen = set()
    for entry in entries:
        name = entry['name']
        if not isinstance(name, str) or not name or len(name) > 64 or re.search(r'[\\/:*?"<>|,$%\[\]\x00-\x1f]', name) or name != name.strip() or name[-1] in '. ' or name.lower() in {'global','ipc$','admin$','.','..'} or name.lower() in seen:
            raise ValueError('Invalid or duplicate SMB share name')
        seen.add(name.lower())
        if entry['path'] != ROOT + name or not isinstance(entry['readOnly'], bool):
            raise ValueError('Invalid SMB share mount')
        if not Path(entry['path']).is_dir():
            raise ValueError('Shared folder mount is missing: ' + name)
    return entries


def password():
    value = os.environ.get('PASSWORD', '')
    if not value or any(character in value for character in '\r\n\0'):
        raise ValueError('A non-empty Windows password without line breaks is required')
    return value


def configure(address, interfaces):
    ipaddress.ip_address(address)
    if not re.fullmatch(r'[a-zA-Z0-9_.:, -]+', interfaces):
        raise ValueError('Invalid Samba network interface')
    entries = folders()
    uid, gid = (int(os.environ[key]) for key in ('WINBOAT_SHARE_UID', 'WINBOAT_SHARE_GID'))
    if not all(0 <= value <= 2147483647 for value in (uid, gid)):
        raise ValueError('Invalid Linux share identity')
    secret = password()
    try:
        grp.getgrgid(gid)
    except KeyError:
        subprocess.run(['groupadd', '--gid', str(gid), 'winboat-share'], check=True, capture_output=True)
    try:
        account = pwd.getpwnam(USER)
        if (account.pw_uid, account.pw_gid) != (uid, gid):
            raise ValueError('Existing SMB account has another Linux identity')
    except KeyError:
        subprocess.run(['useradd', '--no-create-home', '--non-unique', '--uid', str(uid), '--gid', str(gid), '--shell', '/usr/sbin/nologin', USER], check=True, capture_output=True)
    # Credentials go through stdin, never command arguments or diagnostic output.
    subprocess.run(['smbpasswd', '-a', '-s', USER], input=secret+'\n'+secret+'\n', text=True, capture_output=True, check=True)
    configuration = f'''[global]
    server string = WinBoat Shared Folders
    netbios name = HOST
    workgroup = WORKGROUP
    interfaces = {interfaces}
    bind interfaces only = yes
    socket address = {address}
    security = user
    map to guest = Never
    restrict anonymous = 2
    server min protocol = SMB2_02
    server signing = mandatory
    wide links = no
    load printers = no
    printing = bsd
    printcap name = /dev/null
    disable spoolss = yes
'''
    for entry in entries:
        configuration += f'''
[{entry['name']}]
    path = {entry['path']}
    browseable = yes
    guest ok = no
    valid users = {USER}
    force user = {USER}
    read only = {'yes' if entry['readOnly'] else 'no'}
    create mask = 0664
    directory mask = 0775
    follow symlinks = yes
'''
    Path('/etc/samba/smb.conf').write_text(configuration)
    META.write_text(json.dumps({'address':address, 'folders':entries}))
    META.chmod(0o600)
    subprocess.run(['testparm', '-s', '/etc/samba/smb.conf'], check=True, capture_output=True)
    print('Configured authenticated SMB shares: ' + ', '.join(entry['name'] for entry in entries))


def check():
    metadata = json.loads(META.read_text())
    results = []
    # A temporary credential file avoids exposing the password in process lists.
    with tempfile.TemporaryDirectory(prefix='winboat-smb-', dir='/dev/shm') as temporary:
        credentials = Path(temporary) / 'credentials'
        credentials.write_text('username = '+USER+'\npassword = '+password()+'\n')
        credentials.chmod(0o600)
        for entry in metadata['folders']:
            result = subprocess.run(['smbclient', '//'+metadata['address']+'/'+entry['name'], '-A', str(credentials),
                                     '--client-protection=sign', '-m', 'SMB3', '-c', 'ls'], capture_output=True, text=True, timeout=10)
            # Do not emit directory contents or credentials in application logs.
            statuses = re.findall(r'NT_STATUS_[A-Z_]+', result.stdout + result.stderr)
            client_address = metadata['address'] if not ipaddress.ip_address(metadata['address']).is_loopback else 'host.lan'
            results.append({'name':entry['name'], 'ok':result.returncode == 0, 'windowsPath':'\\\\'+client_address+'\\'+entry['name'],
                            'message':'Authenticated SMB connection succeeded' if result.returncode == 0 else (statuses[-1] if statuses else 'SMB connection failed')})
    print(json.dumps(results))


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'configure':
            configure(sys.argv[2], sys.argv[3])
        elif sys.argv[1] == 'check':
            check()
        else:
            raise ValueError('Unknown SMB operation')
    except Exception as error:
        # CalledProcessError only contains program arguments; no stdin secrets.
        print('Shared folders: ' + str(error), file=sys.stderr)
        sys.exit(1)

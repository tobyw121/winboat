#!/usr/bin/env python3
"""Real signed SMB read/write checks in an isolated disposable Linux container.

Requires Samba, smbclient, passwd, and fixture mounts at /winboat-shares/Projects
(read/write) and /winboat-shares/Archive (read-only, initially empty). No Windows
VM or personal directories are used. The container must not publish SMB ports.
"""
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import tempfile
import time

source = Path(__file__).resolve().parents[1]
runtime = Path('/opt/winboat-shares')
if not runtime.exists():
    runtime.symlink_to(source / 'resources/shared-folders', target_is_directory=True)
assert (runtime / 'manage.py').read_bytes() == (source / 'resources/shared-folders/manage.py').read_bytes(), 'Mount the current shared-folder helpers at /opt/winboat-shares'
identity = Path('/winboat-shares/Projects').stat()
uid, gid = identity.st_uid, identity.st_gid
address = socket.gethostbyname(socket.gethostname())
entries = [{'name':'Projects','path':'/winboat-shares/Projects','readOnly':False},
           {'name':'Archive','path':'/winboat-shares/Archive','readOnly':True}]
environment = {**os.environ, 'WINBOAT_SHARED_FOLDERS':json.dumps(entries), 'PASSWORD':'fixture-only null $ password',
               'WINBOAT_SHARE_UID':str(uid),'WINBOAT_SHARE_GID':str(gid),'SAMBA':'Y','NETWORK':'bridge','DHCP':'N',
               # Dockur's VM_NET_IP belongs to Windows, not the SMB server.
               'VM_NET_IP':'192.0.2.123','VM_NET_BRIDGE':'eth0'}
original_modes = [stat.S_IMODE(Path(entry['path']).stat().st_mode) for entry in entries]
subprocess.run(['bash','-c','source "$1"','fixture',str(source/'resources/shared-folders/samba.sh')], env=environment, check=True)
try:
    with tempfile.TemporaryDirectory(prefix='wb-smb-fixture-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        credentials = root/'credentials'
        credentials.write_text('username = winboat\npassword = '+environment['PASSWORD']+'\n')
        credentials.chmod(0o600)
        def client(name, command, authentication=credentials):
            return subprocess.run(['smbclient','//'+address+'/'+name,'--client-protection=sign','-m','SMB3',
                                   '-A',str(authentication),'-c',command],capture_output=True,text=True,timeout=10)
        deadline = time.monotonic()+10
        while client('Projects','ls').returncode:
            if time.monotonic()>deadline:
                raise RuntimeError('The authenticated SMB server did not become ready')
            time.sleep(0.1)
        payload=root/'payload.txt';payload.write_text('SMB round-trip from Linux client\n')
        result=client('Projects',f'put {payload} written.txt')
        assert result.returncode==0, result.stderr
        written=Path('/winboat-shares/Projects/written.txt')
        assert written.read_bytes()==payload.read_bytes()
        assert (written.stat().st_uid,written.stat().st_gid)==(uid,gid), 'Host ownership was not preserved'
        downloaded=root/'downloaded.txt'
        assert client('Projects',f'get written.txt {downloaded}').returncode==0
        assert downloaded.read_bytes()==payload.read_bytes()
        assert client('Archive','ls').returncode==0, 'Empty read-only shares must work without chmod'
        assert client('Archive',f'put {payload} forbidden.txt').returncode!=0
        assert not Path('/winboat-shares/Archive/forbidden.txt').exists()
        wrong=root/'wrong';wrong.write_text('username = winboat\npassword = wrong-fixture\n');wrong.chmod(0o600)
        assert client('Projects','ls',wrong).returncode!=0, 'Invalid credentials were accepted'
        anonymous=subprocess.run(['smbclient','//'+address+'/Projects','-N','-c','ls'],capture_output=True,timeout=10)
        assert anonymous.returncode!=0, 'Guest access was accepted'
        probe=subprocess.run(['python3',str(source/'resources/shared-folders/manage.py'),'check'],env=environment,check=True,capture_output=True,text=True)
        results=json.loads(probe.stdout)
        assert len(results)==2 and all(result['ok'] for result in results),results
        assert all(result['windowsPath'].startswith('\\\\'+address+'\\') for result in results),results
        assert environment['PASSWORD'] not in probe.stdout and environment['PASSWORD'] not in probe.stderr
        assert original_modes==[stat.S_IMODE(Path(entry['path']).stat().st_mode) for entry in entries], 'Host directory permissions were changed'
        print('Real SMB3 signing, authentication, direct IP paths, empty read-only shares, write rejection, host UID/GID and upload/download round-trip passed.')
finally:
    subprocess.run(['smbcontrol','all','shutdown'],capture_output=True)

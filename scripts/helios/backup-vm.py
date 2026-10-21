#!/usr/bin/env python3
"""Offline, verified /storage backup. Restore only into a new directory; never boot."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path,PurePosixPath
import shutil
import stat
import subprocess
import tarfile
import tempfile

LIMIT=1024*1024

def inspect(container):
    return json.loads(subprocess.check_output(['docker','inspect',container],text=True,timeout=10))[0]

def identity(info):
    state=info['State']
    if state['Status']!='exited' or state.get('Running') or state.get('Paused') or state.get('Restarting'):
        raise ValueError('Stop Windows and this container cleanly before backup; no automatic stop is performed')
    if state.get('ExitCode') not in (0,None):raise ValueError('Previous container exit was not clean')
    return (info['Id'],state.get('StartedAt'),state.get('FinishedAt'))

def files(root):
    if root.is_symlink() or not root.is_dir():raise ValueError('Expected a regular storage directory')
    result=[]
    for folder,dirs,names in os.walk(root,followlinks=False):
        for name in dirs+names:
            path=Path(folder)/name;mode=path.lstat().st_mode
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):raise ValueError('Links and special files are not supported')
        for name in names:result.append(Path(folder)/name)
    if not result:raise ValueError('Storage is empty')
    return sorted(result)

def digest(stream):
    h=hashlib.sha256()
    for chunk in iter(lambda:stream.read(LIMIT),b''):h.update(chunk)
    return h.hexdigest()

def opened(path):
    return os.fdopen(os.open(path,os.O_RDONLY|os.O_NOFOLLOW),'rb')

def check_chain(path):
    with opened(path) as stream:header=stream.read(24)
    if header[:4]==b'QFI\xfb' and int.from_bytes(header[16:20],'big'):
        raise ValueError('QCOW2 backing chains require a separate complete-chain backup; no partial VM backup produced')

def create(container,output,observer=inspect):
    before=observer(container);token=identity(before)
    mounts=[m for m in before.get('Mounts',[]) if m.get('Destination')=='/storage']
    if len(mounts)!=1 or mounts[0].get('Type')!='bind':raise ValueError('This backup supports one bind-mounted /storage only')
    root=Path(mounts[0]['Source']);entries=files(root)
    env=before.get('Config',{}).get('Env',[])
    if any(e.startswith('ARGUMENTS=') and any(k in e for k in ('-drive','-blockdev')) for e in env):
        raise ValueError('External QEMU disk arguments require a complete external-disk backup')
    destination=output.parent.resolve()
    if destination==root.resolve() or destination.is_relative_to(root.resolve()):raise ValueError('Backup destination must be outside Windows storage')
    if output.exists() or output.is_symlink():raise ValueError('Backup destination already exists')
    size=sum(p.stat().st_size for p in entries)
    if shutil.disk_usage(destination).free<size+64*1024*1024:raise ValueError('Insufficient free space for an uncompressed full storage backup')
    for path in entries:check_chain(path)
    fd,tmp=tempfile.mkstemp(prefix='.winboat-backup-',dir=destination);os.close(fd)
    manifest={'schema':1,'imageId':before.get('Image'),'files':[],'scope':'Private offline storage and container description; shared host folders and external disks are not included'}
    try:
        with tarfile.open(tmp,'w') as archive:
            config=json.dumps({'Config':before.get('Config'),'HostConfig':before.get('HostConfig'),'Mounts':before.get('Mounts'),'Image':before.get('Image')}).encode()
            item=tarfile.TarInfo('container.json');item.size=len(config);item.mode=0o600;archive.addfile(item,io.BytesIO(config))
            manifest['files'].append({'name':'container.json','bytes':len(config),'sha256':hashlib.sha256(config).hexdigest()})
            for path in entries:
                if path.is_symlink():raise ValueError('Storage changed during backup')
                name='storage/'+path.relative_to(root).as_posix();first=path.stat()
                with opened(path) as stream:pin=digest(stream)
                with opened(path) as stream:
                    item=tarfile.TarInfo(name);item.size=first.st_size;item.mode=0o600;archive.addfile(item,stream)
                with opened(path) as stream:
                    if digest(stream)!=pin or path.stat().st_mtime_ns!=first.st_mtime_ns:raise ValueError('Storage changed during backup')
                manifest['files'].append({'name':name,'bytes':item.size,'sha256':pin})
            body=json.dumps(manifest).encode();item=tarfile.TarInfo('manifest.json');item.size=len(body);item.mode=0o600;archive.addfile(item,io.BytesIO(body))
        if identity(observer(container))!=token or files(root)!=entries:raise ValueError('Container or storage changed during backup')
        for row,path in zip(manifest['files'][1:],entries):
            with opened(path) as stream:
                if digest(stream)!=row['sha256']:raise ValueError('Storage changed during verification')
        verify(Path(tmp))
        if identity(observer(container))!=token:raise ValueError('Container changed during verification')
        with opened(tmp) as stream:os.fsync(stream.fileno())
        # Never overwrite an independently created destination in the meantime.
        os.link(tmp,output);os.unlink(tmp)
        return {'status':'verified','files':len(entries),'bytes':size}
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

def verify(path,restore=None):
    with tarfile.open(path,'r:') as archive:
        entries=[]
        for member in archive:
            entries.append(member)
            if len(entries)>100000:raise ValueError('Too many backup members')
        names=[m.name for m in entries]
        if len(names)>100000 or len(names)!=len(set(names)) or names.count('manifest.json')!=1:raise ValueError('Invalid backup members')
        for member in entries:
            parts=PurePosixPath(member.name).parts
            if str(PurePosixPath(member.name))!=member.name or not member.isfile() or member.name.startswith('/') or any(p in ('.','..') for p in parts) or '\\' in member.name:
                raise ValueError('Unsafe backup member')
            if member.name not in ('manifest.json','container.json') and (len(parts)<2 or parts[0]!='storage'):raise ValueError('Unknown backup member')
        meta=archive.getmember('manifest.json')
        if meta.size>16*1024*1024:raise ValueError('Backup manifest too large')
        manifest=json.load(archive.extractfile(meta))
        if len(manifest['files'])!=len({r['name'] for r in manifest['files']}):raise ValueError('Duplicate manifest row')
        if manifest.get('schema')!=1 or {r['name'] for r in manifest['files']}!=set(names)-{'manifest.json'}:raise ValueError('Incomplete backup manifest')
        for row in manifest['files']:
            member=archive.getmember(row['name'])
            if member.size!=row['bytes'] or digest(archive.extractfile(member))!=row['sha256']:raise ValueError('Backup checksum mismatch')
        if restore is not None:
            restore.mkdir(mode=0o700,parents=False,exist_ok=False)
            try:
                for row in manifest['files']:
                    if not row['name'].startswith('storage/'):continue
                    target=restore/Path(*PurePosixPath(row['name']).parts[1:]);target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
                    fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
                    with os.fdopen(fd,'wb') as out:shutil.copyfileobj(archive.extractfile(row['name']),out,LIMIT)
            except BaseException:
                # Keep a clearly incomplete new directory for inspection; never touch an existing VM.
                (restore/'RESTORE-INCOMPLETE').touch(mode=0o600);raise
    return {'status':'restored-new-directory' if restore is not None else 'verified','files':len(manifest['files'])-1}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--container',default='WinBoat')
    g=p.add_mutually_exclusive_group(required=True);g.add_argument('--create',type=Path);g.add_argument('--verify',type=Path)
    p.add_argument('--restore-to',type=Path);a=p.parse_args()
    try:
        if a.restore_to and not a.verify:raise ValueError('Restore requires a verified existing backup')
        print(json.dumps(create(a.container,a.create) if a.create else verify(a.verify,a.restore_to)))
    except (OSError,ValueError,KeyError,tarfile.TarError,subprocess.SubprocessError) as error:p.exit(1,str(error)+'\n')
if __name__=='__main__':main()

#!/usr/bin/env python3
"""Private offline VM checkpoints, with fenced restore and retained previous storage."""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import uuid

s=importlib.util.spec_from_file_location('backup',Path(__file__).with_name('backup-vm.py'));backup=importlib.util.module_from_spec(s);s.loader.exec_module(backup)
ID=re.compile(r'^[a-f0-9]{32}$')

def write(path,value):
    temporary=path.with_name('.'+uuid.uuid4().hex)
    try:
        fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'w') as out:json.dump(value,out);out.flush();os.fsync(out.fileno())
        os.replace(temporary,path)
    finally:
        if temporary.exists():temporary.unlink()

def storage(info,existing=True):
    rows=[m for m in info.get('Mounts',[]) if m.get('Destination')=='/storage']
    if len(rows)!=1 or rows[0].get('Type')!='bind':raise ValueError('One local bind-mounted /storage is required')
    root=Path(rows[0]['Source'])
    if root.is_symlink() or (existing and not root.is_dir()):raise ValueError('Storage must be a real directory')
    return root.resolve()

def fingerprint(root):return hashlib.sha256(str(root).encode()).hexdigest()

class Engine(http.client.HTTPConnection):
    def __init__(self,address):super().__init__('localhost',timeout=30);self.address=address
    def connect(self):self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);self.sock.settimeout(self.timeout);self.sock.connect(self.address)
    def call(self,method,path,data=None):
        self.request(method,path,body=json.dumps(data).encode() if data is not None else None,headers={'Content-Type':'application/json'})
        response=self.getresponse();body=response.read(1048577)
        if response.status==404:raise FileNotFoundError('Container absent')
        if len(body)>1048576 or response.status>=300:raise ValueError('Docker container operation failed; inspect the private restore transaction')
        return json.loads(body) if body else {}

def local_engine():
    value=os.environ.get('DOCKER_HOST')
    if not value:
        value=subprocess.check_output(['docker','context','inspect','--format','{{.Endpoints.docker.Host}}'],text=True,timeout=5).strip()
    if not value.startswith('unix:///'):raise ValueError('Snapshots require a local Unix Docker engine')
    return Engine(value[len('unix://'):])

def container_config(info):
    config=dict(info['Config']);config['Image']=info['Image'];config['HostConfig']=info['HostConfig']
    config['NetworkingConfig']={'EndpointsConfig':{name:{k:value[k] for k in ('Aliases','Links','IPAMConfig','DriverOpts') if value.get(k) is not None}
        for name,value in info.get('NetworkSettings',{}).get('Networks',{}).items()}}
    return config

class Snapshots:
    def __init__(self,root,observer=backup.inspect,engine=local_engine):self.root=root;self.observe=observer;self.engine=engine
    @contextlib.contextmanager
    def locked(self):
        self.root.mkdir(mode=0o700,parents=True,exist_ok=True)
        info=self.root.lstat()
        if not self.root.is_dir() or self.root.is_symlink() or info.st_uid!=os.getuid() or info.st_mode&0o077:raise ValueError('Snapshot directory must be private and owned by this user')
        fd=os.open(self.root/'manager.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
        try:fcntl.flock(fd,fcntl.LOCK_EX);yield
        finally:os.close(fd)
    def paths(self,key):
        if not ID.fullmatch(key):raise ValueError('Invalid snapshot identity')
        return self.root/(key+'.tar'),self.root/(key+'.json')
    def read(self,key):
        archive,receipt=self.paths(key)
        if receipt.is_symlink() or receipt.stat().st_size>8192 or archive.is_symlink():raise ValueError('Invalid snapshot record')
        value=json.loads(receipt.read_text())
        if value.get('id')!=key or value.get('schema')!=1:raise ValueError('Invalid snapshot record')
        return value
    def list(self):
        rows=[]
        for path in sorted(self.root.glob('*.json')):
            if ID.fullmatch(path.stem):rows.append(self.read(path.stem))
            if len(rows)>1000:raise ValueError('Too many snapshot records')
        return rows
    def create(self,container,label):
        if not 1<=len(label)<=80 or any(ord(c)<32 for c in label):raise ValueError('Use a label of 1..80 printable characters')
        info=self.observe(container);backup.identity(info);root=storage(info);key=uuid.uuid4().hex
        archive,receipt=self.paths(key);backup.create(container,archive,self.observe)
        value={'schema':1,'id':key,'label':label,'createdAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'storageIdentity':fingerprint(root),'imageId':info['Image'],'kind':'offline-storage','archiveBytes':archive.stat().st_size}
        write(receipt,value);return value
    def delete(self,key):
        self.read(key)
        for path in self.paths(key):path.unlink()
        return {'status':'deleted','id':key}
    def restore(self,container,key):
        saved=self.read(key);info=self.observe(container);token=backup.identity(info);root=storage(info)
        if fingerprint(root)!=saved['storageIdentity'] or info['Image']!=saved['imageId']:raise ValueError('Restore requires the same storage identity and host image; use alternate-directory backup restore for a migrated VM')
        active=self.root/'restore-transaction.json'
        if active.exists() and json.loads(active.read_text()).get('status') not in ('completed','rolled-back'):raise ValueError('Resolve the saved restore transaction first')
        stage=root.with_name('.winboat-restore-'+uuid.uuid4().hex);previous=root.with_name(root.name+'.before-'+uuid.uuid4().hex)
        archive,_=self.paths(key);backup.verify(archive,stage)
        if backup.identity(self.observe(container))!=token:raise ValueError('Container changed while preparing restore; existing storage untouched')
        name=info['Name'].lstrip('/')
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}',name):raise ValueError('Invalid container name')
        transaction={'schema':1,'status':'prepared','container':info,'root':str(root),'stage':str(stage),'previous':str(previous),'snapshot':key}
        write(active,transaction);engine=self.engine();removed=False;swapped=False
        try:
            # No force: if somebody starts the old container concurrently, removal fails.
            # Once removed, it cannot be restarted under its old ID while paths move.
            engine.call('DELETE','/containers/'+info['Id']);removed=True
            transaction['status']='container-fenced';write(active,transaction)
            os.rename(root,previous)
            try:os.rename(stage,root)
            except BaseException:os.rename(previous,root);raise
            swapped=True;transaction['status']='storage-replaced';write(active,transaction)
            config=container_config(info);config['Labels']={**(config.get('Labels') or {}),'org.winboat.restore':key}
            result=engine.call('POST','/containers/create?name='+name,config)
            transaction['status']='completed';transaction['newContainerId']=result['Id'];write(active,transaction)
            return {'status':'restored-stopped','id':key,'previousStorage':str(previous),'containerId':result['Id']}
        except Exception:
            if removed:
                try:
                    try:created=engine.call('GET','/containers/'+name+'/json')
                    except FileNotFoundError:created=None
                    if created is not None:
                        transaction['status']='manual-recovery-required';write(active,transaction)
                        raise ValueError('Container creation outcome uncertain; no storage rollback attempted')
                    if swapped:os.rename(root,stage);os.rename(previous,root)
                    engine.call('POST','/containers/create?name='+name,container_config(info))
                    transaction['status']='rolled-back';write(active,transaction)
                except Exception:transaction['status']='manual-recovery-required';write(active,transaction)
            raise
        finally:engine.close()

    def recover(self):
        path=self.root/'restore-transaction.json'
        if path.is_symlink() or path.stat().st_size>1048576:raise ValueError('Invalid restore journal')
        transaction=json.loads(path.read_text());info=transaction['container'];root=storage(info,existing=False)
        if transaction['root']!=str(root):raise ValueError('Restore journal storage mismatch')
        engine=self.engine();name=info['Name'].lstrip('/')
        try:
            try:current=engine.call('GET','/containers/'+name+'/json')
            except FileNotFoundError:current=None
            if current is not None:
                if current['Id']==info['Id'] and transaction['status']=='prepared':transaction['status']='rolled-back'
                elif current['Config'].get('Labels',{}).get('org.winboat.restore')==transaction['snapshot'] and current['Image']==info['Image']:transaction['status']='completed'
                else:raise ValueError('Another container owns this name; no recovery changes performed')
            else:
                previous=Path(transaction['previous']);stage=Path(transaction['stage'])
                if previous.parent!=root.parent or stage.parent!=root.parent or not previous.name.startswith(root.name+'.before-') or not stage.name.startswith('.winboat-restore-'):raise ValueError('Invalid recovery paths')
                if previous.is_symlink() or stage.is_symlink():raise ValueError('Recovery path is a symlink')
                if previous.exists():
                    if root.exists():
                        if stage.exists():raise ValueError('Both candidate paths exist; inspect recovery journal')
                        os.rename(root,stage)
                    os.rename(previous,root)
                if not root.is_dir():raise ValueError('Original storage unavailable')
                engine.call('POST','/containers/create?name='+name,container_config(info));transaction['status']='rolled-back'
            write(path,transaction);return {'status':transaction['status']}
        finally:engine.close()

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=('list','create','restore','delete','recover'))
    p.add_argument('--container',default='WinBoat');p.add_argument('--root',type=Path,default=Path.home()/'.winboat/snapshots')
    p.add_argument('--label',default='Before changes');p.add_argument('--id');a=p.parse_args()
    try:
        manager=Snapshots(a.root)
        with manager.locked():
            if a.action=='list':result=manager.list()
            elif a.action=='create':local_engine().close();result=manager.create(a.container,a.label)
            elif a.action=='recover':result=manager.recover()
            elif a.action=='delete':result=manager.delete(a.id or '')
            else:result=manager.restore(a.container,a.id or '')
        print(json.dumps(result))
    except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError,http.client.HTTPException) as e:p.exit(1,str(e)+'\n')
if __name__=='__main__':main()

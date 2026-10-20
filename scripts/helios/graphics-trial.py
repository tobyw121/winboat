#!/usr/bin/env python3
"""Explicit 60-second trial of the installed Helios device; independent host watchdog."""
import argparse
import contextlib
import fcntl
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

spec=importlib.util.spec_from_file_location('rescue',Path(__file__).with_name('rescue-graphics.py'))
rescue=importlib.util.module_from_spec(spec);spec.loader.exec_module(rescue)
ACTIVE={'armed','enabled','recovering'}
def clock():return time.clock_gettime(time.CLOCK_BOOTTIME)
def boot():return Path('/proc/sys/kernel/random/boot_id').read_text().strip()
class Store:
    def __init__(self,root):self.root=root
    @contextlib.contextmanager
    def locked(self, name='trial.lock'):
        for path in reversed((self.root,*self.root.parents)):
            if path.is_symlink():raise ValueError('Recovery directory is a symlink')
        self.root.mkdir(parents=True,mode=0o700,exist_ok=True)
        if self.root.stat().st_uid!=os.getuid() or self.root.stat().st_mode&0o077:raise ValueError('Recovery directory must be private')
        fd=os.open(self.root/name,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
        try:
            self.private(fd);fcntl.flock(fd,fcntl.LOCK_EX);yield
        finally:os.close(fd)
    @staticmethod
    def private(fd):
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077 or info.st_nlink!=1 or info.st_size>32768:
            raise ValueError('Recovery file must be a private regular file')
    def read(self):
        try:fd=os.open(self.root/'trial.json',os.O_RDONLY|os.O_NOFOLLOW)
        except FileNotFoundError:return {'phase':'none'}
        with os.fdopen(fd) as stream:
            self.private(stream.fileno());state=json.load(stream)
        if (state.get('schema')!=1 or not re.fullmatch(r'[a-f0-9]{32}',str(state.get('id'))) or
            not re.fullmatch(r'[a-f0-9]{64}',str(state.get('containerId'))) or
            type(state.get('deadline')) not in (int,float) or not math.isfinite(state['deadline'])):
            raise ValueError('Invalid trial state')
        return state
    def write(self,state):
        fd,path=tempfile.mkstemp(dir=self.root,prefix='trial-',suffix='.tmp')
        try:
            with os.fdopen(fd,'w') as stream:json.dump(state,stream)
            os.replace(path,self.root/'trial.json')
        finally:
            if os.path.exists(path):os.unlink(path)
    def change(self,token,**fields):
        with self.locked():
            state=self.read()
            if state.get('id')!=token:raise ValueError('Trial identity changed')
            state.update(fields);self.write(state);return state

def container_id(container):
    value=rescue.docker_json('inspect',container)[0]['Id']
    if not re.fullmatch(r'[a-f0-9]{64}',value):raise ValueError('Invalid container identity')
    return value

def adapters(container):
    port=subprocess.check_output(['docker','port',container,'7148/tcp'],text=True,timeout=5).splitlines()
    number=int(port[0].rsplit(':',1)[1]) if port else 0
    if not 1<=number<=65535:raise ValueError('Guest API unavailable')
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),rescue.NoRedirect())
    with opener.open(f'http://127.0.0.1:{number}/graphics/adapters',timeout=3) as response:
        raw=response.read(65537)
        if len(raw)>65536:raise ValueError('Adapter response too large')
        return json.loads(raw)

def healthy(data,enabled):
    desktop=data.get('desktop',{});basic=data.get('basic',{});helios=data.get('helios',{})
    age=data.get('sampleAgeMs')
    return (type(age) is int and 0<=age<=10000 and basic.get('state')=='running' and
            desktop.get('managed') is True and desktop.get('basic',{}).get('state')=='active' and
            desktop.get('basic',{}).get('primary') is True and
            helios.get('state')==('running' if enabled else 'disabled') and
            (not enabled or desktop.get('helios',{}).get('state')=='active'))

def recover(store,token,action=rescue.guest_action,host=rescue.host_action,identify=container_id):
    # Serialize hardware operations separately from state/confirmation commands.
    with store.locked('action.lock'):
        with store.locked():
            state=store.read()
            if state.get('id')!=token or state.get('phase') not in ACTIVE:return state
            state['phase']='recovering';store.write(state)
        try:
            if identify(state['container'])!=state['containerId']:raise ValueError('Container changed')
            try:result=action(state['containerId'],'helios-disable',timeout=6)
            except Exception:result={'status':'unavailable'}
            route='guest'
            if result.get('status') not in {'disabled','held'}:
                host(state['containerId'],False);route='vga-only-host'
            return store.change(token,phase='recovery-requested',route=route)
        except Exception:return store.change(token,phase='recovery-failed')

def watch(store,token,now=clock,sleeper=time.sleep,action=rescue.guest_action,probe=adapters,identify=container_id,restore=recover):
    try:
        with store.locked('action.lock'):
            with store.locked():state=store.read()
            if state.get('id')!=token or state['phase']!='armed':return
            if state.get('command')=='cancel':raise ValueError('Cancelled')
            if now()>=state['deadline'] or state['boot']!=boot() or identify(state['container'])!=state['containerId']:raise ValueError('Trial binding changed')
            result=action(state['containerId'],'helios-enable',timeout=6)
            if result.get('status')!='enabled':raise ValueError('Enable was refused')
            store.change(token,phase='enabled')
        while True:
            with store.locked():state=store.read()
            if state.get('id')!=token or state.get('phase')!='enabled':return
            if now()>=state['deadline'] or state['boot']!=boot() or state.get('command')=='cancel':break
            if state.get('command')=='keep':
                if identify(state['container'])!=state['containerId'] or not healthy(probe(state['containerId']),True):break
                with store.locked():
                    current=store.read()
                    if current.get('id')==token and current.get('phase')=='enabled' and current.get('command')=='keep' and now()<current['deadline']:
                        current['phase']='confirmed';store.write(current);return
                break
            sleeper(.5)
    except Exception:pass
    restore(store,token)

def begin(store,container,spawn=subprocess.Popen,probe=adapters,identify=container_id):
    identity=identify(container)
    if not healthy(probe(identity),False):raise ValueError('Trial requires disabled Helios and fresh healthy primary VGA')
    with store.locked():
        old=store.read()
        if old.get('phase') in ACTIVE:raise ValueError('Previous trial is unresolved; cancel it first')
        state={'schema':1,'id':uuid.uuid4().hex,'container':container,'containerId':identity,
               'phase':'armed','deadline':clock()+60,'boot':boot(),'command':''}
        store.write(state)
        try:
            spawn([sys.executable,str(Path(__file__).resolve()),'--watch',state['id']],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
        except Exception:
            state['phase']='watchdog-failed';store.write(state);raise
    return state

def command(store,token,operation):
    with store.locked():
        state=store.read()
        if state.get('id')!=token:raise ValueError('Unknown trial')
        if state.get('phase') not in {'armed','enabled','recovering'}:raise ValueError('Trial is no longer active')
        if operation=='keep':
            if state.get('phase')!='enabled' or state.get('boot')!=boot() or not math.isfinite(state['deadline']) or clock()>=state['deadline']:raise ValueError('Trial cannot be confirmed')
        state['command']=operation;store.write(state)
    return state

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container',default='WinBoat')
    modes=parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--start',action='store_true');modes.add_argument('--watch');modes.add_argument('--status');modes.add_argument('--confirm');modes.add_argument('--cancel')
    args=parser.parse_args();store=Store(Path.home()/'.winboat/recovery/graphics-trial')
    try:
        token=args.watch or args.status or args.confirm or args.cancel
        if token and not re.fullmatch(r'[a-f0-9]{32}',token):raise ValueError('Invalid trial identity')
        if args.start:state=begin(store,args.container)
        elif args.watch:watch(store,token);return
        elif args.confirm:state=command(store,token,'keep')
        elif args.cancel:command(store,token,'cancel');state=recover(store,token)
        else:
            with store.locked():state=store.read()
            if state.get('id')!=token:raise ValueError('Unknown trial')
        print(json.dumps({key:state.get(key) for key in ('id','phase','route')}))
    except (OSError,ValueError,KeyError,subprocess.SubprocessError) as error:parser.exit(1,str(error)+'\n')
if __name__=='__main__':main()

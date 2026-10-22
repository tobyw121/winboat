#!/usr/bin/env python3
"""Durable host-side configuration trial. Never touches VM disks or Docker volumes."""
import argparse,fcntl,hashlib,json,os,stat,subprocess,time,uuid
from pathlib import Path

def private(directory):
 directory.mkdir(mode=0o700,parents=True,exist_ok=True)
 st=directory.lstat()
 if not stat.S_ISDIR(st.st_mode) or st.st_uid!=os.getuid() or st.st_mode&0o077:raise ValueError('Private owned trial directory required')

def write(path,value):
 tmp=path.with_suffix('.tmp')
 fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
 with os.fdopen(fd,'w') as out:json.dump(value,out);out.flush();os.fsync(out.fileno())
 os.replace(tmp,path)
 directory=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
 try:os.fsync(directory)
 finally:os.close(directory)

def public(state):return {k:v for k,v in state.items() if k!='previous'}

def digest(data):return hashlib.sha256(data).hexdigest()
def read(path):
 fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
 with os.fdopen(fd,'rb') as stream:
  if os.fstat(stream.fileno()).st_size>1048576:raise ValueError('Configuration too large')
  return stream.read()

def restart_ready():
 result=subprocess.run(['docker','inspect','--format','{{json .State.Running}}\n{{json .Config.Env}}','WinBoat'],capture_output=True,text=True,timeout=5)
 if result.returncode!=0:
  listing=subprocess.run(['docker','container','ls','--all','--filter','name=^/WinBoat$','--format','{{.Names}}'],capture_output=True,text=True,timeout=5,check=True)
  if not listing.stdout.strip():return True
  raise ValueError('Cannot verify container state before automatic rollback')
 rows=result.stdout.splitlines()
 if not json.loads(rows[0]):return True
 env=json.loads(rows[1])
 if 'HELIOS_AGENT_CHANNEL=1' not in env:return True
 busy=subprocess.run(['docker','exec','WinBoat','python3','/opt/helios/live-backup.py','busy'],capture_output=True,text=True,timeout=5,check=True)
 return json.loads(busy.stdout).get('state')=='idle'

def transition(root,action,compose=None,expected=None,seconds=300,clock=time.time,run=subprocess.run,restart_safe=restart_ready):
 private(root)
 with (root/'lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  record=root/'state.json';state=json.loads(read(record)) if record.exists() else {'status':'none'}
  if action=='status':return public(state)
  if action=='begin':
   if state['status'] in ('pending','restoring','restore-failed','conflict'):raise ValueError('Confirm or recover the existing configuration trial first')
   if not expected or len(expected)!=64 or any(c not in '0123456789abcdef' for c in expected):raise ValueError('Expected configuration SHA-256 required')
   if not 30<=seconds<=900:raise ValueError('Trial timeout must be 30..900 seconds')
   compose=compose.resolve(strict=True);old=read(compose)
   state={'schema':1,'status':'pending','compose':str(compose),'previous':old.decode(),'previousSha256':digest(old),'expectedSha256':expected,'deadline':clock()+seconds}
   write(record,state)
  elif action=='accept-external':
   if state['status']!='conflict':raise ValueError('No conflicting external configuration to accept')
   write(root/('conflict-'+uuid.uuid4().hex+'.json'),state)
   state['status']='external-accepted';state.pop('previous',None);write(record,state)
  elif action=='confirm':
   if state['status']!='pending' or clock()>=state['deadline']:raise ValueError('Trial expired or not pending')
   if digest(read(Path(state['compose'])))!=state['expectedSha256']:raise ValueError('Configuration changed outside this trial')
   state['status']='confirmed';state.pop('previous',None);write(record,state)
  elif action in ('recover','expire'):
   if state['status'] not in ('pending','restoring','restore-failed'):return public(state)
   if action=='expire' and clock()<state['deadline']:return public(state)
   path=Path(state['compose']);current=read(path);sha=digest(current)
   if sha not in (state['expectedSha256'],state['previousSha256']):
    state['status']='conflict';write(record,state);raise ValueError('Unrelated configuration detected; automatic replacement refused. Saved configuration retained.')
   if not restart_safe():
    if action=='recover':raise ValueError('Wait for the active live export/VSS operation to finish before rollback')
    return {**public(state),'deferred':'live-export'}
   state['status']='restoring';write(record,state)
   # Stop the trial container without deleting volumes; atomically restore compose.
   try:
    run(['docker','compose','-f',str(path),'down'],check=True,timeout=120,capture_output=True)
    tmp=path.with_name(path.name+'.rollback-'+uuid.uuid4().hex);fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as out:out.write(state['previous']);out.flush();os.fsync(out.fileno())
    os.replace(tmp,path)
    run(['docker','compose','-f',str(path),'up','-d'],check=True,timeout=180,capture_output=True)
    state['status']='restored';state.pop('previous',None)
   except Exception:
    state['status']='restore-failed';write(record,state);raise
   write(record,state)
  else:raise ValueError('Unknown action')
  return public(state)

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=('begin','status','confirm','recover','watch','accept-external'));p.add_argument('--root',type=Path,default=Path.home()/'.winboat'/'ConfigTrial');p.add_argument('--compose',type=Path);p.add_argument('--expected');p.add_argument('--seconds',type=int,default=300);a=p.parse_args()
 try:
  if a.action=='watch':
   while True:
    result=transition(a.root,'expire')
    if result['status']!='pending':break
    time.sleep(2)
  else:
   result=transition(a.root,a.action,a.compose,a.expected,a.seconds)
   if a.action=='status' and result['status']=='pending' and time.time()>=result['deadline']:result=transition(a.root,'expire')
  print(json.dumps(result))
 except (OSError,ValueError,subprocess.SubprocessError) as e:p.exit(1,str(e)+'\n')
if __name__=='__main__':main()

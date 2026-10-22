#!/usr/bin/env python3
"""Local QGA/VSS + QMP full disk export; detached worker owns freeze/thaw cleanup."""
import argparse,datetime,fcntl,hashlib,json,os,re,socket,time,uuid,signal,subprocess,shutil
from pathlib import Path
QMP='/run/winboat-maintenance-qmp';QGA='/run/winboat-qga'
class RPC:
 def __init__(self,path,qmp=False):
  self.socket=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);self.socket.settimeout(8);self.socket.connect(path);self.file=self.socket.makefile('rb');self.qmp=qmp;self.serial=0
  if qmp:
   if 'QMP' not in self.read():raise ValueError('Invalid QMP greeting')
   self.call('qmp_capabilities')
  else:
   # Flush any stale guest-agent partial response before trusting this connection.
   token=uuid.uuid4().int&((1<<52)-1)
   self.socket.sendall(b'\xff'+json.dumps({'execute':'guest-sync-delimited','arguments':{'id':token}}).encode()+b'\n')
   if self.read().get('return')!=token:raise ValueError('Guest agent synchronization failed')
 def read(self):
  line=self.file.readline(1048577).lstrip(b'\xff')
  if not line or len(line)>1048576:raise ValueError('Agent response unavailable or oversized')
  return json.loads(line)
 def call(self,name,args=None):
  self.serial+=1;identity=self.serial
  self.socket.sendall(json.dumps({'execute':name,'id':identity,**({'arguments':args} if args is not None else {})}).encode()+b'\n')
  while True:
   value=self.read()
   if 'event' in value:continue
   if (self.qmp or 'id' in value) and value.get('id')!=identity:continue
   if 'error' in value:raise ValueError('Agent operation rejected: '+name+': '+str(value['error'].get('desc','unknown'))[:256])
   if 'return' in value:return value['return']
 def close(self):self.file.close();self.socket.close()
def readiness(agent):
 info=agent.call('guest-info');commands={c['name'] for c in info.get('supported_commands',[]) if c.get('enabled')}
 if not {'guest-fsfreeze-freeze','guest-fsfreeze-thaw','guest-fsfreeze-status','guest-get-osinfo'}<=commands:raise ValueError('QGA freeze/thaw and OS inspection required')
 osinfo=agent.call('guest-get-osinfo')
 if 'windows' not in (str(osinfo.get('name',''))+' '+str(osinfo.get('id',''))).lower():raise ValueError('Windows QGA with VSS support required')
 if agent.call('guest-fsfreeze-status')!='thawed':raise ValueError('Guest filesystem already frozen; inspect before starting another backup')
 return {'state':'ready','scope':'VSS is verified by a successful freeze when exporting; no freeze performed by this check'}
def atomic(path,value):
 temporary=path.with_suffix('.tmp');fd=os.open(temporary,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
 owner=path.parent.stat();os.fchown(fd,owner.st_uid,owner.st_gid)
 try:
  with os.fdopen(fd,'w') as out:json.dump(value,out);out.flush();os.fsync(out.fileno())
  os.replace(temporary,path)
 finally:
  if temporary.exists():temporary.unlink()
def export(qmp,agent,root,clock=time.monotonic,pause=time.sleep,create_target=None):
 readiness(agent)
 if qmp.call('query-status').get('status')!='running':raise ValueError('VM must be running')
 disks=[]
 for block in qmp.call('query-block'):
  data=block.get('inserted',{})
  if block.get('removable') or data.get('ro'):continue
  source=data.get('file','');node=data.get('node-name')
  if not node or not source.startswith('/storage/') or '..' in Path(source).parts:raise ValueError('Only local /storage block nodes are supported')
  size=data.get('image',{}).get('virtual-size')
  if type(size) is not int or not 0<size<2**63:raise ValueError('Disk virtual size unavailable')
  disks.append({'node':node,'source':source,'bytes':size,'targetNode':'wb-target-'+root.name+'-'+str(len(disks)),'target':str(root/('disk-'+str(len(disks))+'.qcow2'))})
 if not disks or len(disks)>8:raise ValueError('Expected 1..8 writable disks including writable firmware nodes')
 if shutil.disk_usage(root).free<sum(d['bytes'] for d in disks)+67108864:raise ValueError('Not enough space for a complete disk export')
 started=[];created=[];state={'schema':1,'status':'preparing','disks':disks,'scope':'Live disk export, no RAM/GPU state. Restore offline with the recorded block mapping.'};atomic(root/'status.json',state)
 def kickoff():
  frozen=False;paused=False
  try:
   # Mark before the request: a lost freeze response still requires thaw.
   frozen=True;count=agent.call('guest-fsfreeze-freeze')
   if type(count) is not int or count<1:raise ValueError('Windows did not confirm VSS freeze')
   freeze_started=clock();paused=True;qmp.call('stop')
   if clock()-freeze_started>5:raise ValueError('VSS snapshot start exceeded freeze window')
   actions=[]
   for i,disk in enumerate(disks):
    job='wb-backup-'+root.name+'-'+str(i);started.append(job)
    actions.append({'type':'blockdev-backup','data':{'device':disk['node'],'job-id':job,'target':disk['targetNode'],'sync':'full','auto-dismiss':False}})
   qmp.call('transaction',{'actions':actions})
   if clock()-freeze_started>8:raise ValueError('VSS snapshot transaction exceeded freeze window')
  finally:
   cleanup=[]
   if paused:
    try:qmp.call('cont')
    except Exception:cleanup.append('VM resume failed')
   if frozen:
    for attempt in range(3):
     try:
      agent.call('guest-fsfreeze-thaw')
      if agent.call('guest-fsfreeze-status')!='thawed':raise ValueError('Thaw not confirmed')
      break
     except Exception:
      if attempt==2:cleanup.append('VSS thaw failed; run explicit thaw recovery')
      else:pause(.5)
   if cleanup:raise ValueError('; '.join(cleanup))
 try:
  for disk in disks:
   if create_target:create_target(disk)
   else:subprocess.run(['/opt/helios/qemu/bin/qemu-img','create','-q','-f','qcow2',disk['target'],str(disk['bytes'])],check=True,timeout=20)
   created.append(disk['targetNode']);qmp.call('blockdev-add',{'driver':'qcow2','node-name':disk['targetNode'],'file':{'driver':'file','filename':disk['target']}})
  kickoff();state['status']='copying';atomic(root/'status.json',state)
  deadline=clock()+86400
  while True:
   rows={r['id']:r for r in qmp.call('query-jobs')};done=True
   for job in started:
    row=rows.get(job)
    if row is None:raise ValueError('Backup job disappeared without completion evidence')
    if row.get('error'):raise ValueError('Backup job failed')
    if row.get('status')!='concluded':done=False
   if done:break
   if clock()>deadline:raise ValueError('Backup job timed out')
   pause(1)
  for job in started:qmp.call('job-dismiss',{'id':job})
  for node in list(created):qmp.call('blockdev-del',{'node-name':node});created.remove(node)
  state['status']='hashing';atomic(root/'status.json',state)
  for disk in disks:
   digest=hashlib.sha256()
   with open(disk['target'],'rb') as stream:
    for chunk in iter(lambda:stream.read(1048576),b''):digest.update(chunk)
   disk['sha256']=digest.hexdigest();owner=root.stat();os.chown(disk['target'],owner.st_uid,owner.st_gid);os.chmod(disk['target'],0o600)
  state['status']='completed';state['finishedAtUtc']=datetime.datetime.now(datetime.timezone.utc).isoformat();atomic(root/'status.json',state);return state
 except Exception:
  for job in started:
   try:qmp.call('job-cancel',{'id':job})
   except Exception:pass
  for attempt in range(5):
   try:
    active={j['id']:j for j in qmp.call('query-jobs')}
    for job in started:
     if active.get(job,{}).get('status')=='concluded':qmp.call('job-dismiss',{'id':job})
    for node in list(created):
     try:qmp.call('blockdev-del',{'node-name':node});created.remove(node)
     except Exception:pass
    if not created:break
    pause(.2)
   except Exception:pause(.2)
  raise

def main():
 def interrupted(*_):raise InterruptedError('Backup interrupted')
 for number in (signal.SIGINT,signal.SIGTERM):signal.signal(number,interrupted)
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=('check','export','status','thaw','busy'));p.add_argument('--id');a=p.parse_args();qmp=agent=None;root=None
 try:
  if a.action in ('export','status'):
   if not re.fullmatch(r'[a-f0-9]{32}',a.id or ''):raise ValueError('Invalid backup identity')
   base=Path('/backup')
   if base.is_symlink() or not base.is_mount():raise ValueError('Dedicated /backup bind mount required')
   candidate=base/a.id
   if candidate.is_symlink():raise ValueError('Invalid backup directory')
   if a.action=='status':
    record=candidate/'status.json'
    if record.is_symlink() or record.stat().st_size>1048576:raise ValueError('Invalid backup status')
    print(record.read_text());return
   candidate.mkdir(mode=0o700);owner=base.stat();os.chown(candidate,owner.st_uid,owner.st_gid);root=candidate
  lock=os.open('/run/winboat-live-backup.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
  if a.action=='busy':
   try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);state='idle'
   except BlockingIOError:state='active'
   print(json.dumps({'state':state}));return
  fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  agent=RPC(QGA)
  if a.action=='check':result=readiness(agent)
  elif a.action=='thaw':result={'thawed':agent.call('guest-fsfreeze-thaw')}
  else:qmp=RPC(QMP,True);result=export(qmp,agent,root)
  print(json.dumps(result))
 except Exception as e:
  if root and root.is_dir() and a.action=='export':atomic(root/'status.json',{'status':'failed','error':str(e),'scope':'Incomplete export must not be used as a completed backup'})
  p.exit(1,str(e)+'\n')
 finally:
  for connection in (qmp,agent):
   if connection:connection.close()
if __name__=='__main__':main()

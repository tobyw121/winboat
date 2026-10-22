#!/usr/bin/env python3
"""Backup capacity, scheduled offline checkpoints and verified live-export staging."""
import argparse,datetime,hashlib,json,os,re,shutil,subprocess,uuid
from pathlib import Path
import importlib.util

def load(name):
 s=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'));m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m

def inventory(root):
 load('config-trial').private(root)
 result=[]
 for p in sorted(root.iterdir()):
  if p.is_symlink():continue
  if p.is_dir() and re.fullmatch('[a-f0-9]{32}',p.name):
   try:r=json.loads(load('config-trial').read(p/'status.json'))
   except (OSError,ValueError):continue
   result.append({'id':p.name,'status':r.get('status'),'finishedAtUtc':r.get('finishedAtUtc'),'bytes':sum(x.stat().st_size for x in p.iterdir() if x.is_file() and not x.is_symlink())})
 return {'freeBytes':shutil.disk_usage(root).free,'exports':result,'scope':'No automatic deletion of live exports. Failed/incomplete exports remain distinct.'}

def verify(root,key):
 if not re.fullmatch('[a-f0-9]{32}',key or ''):raise ValueError('Invalid export identity')
 load('config-trial').private(root);folder=root/key
 if folder.is_symlink() or not folder.is_dir() or folder.stat().st_uid!=os.getuid() or folder.stat().st_mode&0o077:raise ValueError('Invalid export directory')
 state=json.loads(load('config-trial').read(folder/'status.json'))
 if state.get('schema')!=1 or state.get('status')!='completed':raise ValueError('Only completed exports can be verified or staged')
 disks=state.get('disks',[])
 if not 1<=len(disks)<=8:raise ValueError('Invalid disk mapping')
 seen=set()
 for i,d in enumerate(disks):
  if d.get('target')!=f'/backup/{key}/disk-{i}.qcow2':raise ValueError('Unexpected export target mapping')
  source=d.get('source','');relative=Path(source).relative_to('/storage')
  if not relative.parts or '..' in relative.parts or source in seen:raise ValueError('Invalid source mapping')
  seen.add(source);file=folder/f'disk-{i}.qcow2'
  if file.is_symlink() or not file.is_file():raise ValueError('Export disk must be a regular file')
  with file.open('rb') as stream:h=hashlib.file_digest(stream,'sha256').hexdigest()
  if h!=d.get('sha256'):raise ValueError('Export checksum mismatch')
 return {'state':'verified','id':key,'disks':disks,'scope':'Disk bytes verified. TPM/RAM/shared folders are absent; this is not complete-machine recovery.'}

def stage(root,key,parent,run=subprocess.run):
 report=verify(root,key);record=json.loads(load('config-trial').read(root/(key+'.container.json')))
 image=record.get('Image','')
 if not re.fullmatch('sha256:[a-f0-9]{64}',image):raise ValueError('Pinned host image identity required')
 if any(d.get('sourceFormat') not in ('raw','qcow2') or type(d.get('bytes')) is not int or d['bytes']<=0 for d in report['disks']):raise ValueError('Export lacks original disk format/size metadata; do not guess a restore format')
 parent=parent.resolve(strict=True)
 if shutil.disk_usage(parent).free<sum(d['bytes'] for d in report['disks'])+67108864:raise ValueError('Not enough space to stage complete restored disks')
 destination=parent/('WinBoatRestore-'+uuid.uuid4().hex);destination.mkdir(mode=0o700)
 source=(root/key).resolve()
 if any(',' in str(p) for p in (source,destination)):raise ValueError('Docker staging mount paths cannot contain commas')
 base=['docker','run','--rm','--network','none','--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--user',f'{os.getuid()}:{os.getgid()}','--mount',f'type=bind,src={source},dst=/input,readonly','--mount',f'type=bind,src={destination},dst=/output','--entrypoint','/opt/helios/qemu/bin/qemu-img',image]
 plan={'schema':1,'status':'preparing','image':image,'exportId':key,'directory':str(destination),'bootBlocked':True,'missing':['TPM state','RAM state','shared folders'],'disks':[]}
 writer=load('config-trial').write;writer(destination/'restore-plan.json',plan)
 try:
  for i,d in enumerate(report['disks']):
   rel=Path(d['source']).relative_to('/storage');out=destination/rel;out.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
   info=run(base+['info','--output=json',f'/input/disk-{i}.qcow2'],capture_output=True,text=True,check=True,timeout=30)
   metadata=json.loads(info.stdout)
   if metadata.get('backing-filename') or metadata.get('format')!='qcow2' or metadata.get('virtual-size')!=d['bytes']:raise ValueError('Export has a backing chain or mismatched image metadata')
   run(base+['check',f'/input/disk-{i}.qcow2'],capture_output=True,check=True,timeout=3600)
   run(base+['convert','-f','qcow2','-O',d['sourceFormat'],f'/input/disk-{i}.qcow2','/output/'+str(rel)],capture_output=True,check=True,timeout=86400)
   run(base+['compare','-f','qcow2','-F',d['sourceFormat'],f'/input/disk-{i}.qcow2','/output/'+str(rel)],capture_output=True,check=True,timeout=86400)
   os.chmod(out,0o600);plan['disks'].append({'source':d['source'],'format':d['sourceFormat'],'path':str(rel),'compared':True})
  plan['status']='staged-not-bootable';writer(destination/'restore-plan.json',plan);return plan
 except Exception:
  plan['status']='failed';writer(destination/'restore-plan.json',plan);raise

def scheduled(root,container,keep,min_free):
 if not 1<=keep<=50 or not 1<=min_free<=10240:raise ValueError('Invalid retention/capacity policy')
 v=load('vm-snapshots');manager=v.Snapshots(root)
 with manager.locked():
  info=manager.observe(container)
  try:v.backup.identity(info)
  except ValueError:return {'status':'skipped-running-or-unclean','deleted':[]}
  source=v.storage(info);size=sum(p.stat().st_size for p in v.backup.files(source))
  if shutil.disk_usage(root).free<size+min_free*1024**3:return {'status':'skipped-capacity','requiredBytes':size+min_free*1024**3,'deleted':[]}
  created=manager.create(container,'Scheduled offline checkpoint');created['scheduleManaged']=True;v.write(manager.paths(created['id'])[1],created)
  rows=sorted((r for r in manager.list() if r.get('scheduleManaged') is True),key=lambda r:r['createdAtUtc'],reverse=True)
  deleted=[]
  for r in rows[keep:]:manager.delete(r['id']);deleted.append(r['id'])
  return {'status':'created','id':created['id'],'deleted':deleted}

def schedule(action,keep=5,min_free=10):
 # Fixed unit names. Never install host-wide services or silently stop Windows.
 directory=Path.home()/'.config/systemd/user';directory.mkdir(parents=True,exist_ok=True)
 service=directory/'winboat-offline-backup.service';timer=directory/'winboat-offline-backup.timer'
 if action=='schedule-disable':
  subprocess.run(['systemctl','--user','disable','--now',timer.name],check=True,capture_output=True);return {'status':'disabled'}
 worker=Path.home()/'.winboat'/'BackupWorker';load('config-trial').private(worker)
 for name in ('backup-manager.py','vm-snapshots.py','backup-vm.py','config-trial.py'):
  target=worker/name;data=(Path(__file__).parent/name).read_bytes()
  fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
  with os.fdopen(fd,'wb') as stream:stream.write(data)
 script=worker/'backup-manager.py'
 # systemd command quoting: escape percent specifiers and reject unsafe quote/control characters.
 if any(c in str(script) for c in '"\\\n\r'):raise ValueError('Unsupported script path for systemd unit')
 exe=str(script).replace('%','%%')
 service.write_text('[Unit]\nDescription=WinBoat clean offline checkpoint\n[Service]\nType=oneshot\nUMask=0077\nExecStart=/usr/bin/python3 "'+exe+'" scheduled --keep '+str(keep)+' --min-free-gib '+str(min_free)+'\n')
 timer.write_text('[Unit]\nDescription=Daily WinBoat offline backup check\n[Timer]\nOnCalendar=daily\nPersistent=true\n[Install]\nWantedBy=timers.target\n')
 subprocess.run(['systemctl','--user','daemon-reload'],check=True,capture_output=True)
 subprocess.run(['systemctl','--user','enable','--now',timer.name],check=True,capture_output=True)
 return {'status':'scheduled','frequency':'daily','scope':'Runs only in this user service manager. Skips running/unclean VMs; retention only applies to scheduled offline checkpoints.'}

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=('inventory','verify','stage','scheduled','schedule-enable','schedule-disable'));p.add_argument('--root',type=Path,default=Path.home()/'.winboat/LiveBackups');p.add_argument('--id');p.add_argument('--destination',type=Path);p.add_argument('--container',default='WinBoat');p.add_argument('--keep',type=int,default=5);p.add_argument('--min-free-gib',type=int,default=10);a=p.parse_args()
 try:
  if not 1<=a.keep<=50 or not 1<=a.min_free_gib<=10240:raise ValueError('Invalid backup policy')
  if a.action.startswith('schedule-'):result=schedule(a.action,a.keep,a.min_free_gib)
  elif a.action=='scheduled':result=scheduled(Path.home()/'.winboat/snapshots',a.container,a.keep,a.min_free_gib)
  elif a.action=='inventory':result=inventory(a.root)
  elif a.action=='verify':result=verify(a.root,a.id)
  else:
   if not a.destination:raise ValueError('Choose a separate restore staging parent directory')
   result=stage(a.root,a.id,a.destination)
  print(json.dumps(result))
 except (OSError,ValueError,KeyError,subprocess.SubprocessError) as e:p.exit(1,str(e)+'\n')
if __name__=='__main__':main()

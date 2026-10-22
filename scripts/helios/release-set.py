#!/usr/bin/env python3
"""Immutable artifact-set receipt. Hashes prove identity, not hardware acceptance or signing."""
import argparse,datetime,hashlib,json,os,re,subprocess
from pathlib import Path

def digest(file):
 if file.is_symlink() or not file.is_file():raise ValueError('Release members must be regular files')
 with file.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def create(root,image,inspect=None):
 inspect=inspect or (lambda name:json.loads(subprocess.check_output(['docker','image','inspect',name],text=True,timeout=10))[0])
 host=inspect(image);labels=host.get('Config',{}).get('Labels') or {}
 build=json.loads((root/'BUILD-INFO.json').read_text());driver=json.loads((root/'helios-build.json').read_text())
 if digest(root/'HeliosSetup.exe')!=driver.get('sha256'):raise ValueError('Installer receipt mismatch')
 if labels.get('org.winboat.helios.revision')!=build.get('hostRevision') or labels.get('org.winboat.helios.display')!=build.get('displayCapability'):raise ValueError('Host image and application build metadata disagree')
 if not re.fullmatch('sha256:[a-f0-9]{64}',host.get('Id','')):raise ValueError('Pinned image ID required')
 files={p.name:digest(p) for p in sorted(root.iterdir()) if p.name not in ('RELEASE-SET.json','SHA256SUMS') and p.is_file()}
 if not any(n.endswith('.AppImage') for n in files):raise ValueError('Completed AppImage required')
 return {'schema':1,'stage':'built-not-hardware-accepted','createdAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'applicationCommit':build.get('winboatCommit'),'host':{'tag':image,'id':host['Id'],'capabilities':{k:v for k,v in labels.items() if k.startswith('org.winboat.')}},'driver':{k:driver.get(k) for k in ('driverVersion','sha256','manifestSha256','revision')},'files':files,'scope':'Build identity only. Keep the preceding verified release set for rollback. Windows API/power/display acceptance and explicit visual confirmation remain required.'}

def verify(root,value,local=False):
 if value.get('schema')!=1 or not isinstance(value.get('files'),dict) or not value['files']:raise ValueError('Invalid release set')
 for name,sha in value['files'].items():
  if Path(name).name!=name or not re.fullmatch('[a-f0-9]{64}',str(sha)):raise ValueError('Invalid release member')
  if digest(root/name)!=sha:raise ValueError('Release file differs: '+name)
 if local:
  info=json.loads(subprocess.check_output(['docker','image','inspect',value['host']['id']],text=True,timeout=10))[0]
  if info['Id']!=value['host']['id']:raise ValueError('Host image identity differs')
 return {'state':'identity-verified','stage':value.get('stage'),'driverVersion':value.get('driver',{}).get('driverVersion'),'scope':'Identity verified, no rendering or Windows acceptance inferred.'}

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=('create','verify'));p.add_argument('--directory',type=Path,required=True);p.add_argument('--image');p.add_argument('--local-image',action='store_true');a=p.parse_args()
 try:
  root=a.directory.resolve(strict=True);file=root/'RELEASE-SET.json'
  if a.action=='create':
   if not a.image:raise ValueError('Host image required')
   value=create(root,a.image);fd=os.open(file,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
   with os.fdopen(fd,'w') as out:json.dump(value,out,indent=2)
   result={'state':'created','path':str(file),'stage':value['stage']}
  else:
   if file.is_symlink() or file.stat().st_size>1048576:raise ValueError('Invalid release receipt')
   result=verify(root,json.loads(file.read_text()),a.local_image)
  print(json.dumps(result))
 except (OSError,ValueError,KeyError,subprocess.SubprocessError) as e:p.exit(1,str(e)+'\n')
if __name__=='__main__':main()

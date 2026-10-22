"""Disposable real Docker Engine fixture; never addresses the WinBoat container."""
import json,subprocess,tempfile,uuid
from pathlib import Path
name='winboat-integration-snapshot-'+uuid.uuid4().hex[:12]
with tempfile.TemporaryDirectory(prefix='winboat-engine-check-') as temporary:
 root=Path(temporary);storage=root/'storage';storage.mkdir();disk=storage/'disk.img';disk.write_bytes(b'baseline')
 def docker(*args):return subprocess.check_output(['docker',*args],text=True).strip()
 def manager(action,*args):return json.loads(subprocess.check_output(['python3','scripts/helios/vm-snapshots.py',action,'--container',name,'--root',str(root/'snapshots'),*args],text=True))
 created=False
 try:
  docker('create','--name',name,'--mount',f'type=bind,source={storage},target=/storage','node:24-bookworm-slim','node','-e','process.exit(0)')
  created=True
  docker('start','-a',name);row=manager('create','--label','Disposable engine fixture');disk.write_bytes(b'newer')
  result=manager('restore','--id',row['id']);state=json.loads(docker('inspect',name))[0]['State']['Status']
  assert disk.read_bytes()==b'baseline';assert (Path(result['previousStorage'])/'disk.img').read_bytes()==b'newer';assert state=='created',state
  print('Actual Docker Engine snapshot restore passed; recreated fixture remains stopped and previous storage retained.')
 finally:
  if created:subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

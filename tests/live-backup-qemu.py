#!/usr/bin/env python3
"""Real QEMU block backup/transaction fixture; Windows VSS is explicitly simulated."""
import importlib.util,os,subprocess,tempfile,time
from pathlib import Path
source=Path(__file__).resolve().parents[1]/'helios/host/live-backup.py';spec=importlib.util.spec_from_file_location('backup',source);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Agent:
 def __init__(self):self.frozen=False
 def call(self,name,args=None):
  if name=='guest-info':return {'supported_commands':[{'name':n,'enabled':True} for n in ('guest-fsfreeze-freeze','guest-fsfreeze-thaw','guest-fsfreeze-status','guest-get-osinfo')]}
  if name=='guest-get-osinfo':return {'name':'Windows fixture, no real VSS'}
  if name=='guest-fsfreeze-status':return 'frozen' if self.frozen else 'thawed'
  if name=='guest-fsfreeze-freeze':self.frozen=True;return 1
  if name=='guest-fsfreeze-thaw':self.frozen=False;return 1
with tempfile.TemporaryDirectory(prefix='wb-live-qemu-') as folder:
 root=Path(folder);storage=Path('/storage');storage.mkdir(exist_ok=True);disk=storage/'workbench-fixture.raw'
 if disk.exists():raise RuntimeError('Fixture disk already exists')
 disk.write_bytes(b'fixture'+bytes(4*1024*1024-7));backup=root/'export';backup.mkdir();endpoint=str(root/'qmp')
 perf_spec=importlib.util.spec_from_file_location('performance',source.with_name('performance.py'));perf=importlib.util.module_from_spec(perf_spec);perf_spec.loader.exec_module(perf)
 command=['/opt/helios/qemu/bin/qemu-system-x86_64','-machine','q35','-accel','tcg','-m','64','-nodefaults','-display','none','-monitor','none','-drive','if=none,id=fixture,file='+str(disk)+',format=raw','-device','virtio-blk-pci,drive=fixture','-qmp','unix:'+endpoint+',server=on,wait=off']
 command+=['-device','qemu-xhci,id=usb','-device','usb-tablet,bus=usb.0']
 command=[command[0],*perf.options(command[1:],{'HELIOS_AGENT_CHANNEL':'1','HELIOS_RELATIVE_MOUSE':'1'})]
 qemu=subprocess.Popen(command,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 rpc=None
 try:
  for _ in range(100):
   if Path(endpoint).exists():break
   if qemu.poll() is not None:raise RuntimeError(qemu.stderr.read().decode())
   time.sleep(.05)
  rpc=m.RPC(endpoint,True);assert Path('/run/winboat-qga').exists() and Path('/run/winboat-maintenance-qmp').exists()
  mice=rpc.call('query-mice');assert any(not row.get('absolute') for row in mice),mice
  agent=Agent();result=m.export(rpc,agent,backup)
  assert result['status']=='completed' and not agent.frozen
  assert rpc.call('query-status')['status']=='running'
  target=result['disks'][0]['target']
  subprocess.check_call(['/opt/helios/qemu/bin/qemu-img','check',target],stdout=subprocess.DEVNULL)
  subprocess.check_call(['/opt/helios/qemu/bin/qemu-img','compare','-f','raw','-F','qcow2',str(disk),target],stdout=subprocess.DEVNULL)
  print('Actual QEMU transaction/full-copy, concluded-job tracking, resume and exact disk comparison passed. VSS was simulated.')
 finally:
  if rpc:rpc.close()
  qemu.terminate()
  try:qemu.wait(timeout=5)
  except subprocess.TimeoutExpired:qemu.kill();qemu.wait()
  disk.unlink()

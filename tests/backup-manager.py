import hashlib,importlib.util,json,tempfile,unittest
from pathlib import Path
s=importlib.util.spec_from_file_location('manager',Path(__file__).resolve().parents[1]/'scripts/helios/backup-manager.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class Tests(unittest.TestCase):
 def test_only_completed_matching_regular_exports_verify(self):
  with tempfile.TemporaryDirectory() as folder:
   root=Path(folder);key='a'*32;d=root/key;d.mkdir();data=b'test';(d/'disk-0.qcow2').write_bytes(data)
   row={'target':f'/backup/{key}/disk-0.qcow2','source':'/storage/windows.img','sha256':hashlib.sha256(data).hexdigest()}
   p=d/'status.json';p.write_text(json.dumps({'schema':1,'status':'completed','disks':[row]}))
   self.assertEqual(m.verify(root,key)['state'],'verified')
   (d/'disk-0.qcow2').write_bytes(b'corrupt')
   with self.assertRaises(ValueError):m.verify(root,key)
   (d/'disk-0.qcow2').write_bytes(data);row['source']='/storage/../outside';p.write_text(json.dumps({'schema':1,'status':'completed','disks':[row]}))
   with self.assertRaises(ValueError):m.verify(root,key)
   p.write_text(json.dumps({'schema':1,'status':'copying','disks':[]}))
   with self.assertRaises(ValueError):m.verify(root,key)
 def test_bad_identity_and_policy_rejected(self):
  with self.assertRaises(ValueError):m.verify(Path('/tmp'),'../bad')
  with self.assertRaises(ValueError):m.scheduled(Path('/tmp'),'WinBoat',0,10)
 def test_failed_staging_never_modifies_export_and_never_marks_ready(self):
  import subprocess
  from types import SimpleNamespace
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);key='c'*32;folder=root/key;folder.mkdir(mode=0o700);original=b'original qcow bytes';(folder/'disk-0.qcow2').write_bytes(original)
   (folder/'status.json').write_text(json.dumps({'schema':1,'status':'completed','disks':[{'target':f'/backup/{key}/disk-0.qcow2','source':'/storage/windows.img','sourceFormat':'raw','bytes':1024,'sha256':hashlib.sha256(original).hexdigest()}]}))
   (root/(key+'.container.json')).write_text(json.dumps({'Image':'sha256:'+'a'*64}))
   def run(args,**kw):
    if 'info' in args:return SimpleNamespace(stdout=json.dumps({'format':'qcow2','virtual-size':1024}))
    if 'compare' in args:raise subprocess.CalledProcessError(1,args)
    return SimpleNamespace(stdout='')
   with self.assertRaises(subprocess.CalledProcessError):m.stage(root,key,root,run)
   plans=list(root.glob('WinBoatRestore-*/restore-plan.json'));self.assertEqual(len(plans),1)
   self.assertEqual(json.loads(plans[0].read_text())['status'],'failed');self.assertEqual((folder/'disk-0.qcow2').read_bytes(),original)
 def test_running_vm_schedule_is_skipped_without_create_or_delete(self):
  import contextlib
  from types import SimpleNamespace
  original=m.load
  class Manager:
   def __init__(self,root):pass
   def locked(self):return contextlib.nullcontext()
   def observe(self,container):return {'running':True}
  def reject(_):raise ValueError('Running')
  fake=SimpleNamespace(Snapshots=Manager,backup=SimpleNamespace(identity=reject))
  try:
   m.load=lambda name:fake if name=='vm-snapshots' else original(name)
   self.assertEqual(m.scheduled(Path('/tmp'),'WinBoat',5,10)['status'],'skipped-running-or-unclean')
  finally:m.load=original
if __name__=='__main__':unittest.main()

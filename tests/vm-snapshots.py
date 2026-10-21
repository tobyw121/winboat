import importlib.util
from pathlib import Path
import tempfile
import unittest
s=importlib.util.spec_from_file_location('snapshots',Path(__file__).resolve().parents[1]/'scripts/helios/vm-snapshots.py');v=importlib.util.module_from_spec(s);s.loader.exec_module(v)
class Engine:
 def __init__(self):self.calls=[];self.fail=False
 def call(self,method,path,data=None):
  self.calls.append((method,path,data))
  if method=='GET':raise FileNotFoundError()
  if method=='POST' and self.fail:self.fail=False;raise ValueError('create failed')
  return {'Id':'new'}
 def close(self):pass
class Tests(unittest.TestCase):
 def test_restore_fences_container_preserves_old_storage_and_rolls_back_creation_failure(self):
  with tempfile.TemporaryDirectory() as folder:
   root=Path(folder);disk=root/'storage';disk.mkdir();(disk/'disk.img').write_bytes(b'first')
   info={'Id':'old','Name':'/WinBoat','Image':'sha256:image','Config':{'Image':'tag'},'HostConfig':{},'State':{'Status':'exited','ExitCode':0},'Mounts':[{'Destination':'/storage','Type':'bind','Source':str(disk)}]}
   engine=Engine();m=v.Snapshots(root/'snapshots',lambda _:info,lambda:engine)
   with m.locked():
    row=m.create('WinBoat','baseline');(disk/'disk.img').write_bytes(b'newer')
    engine.fail=True
    with self.assertRaises(ValueError):m.restore('WinBoat',row['id'])
    self.assertEqual((disk/'disk.img').read_bytes(),b'newer')
    self.assertEqual(engine.calls[0][0],'DELETE')
    result=m.restore('WinBoat',row['id']);self.assertEqual(result['status'],'restored-stopped')
    self.assertEqual((disk/'disk.img').read_bytes(),b'first');self.assertEqual((Path(result['previousStorage'])/'disk.img').read_bytes(),b'newer')
    self.assertEqual(engine.calls[-1][2]['Image'],'sha256:image')
 def test_identity_and_path_checks(self):
  with tempfile.TemporaryDirectory() as folder:
   m=v.Snapshots(Path(folder))
   for key in ('../bad','a'*31,'z'*32):
    with self.assertRaises(ValueError):m.paths(key)
if __name__=='__main__':unittest.main()

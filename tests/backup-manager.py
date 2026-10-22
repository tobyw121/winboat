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
if __name__=='__main__':unittest.main()

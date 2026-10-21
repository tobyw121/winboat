import importlib.util
import json
import io
import tarfile
from pathlib import Path
import tempfile
import unittest
s=importlib.util.spec_from_file_location('backup',Path(__file__).resolve().parents[1]/'scripts/helios/backup-vm.py');b=importlib.util.module_from_spec(s);s.loader.exec_module(b)
class Tests(unittest.TestCase):
 def test_offline_copy_verification_and_non_destructive_restore(self):
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory);storage=root/'disk';storage.mkdir();(storage/'data.img').write_bytes(b'disk-data');(storage/'nvram').write_bytes(b'firmware')
   info={'Id':'one','State':{'Status':'exited','ExitCode':0,'StartedAt':'before','FinishedAt':'after'},'Mounts':[{'Destination':'/storage','Type':'bind','Source':str(storage)}]}
   target=root/'backup.tar';b.create('vm',target,lambda _:info)
   self.assertEqual(target.stat().st_mode&0o777,0o600)
   b.verify(target,root/'restored');self.assertEqual((root/'restored/data.img').read_bytes(),b'disk-data')
   with self.assertRaises(FileExistsError):b.verify(target,storage)
   info['State']['Status']='running'
   with self.assertRaises(ValueError):b.create('vm',root/'bad.tar',lambda _:info)
 def test_corrupt_archive_never_creates_restore_directory(self):
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory);storage=root/'disk';storage.mkdir();(storage/'data.img').write_bytes(b'disk')
   info={'Id':'one','State':{'Status':'exited','ExitCode':0},'Mounts':[{'Destination':'/storage','Type':'bind','Source':str(storage)}]}
   original=root/'original.tar';b.create('vm',original,lambda _:info)
   bad=root/'corrupt.tar'
   with tarfile.open(original,'r:') as source,tarfile.open(bad,'w') as target:
    for member in source:
     data=source.extractfile(member).read()
     if member.name=='storage/data.img':data=b'FAIL'
     target.addfile(member,io.BytesIO(data))
   with self.assertRaises(ValueError):b.verify(bad,root/'restored')
   self.assertFalse((root/'restored').exists())
 def test_changed_container_cannot_certify_backup(self):
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory);storage=root/'disk';storage.mkdir();(storage/'data.img').write_bytes(b'disk')
   info={'Id':'one','State':{'Status':'exited','ExitCode':0,'StartedAt':'a','FinishedAt':'b'},'Mounts':[{'Destination':'/storage','Type':'bind','Source':str(storage)}]}
   snapshots=[info,{**info,'Id':'replacement'}]
   with self.assertRaises(ValueError):b.create('vm',root/'bad.tar',lambda _:snapshots.pop(0))
   self.assertFalse((root/'bad.tar').exists())
 def test_rejects_links_backing_chain_and_noncanonical_members(self):
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory);(root/'link').symlink_to('/etc/passwd')
   with self.assertRaises(ValueError):b.files(root)
   chain=root/'chain';chain.write_bytes(b'QFI\xfb'+bytes(12)+(4).to_bytes(4,'big')+bytes(4))
   with self.assertRaises(ValueError):b.check_chain(chain)
   path=root/'evil.tar'
   with tarfile.open(path,'w') as archive:
    for name,data in [('manifest.json',b'{}'),('storage/./disk',b'bad')]:
     item=tarfile.TarInfo(name);item.size=len(data);archive.addfile(item,io.BytesIO(data))
   with self.assertRaises(ValueError):b.verify(path,root/'restored')
   self.assertFalse((root/'restored').exists())
if __name__=='__main__':unittest.main()

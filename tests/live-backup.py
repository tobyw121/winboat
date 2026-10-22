import importlib.util,tempfile,unittest
from pathlib import Path
s=importlib.util.spec_from_file_location('backup',Path(__file__).resolve().parents[1]/'helios/host/live-backup.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class Peer:
 def __init__(self,root,fail=None):self.root=root;self.fail=fail;self.calls=[]
 def call(self,name,args=None):
  self.calls.append(name)
  if self.fail==name:raise ValueError('injected')
  if name=='guest-info':return {'supported_commands':[{'name':n,'enabled':True} for n in ('guest-fsfreeze-freeze','guest-fsfreeze-thaw','guest-fsfreeze-status','guest-get-osinfo')]}
  if name=='guest-get-osinfo':return {'name':'Microsoft Windows'}
  if name=='guest-fsfreeze-status':return 'thawed'
  if name=='guest-fsfreeze-freeze':return 1
  if name=='query-status':return {'status':'running'}
  if name=='query-block':return [{'inserted':{'node-name':'disk','file':'/storage/disk.img','ro':False,'image':{'virtual-size':4096}}}]
  if name=='transaction':(self.root/'disk-0.qcow2').write_bytes(b'fixture')
  if name=='query-jobs':return [{'id':'wb-backup-'+self.root.name+'-0','status':'concluded'}]
  return {}
class Tests(unittest.TestCase):
 def test_full_copy_thaws_before_waiting_and_hashes_completed_export(self):
  with tempfile.TemporaryDirectory() as folder:
   root=Path(folder);q=Peer(root);a=Peer(root);result=m.export(q,a,root,pause=lambda _:None,create_target=lambda d:Path(d['target']).write_bytes(b'fixture'))
   self.assertEqual(result['status'],'completed');self.assertEqual(len(result['disks'][0]['sha256']),64)
   self.assertIn('guest-fsfreeze-thaw',a.calls);self.assertLess(q.calls.index('cont'),q.calls.index('query-jobs'))
 def test_lost_freeze_and_transaction_responses_still_resume_and_thaw(self):
  for failure in ('guest-fsfreeze-freeze','transaction','query-jobs'):
   with self.subTest(failure=failure),tempfile.TemporaryDirectory() as folder:
    root=Path(folder);q=Peer(root,failure);a=Peer(root,failure)
    with self.assertRaises(ValueError):m.export(q,a,root,pause=lambda _:None,create_target=lambda d:Path(d['target']).write_bytes(b'fixture'))
    self.assertIn('guest-fsfreeze-thaw',a.calls)
    if failure!='guest-fsfreeze-freeze':self.assertIn('cont',q.calls)
    self.assertNotEqual(__import__('json').loads((root/'status.json').read_text())['status'],'completed')
if __name__=='__main__':unittest.main()

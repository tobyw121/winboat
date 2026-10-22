import importlib.util,tempfile,unittest,subprocess
from pathlib import Path
s=importlib.util.spec_from_file_location('trial',Path(__file__).resolve().parents[1]/'scripts/helios/config-trial.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class Tests(unittest.TestCase):
 def test_expiration_restores_without_deleting_disks_or_other_changes(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/'trial';compose=Path(d)/'compose.yml';compose.write_text('old');calls=[]
   m.transition(root,'begin',compose,m.digest(b'new'),30,clock=lambda:0);compose.write_text('new')
   self.assertEqual(m.transition(root,'expire',clock=lambda:29)['status'],'pending')
   result=m.transition(root,'expire',clock=lambda:31,run=lambda args,**kw:calls.append(args))
   self.assertEqual(result['status'],'restored');self.assertEqual(compose.read_text(),'old');self.assertEqual([c[-1] for c in calls],['down','-d']);self.assertNotIn('previous',result)
 def test_no_confirmation_after_expiry_and_no_unrelated_overwrite(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/'trial';compose=Path(d)/'compose.yml';compose.write_text('old')
   m.transition(root,'begin',compose,m.digest(b'new'),30,clock=lambda:0)
   with self.assertRaises(ValueError):m.transition(root,'confirm',clock=lambda:31)
   compose.write_text('external')
   with self.assertRaises(ValueError):m.transition(root,'expire',clock=lambda:31)
   self.assertEqual(compose.read_text(),'external');self.assertEqual(m.transition(root,'status')['status'],'conflict')
 def test_failed_restore_remains_recoverable(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/'trial';compose=Path(d)/'compose.yml';compose.write_text('old')
   m.transition(root,'begin',compose,m.digest(b'new'),30,clock=lambda:0);compose.write_text('new')
   def fail(*a,**k):raise subprocess.SubprocessError('injected')
   with self.assertRaises(subprocess.SubprocessError):m.transition(root,'recover',run=fail)
   self.assertEqual(m.transition(root,'status')['status'],'restore-failed')
   self.assertEqual(m.transition(root,'recover',run=lambda *a,**k:None)['status'],'restored')
if __name__=='__main__':unittest.main()

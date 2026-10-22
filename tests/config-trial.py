import importlib.util,tempfile,unittest,subprocess
from pathlib import Path
s=importlib.util.spec_from_file_location('trial',Path(__file__).resolve().parents[1]/'scripts/helios/config-trial.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
original=m.transition
def transition(*args,**kwargs):
 kwargs.setdefault('restart_safe',lambda:True)
 return original(*args,**kwargs)
m.transition=transition
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
   self.assertNotIn('previous',m.transition(root,'recover'))
   self.assertEqual(m.transition(root,'accept-external')['status'],'external-accepted')
   self.assertEqual(compose.read_text(),'external');self.assertEqual(len(list(root.glob('conflict-*.json'))),1)
 def test_failed_restore_remains_recoverable(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/'trial';compose=Path(d)/'compose.yml';compose.write_text('old')
   m.transition(root,'begin',compose,m.digest(b'new'),30,clock=lambda:0);compose.write_text('new')
   def fail(*a,**k):raise subprocess.SubprocessError('injected')
   with self.assertRaises(subprocess.SubprocessError):m.transition(root,'recover',run=fail)
   self.assertEqual(m.transition(root,'status')['status'],'restore-failed')
   self.assertEqual(m.transition(root,'recover',run=lambda *a,**k:None)['status'],'restored')
 def test_live_export_defers_expired_rollback(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)/'trial';compose=Path(d)/'compose.yml';compose.write_text('old')
   m.transition(root,'begin',compose,m.digest(b'new'),30,clock=lambda:0);compose.write_text('new')
   result=m.transition(root,'expire',clock=lambda:31,restart_safe=lambda:False)
   self.assertEqual(result['status'],'pending');self.assertEqual(result['deferred'],'live-export');self.assertEqual(compose.read_text(),'new')
   with self.assertRaises(ValueError):m.transition(root,'recover',restart_safe=lambda:False)
if __name__=='__main__':unittest.main()

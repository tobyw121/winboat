import importlib.util
from pathlib import Path
import unittest
s=importlib.util.spec_from_file_location('p',Path(__file__).resolve().parents[1]/'scripts/helios/graphics-preflight.py');p=importlib.util.module_from_spec(s);s.loader.exec_module(p)
class Tests(unittest.TestCase):
 def test_unknown_is_blocked_and_version_drift_detected(self):
  e={'runtime':'r','display':'d','guest':'g','guestRuntime':'v','viewer':13,'revision':'x'}
  h={'runtimeVersion':'r','displayVersion':'d','qemuBackend':{'issues':[]}}
  g={'graphics_protocol':'g','runtime_protocol':'v'};r={'installerVerified':True,'revision':'x','sha256':'a'*64,'manifestSha256':'b'*64,'driverVersion':'22.22.291.0'}
  self.assertEqual(p.assess(h,g,13,r,e)['state'],'compatible-observed')
  for bad in (None,12):self.assertEqual(p.assess(h,g,bad,r,e)['state'],'blocked')
  h['runtimeVersion']='old';self.assertEqual(p.assess(h,g,13,r,e)['checks'][0]['state'],'mismatch')
 def test_repair_never_confuses_disabled_with_absent(self):
  a={'sampleAgeMs':1,'basic':{'state':'running'},'helios':{'state':'disabled'}}
  self.assertEqual(p.repair(a,{})['action'],'rescue-boot')
  a['sampleAgeMs']=20000;self.assertEqual(p.repair(a,{})['action'],'status')
  a['sampleAgeMs']=1;a['helios']['state']='running';self.assertEqual(p.repair(a,{})['action'],'helios-disable')
if __name__=='__main__':unittest.main()

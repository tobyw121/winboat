import copy
import importlib.util
from pathlib import Path
import unittest
s=importlib.util.spec_from_file_location('r',Path(__file__).resolve().parents[1]/'scripts/helios/regression-graphics.py');r=importlib.util.module_from_spec(s);s.loader.exec_module(r)
class Tests(unittest.TestCase):
 def baseline(self):
  return {'hostImage':'same','hostStartedAt':'old','runtime':{'collectedAtUtc':'2026-10-21T00:00:00Z','bootAtUtc':'boot','consoleLogonId':'one'},
   'adapters':{'sampleAgeMs':1,'basic':{'state':'running'},'helios':{'state':'running','desktopState':'active'}},
   'acceptance':{'runId':'first','tests':[{'name':name,'status':'passed','exitCode':0,'sha256':'a'*64} for name in ('D3D11 1x resize','D3D11 format contracts')],'identity':{'machineId':'vm','version':'291','manifestSha256':'hash','profile':{},'bootAtUtc':'boot'},'automatedPassed':True,'finishedAtUtc':'2026-10-21T00:00:01Z'}}
 def test_real_transitions_and_fresh_probes_are_both_required(self):
  a=self.baseline();b=copy.deepcopy(a);b['acceptance']['runId']='second';b['runtime']['collectedAtUtc']='2026-10-21T00:00:02Z'
  self.assertEqual(r.assess(a,b,'cold-boot')['state'],'inconclusive')
  b['runtime']['bootAtUtc']='new';b['hostStartedAt']='new';b['acceptance']['identity']['bootAtUtc']='new'
  self.assertEqual(r.assess(a,b,'cold-boot')['state'],'passed')
  b['acceptance']['finishedAtUtc']='2026-10-20T00:00:01Z'
  self.assertEqual(r.assess(a,b,'cold-boot')['state'],'inconclusive')
 def test_logon_requires_changed_authentication_identity_and_no_crash(self):
  a=self.baseline();b=copy.deepcopy(a);b['acceptance']['runId']='second';b['runtime']['collectedAtUtc']='2026-10-21T00:00:02Z';b['runtime']['consoleLogonId']='two'
  self.assertEqual(r.assess(a,b,'logon')['state'],'passed')
  b['runtime']['dwmCrashes']=[{'timeUtc':'2026-10-21T00:00:01Z'}]
  self.assertEqual(r.assess(a,b,'logon')['state'],'failed')
 def test_standby_needs_ordered_sleep_and_resume(self):
  a=self.baseline();b=copy.deepcopy(a);b['acceptance']['runId']='second';b['runtime']['collectedAtUtc']='2026-10-21T00:00:04Z'
  b['runtime']['powerEvents']=[{'kind':'sleep','timeUtc':'2026-10-21T00:00:01Z'},{'kind':'resume','timeUtc':'2026-10-21T00:00:02Z'}]
  self.assertEqual(r.assess(a,b,'standby')['state'],'passed')
  b['runtime']['powerEvents'][0]['kind']='resume'
  self.assertEqual(r.assess(a,b,'standby')['state'],'inconclusive')
if __name__=='__main__':unittest.main()

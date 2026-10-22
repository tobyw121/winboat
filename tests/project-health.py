import importlib.util,unittest
from pathlib import Path
s=importlib.util.spec_from_file_location('health',Path(__file__).resolve().parents[1]/'scripts/helios/project-health.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class Tests(unittest.TestCase):
 def test_findings_distinguish_absent_evidence_and_mixed_versions(self):
  self.assertEqual(m.findings({})['state'],'no-known-signal')
  r={'graphics/diagnostics':{'driver':{'stackCoherence':{'state':'mismatch'},'application':{'crashes':[{'AppName':'dwm.exe','timeUtc':'t','ProcessId':1}]}}},'host':{'transportErrors':[{'kind':'buffer-size-mismatch'}]}}
  self.assertEqual({x['kind'] for x in m.findings(r)['findings']},{'mixed-active-versions','dwm-crash-observed','allocation-contract-mismatch'})
 def test_comparison_requires_matching_environment_and_preserves_metric_units(self):
  a={'identity':{'image':'a','guestCommit':'g','cpus':'6','ram':'8G','driverVersions':['22.22.291.0'],'resolution':['1920x1080']},'metrics':{'container':{'cpuPercentOfOneCore':150}}};b={**a,'metrics':{'container':{'cpuPercentOfOneCore':120}}}
  self.assertEqual(m.compare(a,b)['measurements'][0]['delta'],-30)
  self.assertEqual(m.compare(a,{**b,'identity':{'image':'b'}})['state'],'not-comparable')
if __name__=='__main__':unittest.main()

import importlib.util
import datetime
from pathlib import Path
import unittest
s=importlib.util.spec_from_file_location('center',Path(__file__).resolve().parents[1]/'scripts/helios/graphics-center.py');center=importlib.util.module_from_spec(s);s.loader.exec_module(center)
class Tests(unittest.TestCase):
 def test_stale_transport_is_historical_and_detection_not_success(self):
  now=datetime.datetime(2026,10,21,tzinfo=datetime.timezone.utc)
  record={'kind':'ack','success':1,'transport':'copy','hostAtUtc':'2026-10-20T23:59:59Z'}
  self.assertEqual(center.transport([record],now)['state'],'recent')
  record['hostAtUtc']='2026-10-20T23:00:00Z';self.assertEqual(center.transport([record],now)['state'],'historical')
  record['success']=0;self.assertEqual(center.transport([record],now),{'state':'unknown'})
 def test_missing_versions_and_private_paths_remain_absent(self):
  d={'controllers':[{'DriverVersion':'22.22.291.0'}],'application':{'loadedApplications':[{'modules':[{'name':'dxgi.dll','path':'PRIVATE'}]}]}}
  r=center.summary({}, {},d,{'transaction':{'candidate':{'version':'22.22.301.0'}}})
  self.assertEqual(r['boundVersions'],['22.22.291.0']);self.assertEqual(r['candidate'],'22.22.301.0');self.assertNotIn('PRIVATE',str(r));self.assertNotIn('version',r['loadedModules'][0])
if __name__=='__main__':unittest.main()

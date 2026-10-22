import importlib.util,unittest
from pathlib import Path
s=importlib.util.spec_from_file_location('workbench',Path(__file__).resolve().parents[1]/'scripts/helios/workbench.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class Tests(unittest.TestCase):
 def test_viewer_rate_is_reset_on_new_process_or_resolution_and_not_called_game_fps(self):
  a={'pid':1,'console':0,'width':1920,'height':1080,'monotonicUs':1000000,'renderedFrames':100,'copySamples':10,'sourceCopyWallUs':1000}
  b={**a,'monotonicUs':2000000,'renderedFrames':160,'copySamples':20,'sourceCopyWallUs':3000}
  self.assertEqual(m.frame_delta(a,b)['viewerRedrawsPerSecond'],60)
  self.assertEqual(m.frame_delta(a,{**b,'pid':2})['state'],'warming-up');self.assertEqual(m.frame_delta(a,{**b,'monotonicUs':20000000})['state'],'stale')
 def test_layout_correlation_checks_allocation_extent_and_format_domains(self):
  host='dmabuf-contract import source=1 ino=42 bytes=4096000 required=4587520 width=1280 height=800 stride=5120 format=44 tiling=0 modifier=72057594037927935 offset=0 planes=1'
  v={'event':'dmabuf-contract','inode':42,'bytes':4096000,'width':1280,'height':800,'stride':5120,'offset':0,'fourcc':0x34325241,'modifier':72057594037927935}
  result=m.transport_contracts(host,__import__('json').dumps(v,separators=(',',':')))
  self.assertIn('allocation-extent',result['checks'][0]['mismatches']);self.assertIn('optimal-shape',result['checks'][0]['mismatches'])
  v['inode']=7;self.assertEqual(m.transport_contracts(host,__import__('json').dumps(v,separators=(',',':')))['checks'][0]['state'],'unmatched')
 def test_presentmon_rate_keeps_one_application_process(self):
  import tempfile
  with tempfile.TemporaryDirectory() as folder:
   path=Path(folder)/'frames.csv';path.write_text('Application,ProcessID,MsBetweenPresents\napp.exe,42,20\napp.exe,42,20\nother.exe,7,5\n')
   result=m.load('measure-performance').read_frame_times(path,'app.exe');self.assertEqual(result['presentCallsPerSecond'],50);self.assertEqual(result['processId'],42)
   with path.open('a') as stream:stream.write('app.exe,43,20\n')
   with self.assertRaises(ValueError):m.load('measure-performance').read_frame_times(path,'app.exe')
 def test_release_gate_rejects_missing_or_other_package_evidence(self):
  identity={'manifestSha256':'a'*64,'machineId':'m','version':'v'};v={'hostImage':'host','acceptance':{'automatedPassed':True,'finishedAtUtc':__import__('datetime').datetime.now(__import__('datetime').timezone.utc).isoformat(),'tests':[{'name':name,'status':'passed','exitCode':0,'sha256':'a'*64} for name in ('D3D11','Vulkan features','Vulkan presentation','OpenGL','D3D11 1x resize','D3D11 format contracts')],'identity':identity}}
  scenarios={name:{'hostImage':'host','acceptance':{'identity':identity},'assessment':{'state':'passed'}} for name in ('cold-boot','resize','logon')}
  self.assertEqual(m.release_gate(v,scenarios)['state'],'eligible-for-visual-confirmation')
  scenarios['resize']['hostImage']='old';self.assertEqual(m.release_gate(v,scenarios)['state'],'incomplete')
  scenarios['logon']['assessment']['state']='failed';self.assertEqual(m.release_gate(v,scenarios)['state'],'blocked')
if __name__=='__main__':unittest.main()

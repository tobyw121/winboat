import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
s=importlib.util.spec_from_file_location('symbols',Path(__file__).resolve().parents[1]/'scripts/helios/symbolize-mesa.py');symbols=importlib.util.module_from_spec(s);s.loader.exec_module(symbols)
class Tests(unittest.TestCase):
 def test_actual_dwarf_lookup_and_mismatch_refusal(self):
  with tempfile.TemporaryDirectory() as folder:
   root=Path(folder);source=root/'fault.c';source.write_text('int fault_site(int n){return n+1;}\n')
   runtime=root/'vulkan_virtio.dll';debug=root/'vulkan_virtio.dll.debug'
   subprocess.run(['cc','-g','-O0','-shared','-fPIC',str(source),'-o',str(runtime)],check=True)
   subprocess.run(['objcopy','--only-keep-debug',str(runtime),str(debug)],check=True)
   subprocess.run(['objcopy','--strip-debug',str(runtime)],check=True)
   rows=subprocess.check_output(['nm','--defined-only',str(runtime)],text=True).splitlines()
   offset=int(next(r.split()[0] for r in rows if r.endswith(' fault_site')),16)
   manifest={'schema':1,'modules':[{'module':runtime.name,'sha256':hashlib.sha256(runtime.read_bytes()).hexdigest(),'debug':debug.name,'debugSha256':hashlib.sha256(debug.read_bytes()).hexdigest(),'imageBase':0}]}
   (root/'symbols.json').write_text(json.dumps(manifest))
   result=symbols.resolve(runtime,root,runtime.name,offset)
   self.assertEqual(result['status'],'resolved');self.assertIn('fault_site',result['analysis']);self.assertIn('fault.c:1',result['analysis'])
   debug.write_bytes(b'wrong symbols')
   with self.assertRaisesRegex(ValueError,'mismatch'):symbols.resolve(runtime,root,runtime.name,offset)
if __name__=='__main__':unittest.main()

import importlib.util,json,pathlib,struct,sys,tempfile,unittest
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'scripts/compatibility'))
import ge_features as ge
spec=importlib.util.spec_from_file_location('hostgame',pathlib.Path(__file__).resolve().parents[1]/'scripts/compatibility/host-game.py');game=importlib.util.module_from_spec(spec);spec.loader.exec_module(game)
class GEFeatures(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=pathlib.Path(self.temp.name)
  self.proton=self.root/'GE-Proton';self.proton.mkdir();(self.proton/'version').write_text('GE-Proton fixture')
  (self.proton/'proton').write_text('PROTON_USE_D7VK PYROVEIL_CONFIG')
  self.exe=self.root/'game.exe';self.pe(self.exe)
  for arch in ('i386-windows','x86_64-windows'):
   dll=self.proton/'files/lib/wine/dxvk'/arch/'dxgi.dll';dll.parent.mkdir(parents=True)
   self.pe(dll,0x14c if arch=='i386-windows' else 0x8664);dll.write_bytes(dll.read_bytes()+b'dxgi.deferInitialFullscreen dxgi.deferSurfaceCreation dxgi.keepFullscreenOnFocusLoss')
  dll=self.proton/'files/lib/wine/d7vk/i386-windows/ddraw.dll';dll.parent.mkdir(parents=True);self.pe(dll)
  manifests=self.proton/'files/share/pyroveil/implicit_layer.d';manifests.mkdir(parents=True)
  library=self.proton/'files/lib/libVkLayer_pyroveil.so';elf=bytearray(64);elf[:6]=b'\x7fELF\x02\x01';struct.pack_into('<H',elf,18,62);library.write_bytes(elf+b'VK_LAYER_PYROVEIL_vkNegotiateLoaderLayerInterfaceVersion')
  (manifests/'pyroveil.json').write_text(json.dumps({'layer':{'name':'VK_LAYER_pyroveil','enable_environment':{'PYROVEIL':'1'},'library_path':'../../../lib/libVkLayer_pyroveil.so'}}))
  self.pyro=self.root/'shader-fix';self.pyro.mkdir();(self.pyro/'pyroveil.json').write_text(json.dumps({'version':2,'type':'pyroveil','matches':[{'spirvExecutionModel':5365,'action':{'glsl-roundtrip':True}}],'roundtripCache':'cache'}))
 def pe(self,path,machine=0x14c):
  data=bytearray(128);data[:2]=b'MZ';struct.pack_into('<I',data,60,64);data[64:68]=b'PE\0\0';struct.pack_into('<H',data,68,machine);path.write_bytes(data)
 def test_recipes_are_gated_on_the_actual_dxgi_and_pinned(self):
  features=ge.prepare(self.proton,self.exe,'dxgi-probe-v1');ge.validate(features,self.proton,self.exe)
  env=ge.environment(features,self.root);self.assertIn('dxgi.deferInitialFullscreen = True',env['DXVK_CONFIG'])
  dll=self.proton/'files/lib/wine/dxvk/i386-windows/dxgi.dll';dll.write_bytes(b'old DLL')
  with self.assertRaises(ValueError):ge.validate(features,self.proton,self.exe)
 def test_d7vk_uses_ge_supported_switch_and_rejects_wrong_architecture(self):
  features=ge.prepare(self.proton,self.exe,d7vk=True);self.assertEqual(ge.environment(features,self.root)['PROTON_USE_D7VK'],'1')
  self.pe(self.exe,0x8664)
  with self.assertRaises(ValueError):ge.prepare(self.proton,self.exe,d7vk=True)
 def test_shader_assets_are_staged_privately_and_changes_block_launch(self):
  features=ge.prepare(self.proton,self.exe,pyroveil=self.pyro);ge.validate(features,self.proton,self.exe)
  prefix=self.root/'prefix';prefix.mkdir();env=ge.environment(features,prefix)
  self.assertEqual(env['PYROVEIL'],'1');self.assertTrue(pathlib.Path(env['PYROVEIL_CONFIG']).is_relative_to(prefix))
  self.assertEqual((self.pyro/'pyroveil.json').read_bytes(),pathlib.Path(env['PYROVEIL_CONFIG']).read_bytes())
  (self.pyro/'pyroveil.json').write_text('{}')
  with self.assertRaises(ValueError):ge.validate(features,self.proton,self.exe)
 def test_shader_path_escape_unbounded_actions_and_staged_symlinks_are_rejected(self):
  path=self.pyro/'pyroveil.json';data=json.loads(path.read_text());data['roundtripCache']='../outside';path.write_text(json.dumps(data))
  with self.assertRaises(ValueError):ge.prepare(self.proton,self.exe,pyroveil=self.pyro)
  data['roundtripCache']='cache';path.write_text(json.dumps(data));features=ge.prepare(self.proton,self.exe,pyroveil=self.pyro)
  prefix=self.root/'prefix';prefix.mkdir();(prefix/'.winboat-pyroveil').symlink_to(self.pyro,target_is_directory=True)
  with self.assertRaises(ValueError):ge.environment(features,prefix)
 def test_real_umu_child_receives_opt_in_switches_and_profile_cannot_silently_change(self):
  profile=game.create(self.exe,self.proton,self.root/'prefix','umu-default',[])
  profile['ge']=ge.prepare(self.proton,self.exe,pyroveil=self.pyro,d7vk=True);game.validate(profile)
  runner=self.root/'umu-run';runner.write_text('#!/usr/bin/python3\nimport os,json\nfrom pathlib import Path\nPath(os.environ["WINEPREFIX"],"env.json").write_text(json.dumps({k:os.environ[k] for k in ["PYROVEIL","PYROVEIL_CONFIG","PROTON_USE_D7VK"]}))\n');runner.chmod(0o700)
  with patch.object(game.shutil,'which',return_value=str(runner)):
   self.assertEqual(game.run(profile)['exitCode'],0)
   env=json.loads((self.root/'prefix/env.json').read_text());self.assertEqual(env['PROTON_USE_D7VK'],'1');self.assertEqual(env['PYROVEIL'],'1')
   changed=json.loads(json.dumps(profile));changed['ge']=ge.prepare(self.proton,self.exe,'keep-fullscreen-v1')
   with self.assertRaisesRegex(ValueError,'different game/runtime'):game.run(changed)
if __name__=='__main__':unittest.main()

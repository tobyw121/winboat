import fcntl
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('hostgame',Path(__file__).resolve().parents[1]/'scripts/compatibility/host-game.py')
game=importlib.util.module_from_spec(spec);spec.loader.exec_module(game)
class HostGame(unittest.TestCase):
 def setUp(self):
  self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
  self.root=Path(self.temporary.name);self.exe=self.root/'a game.exe';self.exe.write_bytes(b'MZ-fixture')
  self.proton=self.root/'GE-Proton';self.proton.mkdir()
  (self.proton/'version').write_text('GE-Proton fixture\n');(self.proton/'proton').write_text('fixture')
  self.profile=game.create(self.exe,self.proton,self.root/'prefix','umu-default',['--argument=a b','$(touch injected)'])
  self.runner=self.root/'umu-run';self.runner.write_text('#!/usr/bin/python3\nimport os,sys,json\nfrom pathlib import Path\nPath(os.environ["WINEPREFIX"],"result.json").write_text(json.dumps({"args":sys.argv[1:],"flag":os.environ["PROTON_USE_WINED3D"]}))\nsys.exit(7)\n');self.runner.chmod(0o700)
 def test_real_child_gets_literal_arguments_and_isolated_options(self):
  self.profile['options']['wined3d']=True
  with patch.object(game.shutil,'which',return_value=str(self.runner)):
   preview=game.run(self.profile,True);self.assertFalse(Path(self.profile['prefix']).exists())
   self.assertEqual(preview['command'][1:],[str(self.exe),*self.profile['args']])
   result=game.run(self.profile)
   self.assertEqual(result['exitCode'],7)
   received=json.loads((self.root/'prefix/result.json').read_text())
   self.assertEqual(received,{'args':[str(self.exe),*self.profile['args']],'flag':'1'})
   self.assertFalse((self.root/'injected').exists())
   self.assertEqual((self.root/'prefix').stat().st_mode&0o777,0o700)
   self.assertEqual((self.root/'prefix/.winboat-umu.json').stat().st_mode&0o777,0o600)
   # Reuse belongs to this exact game and runtime only.
   self.assertEqual(game.run(self.profile)['exitCode'],7)
 def test_update_tampering_unknown_options_and_missing_umu_are_rejected(self):
  for field in ('launcherSha256','versionSha256'):
   changed=json.loads(json.dumps(self.profile));changed['proton'][field]='0'*64
   with self.assertRaises(ValueError):game.validate(changed)
  self.exe.write_bytes(b'new executable')
  with self.assertRaises(ValueError):game.validate(self.profile)
  self.exe.write_bytes(b'MZ-fixture')
  changed=json.loads(json.dumps(self.profile));changed['options']['LD_PRELOAD']='evil'
  with self.assertRaises(ValueError):game.validate(changed)
  with patch.object(game.shutil,'which',return_value=None),self.assertRaisesRegex(ValueError,'umu-run is missing'):game.run(self.profile)
 def test_shared_unmanaged_and_busy_prefixes_are_not_modified(self):
  prefix=self.root/'prefix';prefix.mkdir(mode=0o700);(prefix/'unmanaged').write_text('keep')
  with patch.object(game.shutil,'which',return_value=str(self.runner)):
   with self.assertRaisesRegex(ValueError,'unmanaged'):game.run(self.profile)
   self.assertEqual((prefix/'unmanaged').read_text(),'keep')
   (prefix/'unmanaged').unlink()
   with (prefix/'.winboat-umu.lock').open('w') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    with self.assertRaisesRegex(ValueError,'active'):game.run(self.profile)
   prefix.chmod(0o755)
   with self.assertRaisesRegex(ValueError,'private'):game.run(self.profile)
 def test_environment_is_child_only_and_managed_flags_are_reset(self):
  original={'PROTON_USE_WINED3D':'1','WINEDLLOVERRIDES':'d3d11=b','VK_INSTANCE_LAYERS':'bad','DISPLAY':':0'}
  result=game.environment(self.profile,original)
  self.assertEqual(result['PROTON_USE_WINED3D'],'0');self.assertEqual(result['DISPLAY'],':0')
  self.assertNotIn('WINEDLLOVERRIDES',result);self.assertNotIn('VK_INSTANCE_LAYERS',result)
  self.assertEqual(original['PROTON_USE_WINED3D'],'1')
 def test_profile_creation_does_not_overwrite_existing_data(self):
  destination=self.root/'profile.json';game.private_json(destination,self.profile)
  with self.assertRaises(FileExistsError):game.private_json(destination,{'new':'data'})
  self.assertEqual(json.loads(destination.read_text()),self.profile)
if __name__=='__main__':unittest.main()

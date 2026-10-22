import importlib.util,json,tempfile,unittest
from pathlib import Path
s=importlib.util.spec_from_file_location('release',Path(__file__).resolve().parents[1]/'scripts/helios/release-set.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class Tests(unittest.TestCase):
 def test_release_identity_pins_all_artifacts_and_never_implies_acceptance(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);(root/'HeliosSetup.exe').write_bytes(b'exe');(root/'winboat.AppImage').write_bytes(b'app')
   (root/'helios-build.json').write_text(json.dumps({'sha256':m.digest(root/'HeliosSetup.exe'),'driverVersion':'22.22.291.0'}));(root/'BUILD-INFO.json').write_text(json.dumps({'hostRevision':'abc','displayCapability':'dbus'}))
   info={'Id':'sha256:'+'a'*64,'Config':{'Labels':{'org.winboat.helios.revision':'abc','org.winboat.helios.display':'dbus'}}}
   receipt=m.create(root,'host',lambda _:info);self.assertEqual(receipt['stage'],'built-not-hardware-accepted');self.assertEqual(m.verify(root,receipt)['state'],'identity-verified')
   (root/'winboat.AppImage').write_bytes(b'corrupt')
   with self.assertRaises(ValueError):m.verify(root,receipt)
   receipt['files']={'../outside':'a'*64}
   with self.assertRaises(ValueError):m.verify(root,receipt)
if __name__=='__main__':unittest.main()

import importlib.util
from pathlib import Path
import unittest
s=importlib.util.spec_from_file_location('audio',Path(__file__).resolve().parents[1]/'native/helios-audio/audio.py');a=importlib.util.module_from_spec(s);s.loader.exec_module(a)
class Tests(unittest.TestCase):
 def test_pcm_contract_and_directional_interfaces(self):
  self.assertEqual(a.pcm(16,True,False,48000,2,4,192000,False),'S16LE')
  self.assertEqual(a.pcm(32,True,True,48000,1,4,192000,False),'F32LE')
  for values in ((16,True,False,48000,2,2,192000,False),(64,True,False,48000,1,8,384000,False)):
   with self.assertRaises(ValueError):a.pcm(*values)
  self.assertNotIn('name="Read"',a.xml('Out'));self.assertNotIn('name="Write"',a.xml('In'))
if __name__=='__main__':unittest.main()

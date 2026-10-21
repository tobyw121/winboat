import importlib.util
from pathlib import Path
import unittest
s=importlib.util.spec_from_file_location('caps',Path(__file__).resolve().parents[1]/'scripts/helios/compare-capabilities.py');caps=importlib.util.module_from_spec(s);s.loader.exec_module(caps)
TEXT='cap identity warp 0\ncap d3d11 featureLevel 45056\ncap vulkan apiVersion 4202496\ncap vulkan feature.geometryShader 0\ncap identity complete 1\n'
class Tests(unittest.TestCase):
    def test_new_features_and_removals_require_review(self):
        a=caps.capture(TEXT,'a'*64);b=caps.capture(TEXT.replace('geometryShader 0','geometryShader 1'),'a'*64)
        r=caps.compare(a,b);self.assertTrue(r['reviewRequired']);self.assertEqual(r['changes'][0]['before'],0)
        self.assertFalse(caps.compare(a,a)['reviewRequired'])
    def test_partial_software_duplicate_or_mixed_probes_cannot_certify(self):
        good=caps.capture(TEXT,'a'*64)
        for text in (TEXT.replace('warp 0','warp 1'),TEXT.replace('cap identity complete 1\n','')):
            with self.assertRaises(ValueError):caps.compare(good,caps.capture(text,'a'*64))
        with self.assertRaises(ValueError):caps.capture(TEXT+TEXT,'a'*64)
        with self.assertRaises(ValueError):caps.compare(good,caps.capture(TEXT,'b'*64))
if __name__=='__main__':unittest.main()

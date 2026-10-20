import copy
import importlib.util
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('bisect',ROOT/'scripts/helios/bisect-graphics.py')
bisect=importlib.util.module_from_spec(spec);spec.loader.exec_module(bisect)
CANDIDATES=[str(n)*64 for n in range(5)]


def trial(index,bad=True,axis='guest',salt=''):
    rows=[]
    for label in ('A1','B1','A2','B2'):
        b=label.startswith('B');candidate=CANDIDATES[index] if b else CANDIDATES[0]
        passed=not b or not bad
        rows.append({'host':{'imageId':'sha256:'+(candidate if axis=='host' else 'a'*64)},
                     'graphics/validation':{'acceptance':{'label':label,'comparisonKey':'fixed','automatedPassed':passed,'runId':label+str(index)+salt,
                      'identity':{'version':str(index) if b else '0','machineId':'m','profile':{'x':None},'manifestSha256':candidate if axis=='guest' else 'f'*64},
                      'tests':[{'name':'pixels','status':'passed' if passed else 'failed','exitCode':0 if passed else 1,'codes':[],'sha256':'e'*64}]}}})
    return rows


class BisectTests(unittest.TestCase):
    def test_guest_boundary_and_host_axis_are_separate(self):
        self.assertEqual(bisect.plan('guest',CANDIDATES,[],'pixels')['status'],'validate-endpoints')
        self.assertEqual(bisect.plan('guest',CANDIDATES,[trial(4)],'pixels')['nextIndex'],2)
        self.assertEqual(bisect.plan('guest',CANDIDATES,[trial(4),trial(2,False)],'pixels')['nextIndex'],3)
        result=bisect.plan('guest',CANDIDATES,[trial(4),trial(2,False),trial(3)],'pixels')
        self.assertEqual(result['status'],'adjacent-boundary-observed')
        self.assertFalse(result['contextVerified'])
        self.assertIn('gpu',result['missingContext'])
        self.assertEqual(bisect.plan('host',['sha256:'+c for c in CANDIDATES],[trial(4,axis='host')],'pixels')['nextIndex'],2)

    def test_mixed_host_probe_and_duplicate_evidence_are_refused(self):
        base=trial(4)
        changed=copy.deepcopy(base);changed[1]['host']['imageId']='sha256:'+'b'*64
        with self.assertRaises(ValueError): bisect.plan('guest',CANDIDATES,[changed],'pixels')
        changed=copy.deepcopy(base);changed[1]['graphics/validation']['acceptance']['tests'][0]['sha256']='d'*64
        with self.assertRaises(ValueError): bisect.plan('guest',CANDIDATES,[changed],'pixels')
        with self.assertRaises(ValueError): bisect.plan('guest',CANDIDATES,[base,base],'pixels')
        with self.assertRaises(ValueError): bisect.plan('guest',CANDIDATES,[base,trial(1),trial(2,False)],'pixels')

    def test_resolution_backend_and_gpu_changes_make_trial_inconclusive(self):
        for field in ('resolution','backend','gpu'):
            rows=trial(4)
            for capture in rows:
                capture['host']['qemuBackend']={'backend':'dbus'}
                capture['host']['gpuPreflight']={'devices':[{'selected':True,'deviceUuid':'same'}]}
                capture['graphics/diagnostics']={'driver':{'controllers':[{'CurrentHorizontalResolution':1920,'CurrentVerticalResolution':1080}]}}
            if field=='resolution': rows[1]['graphics/diagnostics']['driver']['controllers'][0]['CurrentHorizontalResolution']=1280
            if field=='backend': rows[1]['host']['qemuBackend']['backend']='egl-headless'
            if field=='gpu': rows[1]['host']['gpuPreflight']['devices'][0]['deviceUuid']='other'
            with self.assertRaises(ValueError): bisect.plan('guest',CANDIDATES,[rows],'pixels')


if __name__=='__main__': unittest.main()

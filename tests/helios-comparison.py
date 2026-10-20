import importlib.util
from pathlib import Path
import tempfile
import subprocess
import sys
import json
import unittest

ROOT=Path(__file__).resolve().parents[1]
def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts/helios'/f'{name}.py')
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result

comparison=module('compare-graphics');metrics=module('measure-performance');correlation=module('graphics-correlation')


class ComparisonTests(unittest.TestCase):
    def test_cli_reads_windows_utf8_bom_exports(self):
        with tempfile.TemporaryDirectory() as root:
            paths=[]
            for label in ('A1','B1','A2','B2'):
                path=Path(root)/(label+'.json')
                path.write_text(json.dumps({'label':label,'comparisonKey':'same','summary':{'meanCpuPercentOfOneCore':100}}),encoding='utf-8-sig')
                paths.append(str(path))
            result=subprocess.run([sys.executable,str(ROOT/'scripts/helios/compare-graphics.py'),*paths],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout)['pairs'][0]['cpuPercentagePointDelta'],0)
    def test_quantiles_and_invalid_durations(self):
        summary=comparison.frame_summary([1,2,3,4,100])
        self.assertEqual(summary['medianMs'],3)
        self.assertAlmostEqual(summary['p95Ms'],80.8)
        for value in (float('nan'),-1,0,True):
            with self.assertRaises(ValueError): comparison.frame_summary([value])

    def test_interleaving_and_workload_identity_are_required(self):
        reports=[{'label':label,'comparisonKey':'same-scene','summary':{'meanCpuPercentOfOneCore':cpu}}
                 for label,cpu in zip(('A1','B1','A2','B2'),(200,150,240,210))]
        self.assertEqual([p['cpuPercentagePointDelta'] for p in comparison.compare(reports)['pairs']],[-50,-30])
        with self.assertRaises(ValueError): comparison.compare(reports[::-1])
        reports[-1]['comparisonKey']='different-resolution'
        with self.assertRaises(ValueError): comparison.compare(reports)

    def test_csv_rejects_multiple_pids_and_excludes_other_apps(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'frames.csv'
            path.write_text('Application,ProcessID,MsBetweenPresents\ngame.exe,2,10\ngame.exe,2,20\nother.exe,3,200\n')
            self.assertEqual(metrics.read_frame_times(path,'game.exe')['medianMs'],15)
            with path.open('a') as output: output.write('game.exe,4,30\n')
            with self.assertRaises(ValueError): metrics.read_frame_times(path,'game.exe')

    def test_resource_lifecycle_keeps_host_scope(self):
        rows=[{'kind':kind,'resourceId':1,'source':2,'inode':3} for kind in ('resource-create','resource-frame','resource-release')]
        result=correlation.correlate({'host':{'frameMetrics':rows,'transportErrors':[{'kind':'budget-rejected'}]}})
        self.assertEqual(len(result['resourceTimeline']),1)
        self.assertEqual(len(result['resourceTimeline'][0]['events']),3)
        self.assertEqual(result['firstObservedHostFailure']['kind'],'budget-rejected')

    def test_clock_skew_is_an_interval_and_missing_clock_unknown(self):
        report={'graphics/diagnostics/runtime':{'driver':{'collectedAtUtc':'2026-10-19T12:01:00Z'}},
                'requestTiming':{'graphics/diagnostics/runtime':{'startUtc':'2026-10-19T12:00:00Z','endUtc':'2026-10-19T12:00:02Z'}}}
        result=correlation.correlate(report)
        self.assertEqual(result['guestMinusHostClockRange'],{'minimumSeconds':58,'maximumSeconds':60})
        self.assertIsNone(correlation.correlate({})['guestMinusHostClockRange'])

    def test_driver_comparison_exposes_different_probe_bytes(self):
        reports=[{'label':label,'comparisonKey':'same','automatedPassed':False,'identity':{'version':version},
                  'tests':[{'name':'D3D11','sha256':sha,'status':'failed'}]}
                 for label,version,sha in zip(('A1','B1','A2','B2'),('291','294','291','294'),('a','b','a','b'))]
        self.assertFalse(comparison.compare(reports)['sameProbeBytes'])
        reports[2]['identity']['version']='296'
        with self.assertRaises(ValueError): comparison.compare(reports)


if __name__=='__main__': unittest.main()

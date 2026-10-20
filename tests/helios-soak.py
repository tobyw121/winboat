import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('soak',ROOT/'scripts/helios/soak-graphics.py')
soak=importlib.util.module_from_spec(spec);spec.loader.exec_module(soak)


class SoakTests(unittest.TestCase):
    def test_final_sample_deduplicates_events_and_retains_sampling_failures(self):
        runtime={'driver':{'collectedAtUtc':'2026-10-20T12:00:00Z','bootAtUtc':'boot1','dwmProcesses':[{'processId':12,'startedAtUtc':'t1'}],
                           'dwmCrashes':[{'timeUtc':'2026-10-20T12:00:20Z','ProcessId':12}], 'errors':[]}}
        rows=[{'kind':'sample','elapsedSeconds':n,'intervalSeconds':60,'baselineGuestUtc':'2026-10-20T12:00:00Z',
               'adapters':{'helios':{'state':'running'}},'container':{'cpuPercentOfOneCore':250,'memoryPercent':10+n/3600},'runtime':runtime} for n in (0,60,180)]
        rows[1]['adapters']={'error':'failed'}
        result=soak.summarize(rows)
        self.assertEqual(result['observedEventCount'],1)
        self.assertEqual(result['observedDwmProcessIdentities'],1)
        self.assertEqual(result['samplingGaps'],1)
        self.assertEqual(result['missingAdapterSamples'],1)
        self.assertAlmostEqual(result['containerMemoryPercentagePointsPerHour'],1)

    def test_actual_streaming_loop_final_checkpoint_and_exclusive_output(self):
        diagnostics=soak.load('diagnose-graphics');metrics=soak.load('measure-performance')
        now=[0]
        def sleep(seconds): now[0]+=seconds
        def endpoint(opener,base,name,timeout):
            return {'helios':{'state':'running','private':'secret'}} if name.endswith('adapters') else {'driver':{'collectedAtUtc':'2026-10-20T12:00:00Z','dwmCrashes':[]}}
        with tempfile.TemporaryDirectory() as root,patch.object(soak,'load',side_effect=lambda name: diagnostics if name=='diagnose-graphics' else metrics),patch.object(soak.subprocess,'check_output',return_value='127.0.0.1:7148'),patch.object(metrics,'gpu_sample',return_value={'available':False}),patch.object(metrics,'container_sample',return_value={'cpuPercentOfOneCore':150}),patch.object(diagnostics,'read_endpoint',side_effect=endpoint):
            output=Path(root)/'run.jsonl'
            result=soak.record('fixture',1,15,output,clock=lambda:now[0],sleeper=sleep)
            self.assertTrue(result['completed']);self.assertEqual(result['validCpuSamples'],4)
            data=[json.loads(line) for line in output.read_text().splitlines()]
            self.assertEqual(data[0]['kind'],'header');self.assertEqual(data[-1]['kind'],'summary')
            self.assertNotIn('secret',output.read_text())
            with self.assertRaises(FileExistsError): soak.record('fixture',1,15,output)
            now[0]=0
            def interrupt(seconds): raise KeyboardInterrupt()
            interrupted=Path(root)/'interrupted.jsonl'
            partial=soak.record('fixture',1,15,interrupted,clock=lambda:now[0],sleeper=interrupt)
            self.assertFalse(partial['completed']);self.assertEqual(partial['validCpuSamples'],1)
            checkpoint=json.loads(interrupted.read_text().splitlines()[-1])
            self.assertEqual(checkpoint['kind'],'summary');self.assertFalse(checkpoint['completed'])

    def test_idle_frames_are_not_hangs_and_stale_telemetry_is_separate(self):
        rows=[{'kind':'sample','elapsedSeconds':i*60,'intervalSeconds':60,'container':{},'adapters':{'helios':{}},
               'viewer':[{'pid':1,'console':0,'monotonicUs':stamp,'renderedFrames':10,'coalescedUpdates':0}]} for i,stamp in enumerate((100,200,200))]
        self.assertIsNone(soak.summarize(rows)['suspectedStallIntervals'])
        result=soak.summarize(rows,True)
        self.assertEqual(result['suspectedStallIntervals'],1)
        self.assertEqual(result['staleViewerTelemetryIntervals'],1)
        self.assertEqual(result['observedRenderedFrames'],0)


if __name__=='__main__': unittest.main()

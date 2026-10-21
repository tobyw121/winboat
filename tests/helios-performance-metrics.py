import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('metrics',Path(__file__).resolve().parents[1]/'scripts/helios/measure-performance.py')
metrics=importlib.util.module_from_spec(spec);spec.loader.exec_module(metrics)


class MetricsTests(unittest.TestCase):
    def test_cpu_above_one_hundred_is_preserved(self):
        with patch.object(metrics.subprocess,'check_output',return_value='{"CPUPerc":"325.5%","MemPerc":"12%"}'):
            self.assertEqual(metrics.container_sample('WinBoat')['cpuPercentOfOneCore'],325.5)

    def test_invalid_data_is_not_a_zero_load_sample(self):
        with patch.object(metrics.subprocess,'check_output',return_value='{"CPUPerc":"NaN%","MemPerc":"12%"}'):
            sample=metrics.container_sample('WinBoat')
        self.assertIn('error',sample)
        self.assertIsNone(metrics.summarize([{'container':sample}])['meanCpuPercentOfOneCore'])

    def test_viewer_counters_exclude_private_fields_and_invalid_numbers(self):
        text='prefix {"event":"statistics","pid":1,"console":2,"monotonicUs":5,"renderedFrames":9,"path":"PRIVATE","copySamples":-1}\n'
        result=metrics.viewer_metrics(text)
        self.assertEqual(result,[{'pid':1,'console':2,'monotonicUs':5,'renderedFrames':9}])
        self.assertEqual(metrics.viewer_metrics('{"event":"statistics","pid":true,"console":0,"monotonicUs":1}'),[])

    def test_multiple_gpu_metrics_and_unavailable_sensor(self):
        with patch.object(metrics.shutil,'which',return_value='/tool'),patch.object(metrics.subprocess,'check_output',return_value='00000000:01:00.0, 42, 1024, 75.50\n00000000:02:00.0, N/A, 500, N/A'):
            result=metrics.gpu_sample()
        self.assertEqual(len(result['devices']),2)
        self.assertEqual(result['devices'][0]['powerWatts'],75.5)
        self.assertNotIn('utilizationPercent',result['devices'][1])

    def test_comparison_context_only_includes_fixed_safe_settings(self):
        inspect='"sha256:pin"\n["PASSWORD=PRIVATE", "CPU_CORES=6", "HELIOS_DISPLAY_WIDTH=1920"]'
        preflight='{"devices":[{"selected":true,"deviceUuid":"gpu"}]}'
        with patch.object(metrics.subprocess,'check_output',side_effect=[inspect,preflight]):
            result=metrics.comparison_context('WinBoat')
        self.assertNotIn('PRIVATE',str(result));self.assertEqual(result['settings']['CPU_CORES'],'6')
        self.assertEqual(result['settings']['HELIOS_DISPLAY_WIDTH'],'1920')

    def test_phase_samples_do_not_sum_overlapping_transports(self):
        result=metrics.phase_summary([{'kind':'capture','published':1,'submitNanoseconds':1000000,'waitNanoseconds':2000000,'cpuNanoseconds':3000000},
                                      {'kind':'capture','published':0,'cpuNanoseconds':999999999},
                                      {'kind':'ack','success':1,'waitMicroseconds':5000}])
        self.assertEqual(result['submitMeanMs'],1)
        self.assertEqual(result['waitMeanMs'],2)
        self.assertEqual(result['ackMeanMs'],5)
        self.assertNotIn('total',result)
        self.assertIsNone(metrics.phase_summary([])['cpuMeanMs'])

    def test_viewer_phases_reject_reset_and_keep_console_identity(self):
        rows=[{'pid':1,'console':0,'monotonicUs':100,'copySamples':2,'sourceCopyWallUs':1000},
              {'pid':2,'console':0,'monotonicUs':100,'copySamples':100},
              {'pid':1,'console':0,'monotonicUs':1000100,'copySamples':4,'sourceCopyWallUs':5000}]
        result=metrics.viewer_phase_summary(rows)
        self.assertEqual(len(result),1)
        self.assertEqual(result[0]['sourceCopyWallUsMeanMs'],2)
        rows[-1]['copySamples']=1
        self.assertNotIn('sourceCopyWallUsMeanMs',metrics.viewer_phase_summary(rows)[0])


if __name__ == '__main__': unittest.main()

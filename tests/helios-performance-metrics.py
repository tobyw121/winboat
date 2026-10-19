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


if __name__ == '__main__': unittest.main()

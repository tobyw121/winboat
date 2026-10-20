import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location('support',ROOT/'scripts/helios/export-support.py')
support=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(support)


class ExportTests(unittest.TestCase):
    def test_nested_private_strings_and_unknown_fields_never_export(self):
        source={'password':'secret','host':{'image':'private-registry/user','qemuBackend':{'backend':'dbus','renderNode':'/dev/dri/renderD128','performance':{'requestedAccelerator':'kvm','ioThreads':[{'pollMaxNs':0}]}}},
                'graphics/diagnostics':{'driver':{'application':{'loadedApplications':[{'name':'dwm.exe','modules':[{'name':'vulkan_virtio.dll','path':'C:\\Users\\private\\x.dll'}]}],
                                                               'umdLogs':[{'file':'umd-123.log','codes':['VK_ERROR_DEVICE_LOST'],'journal':{'firstFailure':[{'kind':'resource','values':['28','1920']}]}}]}}}}
        filtered=support.filter_report(source)
        encoded=json.dumps(filtered)
        self.assertNotIn('private',encoded);self.assertNotIn('secret',encoded)
        self.assertIn('pollMaxNs',encoded);self.assertIn('kvm',encoded);self.assertIn('VK_ERROR_DEVICE_LOST',encoded);self.assertIn('1920',encoded)
        self.assertIsNone(support.filter_report(10**1000))
        self.assertIsNone(support.filter_report(float('nan')))

    def test_numeric_resource_and_heap_observations_survive_filter(self):
        data={'host':{'gpuHeap':{'observation':{'ready':True,'devices':[{'deviceUuid':'a'*32,'heaps':[{'usageBytes':42,'budgetBytes':99}]}]}},
                      'frameMetrics':[{'kind':'resource-create','resourceId':8,'inode':9,'ownedBytes':50}],'private':'secret'},
              'correlation':{'resourceTimeline':[{'resourceId':8,'events':[{'kind':'resource-frame','sequence':2}]}]}}
        result=support.filter_report(data)
        self.assertEqual(result['host']['gpuHeap']['observation']['devices'][0]['heaps'][0]['usageBytes'],42)
        self.assertEqual(result['host']['frameMetrics'][0]['resourceId'],8)
        self.assertNotIn('secret',json.dumps(result))

    def test_real_cli_requires_review_and_exclusive_output(self):
        with tempfile.TemporaryDirectory() as root:
            report=Path(root)/'report.json';out=Path(root)/'support.json'
            report.write_text(json.dumps({'version':{'version':'0.8.7'},'dump':'PRIVATE-MEMORY'}))
            payload,digest=support.prepare(report)
            command=[sys.executable,str(ROOT/'scripts/helios/export-support.py'),str(report)]
            self.assertIn(digest,subprocess.check_output(command,text=True))
            failed=subprocess.run(command+['--output',str(out)],capture_output=True)
            self.assertNotEqual(failed.returncode,0);self.assertFalse(out.exists())
            subprocess.check_call(command+['--output',str(out),'--review-sha256',digest])
            self.assertEqual(out.read_bytes(),payload)
            self.assertEqual(hashlib.sha256(payload).hexdigest(),digest)
            self.assertNotIn('PRIVATE',out.read_text())
            self.assertNotEqual(subprocess.run(command+['--output',str(out),'--review-sha256',digest],capture_output=True).returncode,0)


if __name__=='__main__': unittest.main()

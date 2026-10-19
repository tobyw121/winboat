import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('performance', Path(__file__).resolve().parents[1]/'helios/host/performance.py')
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)
BASE = ['-m','2G','-device','virtio-scsi-pci,id=scsi','-drive','file=disk.raw,cache=writeback,aio=threads',
        '-device','virtio-net-pci,netdev=n0','-netdev','tap,id=n0,script=no,downscript=no',
        '-object','memory-backend-memfd,id=ram,size=2G,share=on','-qmp','unix:/tmp/qmp,server=on,wait=off']


class PerformanceTests(unittest.TestCase):
    def test_default_and_rescue_preserve_every_argument(self):
        self.assertEqual(perf.options(BASE,{}),BASE)
        self.assertEqual(perf.options(BASE,{'HELIOS_RESCUE':'1','HELIOS_NET_QUEUES':'invalid'}),BASE)
        for query in [['--version'],['-device','virtio-gpu-gl-pci,help'],['-cpu','help']]:
            self.assertEqual(perf.options(query,{'HELIOS_IO_THREAD':'1','HELIOS_HUGEPAGES':'2M'}),query)

    def test_io_and_network_keep_disk_flush_policy_and_qmp(self):
        result = perf.options(BASE,{'HELIOS_NET_QUEUES':'4','HELIOS_IO_THREAD':'1'})
        self.assertIn('virtio-net-pci,netdev=n0,mq=on,vectors=10',result)
        self.assertIn('tap,id=n0,script=no,downscript=no,queues=4',result)
        self.assertIn('iothread,id=helios-io',result)
        self.assertIn('file=disk.raw,cache=writeback,aio=threads',result)
        self.assertIn(BASE[-1],result)
        self.assertNotIn('iothread=helios-io',BASE[3])

    def test_incompatible_user_configuration_is_refused(self):
        for args, env in [(BASE+['-device','virtio-scsi-pci,id=other'],{'HELIOS_IO_THREAD':'1'}),
                          ([v.replace('tap,id=n0','user,id=n0') for v in BASE],{'HELIOS_NET_QUEUES':'2'}),
                          ([v.replace('tap,id=n0','tap,id=n0,fd=9') for v in BASE],{'HELIOS_NET_QUEUES':'2'}),
                          (BASE,{'HELIOS_NET_QUEUES':'9'})]:
            with self.subTest(env=env),self.assertRaises(ValueError): perf.options(args,env)

    def test_hugepages_require_available_reservation(self):
        env={'HELIOS_HUGEPAGES':'2M','HELIOS_PREALLOC':'1'}
        self.assertIn('memory-backend-memfd,id=ram,size=2G,share=on,hugetlb=on,hugetlbsize=2097152,prealloc=on',perf.options(BASE,env,1024))
        with self.assertRaises(ValueError): perf.options(BASE,env,1023)
        with self.assertRaises(ValueError): perf.options(BASE,{'HELIOS_HUGEPAGES':'invalid'})

    def test_cache_identity_and_symlink_rejection(self):
        with tempfile.TemporaryDirectory() as root:
            a=perf.cache_environment({},root,b'driver-a'); b=perf.cache_environment({},root,b'driver-b')
            self.assertNotEqual(a['MESA_SHADER_CACHE_DIR'],b['MESA_SHADER_CACHE_DIR'])
            parent=Path(root)/'.winboat-cache/graphics'
            for path in parent.iterdir(): path.rmdir()
            parent.rmdir();parent.symlink_to(root,target_is_directory=True)
            with self.assertRaises(ValueError): perf.cache_environment({},root,b'driver-a')

    def test_cpu_lists_are_bounded(self):
        self.assertEqual(perf.cpu_set('1,3-5'),{1,3,4,5})
        for value in ['','5-3','0-999999','1;reboot','-1']:
            with self.assertRaises(ValueError): perf.cpu_set(value)

    def test_frame_trace_is_explicit_and_preserves_existing_policy(self):
        self.assertEqual(perf.options(BASE,{'HELIOS_FRAME_TRACE':'1'})[-2:],['-trace','enable=helios_vulkan_capture'])
        with self.assertRaises(ValueError): perf.options(BASE+['-trace','events=custom'],{'HELIOS_FRAME_TRACE':'1'})


if __name__ == '__main__': unittest.main()

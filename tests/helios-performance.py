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
    def test_dbus_audio_is_opt_in_preserves_backend_identity_and_never_changes_rescue(self):
        env={'HELIOS_AUDIO_DBUS':'1','HELIOS_DISPLAY':'dbus'}
        result=perf.options(BASE,env);self.assertIn('dbus,id=winboat-audio',result)
        old=BASE+['-device','intel-hda','-device','hda-duplex','-audiodev','none,id=old']
        result=perf.options(old,env);self.assertIn('dbus,id=old',result);self.assertIn('hda-duplex,audiodev=old',result)
        self.assertEqual(perf.options(BASE,{**env,'HELIOS_RESCUE':'1'}),BASE)
        with self.assertRaises(ValueError):perf.options(BASE,{'HELIOS_AUDIO_DBUS':'1'})

    def test_vram_admission_uses_85_percent_and_private_launch_ledger(self):
        report={'devices':[{'selected':True,'heaps':[{'deviceLocal':True,'sizeBytes':8*1024**3},{'deviceLocal':False,'sizeBytes':32*1024**3}]}]}
        with tempfile.TemporaryDirectory() as folder:
            result=perf.vram_environment({},report,folder)
            self.assertEqual(int(result['VKR_DEVICE_MEMORY_LIMIT_BYTES']),8*1024**3*85//100)
            self.assertEqual(result['HELIOS_VRAM_CAP_BYTES'],result['VKR_DEVICE_MEMORY_LIMIT_BYTES'])
            self.assertEqual(Path(result['HELIOS_VRAM_BUDGET_FILE']).stat().st_mode & 0o777,0o600)
            limited=perf.vram_environment({'VKR_DEVICE_MEMORY_LIMIT_BYTES':'1048576'},report,folder)
            self.assertEqual(limited['HELIOS_VRAM_CAP_BYTES'],'1048576')
            self.assertNotEqual(result['HELIOS_VRAM_BUDGET_FILE'],limited['HELIOS_VRAM_BUDGET_FILE'])
            for bad in ({'devices':[]},{'devices':report['devices']*2}):
                with self.assertRaises(ValueError): perf.vram_environment({},bad,folder)

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

    def test_cache_fingerprint_tracks_uuid_runtime_and_profile_not_load(self):
        gpu={'selected':True,'deviceUuid':'a'*32,'driverUuid':'b'*32,'vendorId':4318,'deviceId':7943,'apiVersion':1}
        report={'devices':[gpu]};runtime={'patches':'hash-a','renderer':'hash-b'}
        baseline=perf.graphics_cache_fingerprint(report,runtime)
        self.assertEqual(baseline,perf.graphics_cache_fingerprint({'devices':[{'selected':False},{**gpu,'budget':123}]},dict(reversed(list(runtime.items())))))
        for changed in ({**gpu,'driverUuid':'c'*32},{**gpu,'deviceUuid':'d'*32}):
            self.assertNotEqual(baseline,perf.graphics_cache_fingerprint({'devices':[changed]},runtime))
        self.assertNotEqual(baseline,perf.graphics_cache_fingerprint(report,{**runtime,'patches':'new'}))
        self.assertNotEqual(baseline,perf.graphics_cache_fingerprint(report,runtime,'icarus-v2'))
        for report_,runtime_,namespace in (({'devices':[]},runtime,'default'),({'devices':[gpu,gpu]},runtime,'default'),
                ({'devices':[{**gpu,'driverUuid':'0'*32}]},runtime,'default'),(report,{},'default'),(report,runtime,'../escape')):
            with self.assertRaises(ValueError):perf.graphics_cache_fingerprint(report_,runtime_,namespace)

    def test_cache_identity_and_symlink_rejection(self):
        with tempfile.TemporaryDirectory() as root:
            a=perf.cache_environment({},root,b'driver-a'); b=perf.cache_environment({},root,b'driver-b')
            self.assertNotEqual(a['MESA_SHADER_CACHE_DIR'],b['MESA_SHADER_CACHE_DIR'])
            for key in ('MESA_SHADER_CACHE_DIR','__GL_SHADER_DISK_CACHE_PATH'):
                leaf=Path(a[key])
                self.assertTrue(leaf.is_dir())
                self.assertEqual(leaf.stat().st_mode & 0o777,0o700)
                leaf.rmdir();leaf.symlink_to(root,target_is_directory=True)
                with self.assertRaises(ValueError): perf.cache_environment({},root,b'driver-a')
                leaf.unlink();leaf.mkdir(mode=0o700)
            with self.assertRaises(ValueError): perf.cache_environment({},'relative',b'driver-a')
            parent=Path(root)/'.winboat-cache/graphics'
            for path in parent.iterdir():
                for leaf in path.iterdir(): leaf.rmdir()
                path.rmdir()
            parent.rmdir();parent.symlink_to(root,target_is_directory=True)
            with self.assertRaises(ValueError): perf.cache_environment({},root,b'driver-a')

    def test_guest_agent_is_local_opt_in_and_relative_mouse_replaces_only_the_standard_tablet(self):
        result=perf.options(BASE,{'HELIOS_AGENT_CHANNEL':'1'})
        self.assertIn('unix:/run/winboat-maintenance-qmp,server=on,wait=off',result)
        self.assertNotIn('/run/winboat-qga',BASE)
        with self.assertRaises(ValueError):perf.options(result,{'HELIOS_AGENT_CHANNEL':'1'})
        args=BASE+['-device','usb-tablet,id=input,bus=usb.0']
        self.assertIn('usb-mouse,id=input,bus=usb.0',perf.options(args,{'HELIOS_RELATIVE_MOUSE':'1'}))
        with self.assertRaises(ValueError):perf.options(BASE,{'HELIOS_RELATIVE_MOUSE':'1'})
        self.assertEqual(perf.options(args,{'HELIOS_RESCUE':'1','HELIOS_RELATIVE_MOUSE':'1'}),args)

    def test_cpu_lists_are_bounded(self):
        self.assertEqual(perf.cpu_set('1,3-5'),{1,3,4,5})
        for value in ['','5-3','0-999999','1;reboot','-1']:
            with self.assertRaises(ValueError): perf.cpu_set(value)

    def test_frame_trace_is_explicit_and_preserves_existing_policy(self):
        self.assertEqual(perf.options(BASE,{'HELIOS_FRAME_TRACE':'1'})[-2:],['-trace','enable=helios_vulkan_capture'])
        with self.assertRaises(ValueError): perf.options(BASE+['-trace','events=custom'],{'HELIOS_FRAME_TRACE':'1'})

    def test_explicit_io_polling_preserves_other_policies(self):
        result=perf.options(BASE,{'HELIOS_IO_THREAD':'1','HELIOS_IO_POLL_NS':'0'})
        self.assertIn('iothread,id=helios-io,poll-max-ns=0',result)
        self.assertIn('file=disk.raw,cache=writeback,aio=threads',result)
        for env in ({'HELIOS_IO_POLL_NS':'0'},{'HELIOS_IO_THREAD':'1','HELIOS_IO_POLL_NS':'-1'},
                    {'HELIOS_IO_THREAD':'1','HELIOS_IO_POLL_NS':'999999999'}):
            with self.assertRaises(ValueError): perf.options(BASE,env)

    def test_readback_import_limit_is_opt_in_and_bounded(self):
        self.assertEqual(perf.options(BASE,{'HELIOS_READBACK_CACHE_ENTRIES':'2'}),BASE)
        for bad in ('0','16','-1','two'):
            with self.assertRaises(ValueError): perf.options(BASE,{'HELIOS_READBACK_CACHE_ENTRIES':bad})


if __name__ == '__main__': unittest.main()

import importlib.util
import pathlib
import unittest

path = pathlib.Path(__file__).resolve().parents[1] / 'scripts/helios/inspect-qemu-backend.py'
spec = importlib.util.spec_from_file_location('backend', path)
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)


class BackendTests(unittest.TestCase):
    def base(self):
        return ['qemu-system-x86_64', '-display', 'dbus,gl=on,rendernode=/dev/dri/renderD128',
                '-device', 'virtio-gpu-gl-pci,venus=on,blob=on',
                '-object', 'memory-backend-memfd,id=ram,share=on', '-machine', 'q35,memory-backend=ram']

    def test_actual_combinations_and_wrong_memory_wiring(self):
        args = self.base()
        self.assertEqual(backend.inspect(args)['issues'], [])
        self.assertIn('dbus-gl-and-vnc-incompatible', backend.inspect(args + ['-vnc', ':0'])['issues'])
        args[2] = 'egl-headless,rendernode=/dev/dri/renderD128'
        self.assertEqual(backend.inspect(args + ['-vnc', ':0'])['issues'], [])
        args[-1] = 'q35,memory-backend=other'
        self.assertIn('shared-memfd-not-wired', backend.inspect(args)['issues'])

    def test_rescue_and_no_unrelated_command_line_leak(self):
        self.assertTrue(backend.inspect(['qemu', '-display', 'none', '-vga', 'std'])['vgaRescue'])
        result = backend.inspect(self.base() + ['-smb', 'secret-password', '-name', 'private-user'])
        self.assertNotIn('secret', str(result))
        self.assertNotIn('private', str(result))
        self.assertIn('display-count-invalid', backend.inspect(self.base() + ['-display', 'none'])['issues'])

    def test_performance_audit_filters_paths_and_identifies_emulation(self):
        args=self.base()+['-accel','tcg','-cpu','qemu64','-smp','6,sockets=1,cores=6,threads=1',
                          '-drive','file=/private/disk.raw,cache=unsafe,aio=threads,format=raw',
                          '-device','e1000e,netdev=n0','-object','iothread,id=private-name,poll-max-ns=0']
        report=backend.inspect(args)['performance']
        self.assertEqual(report['topology']['cpus'],6)
        self.assertEqual(report['ioThreads'][0]['pollMaxNs'],0)
        self.assertIn('software-cpu-emulation',report['warnings'])
        self.assertIn('unsafe-disk-cache',report['warnings'])
        self.assertIn('emulated-network-adapter',report['warnings'])
        self.assertNotIn('private',str(report))
        self.assertEqual(backend.performance(['qemu','-enable-kvm','-cpu','host'])['warnings'],[])


if __name__ == '__main__':
    unittest.main()

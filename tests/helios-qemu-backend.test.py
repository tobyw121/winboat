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


if __name__ == '__main__':
    unittest.main()

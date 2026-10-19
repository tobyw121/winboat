"""Exercise the real offline identity reader with checksummed payload fixtures."""
import hashlib
import importlib.util
import json
import lzma
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('identity', Path(__file__).resolve().parents[1] / 'scripts/helios/installer-identity.py')
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


class IdentityTests(unittest.TestCase):
    def inspect(self, entries, extra=b''):
        header = struct.pack('<I', len(entries))
        for name, data in entries:
            name = name.encode()
            header += struct.pack('<H', len(name)) + name + struct.pack('<Q', len(data))
        payload = header + lzma.compress(b''.join(data for _, data in entries) + extra)
        self.exe = b'MZ' + b'\0' * 126 + payload + struct.pack('<QQQ', 128, len(payload), len(header)) + hashlib.sha256(payload).digest() + b'HLIOSET2'
        return self.read()

    def read(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'installer.exe'
            path.write_bytes(self.exe)
            return reader.identity(path)

    def test_exact_manifest_identity(self):
        data = json.dumps({'version': '22.22.294.0'}).encode()
        result = self.inspect([('driver/data', b'other'), ('manifest.json', data)])
        self.assertEqual(result, {'manifestSha256': hashlib.sha256(data).hexdigest(), 'driverVersion': '22.22.294.0'})

    def test_checksum_and_bounds(self):
        self.inspect([('manifest.json', b'{"version":"x"}')])
        self.exe = self.exe[:130] + bytes([self.exe[130] ^ 1]) + self.exe[131:]
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.read()
        self.inspect([('manifest.json', b'{"version":"x"}')])
        self.exe = self.exe[:-64] + struct.pack('<Q', 0) + self.exe[-56:]
        with self.assertRaisesRegex(ValueError, 'bounds'):
            self.read()

    def test_missing_duplicate_and_trailing_data(self):
        for entries, extra in [([('other', b'x')], b''), ([('manifest.json', b'{}'), ('MANIFEST.JSON', b'{}')], b''), ([('manifest.json', b'{"version":"x"}')], b'undeclared')]:
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                self.inspect(entries, extra)


if __name__ == '__main__':
    unittest.main()

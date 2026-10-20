import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile
ROOT=Path(__file__).resolve().parents[1]
class BundleTests(unittest.TestCase):
    def test_real_cli_exports_only_fixed_filtered_entries_and_pins_preview(self):
        with tempfile.TemporaryDirectory() as folder:
            report=Path(folder)/'raw.json';output=Path(folder)/'support.zip'
            report.write_text(json.dumps({'password':'PRIVATE','version':{'version':'0.8.7'},'host':{'transportErrors':[{'kind':'buffer-size-mismatch','requiredBytes':4587520,'bufferBytes':4096000}]}}))
            cli=[sys.executable,str(ROOT/'scripts/helios/support-bundle.py'),str(report)]
            preview=json.loads(subprocess.check_output(cli,text=True))
            self.assertNotIn('PRIVATE',json.dumps(preview))
            args=cli+['--output',str(output),'--review-sha256',preview['sha256']]
            subprocess.check_call(args)
            self.assertEqual(output.stat().st_mode&0o777,0o600)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(set(archive.namelist()),{'README.txt','report.json','manifest.json'})
                manifest=json.loads(archive.read('manifest.json'))
                for row in manifest['files']:self.assertEqual(hashlib.sha256(archive.read(row['name'])).hexdigest(),row['sha256'])
                self.assertNotIn(b'PRIVATE',b''.join(archive.read(name) for name in archive.namelist()))
            self.assertNotEqual(subprocess.run(args,capture_output=True).returncode,0)
            output.unlink();report.write_text('{"version":{"version":"changed"}}')
            self.assertNotEqual(subprocess.run(args,capture_output=True).returncode,0)
            self.assertFalse(output.exists())
if __name__=='__main__':unittest.main()

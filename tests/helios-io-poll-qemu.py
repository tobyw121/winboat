"""Execute production I/O-thread options against actual QEMU (no guest disk/GPU)."""
import importlib.util
import json
from pathlib import Path
import select
import subprocess
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('performance',ROOT/'helios/host/performance.py')
perf=importlib.util.module_from_spec(spec);spec.loader.exec_module(perf)


class QemuPollingTest(unittest.TestCase):
    def test_actual_iothread_property_and_clean_quit(self):
        binary='/opt/helios/qemu/bin/qemu-system-x86_64'
        for poll in ('0','32768'):
            args=perf.options(['-machine','q35,accel=tcg','-m','128M','-nodefaults','-display','none','-S',
                               '-device','virtio-scsi-pci,id=scsi','-qmp','stdio'],{'HELIOS_IO_THREAD':'1','HELIOS_IO_POLL_NS':poll})
            with subprocess.Popen([binary,*args],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE) as process:
                def receive(identifier=None):
                    while True:
                        if not select.select([process.stdout],[],[],10)[0]: raise AssertionError('QMP timeout')
                        line=process.stdout.readline()
                        if not line: raise AssertionError(process.stderr.read().decode())
                        event=json.loads(line)
                        if identifier is None or event.get('id')==identifier: return event
                def command(name):
                    process.stdin.write((json.dumps({'execute':name,'id':name})+'\n').encode());process.stdin.flush()
                    return receive(name)
                try:
                    self.assertIn('QMP',receive())
                    self.assertIn('return',command('qmp_capabilities'))
                    threads=command('query-iothreads')['return']
                    self.assertEqual(len(threads),1)
                    self.assertEqual(threads[0]['id'],'helios-io')
                    self.assertEqual(threads[0]['poll-max-ns'],int(poll))
                    command('quit');self.assertEqual(process.wait(timeout=10),0)
                finally:
                    if process.poll() is None: process.kill();process.wait(timeout=5)


if __name__=='__main__': unittest.main()

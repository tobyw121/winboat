import copy
import importlib.util
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('trial',ROOT/'scripts/helios/graphics-trial.py')
trial=importlib.util.module_from_spec(spec);spec.loader.exec_module(trial)
IDENTITY='a'*64

def status(enabled=False):
    return {'sampleAgeMs':0,'basic':{'state':'running'},'helios':{'state':'running' if enabled else 'disabled'},
            'desktop':{'managed':True,'basic':{'state':'active','primary':True},'helios':{'state':'active' if enabled else 'inactive'}}}

class TrialTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.store=trial.Store(Path(self.tmp.name)/'trial')
        self.identify=lambda _:IDENTITY
    def start(self,spawn=lambda *a,**k:None):
        return trial.begin(self.store,'WinBoat',spawn=spawn,probe=lambda _:status(),identify=self.identify)['id']
    def action(self,container,op,**kw):
        self.assertEqual(container,IDENTITY)
        return {'status':'enabled' if op=='helios-enable' else 'disabled'}
    def test_requires_fresh_healthy_primary_vga(self):
        for change in ('old','primary','managed','helios'):
            data=status()
            if change=='old':data['sampleAgeMs']=11000
            if change=='primary':data['desktop']['basic']['primary']=False
            if change=='managed':data['desktop']['managed']=False
            if change=='helios':data['helios']['state']='running'
            with self.assertRaises(ValueError):trial.begin(self.store,'WinBoat',probe=lambda _:data,identify=self.identify)
    def test_timeout_and_confirmation(self):
        token=self.start();deadline=self.store.read()['deadline'];calls=[]
        def restore(*args):calls.append(True)
        tick=[deadline-1]
        trial.watch(self.store,token,now=lambda:tick[0],sleeper=lambda _:tick.__setitem__(0,deadline),action=self.action,identify=self.identify,restore=restore)
        self.assertEqual(calls,[True])
        trial.recover(self.store,token,action=self.action,identify=self.identify)
        token=self.start();calls=[]
        def keep(_):trial.command(self.store,token,'keep')
        trial.watch(self.store,token,sleeper=keep,action=self.action,identify=self.identify,probe=lambda _:status(True),restore=restore)
        self.assertEqual(self.store.read()['phase'],'confirmed');self.assertEqual(calls,[])
    def test_failed_confirmation_recovers(self):
        token=self.start();calls=[]
        trial.watch(self.store,token,sleeper=lambda _:trial.command(self.store,token,'keep'),action=self.action,identify=self.identify,
                    probe=lambda _:status(),restore=lambda *args:calls.append(True))
        self.assertEqual(calls,[True])
    def test_container_replacement_never_changes_devices(self):
        token=self.start();calls=[]
        state=trial.recover(self.store,token,identify=lambda _:'b'*64,action=lambda *a,**k:calls.append('guest'),host=lambda *a:calls.append('host'))
        self.assertEqual(state['phase'],'recovery-failed');self.assertEqual(calls,[])
    def test_guest_failure_uses_existing_host_rescue(self):
        token=self.start();calls=[]
        result=trial.recover(self.store,token,identify=self.identify,action=lambda *a,**k:{'status':'blocked'},host=lambda *a:calls.append(a))
        self.assertEqual(calls,[(IDENTITY,False)]);self.assertEqual(result['route'],'vga-only-host')
        trial.recover(self.store,token,identify=self.identify,host=lambda *a:self.fail('duplicate rescue'))
    def test_cancel_cannot_race_enable_and_resurrect_trial(self):
        token=self.start();entered=threading.Event();release=threading.Event();calls=[]
        def action(*args,**kwargs):
            calls.append(args[1])
            if args[1]=='helios-enable':entered.set();self.assertTrue(release.wait(3))
            return self.action(*args,**kwargs)
        def restore(store,token):trial.recover(store,token,action=action,identify=self.identify)
        worker=threading.Thread(target=trial.watch,args=(self.store,token),kwargs={'action':action,'identify':self.identify,'restore':restore})
        worker.start();self.assertTrue(entered.wait(3));trial.command(self.store,token,'cancel')
        cancel=threading.Thread(target=restore,args=(self.store,token));cancel.start();release.set()
        worker.join(4);cancel.join(4)
        self.assertFalse(worker.is_alive() or cancel.is_alive());self.assertEqual(calls,['helios-enable','helios-disable'])
        self.assertEqual(self.store.read()['phase'],'recovery-requested')
    def test_detached_watchdog_and_unresolved_trial(self):
        launches=[];self.start(spawn=lambda *a,**k:launches.append(k))
        self.assertTrue(launches[0]['start_new_session'])
        with self.assertRaises(ValueError):self.start()
    def test_state_symlink_and_public_permissions_refused(self):
        token=self.start();state=self.store.root/'trial.json';state.chmod(0o644)
        with self.assertRaises(ValueError):self.store.read()
        state.unlink();state.symlink_to(Path(self.tmp.name)/'unknown')
        with self.assertRaises(OSError):self.store.read()

if __name__=='__main__':unittest.main()

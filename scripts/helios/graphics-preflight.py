"""Fail-closed compatibility assessment; observations are not installation permission."""
import re

def assess(host,guest,viewer,receipt,expected):
    checks=[]
    def check(name,actual,want):
        checks.append({'name':name,'state':'unknown' if actual is None or want is None else 'match' if actual==want else 'mismatch'})
    check('host-runtime',host.get('runtimeVersion'),expected.get('runtime'))
    check('display-protocol',host.get('displayVersion'),expected.get('display'))
    check('guest-graphics',guest.get('graphics_protocol'),expected.get('guest'))
    check('guest-runtime',guest.get('runtime_protocol'),expected.get('guestRuntime'))
    check('viewer',viewer,expected.get('viewer'))
    check('driver-source',receipt.get('revision'),expected.get('revision'))
    check('installer-bytes',receipt.get('installerVerified'),True)
    checks.append({'name':'bundle-receipt','state':'match' if all(re.fullmatch(r'[a-fA-F0-9]{64}',str(receipt.get(k,''))) for k in ('sha256','manifestSha256')) and re.fullmatch(r'22\.22\.\d+\.0',str(receipt.get('driverVersion',''))) else 'unknown'})
    issues=host.get('qemuBackend',{}).get('issues')
    checks.append({'name':'running-backend','state':'match' if issues==[] else 'unknown' if issues is None else 'mismatch'})
    return {'state':'compatible-observed' if all(c['state']=='match' for c in checks) else 'blocked', 'checks':checks,
            'scope':'Version and receipt checks only. Verify selected installer SHA-256, retain a verified offline backup and run rendering acceptance separately.'}

def repair(adapters,transaction):
    basic=adapters.get('basic',{});helios=adapters.get('helios',{})
    fresh=type(adapters.get('sampleAgeMs')) is int and 0<=adapters['sampleAgeMs']<=10000
    if not fresh:return {'step':'refresh','action':'status','reason':'Fresh native adapter observation required'}
    if basic.get('state')!='running':return {'step':'isolate-host','action':'rescue-boot','reason':'VGA is not verified running; use a VGA-only boot before device maintenance'}
    if helios.get('state')=='running':return {'step':'isolate-guest','action':'helios-disable','reason':'Keep VGA running and verify Helios disabled before repair'}
    if helios.get('state')=='disabled':return {'step':'rescue-before-cleanup','action':'rescue-boot','reason':'Disabled is not physically absent. DriverStore cleanup requires a VGA-only boot'}
    if transaction.get('status') in ('rollback-required','rollback-staged','rollback-cleanup-restart'):
        return {'step':'verify-stable-rollback','action':'prepare-rollback','reason':'Cleanup and rollback retain their own identity and backup prerequisites'}
    return {'step':'inspect','action':'status','reason':'No verified automated next repair step; inspect installed packages in Windows'}

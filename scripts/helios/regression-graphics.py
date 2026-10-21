#!/usr/bin/env python3
"""Read-only regression checkpoints around operator-controlled power/display changes."""
import argparse
import datetime
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import urllib.request

def load(name):
    s=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'));m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m

def stamp(value):
    try:
        t=datetime.datetime.fromisoformat(value.replace('Z','+00:00'))
        return t.timestamp() if t.tzinfo else None
    except (ValueError,AttributeError):return None

def capture(container):
    d=load('diagnose-graphics');c=load('graphics-center');base=c.endpoint(container)
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),d.NoRedirect())
    values={}
    for endpoint in ('graphics/adapters','graphics/diagnostics/runtime','graphics/diagnostics','graphics/validation'):
        values[endpoint]=d.read_endpoint(opener,base,endpoint,20)
    raw=subprocess.check_output(['docker','inspect','--format','{{json .Image}}\n{{json .State.StartedAt}}',container],text=True,timeout=5).splitlines()
    return {'schema':1,'hostImage':json.loads(raw[0]),'hostStartedAt':json.loads(raw[1]),
            'adapters':values['graphics/adapters'],'runtime':values['graphics/diagnostics/runtime'].get('driver',{}),
            'controllers':values['graphics/diagnostics'].get('driver',{}).get('controllers',[]),
            'acceptance':values['graphics/validation'].get('acceptance',{})}

def assess(before,after,scenario):
    failures=[];missing=[]
    first=before.get('acceptance',{});last=after.get('acceptance',{})
    a=first.get('identity',{});b=last.get('identity',{})
    for key in ('machineId','version','manifestSha256','profile'):
        if a.get(key) is None or b.get(key) is None:missing.append(key)
        elif a[key]!=b[key]:failures.append('changed-'+key)
    if not before.get('hostImage') or not after.get('hostImage'):missing.append('host-image')
    elif before['hostImage']!=after['hostImage']:failures.append('host-image-changed')
    rt=after.get('runtime',{});start=stamp(before.get('runtime',{}).get('collectedAtUtc'));end=stamp(rt.get('collectedAtUtc'))
    if start is None or end is None or end<start:missing.append('guest-clock-window')
    finish=stamp(last.get('finishedAtUtc'))
    if last.get('automatedPassed') is not True or last.get('runId') is None or last.get('runId')==first.get('runId') or finish is None or start is None or end is None or not start<=finish<=end:missing.append('fresh-post-transition-acceptance')
    for name in ('D3D11 1x resize','D3D11 format contracts'):
        rows=[r for r in last.get('tests',[]) if r.get('name')==name and r.get('status')=='passed' and r.get('exitCode')==0 and isinstance(r.get('sha256'),str) and len(r['sha256'])==64]
        if len(rows)!=1:missing.append('post-transition-pixel-probe-'+name)
    if not b.get('bootAtUtc') or b.get('bootAtUtc')!=rt.get('bootAtUtc'):missing.append('current-boot-acceptance')
    for kind in ('dwmCrashes','displayResets'):
        for event in rt.get(kind,[]):
            at=stamp(event.get('timeUtc'))
            if start is not None and at is not None and at>=start:failures.append(kind)
    if rt.get('errors') or not rt.get('collectedAtUtc'):missing.append('runtime-observation')
    adapters=after.get('adapters',{})
    if not 0<=adapters.get('sampleAgeMs',-1)<=10000:missing.append('fresh-adapters')
    if any(adapters.get(name,{}).get('state')!='running' for name in ('basic','helios')):failures.append('adapter-not-running')
    if adapters.get('helios',{}).get('desktopState')!='active':missing.append('active-helios-output')
    transition=False
    if scenario=='cold-boot':
        transition=bool(before.get('hostStartedAt') and after.get('hostStartedAt') and before['hostStartedAt']!=after['hostStartedAt'] and
                        before.get('runtime',{}).get('bootAtUtc') and rt.get('bootAtUtc') and before['runtime']['bootAtUtc']!=rt['bootAtUtc'])
    elif scenario=='standby':
        events=sorted((stamp(e.get('timeUtc')),e.get('kind')) for e in rt.get('powerEvents',[]) if stamp(e.get('timeUtc')) is not None and start is not None and stamp(e['timeUtc'])>start)
        transition=any(x[1]=='sleep' and y[1]=='resume' and x[0]<y[0] for x in events for y in events)
    elif scenario=='resize':
        def extent(s):
            rows=[r for r in s.get('controllers',[]) if str(r.get('PNPDeviceID','')).upper().startswith('PCI\\VEN_1AF4&DEV_1050')]
            if len(rows)!=1:return None
            r=rows[0];w=r.get('CurrentHorizontalResolution');h=r.get('CurrentVerticalResolution')
            return (w,h) if type(w) is int and type(h) is int and w>0 and h>0 else None
        transition=extent(before) is not None and extent(after) is not None and extent(before)!=extent(after)
    elif scenario=='logon':
        old=before.get('runtime',{}).get('consoleLogonId');new=rt.get('consoleLogonId')
        transition=bool(old and new and old!=new and before.get('runtime',{}).get('bootAtUtc')==rt.get('bootAtUtc'))
    # DWM restart, a new session number or elapsed time alone cannot prove logon.
    if not transition:missing.append('scenario-transition-proof')
    return {'scenario':scenario,'state':'failed' if failures else 'inconclusive' if missing else 'passed',
            'failures':sorted(set(failures)),'missing':sorted(set(missing)),
            'scope':'Automated evidence assessment, no power actions. Guest standby events do not prove host suspend. Logon requires a changed authentication LUID within the same boot. Visible recovery remains a separate observation.'}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--container',default='WinBoat');p.add_argument('--output',type=Path,required=True)
    p.add_argument('--before',type=Path);p.add_argument('--scenario',choices=('cold-boot','standby','resize','logon'));a=p.parse_args()
    try:
        if bool(a.before)!=bool(a.scenario):raise ValueError('Provide --before and --scenario together')
        current=capture(a.container)
        if a.before:
            if a.before.stat().st_size>1048576:raise ValueError('Checkpoint too large')
            before=json.loads(a.before.read_text(encoding='utf-8-sig'));current['assessment']=assess(before,current,a.scenario)
        with os.fdopen(os.open(a.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as out:json.dump(current,out,indent=2)
        print(json.dumps(current.get('assessment',{'state':'baseline-recorded'})))
    except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as e:p.exit(1,str(e)+'\n')
if __name__=='__main__':main()

#!/usr/bin/env python3
"""Bounded read-only long-run sampling; never restart, install or enable a GPU."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request


def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def adapter_sample(data):
    if 'error' in data: return {'error':'unavailable'}
    result={}
    for name in ('helios','basic'):
        if isinstance(data.get(name),dict):
            result[name]={key:data[name][key] for key in ('state','problemCode') if key in data[name]}
    return result


def summarize(rows):
    cpu=[];memory=[];events=set();boots=set();dwm=set();gaps=0;missing=0;errors=0
    start=None;last=None
    for row in rows:
        if row.get('kind')!='sample': continue
        elapsed=row['elapsedSeconds']
        if last is not None and elapsed-last>row['intervalSeconds']*1.5: gaps+=1
        last=elapsed
        if start is None: start=elapsed
        sample=row.get('container',{})
        if 'cpuPercentOfOneCore' in sample: cpu.append(sample['cpuPercentOfOneCore'])
        if 'memoryPercent' in sample: memory.append((elapsed,sample['memoryPercent']))
        adapters=row.get('adapters',{})
        if 'error' in adapters or not isinstance(adapters.get('helios'),dict): missing+=1
        runtime=row.get('runtime')
        if runtime is not None:
            driver=runtime.get('driver',{})
            if 'error' in runtime or driver.get('errors'): errors+=1
            if driver.get('bootAtUtc'): boots.add(driver['bootAtUtc'])
            current=driver.get('collectedAtUtc','')
            for process in driver.get('dwmProcesses',[]):
                dwm.add((process.get('processId'),process.get('startedAtUtc')))
            for kind in ('dwmCrashes','displayResets'):
                for event in driver.get(kind,[]):
                    # Exclude historical events preceding the first runtime
                    # sample in the guest clock domain. Host UTC may differ.
                    if row.get('baselineGuestUtc') and event.get('timeUtc','')>=row['baselineGuestUtc']:
                        events.add((kind,event.get('timeUtc'),event.get('ProcessId'),event.get('recordId')))
    slope=None
    if len(memory)>1 and memory[-1][0]>memory[0][0]:
        slope=(memory[-1][1]-memory[0][1])/(memory[-1][0]-memory[0][0])*3600
    return {'validCpuSamples':len(cpu),'meanCpuPercentOfOneCore':sum(cpu)/len(cpu) if cpu else None,
            'containerMemoryPercentagePointsPerHour':slope,'observedEventCount':len(events),
            'observedDwmProcessIdentities':len(dwm),'observedBootIdentities':len(boots),
            'missingAdapterSamples':missing,'runtimeErrorSamples':errors,'samplingGaps':gaps,
            'scope':'Observed events are a lower bound. DWM identities are not crash counts. Memory trend is not proof of a leak. No visible-frame or hang guarantee.'}


def record(container, minutes, interval, output, clock=time.monotonic, sleeper=time.sleep):
    if not 1<=minutes<=1440 or not 15<=interval<=300: raise ValueError('Use 1..1440 minutes and 15..300 seconds')
    diagnostics=load('diagnose-graphics');metrics=load('measure-performance')
    port=subprocess.check_output(['docker','port',container,'7148/tcp'],text=True,timeout=10).splitlines()
    number=int(port[0].rsplit(':',1)[1]) if port else 0
    if not 1<=number<=65535: raise ValueError('Guest API port unavailable')
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),diagnostics.NoRedirect())
    base=f'http://127.0.0.1:{number}';started=clock();next_slow=0;baseline=None;rows=[];completed=False
    fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as stream,ThreadPoolExecutor(max_workers=2) as pool:
        def write(data):
            stream.write(json.dumps(data,separators=(',',':'))+'\n');stream.flush()
        write({'kind':'header','schema':1,'minutes':minutes,'intervalSeconds':interval,
               'startedAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat()})
        try:
            while clock()-started<minutes*60:
                begin=clock();elapsed=begin-started
                future=pool.submit(metrics.container_sample,container)
                row={'kind':'sample','elapsedSeconds':elapsed,'intervalSeconds':interval,
                     'adapters':adapter_sample(diagnostics.read_endpoint(opener,base,'graphics/adapters',timeout=3))}
                row['container']=future.result()
                if elapsed>=next_slow:
                    row['runtime']=diagnostics.read_endpoint(opener,base,'graphics/diagnostics/runtime',timeout=20)
                    stamp=row['runtime'].get('driver',{}).get('collectedAtUtc')
                    if baseline is None and stamp: baseline=stamp
                    row['baselineGuestUtc']=baseline
                    next_slow=elapsed+300
                rows.append(row);write(row)
                # Output remains available during interruption; no sleep >30s.
                deadline=min(started+minutes*60,begin+interval)
                while clock()<deadline: sleeper(min(30,deadline-clock()))
            # Closing runtime sample also captures failures in the last 5min.
            final=diagnostics.read_endpoint(opener,base,'graphics/diagnostics/runtime',timeout=20)
            row={'kind':'sample','elapsedSeconds':clock()-started,'intervalSeconds':interval,
                 'runtime':final,'baselineGuestUtc':baseline,'adapters':adapter_sample(diagnostics.read_endpoint(opener,base,'graphics/adapters',timeout=3)),'container':{}}
            rows.append(row);write(row);completed=True
        except KeyboardInterrupt:
            pass
        finally:
            summary=summarize(rows);summary['completed']=completed
            write({'kind':'summary',**summary})
    return summary


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container',default='WinBoat');parser.add_argument('--minutes',type=int,default=60)
    parser.add_argument('--interval',type=int,default=60);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    try:
        result=record(args.container,args.minutes,args.interval,args.output)
        print('Recording:',args.output);print(json.dumps(result,indent=2))
        if not result['validCpuSamples']: parser.exit(1,'No CPU observations; inspect saved failures.\n')
    except (OSError,ValueError,subprocess.SubprocessError) as error: parser.exit(1,str(error)+'\n')


if __name__=='__main__': main()

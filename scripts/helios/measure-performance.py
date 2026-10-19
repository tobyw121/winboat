#!/usr/bin/env python3
"""Read-only host sampling for interleaved A/B comparisons; no VM changes."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime
import json
import math
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import time

VIEWER_FIELDS = ('pid','console','monotonicUs','dmabufFrames','softwareFrames','renderedFrames',
                 'sourceCopyWallUs','completionWaitUs','copySamples','skippedRedraws','coalescedUpdates')


def viewer_metrics(text):
    result=[]
    for line in text.splitlines():
        start=line.find('{"event":"statistics"')
        if start < 0: continue
        try: data=json.loads(line[start:])
        except ValueError: continue
        clean={key:data[key] for key in VIEWER_FIELDS if type(data.get(key)) is int and 0 <= data[key] <= 2**63-1}
        if all(key in clean for key in ('pid','console','monotonicUs')): result.append(clean)
    return result[-120:]


def container_sample(container):
    try:
        raw=subprocess.check_output(['docker','stats','--no-stream','--format','{{json .}}',container],timeout=8,text=True)
        if len(raw)>16384: raise ValueError('Oversized metrics')
        data=json.loads(raw)
        values={}
        for field,key in [('CPUPerc','cpuPercentOfOneCore'),('MemPerc','memoryPercent')]:
            if not re.fullmatch(r'\d+(?:\.\d+)?%',str(data.get(field,''))): raise ValueError('Invalid percentage')
            value=float(data[field][:-1])
            if not math.isfinite(value) or value>100000: raise ValueError('Invalid percentage')
            values[key]=value
        return values
    except (OSError,ValueError,subprocess.SubprocessError) as error:
        return {'error':type(error).__name__}


def gpu_sample():
    if not shutil.which('nvidia-smi'): return {'available':False}
    try:
        output=subprocess.check_output(['nvidia-smi','--query-gpu=pci.bus_id,utilization.gpu,memory.used,power.draw',
                                        '--format=csv,noheader,nounits'],timeout=5,text=True)
        if len(output)>8192: raise ValueError('Oversized GPU metrics')
        devices=[]
        for line in output.splitlines()[:8]:
            values=[v.strip() for v in line.split(',')]
            if len(values)!=4 or not re.fullmatch(r'[0-9a-fA-F:.]{7,16}',values[0]): continue
            item={'pciBusId':values[0]}
            for key,value in zip(('utilizationPercent','memoryUsedMiB','powerWatts'),values[1:]):
                if re.fullmatch(r'\d+(?:\.\d+)?',value): item[key]=float(value)
            devices.append(item)
        return {'available':True,'devices':devices}
    except (OSError,ValueError,subprocess.SubprocessError) as error:
        return {'available':False,'error':type(error).__name__}


def summarize(samples):
    values=[s['container']['cpuPercentOfOneCore'] for s in samples if 'cpuPercentOfOneCore' in s['container']]
    return {'validCpuSamples':len(values),'meanCpuPercentOfOneCore':statistics.mean(values) if values else None,
            'medianCpuPercentOfOneCore':statistics.median(values) if values else None}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container',default='WinBoat')
    parser.add_argument('--label',required=True,help='Comparison arm, for example A1 or B1')
    parser.add_argument('--samples',type=int,choices=range(2,61),default=10)
    parser.add_argument('--interval',type=int,choices=range(1,31),default=2)
    parser.add_argument('--viewer-log',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9_.-]{1,48}',args.label): parser.error('Use a short comparison label')
    samples=[];started=time.monotonic()
    with ThreadPoolExecutor(max_workers=2) as pool:
        for index in range(args.samples):
            begin=time.monotonic()
            container=pool.submit(container_sample,args.container);gpu=pool.submit(gpu_sample)
            samples.append({'elapsedSeconds':begin-started,'container':container.result(),'gpu':gpu.result(),
                            'sampleDurationSeconds':time.monotonic()-begin})
            if index+1<args.samples: time.sleep(max(0,args.interval-(time.monotonic()-begin)))
    report={'label':args.label,'collectedAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'elapsedSeconds':time.monotonic()-started,'samples':samples,'summary':summarize(samples),
            'scope':'Container CPU includes QEMU and renderer; 100% is one host CPU. No guest FPS or latency claim.'}
    if args.viewer_log:
        with args.viewer_log.open('rb') as stream:
            stream.seek(max(0,args.viewer_log.stat().st_size-262144))
            report['viewer']=viewer_metrics(stream.read(262144).decode('utf-8',errors='replace'))
        report['viewerScope']='Fixed counters from a bounded log tail; verify PID, console and monotonic interval before comparing.'
    descriptor=os.open(args.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(descriptor,'w') as output: json.dump(report,output,indent=2);output.write('\n')
    print('Recording:',args.output)
    print(json.dumps(report['summary']))
    if not report['summary']['validCpuSamples']: parser.exit(1,'No valid container CPU samples; report contains the failures.\n')


if __name__ == '__main__': main()

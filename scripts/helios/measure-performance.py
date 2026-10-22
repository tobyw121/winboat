#!/usr/bin/env python3
"""Read-only host sampling for interleaved A/B comparisons; no VM changes."""
import argparse
import csv
import importlib.util
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

VIEWER_FIELDS = ('requestedTransportMode','accelerated','width','height','requestedWidth','requestedHeight','resizeRequestFailed','pid','console','monotonicUs','dmabufFrames','softwareFrames','renderedFrames',
                 'sourceCopyWallUs','completionWaitUs','copySamples','skippedRedraws','coalescedUpdates','sourceInode')


def read_frame_times(path, application):
    spec=importlib.util.spec_from_file_location('comparison',Path(__file__).with_name('compare-graphics.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    if path.stat().st_size>67108864: raise ValueError('Frame CSV exceeds 64 MiB')
    values=[];pids=set();rejected=0
    with path.open(newline='',encoding='utf-8-sig') as stream:
        for row in csv.DictReader(stream):
            if row.get('Application','').casefold()!=application.casefold(): continue
            try:
                value=float(row['MsBetweenPresents'])
                if not math.isfinite(value) or not 0<value<=60000: raise ValueError()
                pids.add(int(row['ProcessID']));values.append(value)
            except (ValueError,KeyError): rejected+=1
    if len(pids)!=1 or len(values)<2: raise ValueError('Select one application process with at least two valid presents')
    result=module.frame_summary(values)
    result.update(meanPresentIntervalMs=sum(values)/len(values),presentCallsPerSecond=1000*len(values)/sum(values))
    result.update(processId=next(iter(pids)),rejectedSamples=rejected,
                  scope='PresentMon MsBetweenPresents; presentation intervals, not input latency or displayed-frame proof')
    return result


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


def phase_summary(records):
    captures=[r for r in records if r.get('kind')=='capture' and r.get('published')==1]
    result={}
    for key in ('submitNanoseconds','waitNanoseconds','cpuNanoseconds'):
        values=[r[key]/1e6 for r in captures if type(r.get(key)) is int and 0<=r[key]<2**63]
        result[key.replace('Nanoseconds','MeanMs')]=statistics.mean(values) if values else None
    acks=[r['waitMicroseconds']/1000 for r in records if r.get('kind')=='ack' and r.get('success')==1 and type(r.get('waitMicroseconds')) is int]
    result.update(captureSamples=len(captures),ackSamples=len(acks),ackMeanMs=statistics.mean(acks) if acks else None,
                  scope='Independent bounded samples; ACK and capture may overlap. Submit CPU time is not GPU render time. Never sum across transports.')
    return result


def viewer_phase_summary(records):
    groups={};result=[]
    for row in records:
        key=(row['pid'],row['console'])
        groups.setdefault(key,[]).append(row)
    for (pid,console),rows in groups.items():
        first,last=rows[0],rows[-1]
        if last['monotonicUs']<=first['monotonicUs']: continue
        item={'pid':pid,'console':console,'elapsedSeconds':(last['monotonicUs']-first['monotonicUs'])/1e6}
        for field in ('sourceCopyWallUs','completionWaitUs','copySamples','renderedFrames','coalescedUpdates','skippedRedraws'):
            if field in first and field in last and last[field]>=first[field]: item[field+'Delta']=last[field]-first[field]
        count=item.get('copySamplesDelta',0)
        if count:
            for field in ('sourceCopyWallUs','completionWaitUs'):
                if field+'Delta' in item: item[field+'MeanMs']=item[field+'Delta']/count/1000
        result.append(item)
    return result


def transport_evidence(rows,requested):
    rows=[r for r in rows if r.get('accelerated')==1]
    identities={(r['pid'],r['console'],r.get('width'),r.get('height'),r.get('requestedTransportMode')) for r in rows}
    if len(rows)<2 or len(identities)!=1:return {'state':'unknown','reason':'Need one stable Helios console and multiple fresh samples'}
    first,last=rows[0],rows[-1];mode=1 if requested=='copy' else 2
    if first.get('requestedTransportMode')!=mode or not first.get('width') or not first.get('height') or last['monotonicUs']<=first['monotonicUs']:return {'state':'unknown','reason':'Requested path or geometry not observed'}
    deltas={key:last.get(key,0)-first.get(key,0) for key in ('softwareFrames','dmabufFrames')}
    expected='softwareFrames' if requested=='copy' else 'dmabufFrames';other='dmabufFrames' if requested=='copy' else 'softwareFrames'
    valid=deltas[expected]>0 and deltas[other]==0
    return {'state':'observed' if valid else 'unknown','transport':requested,'width':first['width'],'height':first['height'],'deltas':deltas,
            'scope':'Completed source reads during this measurement; not displayed FPS or GPU render time'}

def comparison_context(container):
    try:
        fields=subprocess.check_output(['docker','inspect','--format','{{json .Image}}\n{{json .Config.Env}}',container],text=True,timeout=5).splitlines()
        image=json.loads(fields[0]);values=dict(item.split('=',1) for item in json.loads(fields[1]) if '=' in item)
        names=('RAM_SIZE','CPU_CORES','HELIOS_DISPLAY','HELIOS_DISPLAY_WIDTH','HELIOS_DISPLAY_HEIGHT','VKR_DEVICE_MEMORY_LIMIT_BYTES','HELIOS_SHADER_CACHE','HELIOS_IO_THREAD','HELIOS_IO_POLL_NS','HELIOS_IDLE_REFRESH','HELIOS_READBACK_DAMAGE','HELIOS_READBACK_BUDGET_MIB','HELIOS_READBACK_CACHE_ENTRIES')
        preflight=json.loads(subprocess.check_output(['docker','exec',container,'cat','/run/helios-gpu-preflight.json'],text=True,timeout=5))
        uuids=[d['deviceUuid'] for d in preflight.get('devices',[]) if d.get('selected') is True and d.get('deviceUuid')]
        return {'imageId':image,'gpu':uuids,'settings':{key:values.get(key) for key in names},
                'scope':'Configured host settings only. Match actual guest resolution and scene manually.'}
    except (OSError,ValueError,KeyError,IndexError,subprocess.SubprocessError):return {'error':'comparison-context-unavailable'}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container',default='WinBoat')
    parser.add_argument('--label',required=True,help='Comparison arm, for example A1 or B1')
    parser.add_argument('--samples',type=int,choices=range(2,61),default=10)
    parser.add_argument('--interval',type=int,choices=range(1,31),default=2)
    parser.add_argument('--viewer-log',type=Path)
    parser.add_argument('--comparison-key',help='Same workload, resolution and settings identifier for A/B/A/B')
    parser.add_argument('--frame-csv',type=Path,help='Existing PresentMon CSV; collection is never started automatically')
    parser.add_argument('--frame-application',help='Exact Application column value; one PID required')
    parser.add_argument('--transport-mode',choices=('copy','dmabuf'),help='Verify the explicitly selected viewer test mode; requires --viewer-log')
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if bool(args.frame_csv)!=bool(args.frame_application): parser.error('Provide both frame CSV and application')
    if args.comparison_key and not re.fullmatch(r'[a-zA-Z0-9_.-]{1,96}',args.comparison_key): parser.error('Invalid comparison key')
    if args.transport_mode and not args.viewer_log:parser.error('--transport-mode requires --viewer-log')
    log_start=args.viewer_log.stat() if args.viewer_log else None
    frames=None
    if args.frame_csv:
        try: frames=read_frame_times(args.frame_csv,args.frame_application)
        except (OSError,ValueError) as error: parser.error(str(error))
    if not re.fullmatch(r'[a-zA-Z0-9_.-]{1,48}',args.label): parser.error('Use a short comparison label')
    context_before=comparison_context(args.container)
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
    context_after=comparison_context(args.container)
    report.update(comparisonKey=args.comparison_key,frameTimes=frames,context=context_before,contextStable=context_before==context_after)
    if args.viewer_log:
        try:
            with args.viewer_log.open('rb') as stream:
                end=os.fstat(stream.fileno());same=(end.st_dev,end.st_ino)==(log_start.st_dev,log_start.st_ino) and end.st_size>=log_start.st_size
                count=end.st_size-log_start.st_size if same else 0
                stream.seek(max(log_start.st_size,end.st_size-262144) if same else end.st_size)
                report['viewer']=viewer_metrics(stream.read(262144).decode('utf-8',errors='replace'))
                report['viewerWindowComplete']=same and count<=262144
        except OSError:
            report.update(viewer=[],viewerWindowComplete=False,viewerError='Viewer log unavailable during measurement')
        if args.transport_mode:
            report['transportEvidence']=transport_evidence(report['viewer'],args.transport_mode) if report['viewerWindowComplete'] else {'state':'unknown','reason':'Viewer log rotated or exceeded capture bound'}
            report['transportMode']=args.transport_mode
        report['viewerPhases']=viewer_phase_summary(report['viewer'])
        report['viewerScope']='Fixed counters from a bounded log tail; verify PID, console and monotonic interval before comparing.'
    descriptor=os.open(args.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(descriptor,'w') as output: json.dump(report,output,indent=2);output.write('\n')
    print('Recording:',args.output)
    print(json.dumps(report['summary']))
    if args.transport_mode and report.get('transportEvidence',{}).get('state')!='observed':parser.exit(2,'Requested transport not verified; report retained. Use a moving scene and the matching viewer test mode.\n')
    if not report['summary']['validCpuSamples']: parser.exit(1,'No valid container CPU samples; report contains the failures.\n')


if __name__ == '__main__': main()

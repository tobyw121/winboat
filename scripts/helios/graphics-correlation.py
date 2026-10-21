"""Bounded evidence grouping. Host and guest UTC clocks are not assumed equal."""
import datetime
import re


def instant(value):
    if not isinstance(value,str): return None
    try:
        stamp=datetime.datetime.fromisoformat(value.replace('Z','+00:00'))
        return stamp.timestamp() if stamp.tzinfo else None
    except ValueError: return None


def contract_violations(row):
    issues=[]
    def number(name):
        value=row.get(name)
        return value if type(value) is int and value>=0 else None
    size=number('bufferBytes');required=number('requiredBytes');offset=number('offset');alignment=number('alignment')
    if size is not None and required is not None and required>size:issues.append('required-size-exceeds-fd')
    if alignment is not None and (not alignment or alignment&(alignment-1)):issues.append('invalid-alignment')
    if offset is not None and alignment and offset%alignment:issues.append('misaligned-offset')
    if number('planes') not in (None,1):issues.append('unsupported-plane-count')
    image=number('imageMemoryBits');fd=number('fdMemoryBits')
    if image is not None and fd is not None and not image&fd:issues.append('no-compatible-memory-type')
    width=number('width');height=number('height');stride=number('stride')
    if width==0 or height==0:issues.append('empty-extent')
    # Row-major bounds only for explicit LINEAR RGBA8/BGRA8. Never infer a
    # tiled/OPTIMAL allocation's byte extent from pitch times height.
    if row.get('tiling')==1 and row.get('format') in (37,44) and None not in (width,height,stride,offset,size) and width and height:
        if stride<width*4:issues.append('short-linear-stride')
        if offset+(height-1)*stride+width*4>size:issues.append('linear-extent-exceeds-fd')
    return issues

def lifetime(events):
    state='unknown';issues=[];cycles=0
    for index,row in enumerate(events):
        kind=row['kind']
        if kind=='resource-create':
            if state=='live':issues.append({'eventIndex':index,'kind':'create-before-release'})
            state='live';cycles+=1
        elif kind=='resource-frame':
            if state=='released':issues.append({'eventIndex':index,'kind':'frame-after-release'})
        elif kind=='resource-release':
            if state=='released':issues.append({'eventIndex':index,'kind':'repeated-release'})
            state='released'
    return {'observedCreates':cycles,'tailState':state,'possibleViolations':issues,
            'prefixComplete':bool(events and events[0]['kind']=='resource-create'),
            'scope':'Bounded tail; open resources are not leaks. IDs may be reused after a process restart; violations require a matching process epoch.'}

def frame_evidence(rows):
    # Vulkan capture counters and listener ACK counters are independent. Their
    # coincident numeric value must never be used as a cross-stage frame ID.
    frames={}
    for row in rows:
        if row.get('kind') not in ('capture','resource-frame'):continue
        key=(row.get('inode'),row.get('sequence'))
        if None in key:continue
        frames.setdefault(key,[]).append(row)
    result=[]
    for (inode,sequence),events in frames.items():
        captures=[r for r in events if r['kind']=='capture'];resources=[r for r in events if r['kind']=='resource-frame']
        result.append({'inode':inode,'sequence':sequence,'events':events,
                      'association':'candidate' if len(captures)==len(resources)==1 else 'ambiguous-or-incomplete'})
    return {'captureCandidates':result,'acks':[r for r in rows if r.get('kind')=='ack'],
            'endToEndVerified':False,'scope':'No common guest/host/viewer frame token yet. Candidate inode/sequence joins require the same process epoch. ACK is source-read completion, not visible presentation.'}

def correlate(report):
    runtime=report.get('graphics/diagnostics/runtime',{}).get('driver',{})
    timing=report.get('requestTiming',{}).get('graphics/diagnostics/runtime',{})
    guest=instant(runtime.get('collectedAtUtc'))
    start=instant(timing.get('startUtc'));end=instant(timing.get('endUtc'))
    # Collection happens between request and response; report an interval, not
    # a single guessed offset. Never mix naive timestamps with UTC.
    offset=None
    if None not in (guest,start,end) and start<=end:
        offset={'minimumSeconds':guest-end,'maximumSeconds':guest-start}
    application=report.get('graphics/diagnostics',{}).get('driver',{}).get('application',{})
    events=[]
    for kind,entries in [('dwm-crash',runtime.get('dwmCrashes',[])),('display-reset',runtime.get('displayResets',[])),
                         ('application-crash',application.get('crashes',[]))]:
        for entry in entries[:16]:
            if instant(entry.get('timeUtc')) is None: continue
            row={'kind':kind,'guestAtUtc':entry['timeUtc']}
            for key in ('ProcessId','AppName','ModuleName','ExceptionCode','FaultingOffset','recordId'):
                if key in entry: row[key]=entry[key]
            events.append(row)
    logs=[]
    for entry in application.get('umdLogs',[])[:8]:
        if re.fullmatch(r'umd(?:12)?-\d{1,10}\.log',str(entry.get('file',''))):
            logs.append({key:entry[key] for key in ('file','updatedAtUtc','signals','codes') if key in entry})
    resources={}
    for row in report.get('host',{}).get('frameMetrics',[]):
        if row.get('kind') not in ('resource-create','resource-release','resource-frame'): continue
        key=(row['resourceId'],row['source'],row['inode'])
        group=resources.setdefault(key,{'resourceId':key[0],'source':key[1],'inode':key[2],'events':[]})
        group['events'].append(row)
    contracts={}
    for row in report.get('host',{}).get('frameMetrics',[]):
        if row.get('kind') in ('dmabuf-export','dmabuf-import'):
            contracts.setdefault(row['inode'],[]).append(row)
    for group in resources.values():group['lifetime']=lifetime(group['events'])
    contract_rows=[]
    for inode,contract_events in contracts.items():
        imports=[row for row in contract_events if row['kind']=='dmabuf-import']
        comparisons=[{'requiredBytes':r['requiredBytes'],'bufferBytes':r['bufferBytes'],'violations':contract_violations(r),
                      'verdict':'undersized' if r['requiredBytes']>r['bufferBytes'] else
                                'size-equal' if r['requiredBytes']==r['bufferBytes'] else 'padded-or-different-layout'} for r in imports]
        contract_rows.append({'inode':inode,'events':contract_events,'sizeChecks':comparisons,
                              'multipleExports':sum(row['kind']=='dmabuf-export' for row in contract_events)>1})
    first_failure=next(iter(report.get('host',{}).get('transportErrors',[])),None)
    return {'schema':1,'captureId':report.get('captureId'),'guestMinusHostClockRange':offset,
            'bufferContracts':contract_rows,'frameEvidence':frame_evidence(report.get('host',{}).get('frameMetrics',[])),
            'resourceTimeline':list(resources.values()),'firstObservedHostFailure':first_failure,
            'resourceScope':'Process-local IDs and bounded historical tail; no inferred equality with guest KMD IDs or Vulkan object handles.',
            'guestEvents':events,'umdFiles':logs,'hostEvents':report.get('host',{}).get('transportErrors',[])[-32:],
            'scope':'Separate clock domains. File modification times and reused PIDs do not establish crash causality. Missing evidence is unknown.'}

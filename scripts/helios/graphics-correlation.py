"""Bounded evidence grouping. Host and guest UTC clocks are not assumed equal."""
import datetime
import re


def instant(value):
    if not isinstance(value,str): return None
    try:
        stamp=datetime.datetime.fromisoformat(value.replace('Z','+00:00'))
        return stamp.timestamp() if stamp.tzinfo else None
    except ValueError: return None


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
    contract_rows=[]
    for inode,events in contracts.items():
        imports=[row for row in events if row['kind']=='dmabuf-import']
        comparisons=[{'requiredBytes':r['requiredBytes'],'bufferBytes':r['bufferBytes'],
                      'verdict':'undersized' if r['requiredBytes']>r['bufferBytes'] else
                                'size-equal' if r['requiredBytes']==r['bufferBytes'] else 'padded-or-different-layout'} for r in imports]
        contract_rows.append({'inode':inode,'events':events,'sizeChecks':comparisons,
                              'multipleExports':sum(row['kind']=='dmabuf-export' for row in events)>1})
    first_failure=next(iter(report.get('host',{}).get('transportErrors',[])),None)
    return {'schema':1,'captureId':report.get('captureId'),'guestMinusHostClockRange':offset,
            'bufferContracts':contract_rows,
            'resourceTimeline':list(resources.values()),'firstObservedHostFailure':first_failure,
            'resourceScope':'Process-local IDs and bounded historical tail; no inferred equality with guest KMD IDs or Vulkan object handles.',
            'guestEvents':events,'umdFiles':logs,'hostEvents':report.get('host',{}).get('transportErrors',[])[-32:],
            'scope':'Separate clock domains. File modification times and reused PIDs do not establish crash causality. Missing evidence is unknown.'}

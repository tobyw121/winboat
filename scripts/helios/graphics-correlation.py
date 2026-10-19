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
    return {'schema':1,'captureId':report.get('captureId'),'guestMinusHostClockRange':offset,
            'guestEvents':events,'umdFiles':logs,'hostEvents':report.get('host',{}).get('transportErrors',[])[-32:],
            'scope':'Separate clock domains. File modification times and reused PIDs do not establish crash causality. Missing evidence is unknown.'}

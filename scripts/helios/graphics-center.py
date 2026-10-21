#!/usr/bin/env python3
"""Fixed on-demand graphics status and maintenance for the WinBoat UI."""
import argparse
import datetime
import importlib.util
import json
from pathlib import Path
import subprocess
import urllib.request

def module(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result

diag=module('diagnose-graphics');rescue=module('rescue-graphics')

def transport(rows,now=None):
    now=now or datetime.datetime.now(datetime.timezone.utc)
    rows=[r for r in rows if r.get('kind')=='ack' and r.get('success')==1]
    if not rows:return {'state':'unknown'}
    row=rows[-1]
    try:age=(now-datetime.datetime.fromisoformat(row['hostAtUtc'].replace('Z','+00:00'))).total_seconds()
    except (KeyError,ValueError):return {'state':'unknown'}
    return {'state':'recent' if 0<=age<=10 else 'historical','transport':row['transport'],'ageSeconds':round(age,1),
            'scope':'Last acknowledged host transport; does not prove visible pixels.'}

def summary(host,adapters,driver,validation):
    controllers=driver.get('controllers',[])
    app=driver.get('application',{})
    transaction=validation.get('transaction',{})
    return {'schema':1,'adapters':adapters,
            'boundVersions':sorted({c['DriverVersion'] for c in controllers if isinstance(c.get('DriverVersion'),str)}),
            'loadedModules':[{k:m[k] for k in ('name','version') if k in m} for p in app.get('loadedApplications',[])[:8] for m in p.get('modules',[])[:16]],
            'transaction':{k:transaction[k] for k in ('status','reason') if k in transaction},
            'stable':validation.get('last-good',{}).get('version','not-recorded'),
            'candidate':transaction.get('candidate',{}).get('version','not-recorded'),
            'backend':host.get('qemuBackend',{}).get('backend','unknown'),
            'runtime':host.get('runtimeVersion','unknown'),'transport':transport(host.get('frameMetrics',[])),
            'recentTransportErrors':host.get('transportErrors',[])[-8:],
            'scope':'On-demand observations only. Missing module version, stale sample or absent frame trace remains unknown.'}

def endpoint(container):
    lines=subprocess.check_output(['docker','port',container,'7148/tcp'],text=True,timeout=5).splitlines()
    port=int(lines[0].rsplit(':',1)[1])
    if not 1<=port<=65535:raise ValueError('Invalid guest API port')
    return f'http://127.0.0.1:{port}'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('status','helios-disable','rescue-boot','restore-host','check-update','prepare-rollback','capture-enable','capture-disable'))
    parser.add_argument('--container',default='WinBoat');args=parser.parse_args()
    try:
        if args.action in ('rescue-boot','restore-host'):
            rescue.host_action(args.container,args.action=='restore-host');result={'status':'restart-requested'}
        elif args.action=='helios-disable':result=rescue.guest_action(args.container,args.action)
        else:
            base=endpoint(args.container);opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),rescue.NoRedirect())
            if args.action=='status':
                adapters=diag.read_endpoint(opener,base,'graphics/adapters',3)
                driver=diag.read_endpoint(opener,base,'graphics/diagnostics',20).get('driver',{})
                validation=diag.read_endpoint(opener,base,'graphics/validation',3)
                result=summary(diag.collect_host(args.container),adapters,driver,validation)
            else:
                request=urllib.request.Request(base+'/graphics/maintenance',data=b'',method='POST',headers={'X-WinBoat-Maintenance':args.action})
                with opener.open(request,timeout=60) as response:
                    data=response.read(65537)
                    if len(data)>65536:raise ValueError('Maintenance response too large')
                    result=json.loads(data)
        print(json.dumps(result))
    except (OSError,ValueError,RuntimeError,KeyError,IndexError,subprocess.SubprocessError) as error:parser.exit(1,str(error)+'\n')
if __name__=='__main__':main()

#!/usr/bin/env python3
"""Read-only host/network/stack checks and private comparable performance records."""
import argparse,datetime,hashlib,importlib.util,json,os,re,shutil,socket,subprocess,uuid
from pathlib import Path

def load(name):
 s=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'));m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m

def command(args,timeout=8):
 try:
  p=subprocess.run(args,capture_output=True,text=True,timeout=timeout)
  return {'available':p.returncode==0,'output':p.stdout[:32768] if p.returncode==0 else ''}
 except (OSError,subprocess.SubprocessError):return {'available':False,'output':''}

def host():
 checks=[]
 def add(name,state,detail):checks.append({'name':name,'state':state,'detail':detail})
 add('kvm','ready' if os.access('/dev/kvm',os.R_OK|os.W_OK) else 'unavailable','KVM device access for this user')
 nodes=sorted(Path('/dev/dri').glob('renderD*'))
 add('render-nodes','ready' if any(os.access(p,os.R_OK|os.W_OK) for p in nodes) else 'unavailable','Accessible DRM render node required for accelerated Helios')
 desktop=bool(os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY'))
 add('desktop-session','present' if desktop else 'unavailable','Session variables alone do not prove a working display')
 for binary,args in [('docker',['version','--format','{{.Server.Version}}']),('glxinfo',['-B']),('vulkaninfo',['--summary'])]:
  r=command([binary,*args]);add(binary,'observed' if r['available'] else 'unavailable',r['output'])
 gtk=command(['pkg-config','--modversion','gtk4']);add('gtk4-build-metadata','observed' if gtk['available'] else 'unknown',gtk['output'])
 free=shutil.disk_usage(Path.home()).free;add('home-free-bytes','observed',free)
 return {'schema':1,'checks':checks,'scope':'Read-only observations. Docker device access, GTK context creation and actual rendering require the dedicated probes.'}

def reachable(address,port,timeout=2):
 try:
  with socket.create_connection((address,port),timeout):return True
 except OSError:return False

def network(container):
 info=json.loads(subprocess.check_output(['docker','inspect',container],text=True,timeout=8))[0]
 bindings=info.get('NetworkSettings',{}).get('Ports') or {};rows=[]
 for name,port in [('guest-api',7148),('rdp',3389),('browser-display',8006)]:
  entries=bindings.get(str(port)+'/tcp') or []
  ports=sorted({int(e['HostPort']) for e in entries})
  rows.append({'name':name,'state':'reachable' if any(reachable('127.0.0.1',p) for p in ports) else 'unreachable' if ports else 'unpublished','hostPorts':ports})
 mode=info.get('HostConfig',{}).get('NetworkMode','unknown')
 drivers=[]
 for n in info.get('NetworkSettings',{}).get('Networks',{}):
  r=command(['docker','network','inspect','--format','{{.Driver}}',n])
  if r['available']:drivers.append(r['output'].strip())
 return {'schema':1,'checks':rows,'networkMode':mode,'drivers':drivers,'macvlanHostIsolationPossible':'macvlan' in drivers,'scope':'TCP reachability only, not authentication or service health. SMB shares use the separate authenticated share checker. No routes or interfaces changed.'}

def findings(report):
 driver=report.get('graphics/diagnostics',{}).get('driver',{});app=driver.get('application',{})
 runtime=report.get('graphics/diagnostics/runtime',{}).get('driver',{})
 result=[]
 coherence=driver.get('stackCoherence',{})
 if coherence.get('state')=='mismatch':result.append({'kind':'mixed-active-versions','evidence':coherence,'next':'Keep VGA rescue. Complete the verified driver transaction and reboot before testing.'})
 crashes=[c for c in app.get('crashes',[])+runtime.get('dwmCrashes',[]) if str(c.get('AppName','')).lower()=='dwm.exe']
 if crashes:result.append({'kind':'dwm-crash-observed','count':len({(c.get('timeUtc'),c.get('ProcessId')) for c in crashes}),'next':'Inspect module, offset and local dump. A historical crash is not proof of the current cause.'})
 errors=report.get('host',{}).get('transportErrors',[])
 if any(e.get('kind')=='buffer-size-mismatch' for e in errors):result.append({'kind':'allocation-contract-mismatch','next':'Compare producer/import layouts. Increasing a fixed buffer or reinterpreting OPTIMAL as LINEAR is not a repair.'})
 if any(e.get('kind') in ('device-lost','device-memory-limit','allocation-failed') for e in errors):result.append({'kind':'gpu-resource-pressure','next':'Inspect shared VRAM accounting and host GPU usage; lower workload before raising any cap.'})
 return {'findings':result,'state':'review' if result else 'no-known-signal','scope':'Suggestions only. Independent host/guest clocks and bounded logs do not establish causality or stability.'}

def identity(info,version):
 env=dict(v.split('=',1) for v in info.get('Config',{}).get('Env',[]) if '=' in v)
 return {'image':info['Image'],'guestCommit':version.get('commit_hash'),'guestProtocol':version.get('graphics_protocol'),'cpus':env.get('CPU_CORES'),'ram':env.get('RAM_SIZE'),'gpu':env.get('RENDERNODE')}

def compare(a,b):
 if not all(a.get('identity',{}).get(k) for k in ('image','guestCommit','cpus','ram','driverVersions','resolution')) or a.get('identity')!=b.get('identity'):return {'state':'not-comparable','reason':'Host image, guest build, allocation or selected GPU changed'}
 rows=[]
 for name in ('cpuPercentOfOneCore','memoryPercent'):
  x=a.get('metrics',{}).get('container',{}).get(name);y=b.get('metrics',{}).get('container',{}).get(name)
  if type(x) in (int,float) and type(y) in (int,float):rows.append({'metric':name,'before':x,'after':y,'delta':round(y-x,3)})
 return {'state':'observed' if rows else 'incomplete','measurements':rows,'scope':'Point samples, not a benchmark. Match application, scene, duration and thermal conditions before attributing performance.'}

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=('host','network','incidents','record','history','compare'));p.add_argument('--container',default='WinBoat');p.add_argument('--report',type=Path);p.add_argument('--root',type=Path,default=Path.home()/'.winboat'/'PerformanceHistory');p.add_argument('--label',default='Manual sample');p.add_argument('--before');p.add_argument('--after');a=p.parse_args()
 try:
  if a.action=='host':result=host()
  elif a.action=='network':result=network(a.container)
  elif a.action=='incidents':
   if not a.report or a.report.stat().st_size>4194304:raise ValueError('Choose a bounded graphics diagnostic JSON report')
   result=findings(json.loads(a.report.read_text()))
  else:
   load('config-trial').private(a.root)
   def record(key):
    if not re.fullmatch('[a-f0-9]{32}',key or ''):raise ValueError('Invalid measurement identity')
    return json.loads(load('config-trial').read(a.root/(key+'.json')))
   if a.action=='compare':result=compare(record(a.before),record(a.after))
   elif a.action=='history':
    rows=[record(f.stem) for f in a.root.glob('*.json') if re.fullmatch('[a-f0-9]{32}',f.stem)]
    result=[{'id':r['id'],'label':r['label'],'timeUtc':r['timeUtc'],'cpuPercentOfOneCore':r.get('metrics',{}).get('container',{}).get('cpuPercentOfOneCore')} for r in sorted(rows,key=lambda r:r['timeUtc'])][-200:]
   else:
    if not 1<=len(a.label)<=80 or any(ord(c)<32 for c in a.label):raise ValueError('Use a short printable measurement label')
    if len(list(a.root.glob('*.json')))>=200:raise ValueError('History limit reached; archive old records first')
    info=json.loads(subprocess.check_output(['docker','inspect',a.container],text=True,timeout=8))[0]
    import urllib.request
    d=load('diagnose-graphics');base=load('graphics-center').endpoint(a.container);opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),d.NoRedirect())
    version=d.read_endpoint(opener,base,'version',5);m=load('measure-performance')
    graphics=d.read_endpoint(opener,base,'graphics/diagnostics',20).get('driver',{});controllers=graphics.get('controllers',[])
    ids=identity(info,version);ids['driverVersions']=sorted({c['DriverVersion'] for c in controllers if c.get('DriverVersion')});ids['resolution']=sorted({f"{c['CurrentHorizontalResolution']}x{c['CurrentVerticalResolution']}" for c in controllers if c.get('CurrentHorizontalResolution') and c.get('CurrentVerticalResolution')})
    result={'schema':1,'id':uuid.uuid4().hex,'label':a.label,'timeUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'identity':ids,'metrics':{'container':m.container_sample(a.container),'hostGPU':m.gpu_sample()}}
    load('config-trial').write(a.root/(result['id']+'.json'),result)
  print(json.dumps(result))
 except (OSError,ValueError,KeyError,subprocess.SubprocessError) as e:p.exit(1,str(e)+'\n')
if __name__=='__main__':main()

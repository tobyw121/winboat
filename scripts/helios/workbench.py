#!/usr/bin/env python3
"""On-demand performance observations and graphics release evidence; no automatic power actions."""
import argparse,datetime,importlib.util,json,os,subprocess,re
from pathlib import Path

def load(name):
 s=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'));m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m

def frame_delta(a,b):
 keys=('pid','console','width','height','requestedTransportMode')
 if not a or any(a.get(k)!=b.get(k) for k in keys):return {'state':'warming-up'}
 elapsed=(b.get('monotonicUs',0)-a.get('monotonicUs',0))/1000000
 if not 0<elapsed<=15:return {'state':'stale'}
 count=b.get('renderedFrames',0)-a.get('renderedFrames',0);copies=b.get('copySamples',0)-a.get('copySamples',0)
 if count<0 or copies<0:return {'state':'reset'}
 return {'state':'measured','viewerRedrawsPerSecond':round(count/elapsed,2),'averageSourceCopyMs':round((b.get('sourceCopyWallUs',0)-a.get('sourceCopyWallUs',0))/copies/1000,3) if copies else None,'transport':'dmabuf' if b.get('dmabufFrames',0)>a.get('dmabufFrames',0) else 'software-or-idle','scope':'Viewer redraw rate, not game FPS or displayed-frame proof'}

def release_gate(validation,scenarios):
 acceptance=validation.get('acceptance',{});failures=[];missing=[]
 if acceptance.get('automatedPassed') is not True:missing.append('interactive-api-tests')
 try:
  finish=datetime.datetime.fromisoformat(acceptance['finishedAtUtc'].replace('Z','+00:00'))
  age=(datetime.datetime.now(datetime.timezone.utc)-finish).total_seconds()
  if not 0<=age<=86400:missing.append('fresh-acceptance')
 except (KeyError,ValueError,TypeError):missing.append('fresh-acceptance')
 for name in ('D3D11','Vulkan features','Vulkan presentation','OpenGL','D3D11 1x resize','D3D11 format contracts'):
  rows=[r for r in acceptance.get('tests',[]) if r.get('name')==name and r.get('status')=='passed' and r.get('exitCode')==0 and len(str(r.get('sha256','')))==64]
  if len(rows)!=1:missing.append(name)
 required={'cold-boot','resize','logon'}
 for scenario in required:
  row=scenarios.get(scenario,{})
  assessment=row.get('assessment',{})
  recorded=row.get('acceptance',{}).get('identity',{});identity=acceptance.get('identity',{})
  if not identity.get('manifestSha256') or any(recorded.get(k)!=identity.get(k) for k in ('manifestSha256','version','machineId')) or row.get('hostImage')!=validation.get('hostImage'):missing.append(scenario+'-identity')
  if assessment.get('state')=='failed':failures.append(scenario)
  elif assessment.get('state')!='passed':missing.append(scenario)
 transaction=validation.get('transaction',{})
 if transaction.get('status') in ('failed','rollback-required'):failures.append('update-transaction')
 # Acceptance cannot be inferred from a successful build or a bound driver.
 return {'state':'blocked' if failures else 'incomplete' if missing else 'eligible-for-visual-confirmation','failures':failures,'missing':missing,'scope':'No installation or candidate promotion is performed. Explicit visual confirmation remains required.'}

def transport_contracts(host_text,viewer_text):
 host=[];viewer=[]
 for line in host_text.splitlines():
  if 'dmabuf-contract import ' not in line:continue
  row={k:int(v) for k,v in re.findall(r'([a-z_]+)=(\d{1,20})(?=\s|$)',line)}
  if all(k in row for k in ('ino','bytes','width','height','modifier')):host.append(row)
 for line in viewer_text.splitlines():
  start=line.find('{"event":"dmabuf-contract"')
  if start<0:continue
  try:row=json.loads(line[start:])
  except ValueError:continue
  if all(type(row.get(k)) is int for k in ('inode','bytes','width','height','stride','offset','fourcc','modifier')):viewer.append(row)
 checks=[]
 for v in viewer[-8:]:
  candidates=[h for h in host if h['ino']==v['inode'] and h['bytes']==v['bytes']]
  if not candidates:checks.append({'state':'unmatched','inode':str(v['inode'])});continue
  h=candidates[-1];mismatch=[k for k in ('width','height','stride','offset','modifier') if h.get(k)!=v.get(k)]
  formats={37:{0x34324241,0x34324258},44:{0x34325241,0x34325258}}
  if h.get('format') not in formats:checks.append({'state':'unknown-format','inode':str(v['inode'])});continue
  if v['fourcc'] not in formats[h['format']]:mismatch.append('format')
  if h.get('required',0)>h['bytes']:mismatch.append('allocation-extent')
  if h.get('tiling')==0 and h.get('modifier')==0x00ffffffffffffff and h.get('required')!=h['bytes']:mismatch.append('optimal-shape')
  checks.append({'state':'metadata-mismatch' if mismatch else 'compatible-metadata','inode':str(v['inode']),'mismatches':mismatch,'modifier':hex(v['modifier'])})
 return {'checks':checks,'scope':'Bounded historical metadata correlation, not GPU completion or visible-pixel proof. INVALID modifiers are never treated as LINEAR.'}

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=('metrics','gate','transport'));p.add_argument('--container',default='WinBoat');p.add_argument('--viewer',type=Path);p.add_argument('--evidence',type=Path);p.add_argument('--presentmon',type=Path);p.add_argument('--application');a=p.parse_args()
 try:
  if a.action=='metrics':
   m=load('measure-performance');rows=[]
   if a.viewer and a.viewer.exists():
    with a.viewer.open('rb') as stream:stream.seek(max(0,a.viewer.stat().st_size-262144));rows=m.viewer_metrics(stream.read().decode('utf-8','replace'))
   result={'container':m.container_sample(a.container),'hostGPU':m.gpu_sample(),'viewer':rows[-1] if rows else None,'scope':'On-demand sample; GPU sensors can be unavailable.'}
   if a.presentmon:
    if not a.application:raise ValueError('Choose the exact PresentMon application name')
    result['applicationFrames']=m.read_frame_times(a.presentmon,a.application)
  elif a.action=='transport':
   logs=subprocess.run(['docker','logs','--tail','500','--timestamps',a.container],capture_output=True,text=True,timeout=8,check=True)
   text=''
   if a.viewer and a.viewer.exists():
    with a.viewer.open('rb') as stream:stream.seek(max(0,a.viewer.stat().st_size-262144));text=stream.read().decode('utf-8','replace')
   host=(logs.stdout+'\n'+logs.stderr)[-262144:];result=transport_contracts(host,text);result['errors']=load('diagnose-graphics').parse_transport_errors(host)
  else:
   r=load('regression-graphics');current=r.capture(a.container);v=load('graphics-center');base=v.endpoint(a.container);d=load('diagnose-graphics');import urllib.request
   validation=d.read_endpoint(urllib.request.build_opener(urllib.request.ProxyHandler({}),d.NoRedirect()),base,'graphics/validation',20)
   validation['hostImage']=current.get('hostImage')
   evidence=json.loads(a.evidence.read_text()) if a.evidence and a.evidence.exists() and a.evidence.stat().st_size<=1048576 else {}
   result=release_gate(validation,evidence);result['identity']={k:current.get(k) for k in ('hostImage','hostStartedAt')}
  print(json.dumps(result))
 except (OSError,ValueError,subprocess.SubprocessError,KeyError) as e:p.exit(1,str(e)+'\n')
if __name__=='__main__':main()

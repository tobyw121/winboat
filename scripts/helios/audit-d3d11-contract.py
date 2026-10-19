#!/usr/bin/env python3
"""Reproduce the .291/newer MSAA contract split using real Rust functions.

Only COM backend answers, handle lookup and logging are fixtures. No GPU or
Windows runtime is exercised. Successful reproduction is not rendering success.
Requires rustc and local Git objects for the selected historical revisions.
"""
import argparse
import pathlib
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--rustc', default=shutil.which('rustc'))
parser.add_argument('--revisions', nargs='+', default=['f0a662f', '4c08daa', 'working-tree'])
args = parser.parse_args()
if not args.rustc:
    parser.error('rustc is required; pass --rustc /path/to/rustc')
root = pathlib.Path(__file__).resolve().parents[2]
def source(path, revision):
    if revision=='working-tree':return (root/path).read_text()
    return subprocess.check_output(['git','show',revision+':'+path],cwd=root,text=True)
def function(text,name):
    start=text.index('fn '+name+'(')
    start=text.rfind('\n',0,start)+1
    end=text.index('{',start)+1; depth=1
    while depth:
        depth+=(text[end]=='{')-(text[end]=='}');end+=1
    return text[start:end]
prefix=r'''
#![allow(dead_code,non_snake_case,non_camel_case_types,unused_imports,unused_variables)]
use std::sync::atomic::{AtomicU32,Ordering};
static MODE:AtomicU32=AtomicU32::new(1);
static CASE:AtomicU32=AtomicU32::new(0);
fn feature_level_mode()->u32{MODE.load(Ordering::Relaxed)}
macro_rules! trace_line {($($args:tt)*)=>{let _=format_args!($($args)*);}}
mod ddi {pub type DXGI_FORMAT=u32;}
type Hdevice=usize;
#[derive(Clone,Copy)] struct DXGI_FORMAT(i32);
struct Hr(i32); struct Error;
impl Error {fn code(&self)->Hr{Hr(0x80004005u32 as i32)}}
struct ID3D11Device2; struct Device;
fn d3d11_device(_:Hdevice)->Option<Device>{Some(Device)}
impl Device {
 unsafe fn CheckFormatSupport(&self,_:DXGI_FORMAT)->Result<u32,Error>{
  Ok(if CASE.load(Ordering::Relaxed)==2 {0x1330} else if CASE.load(Ordering::Relaxed)==1 {0x000041b0} else {0x006041b0})
 }
 unsafe fn CheckMultisampleQualityLevels(&self,_:DXGI_FORMAT,n:u32)->Result<u32,Error>{
  Ok(if n==1 || CASE.load(Ordering::Relaxed)==0 {1}else{0})
 }
 fn cast<T>(&self)->Result<Device,Error>{Ok(Device)}
 unsafe fn CheckMultisampleQualityLevels1(&self,f:DXGI_FORMAT,n:u32,flags:u32)->Result<u32,Error>{
  if flags!=0{Err(Error)}else{self.CheckMultisampleQualityLevels(f,n)}
 }
}
struct LogThrottle;
impl LogThrottle{const fn new()->Self{Self} fn first_n_then_every(&self,_:u32,_:u32)->Option<u32>{None}}
mod diagnostics{pub unsafe fn note(_:usize,_:&str,_:[u64;6]){}}
'''
results=[]
for revision in args.revisions:
    fmt=source('helios/upstream/umd/src/forward/format_caps.rs',revision)
    q=source('helios/upstream/umd/src/forward/queries.rs',revision)
    f=source('helios/upstream/umd/src/forward.rs',revision)
    caps=source('helios/upstream/umd/src/caps.rs',revision)
    caps=caps[caps.index('/// How the FL11'):caps.index('pub(crate) fn feature_profile(')]+function(caps,'feature_profile')
    helpers='\n'.join(function(f,n) for n in ['dxgi_bits_per_sample','dxgi_output_family_bits','dxgi_output_bits_per_sample','dxgi_msaa_bits_per_sample','dxgi_resolve_required','dxgi_color_typeless_parent','dxgi_integer_typed_format'])
    query=function(q,'helios_multisample_quality_levels')
    flags=',0' if 'flags: u32' in query else ''
    tiled=',1' if flags else ''
    rust=prefix+'\nmod caps{use crate::feature_level_mode;\n'+caps+'}\n'
    rust+='mod format;\n'
    rust+=helpers+'\n'+function(fmt,'check_format_support')+'\nstatic MSAA_LOG_COUNT:LogThrottle=LogThrottle::new();\n'+query
    rust+='\nfn main(){unsafe{\n'
    rust+='for (case,fmt) in [(0,28),(1,28),(2,6)]{CASE.store(case,Ordering::Relaxed);let mut caps=0;check_format_support(1,fmt,&mut caps);let q=helios_multisample_quality_levels(1,fmt,4'+flags+'); println!("case={} fmt={} final=0x{:08x} quality4={} contradiction={}",case,fmt,caps,q,(caps&8!=0 && q==0));}\n'
    rust+='CASE.store(0,Ordering::Relaxed);let tiled=helios_multisample_quality_levels(1,28,4'+tiled+');println!("tiled_tier={} tiled_quality4={}",caps::feature_profile().options1,tiled);\n'
    rust+='MODE.store(0,Ordering::Relaxed);CASE.store(1,Ordering::Relaxed);let mut caps=0;check_format_support(1,28,&mut caps);let q=helios_multisample_quality_levels(1,28,4'+flags+');println!("fl10_strip_control high_msaa={} quality4={}",caps&0x640000,q);\n}}'
    with tempfile.TemporaryDirectory(prefix='helios-contract-') as d:
        p=pathlib.Path(d)/'audit.rs';p.write_text(rust)
        (pathlib.Path(d)/'format.rs').write_text(source('helios/upstream/umd_common/src/format.rs', revision))
        subprocess.run([args.rustc,'--edition=2021','-Awarnings',str(p),'-o',str(p.with_suffix(''))],check=True)
        out=subprocess.check_output([str(p.with_suffix(''))],text=True)
        print(revision+'\n'+out)
        results.append((revision,out))
for revision, output in results:
    assert 'case=0 fmt=28' in output and output.splitlines()[0].endswith('contradiction=false'), revision
    assert 'fl10_strip_control high_msaa=0 quality4=0' in output, revision
print('Supported-format and FL10 controls verified. Interpret contradiction lines as source evidence only.')

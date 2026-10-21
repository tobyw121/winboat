#!/usr/bin/env python3
"""Resolve a local Mesa crash RVA with an exactly hash-paired runtime and DWARF."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

def resolve(runtime,symbols,module,offset,tool='addr2line'):
    if module not in ('vulkan_virtio.dll','libgallium_wgl.dll') or not 0<=offset<2**32:raise ValueError('Expected a known Mesa module and 32-bit relative address')
    manifest=symbols/'symbols.json'
    if manifest.is_symlink() or manifest.stat().st_size>32768:raise ValueError('Invalid symbols manifest')
    doc=json.loads(manifest.read_text(encoding='utf-8-sig'))
    if doc.get('schema')!=1:raise ValueError('Unsupported symbol manifest')
    rows=[r for r in doc['modules'] if r.get('module')==module]
    if len(rows)!=1:raise ValueError('Unique module identity required')
    row=rows[0]
    if row['debug']!=module+'.debug' or type(row.get('imageBase')) is not int or not 0<=row['imageBase']<2**64:raise ValueError('Invalid symbol mapping')
    debug=symbols/row['debug']
    for file,pin in ((runtime,row['sha256']),(debug,row['debugSha256'])):
        if file.is_symlink() or not file.is_file() or file.stat().st_size>536870912:raise ValueError('Expected bounded regular symbol/runtime files')
        digest=hashlib.sha256()
        with file.open('rb') as stream:
            for data in iter(lambda:stream.read(1048576),b''):digest.update(data)
        if digest.hexdigest()!=pin:raise ValueError('Runtime or symbols mismatch; no symbol lookup performed')
    # addr2line uses link-time VA. Windows faulting offsets are RVAs, not live ASLR VAs.
    result=subprocess.run([tool,'-e',str(debug),'-f','-C',hex(row['imageBase']+offset)],text=True,capture_output=True,timeout=20,check=True)
    text=result.stdout[:16384]
    return {'status':'resolved' if text.strip() and '??' not in text else 'unresolved','analysis':text,
            'scope':'Local address lookup, not proof of crash causality. Never included automatically in support exports.'}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--symbols',type=Path,required=True)
    p.add_argument('--module',required=True);p.add_argument('--offset',type=lambda s:int(s,16),required=True);p.add_argument('--addr2line',default='addr2line');a=p.parse_args()
    try:print(json.dumps(resolve(a.runtime,a.symbols,a.module,a.offset,a.addr2line),indent=2))
    except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as error:p.exit(1,str(error)+'\n')
if __name__=='__main__':main()

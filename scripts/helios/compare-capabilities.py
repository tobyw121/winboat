#!/usr/bin/env python3
"""Capture/diff bounded native helios-capabilities probe output; no VM writes."""
import argparse
import hashlib
import json
from pathlib import Path
import re

def capture(text,probe):
    caps={}
    for line in text.splitlines():
        match=re.fullmatch(r'cap (d3d11|vulkan|identity) ([A-Za-z0-9_.]{1,280}) (\d{1,20})',line)
        if not match:continue
        api,name,value=match.groups();key=api+'.'+name
        if key in caps:raise ValueError('Duplicate capability; do not combine probe runs')
        caps[key]=int(value)
    if not caps or len(caps)>8192:raise ValueError('No complete bounded capability evidence')
    if not re.fullmatch(r'[a-fA-F0-9]{64}',probe):raise ValueError('Exact probe SHA-256 required')
    complete=caps.get('identity.complete')==1 and caps.get('identity.warp')==0 and 'd3d11.featureLevel' in caps and 'vulkan.apiVersion' in caps
    return {'schema':1,'probeSha256':probe.lower(),'complete':complete,'capabilities':caps,
            'scope':'Advertised queries only; rendering acceptance is separate.'}

def compare(a,b):
    if not a.get('complete') or not b.get('complete') or a['probeSha256']!=b['probeSha256']:
        raise ValueError('Complete Helios captures with identical external probe bytes required')
    first=a['capabilities'];second=b['capabilities']
    changes=[{'name':k,'before':first.get(k),'after':second.get(k)} for k in sorted(first.keys()|second.keys()) if first.get(k)!=second.get(k)]
    return {'schema':1,'changes':changes,'reviewRequired':bool(changes),'scope':'Any changed capability requires review and relevant pixel tests; additions are not automatically safe.'}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('input',type=Path);p.add_argument('--probe',type=Path);p.add_argument('--against',type=Path)
    a=p.parse_args()
    try:
        if a.input.stat().st_size>1048576:raise ValueError('Input too large')
        if a.probe:
            h=hashlib.sha256()
            with a.probe.open('rb') as f:
                for data in iter(lambda:f.read(1048576),b''):h.update(data)
            result=capture(a.input.read_text(encoding='utf-8-sig'),h.hexdigest())
        else:
            if not a.against or a.against.stat().st_size>1048576:raise ValueError('Provide --probe or --against')
            result=compare(json.loads(a.against.read_text(encoding='utf-8-sig')),json.loads(a.input.read_text(encoding='utf-8-sig')))
        print(json.dumps(result,indent=2))
    except (OSError,ValueError,KeyError,TypeError) as error:p.exit(1,str(error)+'\n')
if __name__=='__main__':main()

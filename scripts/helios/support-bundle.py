#!/usr/bin/env python3
"""Local filtered graphics ZIP; fixed entries, no dumps, paths, upload or shell."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import zipfile

spec=importlib.util.spec_from_file_location('support',Path(__file__).with_name('export-support.py'))
support=importlib.util.module_from_spec(spec);spec.loader.exec_module(support)
README=b'WinBoat filtered graphics diagnostics\nreport.json contains allowlisted observations only.\nNo memory dumps or raw logs are included. Nothing was uploaded.\nMissing evidence is unknown; this packet does not certify rendering success.\n'
def prepare(path):
    payload,digest=support.prepare(path)
    return payload,digest

def write_bundle(output,payload,digest):
    entries={'report.json':payload,'README.txt':README}
    manifest={'schema':1,'reportSha256':digest,'files':[{'name':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()} for name,data in entries.items()]}
    fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    try:
        with os.fdopen(fd,'wb') as stream,zipfile.ZipFile(stream,'w',compression=zipfile.ZIP_DEFLATED) as archive:
            for name,data in entries.items(): archive.writestr(name,data)
            archive.writestr('manifest.json',json.dumps(manifest,indent=2)+'\n')
    except BaseException:
        output.unlink(missing_ok=True)
        raise

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report',type=Path);parser.add_argument('--output',type=Path)
    parser.add_argument('--review-sha256')
    args=parser.parse_args()
    try:
        payload,digest=prepare(args.report)
        if not args.output:
            print(json.dumps({'sha256':digest,'preview':json.loads(payload)}));return
        if args.review_sha256!=digest: raise ValueError('Preview changed; review the filtered report again')
        write_bundle(args.output,payload,digest)
        print(json.dumps({'status':'saved','sha256':digest}))
    except (OSError,ValueError) as error:parser.exit(1,str(error)+'\n')
if __name__=='__main__':main()

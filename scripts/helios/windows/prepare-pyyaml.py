#!/usr/bin/env python3
"""Stage pinned, pure-Python PyYAML for Mesa's MINGW32 build generators."""
import argparse
import hashlib
import io
from pathlib import Path
import tarfile
import urllib.request

URL='https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/pyyaml-6.0.3.tar.gz'
SHA256='d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f'

def prepare(output):
    with urllib.request.urlopen(URL,timeout=60) as response:raw=response.read(2*1024*1024)
    if hashlib.sha256(raw).hexdigest()!=SHA256:raise ValueError('PyYAML source checksum mismatch')
    output.mkdir(parents=True,exist_ok=False)
    with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as archive:
        for member in archive.getmembers():
            # No setup.py/build hooks, native extension, symlinks or arbitrary extraction.
            path=Path(member.name)
            if len(path.parts)!=4 or path.parts[:3]!=('pyyaml-6.0.3','lib','yaml') or path.suffix!='.py' or not member.isfile():continue
            destination=output/'yaml'/path.name;destination.parent.mkdir(exist_ok=True)
            destination.write_bytes(archive.extractfile(member).read())
    if not (output/'yaml/__init__.py').is_file():raise ValueError('PyYAML package missing')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('output',type=Path)
    prepare(parser.parse_args().output)

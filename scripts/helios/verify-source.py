#!/usr/bin/env python3
"""Verify the vendored Helios snapshot before fetching its pinned dependencies."""
import hashlib
import json
import pathlib
import sys


def verify(root):
    helios = pathlib.Path(root)
    source = json.loads((helios / 'source.lock.json').read_text())
    stack = json.loads((helios / 'stack.lock.json').read_text())
    if source['revision'] != stack['hostRevision']:
        raise ValueError('Helios source and host revision differ')
    upstream = helios / 'upstream'
    actual = set()
    for file in upstream.rglob('*'):
        if file.is_symlink():
            raise ValueError(f'Unexpected symlink: {file}')
        if file.is_file():
            name = file.relative_to(upstream).as_posix()
            actual.add(name)
            if hashlib.sha256(file.read_bytes()).hexdigest() != source['files'].get(name):
                raise ValueError(f'Helios source checksum mismatch: {name}')
    if actual != set(source['files']):
        raise ValueError('Incomplete Helios source snapshot')
    for dep in source['submodules']:
        if dep['path'] in stack['sharedSources'] and dep['revision'] != stack['sharedSources'][dep['path']]:
            raise ValueError(f'Helios dependency revision mismatch: {dep["path"]}')
    print(f'Verified {len(actual)} Helios source files at {source["revision"]}.')
    return source


if __name__ == '__main__':
    try:
        verify(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[2] / 'helios')
    except (ValueError, KeyError, OSError) as error:
        sys.exit(str(error))

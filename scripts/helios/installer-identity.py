#!/usr/bin/env python3
"""Read a checksummed Helios payload manifest without executing the installer."""
import hashlib
import io
import json
import lzma
from pathlib import Path
import struct
import sys


def identity(path):
    path = Path(path)
    if not 128 <= path.stat().st_size <= 256 * 1024 * 1024:
        raise ValueError('Installer size outside inspection bounds')
    exe = path.read_bytes()
    if exe[:2] != b'MZ' or exe[-8:] != b'HLIOSET2':
        raise ValueError('Installer has no complete payload')
    offset, size, header = struct.unpack_from('<QQQ', exe, len(exe) - 64)
    if offset < 64 or offset + size != len(exe) - 64 or not 4 <= header <= min(size, 1024 * 1024):
        raise ValueError('Invalid payload bounds')
    payload = exe[offset:-64]
    if hashlib.sha256(payload).digest() != exe[-40:-8]:
        raise ValueError('Payload checksum mismatch')
    cursor = 4
    count, = struct.unpack_from('<I', payload)
    if not 1 <= count <= 4096:
        raise ValueError('Invalid payload entry count')
    entries, names, total = [], set(), 0
    for _ in range(count):
        if cursor + 2 > header:
            raise ValueError('Truncated payload header')
        length, = struct.unpack_from('<H', payload, cursor)
        cursor += 2
        if not length or cursor + length + 8 > header:
            raise ValueError('Invalid payload entry')
        name = payload[cursor:cursor + length].decode('utf-8')
        cursor += length
        entry_size, = struct.unpack_from('<Q', payload, cursor)
        cursor += 8
        if name.casefold() in names or '\\' in name or any(p in ('', '.', '..') for p in name.split('/')):
            raise ValueError('Ambiguous payload entry')
        names.add(name.casefold())
        entries.append((name, entry_size))
        total += entry_size
    if cursor != header or total > 1024 * 1024 * 1024:
        raise ValueError('Invalid payload size')
    manifest = None
    with lzma.LZMAFile(io.BytesIO(payload[header:])) as stream:
        for name, remaining in entries:
            is_manifest = name.casefold() == 'manifest.json'
            if is_manifest and remaining > 1024 * 1024:
                raise ValueError('Manifest too large')
            chunks = []
            while remaining:
                chunk = stream.read(min(remaining, 1024 * 1024))
                if not chunk:
                    raise ValueError('Truncated payload data')
                remaining -= len(chunk)
                if is_manifest:
                    chunks.append(chunk)
            if is_manifest:
                manifest = b''.join(chunks)
        if stream.read(1) or manifest is None:
            raise ValueError('Missing manifest or unexpected payload data')
    data = json.loads(manifest.decode('utf-8-sig'))
    if not isinstance(data.get('version'), str) or not data['version']:
        raise ValueError('Missing manifest version')
    return {'manifestSha256': hashlib.sha256(manifest).hexdigest(), 'driverVersion': data['version']}


if __name__ == '__main__':
    print(json.dumps(identity(sys.argv[1])))

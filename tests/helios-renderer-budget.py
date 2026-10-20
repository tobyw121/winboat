"""Apply the pinned renderer overlay and execute its real accounting functions."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request
ROOT=Path(__file__).resolve().parents[1]
PATCHES=ROOT/'helios/host/renderer-patches'
revision=next(d['revision'] for d in json.loads((ROOT/'helios/source.lock.json').read_text())['submodules'] if d['path']=='virglrenderer')
def function(source,name):
    match=re.search(r'(?:static\s+)?(?:void|bool)\s+'+name+r'\([^;]*?\)\s*\{',source)
    assert match,name
    depth=1;end=match.end()
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[match.start():end]+'\n'
with tempfile.TemporaryDirectory() as folder:
    root=Path(folder)
    for line in (PATCHES/'BASE-SHA256SUMS').read_text().splitlines():
        digest,name=line.split()
        data=(Path(sys.argv[1])/name).read_bytes() if len(sys.argv)>1 else urllib.request.urlopen(f'https://raw.githubusercontent.com/winboat-org/virglrenderer/{revision}/{name}',timeout=30).read()
        assert hashlib.sha256(data).hexdigest()==digest,name
        path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
    subprocess.run(['git','init','-q','--template=',str(root)],check=True)
    subprocess.run(['git','-C',str(root),'add','.'],check=True)
    for line in (PATCHES/'SHA256SUMS').read_text().splitlines():
        digest,name=line.split();patch=PATCHES/name
        assert hashlib.sha256(patch.read_bytes()).hexdigest()==digest
        subprocess.run(['git','-C',str(root),'apply','--check','--index',str(patch)],check=True)
        subprocess.run(['git','-C',str(root),'apply','--index',str(patch)],check=True)
    source=(root/'src/venus/vkr_device_memory.c').read_text()
    body='''#define _GNU_SOURCE
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <errno.h>
#include <stdio.h>
#include <inttypes.h>
#include <assert.h>
#define vkr_log(...) ((void)fprintf(stderr,__VA_ARGS__))
static atomic_uint_fast64_t vkr_device_memory_budget_used;
static uint64_t vkr_device_memory_budget_limit;
'''
    for name in ('vkr_device_memory_budget_init','vkr_device_memory_budget_reserve','vkr_device_memory_budget_release'):
        body+=function(source,name)
    body+='''int main(void) {
    unsetenv("VKR_DEVICE_MEMORY_LIMIT_BYTES");vkr_device_memory_budget_init();
    assert(vkr_device_memory_budget_reserve(4096));assert(atomic_load(&vkr_device_memory_budget_used)==4096);
    vkr_device_memory_budget_release(512);assert(atomic_load(&vkr_device_memory_budget_used)==3584);
    vkr_device_memory_budget_release(8192);assert(atomic_load(&vkr_device_memory_budget_used)==3584);
    vkr_device_memory_budget_release(3584);assert(atomic_load(&vkr_device_memory_budget_used)==0);
    setenv("VKR_DEVICE_MEMORY_LIMIT_BYTES","100",1);vkr_device_memory_budget_init();
    assert(!vkr_device_memory_budget_reserve(101));assert(vkr_device_memory_budget_reserve(60));
    assert(!vkr_device_memory_budget_reserve(41));vkr_device_memory_budget_release(60);
    unsetenv("VKR_DEVICE_MEMORY_LIMIT_BYTES");vkr_device_memory_budget_init();
    assert(vkr_device_memory_budget_reserve(UINT64_MAX));assert(!vkr_device_memory_budget_reserve(1));
    vkr_device_memory_budget_release(UINT64_MAX);assert(atomic_load(&vkr_device_memory_budget_used)==0);
}
'''
    test=root/'test.c';test.write_text(body)
    binary=root/'test'
    subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',str(test),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
    print('Pinned renderer overlay and actual accounting: unlimited tracking, bounds, overflow and underflow retention passed.')

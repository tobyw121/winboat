#!/usr/bin/env python3
"""Explicit QEMU comparison options; defaults preserve the original command."""
import hashlib
import os
import json
import subprocess
from pathlib import Path
import re
import sys


def cpu_set(value):
    if len(value) > 256 or not re.fullmatch(r'\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*', value):
        raise ValueError('Invalid CPU affinity')
    cpus = set()
    for part in value.split(','):
        bounds = list(map(int, part.split('-')))
        first, last = bounds[0], bounds[-1]
        if not 0 <= first <= last < 4096:
            raise ValueError('CPU affinity range outside bounds')
        cpus.update(range(first, last + 1))
    return cpus


def number(env, key, maximum):
    value = env.get(key, '0')
    if not re.fullmatch(r'\d{1,2}', value) or not 0 <= int(value) <= maximum:
        raise ValueError('Invalid '+key)
    return int(value)


def options(args, env, huge_free=None):
    args = list(args)
    if env.get('HELIOS_RESCUE') == '1' or inspection(args):
        return args
    if env.get('HELIOS_READBACK_CACHE_ENTRIES','8') not in ('1','2','4','8'):
        raise ValueError('Readback cache entries must be 1, 2, 4 or 8')
    budget=env.get('HELIOS_READBACK_BUDGET_MIB','0')
    if not re.fullmatch(r'\d{1,5}',budget) or not 0<=int(budget)<=16384:
        raise ValueError('Readback owned-memory budget must be 0..16384 MiB')
    number(env,'HELIOS_READBACK_DAMAGE',1)
    if number(env,'HELIOS_FRAME_TRACE',1):
        if '-trace' in args: raise ValueError('Existing QEMU trace configuration must be preserved')
        args += ['-trace','enable=helios_vulkan_capture']
    devices = [(i,v.split(',')) for i,v in enumerate(args) if i and args[i-1] == '-device']
    queues = number(env,'HELIOS_NET_QUEUES',8)
    if queues > 1:
        nics = [(i,p) for i,p in devices if p[0] == 'virtio-net-pci']
        if len(nics) != 1:
            raise ValueError('Multiqueue requires one VirtIO network adapter')
        index, nic = nics[0]
        net = next((p.split('=',1)[1] for p in nic if p.startswith('netdev=')), None)
        backends = [(i,v.split(',')) for i,v in enumerate(args) if i and args[i-1] == '-netdev' and 'id='+str(net) in v.split(',')]
        if len(backends) != 1 or backends[0][1][0] != 'tap':
            raise ValueError('Multiqueue requires TAP; user networking remains single queue')
        bi, backend = backends[0]
        if any(p.split('=')[0] in ('fd','fds','queues') for p in backend) or any(p.split('=')[0] in ('mq','vectors') for p in nic):
            raise ValueError('Existing queue/FD configuration must be preserved')
        args[index] = ','.join(nic+['mq=on','vectors='+str(2*queues+2)])
        args[bi] = ','.join(backend+['queues='+str(queues)])
    io_thread=number(env,'HELIOS_IO_THREAD',1)
    poll=env.get('HELIOS_IO_POLL_NS','')
    if poll and (poll not in ('0','32768','65536') or not io_thread):
        raise ValueError('I/O polling requires an enabled I/O thread and 0, 32768 or 65536 ns')
    if io_thread:
        controllers = [(i,p) for i,p in devices if p[0] in ('virtio-scsi-pci','virtio-blk-pci')]
        if len(controllers) != 1 or any(p.startswith('iothread=') for p in controllers[0][1]):
            raise ValueError('I/O thread requires one unassigned VirtIO storage controller')
        if any('id=helios-io' in value.split(',') for value in args):
            raise ValueError('I/O thread identity already in use')
        index, controller = controllers[0]
        args[index] = ','.join(controller+['iothread=helios-io'])
        args += ['-object','iothread,id=helios-io'+(',poll-max-ns='+poll if poll else '')]
    huge = env.get('HELIOS_HUGEPAGES','off')
    prealloc = number(env,'HELIOS_PREALLOC',1)
    if huge not in ('off','2M','1G'):
        raise ValueError('Use HELIOS_HUGEPAGES=off, 2M or 1G')
    if huge != 'off' or prealloc:
        memory = [(i,v.split(',')) for i,v in enumerate(args) if i and args[i-1] == '-object' and v.startswith('memory-backend-memfd,')]
        if len(memory) != 1 or 'share=on' not in memory[0][1]:
            raise ValueError('Memory options require the shared Helios memfd backend')
        index, parts = memory[0]
        if any(p.split('=')[0] in ('hugetlb','hugetlbsize','prealloc') for p in parts):
            raise ValueError('Existing memory allocation policy must be preserved')
        if huge != 'off':
            page = 2097152 if huge == '2M' else 1073741824
            value = next((p[5:] for p in parts if p.startswith('size=')), '')
            match = re.fullmatch(r'(\d+)([MGT])',value)
            if not match:
                raise ValueError('Hugepages require integral RAM size in M/G/T')
            size = int(match[1])*{'M':2**20,'G':2**30,'T':2**40}[match[2]]
            free = huge_free if huge_free is not None else int(Path('/sys/kernel/mm/hugepages/hugepages-'+str(page//1024)+'kB/free_hugepages').read_text())
            if size % page or free*page < size:
                raise ValueError('Insufficient reserved hugepages; host reservation is unchanged')
            parts += ['hugetlb=on','hugetlbsize='+str(page)]
        if prealloc:
            parts += ['prealloc=on']
        args[index] = ','.join(parts)
    return args


def inspection(args):
    return args in (['--version'],['-version'],['--help'],['-help']) or (
        len(args)==2 and args[0] in ('-device','-machine','-accel','-cpu','-trace') and
        (args[1]=='help' or args[0]=='-device' and args[1].endswith(',help')))


def cache_environment(env, storage, fingerprint):
    if not Path(storage).is_absolute():
        raise ValueError('Graphics cache storage must be an absolute path')
    cache = Path(storage)/'.winboat-cache'/'graphics'/hashlib.sha256(fingerprint).hexdigest()[:24]
    for path in (cache.parent.parent,cache.parent,cache,cache/'mesa',cache/'nvidia'):
        if path.is_symlink():
            raise ValueError('Graphics cache path must not be a symlink')
        path.mkdir(mode=0o700,parents=True,exist_ok=True)
    result = dict(env)
    result.update(MESA_SHADER_CACHE_DIR=str(cache/'mesa'),__GL_SHADER_DISK_CACHE='1',__GL_SHADER_DISK_CACHE_PATH=str(cache/'nvidia'))
    result.setdefault('MESA_SHADER_CACHE_MAX_SIZE','1G')
    return result


def main():
    env = dict(os.environ)
    args = options(sys.argv[2:],env)
    if env.get('HELIOS_RESCUE') != '1' and not inspection(args):
        if any(i and args[i-1]=='-device' and value.split(',')[0] in ('virtio-gpu-gl-pci','virtio-vga-gl') for i,value in enumerate(args)):
            probe=subprocess.run(['/opt/helios/gpu-preflight',env.get('RENDERNODE','/dev/dri/renderD128')],
                                 capture_output=True,text=True,timeout=20,check=True)
            if len(probe.stdout)>32768: raise ValueError('GPU preflight report exceeds limit')
            report=json.loads(probe.stdout)
            if report.get('ready') is not True: raise ValueError('Host GPU identity/capability preflight failed')
            fd=os.open('/run/helios-gpu-preflight.json',os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
            with os.fdopen(fd,'w') as output: json.dump(report,output)
    
        if env.get('HELIOS_CPU_AFFINITY'):
            cpus = cpu_set(env['HELIOS_CPU_AFFINITY'])
            if not cpus <= os.sched_getaffinity(0):
                raise ValueError('Requested CPUs are unavailable to this container')
            os.sched_setaffinity(0,cpus)
        if number(env,'HELIOS_SHADER_CACHE',1):
            fingerprint = bytearray()
            node = Path(env.get('RENDERNODE','/dev/dri/renderD128')).name
            for path in [Path('/opt/helios/host-patches.sha256'),Path('/proc/driver/nvidia/version'),Path('/sys/class/drm')/node/'device/uevent']:
                if path.is_file():
                    fingerprint.extend(path.read_bytes()[:65536])
            if not fingerprint:
                raise ValueError('GPU/runtime identity unavailable for persistent cache')
            env = cache_environment(env,env.get('STORAGE') or '/storage',fingerprint)
    os.execve(sys.argv[1],[sys.argv[1],*args],env)


if __name__ == '__main__':
    try:
        main()
    except (OSError,ValueError,subprocess.SubprocessError) as error:
        sys.exit('Helios performance configuration: '+str(error))

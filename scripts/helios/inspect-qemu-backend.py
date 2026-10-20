#!/usr/bin/env python3
"""Read-only in-container inspection; output fixed GPU configuration fields only."""
import glob
import json
import os
import re


def options(args, name):
    return [args[i + 1] for i, item in enumerate(args[:-1]) if item == name]


def properties(value):
    return dict(part.split('=', 1) for part in value.split(',')[1:] if '=' in part)


def performance(args):
    machines=options(args,'-machine');accels=options(args,'-accel')
    accelerator=accels[0].split(',')[0] if len(accels)==1 else None
    if '-enable-kvm' in args: accelerator='kvm'
    if accelerator is None and len(machines)==1: accelerator=properties(machines[0]).get('accel')
    accelerator=accelerator if accelerator in ('kvm','tcg') else 'unspecified'
    cpus=options(args,'-cpu');cpu=cpus[0].split(',')[0] if len(cpus)==1 else 'unspecified'
    cpu=cpu if cpu in ('host','max','qemu64','qemu32') else 'other'
    smp=options(args,'-smp');topology={}
    if len(smp)==1:
        for part in smp[0].split(','):
            key,value=part.split('=',1) if '=' in part else ('cpus',part)
            if key in ('cpus','sockets','dies','cores','threads','maxcpus') and re.fullmatch(r'[0-9]{1,5}',value): topology[key]=int(value)
    disks=[]
    for value in options(args,'-drive'):
        parts=properties('drive,'+value)
        disks.append({key:parts[key] for key in ('cache','aio','discard','detect-zeroes','format')
                      if parts.get(key) in ('none','writeback','writethrough','directsync','unsafe','native','threads','io_uring','unmap','on','off','raw','qcow2')})
    threads=[]
    for value in options(args,'-object'):
        if value.startswith('iothread,'):
            parts=properties(value)
            threads.append({'pollMaxNs':int(parts['poll-max-ns']) if re.fullmatch(r'[0-9]{1,9}',parts.get('poll-max-ns','')) else None})
    nics=[item.split(',')[0] for item in options(args,'-device') if item.split(',')[0] in ('virtio-net-pci','e1000','e1000e','rtl8139')]
    warnings=[]
    if accelerator=='tcg': warnings.append('software-cpu-emulation')
    if accelerator=='kvm' and cpu!='host': warnings.append('cpu-model-not-host')
    if any(d.get('cache')=='unsafe' for d in disks): warnings.append('unsafe-disk-cache')
    if any(n!='virtio-net-pci' for n in nics): warnings.append('emulated-network-adapter')
    return {'requestedAccelerator':accelerator,'cpuModel':cpu,'topology':topology,'disks':disks[:8],
            'ioThreads':threads[:8],'networkModels':nics[:8],'warnings':warnings,
            'scope':'Requested arguments only. KVM activity and performance require runtime measurements; no disk paths or VM names exported.'}


def inspect(args):
    displays = options(args, '-display')
    devices = options(args, '-device')
    gpus = [item for item in devices if item.split(',')[0] in ('virtio-gpu-gl-pci', 'virtio-vga-gl')]
    vnc = bool(options(args, '-vnc'))
    models = [item.split(',')[0] for item in displays]
    backend = models[0] if len(models) == 1 and models[0] in ('dbus', 'egl-headless', 'none') else 'unknown'
    display = properties(displays[0]) if len(displays) == 1 else {}
    gpu = properties(gpus[0]) if len(gpus) == 1 else {}
    objects = options(args, '-object')
    memory = [properties(item) for item in objects if item.startswith('memory-backend-memfd,')]
    shared = [item.get('id') for item in memory if item.get('share') == 'on']
    wired = any(properties('machine,' + item).get('memory-backend') in shared
                for item in options(args, '-machine'))
    rescue = backend == 'none' and not gpus and any(item.startswith('std') for item in options(args, '-vga'))
    issues = []
    if len(displays) != 1:
        issues.append('display-count-invalid')
    if backend == 'dbus' and vnc:
        issues.append('dbus-gl-and-vnc-incompatible')
    if backend == 'dbus' and display.get('gl') != 'on':
        issues.append('dbus-gl-not-enabled')
    if not rescue:
        if len(gpus) != 1:
            issues.append('accelerated-gpu-count-invalid')
        if gpu.get('venus') != 'on' or gpu.get('blob') != 'on':
            issues.append('venus-or-blob-not-enabled')
        if not wired:
            issues.append('shared-memfd-not-wired')
        if backend not in ('dbus', 'egl-headless'):
            issues.append('unsupported-accelerated-display')
    render_node = display.get('rendernode', '')
    if not re.fullmatch(r'/dev/dri/renderD[0-9]+', render_node):
        render_node = None
        if not rescue:
            issues.append('render-node-not-explicit')
    return {'backend': backend, 'vnc': vnc, 'gpuCount': len(gpus), 'venus': gpu.get('venus') == 'on',
            'blob': gpu.get('blob') == 'on', 'sharedMemfd': wired, 'vgaRescue': rescue,
            'renderNode': render_node, 'issues': issues, 'performance': performance(args),
            'scope': 'Launch configuration only; no Vulkan import or visible-frame validation'}


def collect():
    candidates = []
    for path in glob.glob('/proc/[0-9]*/cmdline'):
        try:
            with open(path, 'rb') as file:
                raw = file.read(131073)
            if len(raw) > 131072:
                continue
            args = raw.rstrip(b'\0').decode('utf-8', errors='replace').split('\0')
            if os.path.basename(args[0]) == 'qemu-system-x86_64':
                result=inspect(args)
                affinity=len(os.sched_getaffinity(int(path.split('/')[2])))
                result['performance']['availableLogicalCpus']=affinity
                cpus=result['performance']['topology'].get('cpus')
                if cpus and cpus>affinity: result['performance']['warnings'].append('vcpu-affinity-oversubscribed')
                candidates.append(result)
        except (OSError, ValueError):
            continue
    return candidates[0] if len(candidates) == 1 else {'error': 'Expected exactly one QEMU process'}


if __name__ == '__main__':
    print(json.dumps(collect()))

#!/usr/bin/env python3
"""Create an explicit Compose comparison override; never restart a VM."""
import argparse
import json
import os
from pathlib import Path
import re


def profile(name, affinity='', queues=0, hugepages='off', preallocate=False):
    if name not in ('baseline','cache','io-thread','io-thread-low-cpu','readback-small-cache','custom'):
        raise ValueError('Unknown comparison profile')
    if name != 'custom' and (affinity or queues or hugepages != 'off' or preallocate):
        raise ValueError('Use custom for CPU, network or memory options')
    return {'HELIOS_SHADER_CACHE':str(int(name == 'cache')),
            'HELIOS_IO_THREAD':str(int(name in ('io-thread','io-thread-low-cpu'))),
            'HELIOS_READBACK_CACHE_ENTRIES':'2' if name=='readback-small-cache' else '8',
            'HELIOS_IO_POLL_NS':'0' if name=='io-thread-low-cpu' else '',
            'HELIOS_CPU_AFFINITY':affinity,'HELIOS_NET_QUEUES':str(queues),
            'HELIOS_HUGEPAGES':hugepages,'HELIOS_PREALLOC':str(int(preallocate)),'HELIOS_FRAME_TRACE':'0'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile',choices=('baseline','cache','io-thread','io-thread-low-cpu','readback-small-cache','custom'))
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--service',default='windows')
    parser.add_argument('--cpu-affinity',default='')
    parser.add_argument('--net-queues',type=int,choices=range(0,9),default=0)
    parser.add_argument('--hugepages',choices=('off','2M','1G'),default='off')
    parser.add_argument('--preallocate',action='store_true')
    parser.add_argument('--shader-cache',action='store_true')
    parser.add_argument('--io-thread',action='store_true')
    parser.add_argument('--io-poll-ns',choices=('0','32768','65536'))
    parser.add_argument('--frame-trace',action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}',args.service):
        parser.error('Invalid Compose service name')
    try:
        env=profile(args.profile,args.cpu_affinity,args.net_queues,args.hugepages,args.preallocate)
        if args.shader_cache or args.io_thread or args.frame_trace or args.io_poll_ns:
            if args.profile != 'custom': raise ValueError('Use custom to combine options')
            env['HELIOS_SHADER_CACHE']=str(int(args.shader_cache))
            env['HELIOS_IO_THREAD']=str(int(args.io_thread))
            env['HELIOS_FRAME_TRACE']=str(int(args.frame_trace))
            if args.io_poll_ns:
                if not args.io_thread: raise ValueError('Use --io-thread with --io-poll-ns')
                env['HELIOS_IO_POLL_NS']=args.io_poll_ns
        # Validate CPU syntax with the same production parser, without changing affinity.
        import importlib.util
        path=Path(__file__).resolve().parents[2]/'helios/host/performance.py'
        spec=importlib.util.spec_from_file_location('host_performance',path)
        host=importlib.util.module_from_spec(spec);spec.loader.exec_module(host)
        if args.cpu_affinity: host.cpu_set(args.cpu_affinity)
        data={'services':{args.service:{'environment':env}}}
        fd=os.open(args.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'w') as output: json.dump(data,output,indent=2);output.write('\n')
    except (OSError,ValueError) as error:
        parser.exit(1,str(error)+'\n')
    print('Created:',args.output)
    print('Apply explicitly with your original Compose file plus this override. No VM was changed.')
    print('Compare A/B/A/B; disable the override to restore the original configuration.')


if __name__ == '__main__': main()

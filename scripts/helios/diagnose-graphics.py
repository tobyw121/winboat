#!/usr/bin/env python3
"""Collect bounded, read-only guest graphics diagnostics without VM clipboard use."""
import argparse
import importlib.util
import datetime
import json
import os
import pathlib
import re
import subprocess
import time
import urllib.error
import urllib.request
import uuid


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise urllib.error.URLError('The local guest API unexpectedly redirected')


def parse_transport_errors(text):
    events = []
    patterns = (
        ('buffer-size-mismatch', r'OPTIMAL DMA-BUF shape mismatch required=(\d+) fd_size=(\d+)', ('requiredBytes', 'bufferBytes')),
        ('egl-image-error', r'glEGLImageTargetTexture2DOES failed: (0x[0-9a-fA-F]+)', ('glError',)),
        ('egl-import-error', r'EGL DMA-BUF import failed for fourcc=(0x[0-9a-fA-F]+) modifier=(0x[0-9a-fA-F]+)', ('fourcc', 'modifier')),
        ('memory-accounting-error', r'invalid device-local memory accounting: release=(\d+) used=(\d+)', ('releasedBytes', 'usedBytes')),
        ('device-selection-mismatch', r'no unique Vulkan device matches DRM render node (\d+):(\d+)', ('drmMajor', 'drmMinor')),
        ('vram-budget-refused',r'vram-budget refused: release=([01]) requested=(\d{1,20}) used=(\d{1,20}) cap=(\d{1,20})',('release','requestedBytes','usedBytes','limitBytes')),
        ('budget-rejected', r'budget-rejected requested=(\d{1,20}) owned=(\d{1,20}) limit=(\d{1,20})', ('requestedBytes','ownedBytes','limitBytes')),
        ('import-backoff', r'import-held source=(\d+) ino=(\d+) attempts=(\d+) delay_ns=(\d+)', ('source','inode','attempts','delayNanoseconds')),
    )
    # Capture fixed numeric fields only, never arbitrary container log messages.
    for line in text.splitlines():
        for kind, pattern, names in patterns:
            match = re.search(pattern, line)
            if match:
                event = {'kind': kind}
                stamp=re.match(r'^(\d{4}-\d{2}-\d{2}T[0-9:.]+Z) ',line)
                if stamp: event['hostAtUtc']=stamp[1]
                event.update({name: value if value.startswith('0x') else int(value)
                              for name, value in zip(names, match.groups())})
                events.append(event)
    return events[-32:]


def parse_frame_metrics(text):
    records=[]
    patterns=(
        ('dmabuf-export',r'dmabuf-contract export ino=(\d{1,20}) allocated=(\d{1,20}) blob=(\d{1,20}) fd_bytes=(\d{1,20}) memory_type=(\d{1,10}) fd_type=(\d{1,10})',
         ('inode','allocationBytes','blobBytes','bufferBytes','memoryType','fdType')),
        ('dmabuf-import',r'dmabuf-contract import source=(\d{1,10}) ino=(\d{1,20}) bytes=(\d{1,20}) required=(\d{1,20}) alignment=(\d{1,20}) width=(\d{1,10}) height=(\d{1,10}) stride=(\d{1,10}) format=(\d{1,10}) tiling=(\d{1,10}) modifier=(\d{1,20}) usage=(\d{1,10}) flags=(\d{1,10}) image_bits=(\d{1,10}) fd_bits=(\d{1,10})(?: offset=(\d{1,10}) planes=(\d{1,10}))?',
         ('source','inode','bufferBytes','requiredBytes','alignment','width','height','stride','format','tiling','modifier','usage','flags','imageMemoryBits','fdMemoryBits','offset','planes')),
        ('ack',r'frame-ack source=(\d+) sequence=(\d+) wait_us=(\d+) success=([01]) in_flight=(\d+) transport=(copy|dmabuf)(?: inode=(\d{1,20}))?',
         ('source','sequence','waitMicroseconds','success','inFlight','transport','inode')),
        ('resource-create',r'resource-create id=(\d{1,20}) source=(\d{1,20}) ino=(\d{1,20}) imported=(\d{1,20}) snapshot=(\d{1,20}) staging=(\d{1,20}) owned_total=(\d{1,20}) peak=(\d{1,20})',
         ('resourceId','source','inode','importedBytes','snapshotBytes','stagingBytes','ownedBytes','peakBytes')),
        ('resource-release',r'resource-release id=(\d{1,20}) source=(\d{1,20}) ino=(\d{1,20}) imported=(\d{1,20}) owned=(\d{1,20}) remaining=(\d{1,20}) peak=(\d{1,20})',
         ('resourceId','source','inode','importedBytes','releasedBytes','ownedBytes','peakBytes')),
        ('resource-frame',r'resource-frame id=(\d{1,20}) source=(\d{1,20}) ino=(\d{1,20}) sequence=(\d{1,20}) published=([01])',
         ('resourceId','source','inode','sequence','published')),
        ('frame-region',r'frame-region source=(\d{1,20}) x=(\d{1,10}) y=(\d{1,10}) width=(\d{1,10}) height=(\d{1,10}) bytes=(\d{1,20}) partial=([01])',
         ('source','x','y','width','height','bytes','partial')),
        ('capture',r'helios_vulkan_capture ino (\d+) seq (\d+) publish ([01]) (\d+)x(\d+) submit_ns (\d+) wait_ns (\d+) cpu_ns (\d+)',
         ('inode','sequence','published','width','height','submitNanoseconds','waitNanoseconds','cpuNanoseconds')),
    )
    for line in text.splitlines():
        for kind,pattern,names in patterns:
            match=re.search(pattern,line)
            if match:
                record={'kind':kind}
                record.update({key:value if key=='transport' else int(value) for key,value in zip(names,match.groups()) if value is not None})
                stamp=re.match(r'^(\d{4}-\d{2}-\d{2}T[0-9:.]+Z) ',line)
                if stamp: record['hostAtUtc']=stamp[1]
                if all(type(v) is not int or 0<=v<2**64 for v in record.values()): records.append(record)
    return records[-64:]


def collect_gpu_heap(container, render_node):
    if not isinstance(render_node,str) or not re.fullmatch(r'/dev/dri/renderD[0-9]{1,6}',render_node):
        return {'error':'Explicit DRM render node unavailable'}
    try:
        raw=subprocess.check_output(['docker','exec',container,'/opt/helios/gpu-preflight',render_node],text=True,timeout=20)
        if len(raw)>32768: raise ValueError('Oversized preflight report')
        report=json.loads(raw)
        if not isinstance(report,dict) or report.get('ready') is not True: raise ValueError('GPU identity not ready')
        return {'sampledAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'observation':report}
    except (OSError,ValueError,subprocess.SubprocessError):
        return {'error':'Live Vulkan heap observation unavailable'}


def collect_host(container):
    result = {}
    try:
        template = '{{json .Config.Image}}\n{{json .Image}}\n{{json .State.Status}}'
        fields = subprocess.check_output(['docker', 'inspect', '--format', template, container], text=True, timeout=10).splitlines()
        result.update(zip(('image', 'imageId', 'containerState'), map(json.loads, fields)))
        logs = subprocess.run(['docker', 'logs', '--timestamps', '--tail', '300', container], capture_output=True, text=True, timeout=10, check=True)
        result['transportErrors'] = parse_transport_errors((logs.stdout + '\n' + logs.stderr)[-262144:])
        result['frameMetrics'] = parse_frame_metrics((logs.stdout + '\n' + logs.stderr)[-262144:])
        # Use the same fixed phase decoder as performance comparisons when
        # running from the source tree; packaged capture still retains counters.
        helper=pathlib.Path(__file__).with_name('measure-performance.py')
        if helper.is_file():
            spec=importlib.util.spec_from_file_location('performance_metrics',helper)
            metrics=importlib.util.module_from_spec(spec);spec.loader.exec_module(metrics)
            result['framePhases']=metrics.phase_summary(result['frameMetrics'])
        result['frameMetricsScope'] = 'Bounded log tail; ACK wall time and Vulkan capture phases, not guest FPS or end-to-end input latency. Frame tracing is optional.'
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        result['error'] = type(error).__name__ + ': host graphics details unavailable'
    root = pathlib.Path(__file__).resolve().parents[2]
    try:
        template = '{{index .Config.Labels "org.winboat.helios.runtime"}}\n{{index .Config.Labels "org.winboat.helios.display"}}'
        labels = subprocess.check_output(['docker', 'image', 'inspect', '--format', template, result['imageId']], text=True, timeout=10).splitlines()
        result['runtimeVersion'] = labels[0] if re.fullmatch(r'glvnd-v\d{1,3}', labels[0]) else None
        result['displayVersion'] = labels[1] if re.fullmatch(r'dbus-v\d{1,3}', labels[1]) else None
        source=root / 'src/shared/helios.ts'
        expected = re.search(r"HELIOS_RUNTIME_VERSION = '(glvnd-v\d+)'",source.read_text()) if source.is_file() else None
        if expected:
            result['expectedRuntimeVersion'] = expected[1]
            result['runtimeMatches'] = result['runtimeVersion'] == expected[1]
    except (OSError, KeyError, IndexError, ValueError, subprocess.SubprocessError):
        result['runtimeError'] = 'Host runtime capability labels unavailable'
    try:
        helper = pathlib.Path(__file__).with_name('inspect-qemu-backend.py').read_text()
        process = subprocess.run(['docker', 'exec', '-i', container, 'python3', '-'], input=helper,
                                 capture_output=True, text=True, timeout=10, check=True)
        if len(process.stdout) > 8192:
            raise ValueError('Oversized backend report')
        result['qemuBackend'] = json.loads(process.stdout)

    except (OSError, ValueError, subprocess.SubprocessError):
        result['qemuBackend'] = {'error': 'Running QEMU configuration unavailable'}
    try:
        raw=subprocess.check_output(['docker','exec',container,'cat','/run/helios-gpu-preflight.json'],text=True,timeout=5)
        if len(raw)>32768: raise ValueError('Oversized preflight report')
        result['gpuPreflight']=json.loads(raw)
    except (OSError,ValueError,subprocess.SubprocessError):
        result['gpuPreflight']={'error':'GPU preflight unavailable; update host runtime'}
    node=result.get('qemuBackend',{}).get('renderNode')
    if node: result['gpuHeap']=collect_gpu_heap(container,node)
    try:
        bundle=(pathlib.Path(__file__).parent.parent/'helios') if pathlib.Path(__file__).parent.name=='graphics-tools' else root/'resources/helios'
        receipt = json.loads((bundle/'helios-build.json').read_text())
        result['bundledInstaller'] = {key: receipt.get(key) for key in ('sha256', 'winboatCommit', 'sourceLockSha256')}
    except (OSError, ValueError):
        result['bundleError'] = 'Local installer receipt unavailable'
    return result


def read_endpoint(opener, base, endpoint, timeout=20):
    try:
        with opener.open(base + '/' + endpoint, timeout=timeout) as response:
            raw = response.read(131073)
            if len(raw) > 131072:
                raise ValueError('Response exceeds 128 KiB')
            data = json.loads(raw)
            if not isinstance(data, dict):
                raise ValueError('Expected a JSON object')
            return data
    except urllib.error.HTTPError as error:
        detail = {'error': str(error), 'httpStatus': error.code}
        try:
            raw = error.read(131073)
            if len(raw) <= 131072:
                detail['response'] = json.loads(raw)
        except (OSError, ValueError):
            pass
        return detail
    except (urllib.error.URLError, TimeoutError, ValueError) as error:
        return {'error': str(error)}


def collect(container, opener=None, samples=1, interval=5, sleeper=None):
    if not 1 <= samples <= 12 or not 2 <= interval <= 30:
        raise ValueError('Use 1..12 samples and a 2..30 second interval')
    port = subprocess.check_output(['docker', 'port', container, '7148/tcp'], text=True).splitlines()
    if not port:
        raise RuntimeError('Guest API port 7148/tcp is not published')
    number = int(port[0].rsplit(':', 1)[1])
    if not 1 <= number <= 65535:
        raise RuntimeError('Invalid guest API port')
    opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    base = f'http://127.0.0.1:{number}'
    result = {'collectedAtUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),'captureId':uuid.uuid4().hex,'requestTiming':{}}
    if samples > 1:
        observations = []
        for index in range(samples):
            observations.append({'hostAtUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                 'adapters': read_endpoint(opener, base, 'graphics/adapters',timeout=3)})
            if index + 1 < samples:
                (sleeper or time.sleep)(interval)
        result['capture'] = {'intervalSeconds': interval, 'observations': observations,
                             'scope': 'Cached native monitor samples; no extra PowerShell polling'}
    # Slow collectors run once after sampling. Older guests retain explicit 404s.
    for endpoint in ('version', 'graphics/diagnostics', 'graphics/helios', 'graphics/history',
                     'graphics/diagnostics/journals', 'graphics/diagnostics/runtime','graphics/validation'):
        started=datetime.datetime.now(datetime.timezone.utc).isoformat()
        slow=endpoint in ('graphics/diagnostics','graphics/diagnostics/journals','graphics/diagnostics/runtime')
        result[endpoint] = read_endpoint(opener, base, endpoint,timeout=20 if slow else 3)
        result['requestTiming'][endpoint]={'startUtc':started,'endUtc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    result['finishedAtUtc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', default='WinBoat')
    parser.add_argument('--output', type=pathlib.Path)
    parser.add_argument('--samples', type=int, choices=range(1, 13), default=1)
    parser.add_argument('--expected-runtime')
    parser.add_argument('--interval', type=int, choices=range(2, 31), default=5)
    args = parser.parse_args()
    if args.expected_runtime and not re.fullmatch(r'glvnd-v\d{1,3}',args.expected_runtime): parser.error('Invalid expected runtime capability')
    try:
        result = collect(args.container, samples=args.samples, interval=args.interval)
        result['host'] = collect_host(args.container)
        if args.expected_runtime:
            result['host'].update(expectedRuntimeVersion=args.expected_runtime,
                                  runtimeMatches=result['host'].get('runtimeVersion')==args.expected_runtime)
        spec=importlib.util.spec_from_file_location('correlation',pathlib.Path(__file__).with_name('graphics-correlation.py'))
        correlation=importlib.util.module_from_spec(spec);spec.loader.exec_module(correlation)
        result['correlation']=correlation.correlate(result)
        path = args.output or pathlib.Path.home() / '.winboat/diagnostics' / (
            'graphics-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d-%H%M%S-%f') + '.json')
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w', encoding='utf-8') as output:
            json.dump(result, output, indent=2, ensure_ascii=False)
            output.write('\n')
        print('Recording:', path)
        application = result.get('graphics/diagnostics', {}).get('driver', {}).get('application')
        if application is None:
            print('Application diagnostics unavailable; update the WinBoat guest service for feature/crash details.')
        if any(result.get(endpoint, {}).get('httpStatus') == 404 for endpoint in (
                'graphics/history', 'graphics/diagnostics/journals', 'graphics/diagnostics/runtime')):
            print('Extended diagnostics unavailable; update the WinBoat guest service.')
        print(json.dumps(result, indent=2, ensure_ascii=False))
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()

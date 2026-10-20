#!/usr/bin/env python3
"""Preview a filtered graphics report; export only after matching its preview hash."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re

# Positive schema: unknown fields/strings are omitted, even if a future guest
# accidentally returns passwords, application arguments, paths or dump data.
KEYS=set('''schema diagnosticsVersion collectedAtUtc finishedAtUtc captureId version
build_time graphics_protocol runtime_protocol commit_hash errors status state scope
host runtimeVersion displayVersion expectedRuntimeVersion runtimeMatches containerState
qemuBackend backend vnc gpuCount venus blob sharedMemfd vgaRescue renderNode issues
transportErrors kind requiredBytes bufferBytes releasedBytes usedBytes hostAtUtc
gpuPreflight gpuHeap sampledAtUtc observation devices matchingDevices ready vendorId deviceId apiVersion selected
vramBudgetPercent vramHardCapBytes
timelineSemaphore synchronization2 dynamicRendering bgraOptimalImportable imageQueryResult
externalMemoryFd memoryBudgetAvailable pciMatchesDrm deviceUuid driverUuid heaps sizeBytes deviceLocal
sizeChecks verdict multipleExports bufferContracts allocationBytes blobBytes memoryType fdType alignment stride offset planes tiling modifier usage imageMemoryBits fdMemoryBits
resourceTimeline firstObservedHostFailure resourceId importedBytes snapshotBytes stagingBytes ownedBytes peakBytes
limitBytes requestedBytes partial x y sourceInode
frameMetrics inode sequence published width height submitNanoseconds waitNanoseconds
cpuNanoseconds source waitMicroseconds success inFlight transport capture intervalSeconds
observations adapters sampleAgeMs helios basic problemCode desktopState recovery policy goal
updatedAtUtc graphics/diagnostics graphics/diagnostics/runtime graphics/diagnostics/journals
graphics/validation graphics/history graphics/helios driver controllers DriverVersion
ConfigManagerErrorCode CurrentHorizontalResolution CurrentVerticalResolution application
crashes dwmCrashes displayResets AppName ModuleName ExceptionCode FaultingOffset ProcessId
timeUtc recordId umdLogs journals file signals count codes tailBytes tailTruncated
moduleBoundaryFound deviceReadyMeaning journal device birth elapsedMs queries mismatches
presented firstMismatch firstFailure events seq values format samples flags levels hr
requestTiming startUtc endUtc correlation guestEvents hostEvents umdFiles
minimumSeconds maximumSeconds guestMinusHostClockRange truncated rejectedFeatures feature
processId loadedApplications modules name path boundDriverVersion testSigning rescueHold
driverRegistry requestedCycles restartAdapter cycles cycle lifecycle
acceptance transaction comparison resume release dump-policy results
label passed exitCode test summary identity manifestSha256 machineId bootAtUtc profile
UmdD3D12 UmdCommandLists UmdFreeThreaded UmdAsyncPresentStream UmdPresentBatchFold FeatureLevel11
maximumFiles expiresAtUtc dumpType enabled owned bytes available warnings apiRegistration
performance requestedAccelerator cpuModel topology cpus sockets dies cores threads maxcpus
disks cache aio discard detect-zeroes ioThreads pollMaxNs networkModels availableLogicalCpus
memoryBudget local budgetBytes usageBytes reservationBytes availableReservationBytes
framePhases submitMeanMs waitMeanMs cpuMeanMs ackSamples ackMeanMs captureSamples
values featureCorrelation umdCorrelation runtimeModules exceptionCode faultingOffset
'''.split())
# No path or machine/user-specific free text is accepted. Even known keys such
# as path/name/errors are filtered by exact values and numeric/API grammars.
WORDS=set('''running stopped disabled enabled waiting held none unknown unavailable
passed failed timeout not-run not-recorded not-installed pending-reboot experimental
vm-tested accepted awaiting-acceptance vga-rescue dbus egl-headless copy dmabuf
created format msaa msaa-refused msaa-policy runtime-error resource view shader present
returned device-ready device-create-failed device-destroyed no-present-observed adapter-open
producer-init-failed producer-submit-failed buffer-size-mismatch egl-image-error
egl-import-error memory-accounting-error device-selection-mismatch import-backoff
undersized size-equal padded-or-different-layout dmabuf-export dmabuf-import vram-budget-refused budget-rejected resource-create resource-release resource-frame frame-region ack capture
kvm tcg host max qemu64 qemu32 other unspecified virtio-net-pci e1000 e1000e rtl8139
writeback writethrough directsync unsafe native io_uring unmap on off raw qcow2
software-cpu-emulation cpu-model-not-host unsafe-disk-cache emulated-network-adapter vcpu-affinity-oversubscribed
minidump dwm.exe vulkan_virtio.dll helios_umd.dll helios_umd32.dll helios_umd12.dll
helios_umd12_32.dll d3d11.dll dxgi.dll d3d12.dll vulkan-1.dll libgallium_wgl.dll
'''.split()) | {'Microsoft Basic Display Adapter','Helios vGPU'}
TOKEN=re.compile(r'^(?:[0-9a-fA-F]{1,64}|0x[0-9a-fA-F]{1,16}|\d+(?:\.\d+){1,3}|'
                 r'\d{4}-\d\d-\d\dT[0-9:.+Z-]{8,32}|(?:glvnd|dbus)-v\d{1,3}|'
                 r'helios-watchdog-v\d{1,3}|vcredist-v\d{1,3}|umd(?:12)?-\d{1,10}\.log|'
                 r'VK_ERROR_[A-Z0-9_]{1,64}|(?:hr|HRESULT)=0x[0-9a-fA-F]{8}|[AB][12])$')


def filter_report(value, depth=0):
    if depth>16: return None
    if value is None or type(value) is bool: return value
    if type(value) in (int,float):
        return value if abs(value)<=2**64 and math.isfinite(value) else None
    if isinstance(value,str): return value if len(value)<=128 and (value in WORDS or TOKEN.fullmatch(value)) else None
    if isinstance(value,list): return [clean for item in value[:128] if (clean:=filter_report(item,depth+1)) is not None]
    if isinstance(value,dict):
        return {key:clean for key,item in value.items() if key in KEYS and (clean:=filter_report(item,depth+1)) is not None}
    return None


def prepare(path):
    if path.stat().st_size>2097152: raise ValueError('Input exceeds 2 MiB')
    data=json.loads(path.read_text(encoding='utf-8-sig'))
    if not isinstance(data,dict): raise ValueError('Expected graphics JSON object')
    clean=filter_report(data)
    payload=(json.dumps({'schema':1,'filteredGraphics':clean},ensure_ascii=True,indent=2)+'\n').encode()
    return payload,hashlib.sha256(payload).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report',type=Path)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--review-sha256',help='SHA256 displayed by the preceding preview')
    args=parser.parse_args()
    try:
        payload,digest=prepare(args.report)
        if args.output:
            if args.review_sha256!=digest: raise ValueError('Preview hash required or preview changed; review again')
            fd=os.open(args.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
            with os.fdopen(fd,'wb') as stream: stream.write(payload)
            print('Exported:',args.output)
        else:
            print(payload.decode(),end='')
            print('Review SHA256:',digest)
            print('Paths, user/application text, unknown fields and all memory dumps excluded. Nothing uploaded.')
    except (OSError,ValueError) as error: parser.exit(1,str(error)+'\n')


if __name__=='__main__': main()

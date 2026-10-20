# Helios .299: host, QEMU and guest contracts

The default bundled installer remains **22.22.291.0**. `.299` is a separate
source/build candidate. The .294 and .296 test bundles are unchanged. Nothing
here certifies that the reported NVIDIA flicker, black screen or game crashes
are fixed. A physical Windows/NVIDIA validation VM was not attached for these
changes.

## Implemented changes

| Layer | Behavior | Default / limit |
|---|---|---|
| Host admission | Vulkan UUID + DRM major/minor selection; compare known PCI BDFs; require a unique Vulkan 1.3 device and external-memory FD support | Accelerated launches only; inspection and VGA rescue remain available |
| Host capabilities | Report timeline semaphore, synchronization2, dynamic rendering, BGRA optimal external import support | Capability queries, not an actual DMA-BUF import or rendering test |
| Memory observation | Startup preflight JSON and refreshed selected-device heap observations; existing NVIDIA sensor sampling | On diagnostics request; every five minutes in soak |
| QEMU memory | Account successful owned snapshot/staging Vulkan allocations, rollback failed reservations, refuse overflow/underflow | Imported producer memory is separate; not total renderer/driver VRAM |
| QEMU byte budget | Reserve before allocation; reject allocations exceeding a process-wide owned-byte cap | Off by default; `readback-budget` profile selects 256 MiB |
| Damage readback | Row-packed immutable partial CPU transport after a valid full baseline; repair after capture failure with a full frame | Off by default; `readback-damage` profile enables it |
| Correlation | Resource create/frame/release IDs, source ID, DMA-BUF inode and ACK; viewer reports imported inode | Trace is opt-in; IDs are process-local and historical |
| Shared resources | Two D3D11 devices and a child process; inherited NT handle allowlist, keyed mutex, exact red/green readback both directions | Native validation tool; child timeout 15 s and mutex timeout 3 s |
| Capabilities | Child-only `d3d11-backend-caps` intersects normalized output/MSAA support with real backend answers | Off by default; may expose a legitimate FL11 creation failure |
| Activation | Check bound driver version, all five driver-image hashes, runtime hashes and six API registration paths before explicit re-enable | Reject mixed packages without enabling Helios |
| Lifecycle | Repeat acceptance tests; optional explicit Helios restart with verified primary VGA; persist partial failures | Three cycles by default; stop at first failure; never restart VGA |
| Compatibility | Host runtime `glvnd-v9`; Guest API `helios-watchdog-v16` | Old host runtime requires rebuild; `.291` installer pin unchanged |

`VK_EXT_memory_budget` heapUsage is an observation for the temporary **probe
process**, not the renderer's allocations. Driver budgets can reflect broader
pressure; use the existing NVIDIA sensor sample for whole-device observations.
QEMU's owned-byte ledger covers only its own snapshot/staging allocations.
These three measurements must not be summed as if they measured one quantity.

The damage profile reduces the CPU payload for small dirty rectangles. It does
not guarantee that the underlying Vulkan image copy avoids full-image work.
The budget profile can retain the last completed frame when a new allocation is
refused. Neither profile is enabled automatically or promises higher FPS.

## Using the tools

After updating/rebuilding the host and app, leave the VM running and collect:

```bash
python3 scripts/helios/diagnose-graphics.py
```

This includes the actual QEMU backend, startup admission result, a fresh heap
observation, fixed numeric transport errors and resource correlation. Trace
identifiers do not imply equality with guest KMD handles or Vulkan object
handles. Missing evidence, reused IDs and log rotation do not prove causality.

For longer observations, use a new output filename:

```bash
python3 scripts/helios/soak-graphics.py --minutes 30 --interval 60 --output /tmp/helios-soak.jsonl
```

In the logged-in Windows desktop, use the Helios control panel's repeat-test
button or native 64-bit PowerShell:

```powershell
& 'C:\Program Files\WinBoat\scripts\Test-HeliosLifecycle.ps1' -Cycles 3
```

For a custom Guest Server installation, run the script from its `scripts`
directory beside `Show-HeliosControlPanel.ps1`.
To include the independently hashed extended tools (resize/MSAA, format contracts
and shared-process pixels), supply `-ToolsPath` and `-ToolsManifestSha256` as
with `Test-HeliosAcceptance.ps1`. The SHA-256 is the trusted `tools.json` hash,
not an executable's hash.

`-RestartAdapter` is an explicit additional lifecycle test. It requires elevation,
a coherent package, no rescue hold and a fresh console-session observation of
healthy primary VGA. It restarts only the verified Helios PCI instance. Reboot
requirements, timeouts or failures stop the test; no automatic reboot follows.
Manual host standby/reconnect observation remains in `Test-HeliosResume.ps1`.

Saved lifecycle results are read through **GET `/graphics/validation`**. The API
cannot launch these probes or accept a caller-supplied executable. Detailed
acceptance runs remain in the existing bounded comparison history.

## Validation and release boundary

Windows CI passed the actual WARP two-device/two-process shared-resource pixel
probe. Local validation covered real Mesa GL/GLES viewer rendering and D-Bus
lifecycle, patched QEMU callback/ROI/ACK behavior, actual Vulkan allocation and
budget refusal on Lavapipe, Go race tests and Windows compilation, Rust contract
logic, and PowerShell activation/lifecycle failure gates. WARP/Lavapipe success
is not NVIDIA/Helios acceptance.

Before adopting `.299`, test cold boot, login and DWM stability, Vulkan and D3D11
pixel probes, odd-size resize, shared-process tools, explicit restart and manual
host suspend/resume on the actual VM. Compare `.291` and `.299` with identical
host image, probes, scene and resolution. Keep VGA available and record both
loaded UMD/ICD paths and driver hashes. Building an installer does not change
the bundled default or establish this acceptance.

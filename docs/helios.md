# Helios integration

For a combined Docker build from this repository, see
[WinBoat und Helios lokal bauen](build-helios-local.md). The upstream Helios
root sources are included under `helios/upstream/`; the host build verifies
that snapshot and fetches only its pinned external dependencies.
For the proposed local DMA-BUF viewer and its implementation requirements, see
[Helios architecture](helios-architecture.md).
An initial optional native viewer is documented in
[Local Helios desktop](helios-local-display.md).

This WinBoat branch integrates the Helios Windows WDDM graphics stack at commit
`d82ce565ac792eb48da5e59f2a82a12ff221851d`. Its Windows installer is pinned to
`fecffde64fd32399a877b452332681ef0db7993e`, the last complete upstream bundle.
The guest/transport/renderer, installer and Windows build-tool trees are identical between these revisions;
the newer host pin carries QEMU fixes. `helios/stack.lock.json` records this pair,
the shared tree/gitlink identities, bundled executable hash and its original provenance.
It uses Helios's own installer and paired QEMU, Venus protocol, virglrenderer, Mesa, DXVK and vkd3d revisions.
It does not pass a physical GPU exclusively to Windows. Windows remains a full
VM. The old `VIRGL=1` toggle is replaced by a Helios graphics selection.

## Included Windows installer and source build

The complete `resources/helios/HeliosSetup.exe` and `helios-build.json` are tracked
in this WinBoat repository. A fresh clone has the installer; packaging never
needs an upstream Actions download or GitHub token. The initial imported binary
retains its upstream origin and SHA-256 in `helios/stack.lock.json`; it is not
presented as a newly compiled WinBoat binary.

WinBoat's `.github/workflows/build-helios-windows.yml` checks out **this repository**
and verifies/prepares its embedded `helios/upstream/` sources. It builds the WDK
miniport, native/WoW64 D3D11/D3D12 UMDs, Mesa Venus/Zink, CLVK, loaders and complete
Rust installer payload. External engines remain dependencies fetched at the
recorded gitlinks. The workflow runs on relevant pushes to `work`. Manual
dispatch is available once the workflow is also present on the default branch.
It does not automatically publish or replace the checked-in binary.

To promote a reviewed package from WinBoat's own CI:

```sh
npm run helios:adopt-installer -- /path/to/downloaded-winboat-artifact
```

Commit the updated installer, receipt and checksum lock together. The receipt
records the producing WinBoat commit, repository, embedded source snapshot and
source-lock digest, alongside guest compatibility and executable SHA-256.
Normal staging/package builds enforce the pinned hash and reject an unexpected
replacement. The receipt is an integrity/provenance record, not a digital signature.
`npm run helios:fetch-installer` remains a compatibility alias that verifies the
included bundle locally; it no longer contacts GitHub.

See [the Windows build instructions](helios-windows-build.md) for the complete
source/build/import flow. The installed Linux application carries both files
under its `resources/helios` directory.

The actual installer offers GUI install/repair/update/uninstall, as well as:

```powershell
.\HeliosSetup.exe --silent
.\HeliosSetup.exe --silent --uninstall
```

Use the GUI for manual installation into an existing VM and follow its reboot
prompts. Drivers from this workflow are **test-signed**, not Microsoft production
signed. VM Secure Boot must be disabled for that development signing mode; the
installer verifies the requirement. WinBoat does not change host firmware or
turn off host security features. Production distribution requires an appropriate
Microsoft driver signing process. Upstream's root sources currently have no
explicit root license; clarify redistribution rights before publishing builds.
Keep all supplied engine/component licenses with distributed artifacts.

## Build the matching Linux host image

On Linux x86_64, with Docker/Compose available:

```sh
npm run build:helios:host
```

The Dockerfile starts from a digest-pinned dockur Windows 5.07 image. It builds
Helios's pinned protocol, renderer and QEMU fork, runs the upstream protocol and
renderer synchronization tests, and installs an explicit QEMU wrapper selecting
the paired renderer library and render server. Build concurrency defaults to four
and can be changed with `HELIOS_BUILD_JOBS`. Allow at least 20 GB of free disk space for source/build layers. The final image
uses a separate runtime stage without compilers or source trees.
No source is fetched from a moving branch. Build-time proxy trust can be mounted
as the optional `proxy_ca` BuildKit secret; certificates are not baked into layers.

The resulting local image is `winboat/helios:d82ce565ac79`. Compose uses
`pull_policy: never`; WinBoat checks its source-revision label before use.
The host needs Linux 6.13+, KVM, a working Vulkan 1.3-capable GPU/driver,
`vulkan-tools`, and an accessible `/dev/dri/renderD*` node. These are runtime
requirements, not capabilities established by a successful container build.

NVIDIA additionally needs NVIDIA Container Toolkit configured as the Docker
`nvidia` runtime. WinBoat then requests the GPU with Compose `gpus: all` and the
graphics capabilities; the Linux NVIDIA driver continues to own it. Default
render-node selection is the first accessible node. To select a specific GPU,
launch WinBoat with `WINBOAT_HELIOS_RENDER_NODE=/dev/dri/renderD129` (adjust to your
actual device). Both the selected node and Vulkan compatibility need testing on
the target host; the Vulkan summary is a prerequisite check, not conformance.

## New Windows VMs

Choose Helios in setup (initially selected when a render node is detected).
Preflight verifies host/image/bundle prerequisites before writing VM setup.
The usual Windows disk, guest server, shared folders, API, QMP and RDP ports
remain part of the VM. The GPU device is `virtio-gpu-gl-pci` with Venus and blob
resources and shared memfd-backed guest RAM; EGL-headless and VNC/WebSocket expose its console.

WinBoat places the verified installer in the OEM directory. After guest-server
installation, the OEM helper queues a durable SYSTEM worker which invokes
`HeliosSetup.exe --silent --automatic`. The first invocation runs independently
of the SetupComplete/AME session. The verified installer, receipt and worker
are retained in the protected `C:\ProgramData\WinBoat\Helios` directory.
The upstream installer owns driver backup/registration, signature verification,
repair and its resume task. WinBoat's worker starts at startup/logon, resumes a
missed or disabled official task, and recovers a missing task through its cached
verified installer. It never starts a second installer while the official task
is running. It observes fresh results and performs at most two Windows-only restarts. A persisted boot
and stage guard prevents repeated reboot loops. Failures stop this task and are
published to the UI. Installation only completes after the guest status says
`finished`, an installation record exists, and the revision matches the pinned guest revision in the host/guest compatibility lock.
No unauthenticated driver-install or reboot API endpoint is added.

## Existing VMs and rollback

Back up the Windows disk before changing graphics drivers. Existing VMs are not
automatically converted. Update their WinBoat guest server, enable Helios in
WinBoat's configuration and confirm the adapter switch. The host prerequisites
are checked and the verified installer folder is opened. The VM restarts with
Venus available; use **Browser Display / Windows Desktop** to access the console,
copy `HeliosSetup.exe` into Windows, run the GUI and complete its restarts.
Do not require driver completion before switching the host: the driver needs the
Helios/Venus device during its first boot. Selecting the adapter alone does not
establish installed-driver readiness. The guest server reads the installed
upstream manifest for the source identity; `GET /graphics/helios` should report
`installed: true`, `status: finished` and the pinned guest revision afterward.

To return to the standard image, uninstall through `HeliosSetup.exe` **inside
Windows**, restart Windows, then disable Helios in WinBoat. Configuration refuses
the switch while the managed driver remains installed. Compose replacement keeps
the storage mapping and backs up the previous compose file; it never formats the
Windows disk. If Windows cannot start, recover from the disk backup rather than
repeatedly toggling graphics devices.

## Display and diagnostics

For a Helios VM, the **Windows Desktop** action opens the console via the browser
display by default, or the optional native viewer when enabled in Settings.
Both stay on the Helios adapter instead of creating an RDP desktop.
Individual RemoteApp launches still use the existing FreeRDP integration.
The default console transport is noVNC. The experimental native GTK4 viewer
imports DMA-BUF frames with a conservative GPU-copy/acknowledgment path; it is
not yet a direct-scanout gaming viewer. Rendering performance must not be
confused with viewer FPS or audio/controller support.

- `GET /graphics/helios` is a read-only guest-server status endpoint.
- Windows setup log: `C:\ProgramData\Helios\logs\setup.log`.
- Durable status: `C:\ProgramData\Helios\provisioning-status.json`.
- WinBoat restart guard/receipt: `C:\ProgramData\WinBoat\Helios`.
- Host diagnostics: `docker logs WinBoat` and host NVIDIA Xid/kernel messages.
- Run upstream `Verify-Helios.ps1 -RunSmokeTests` in the logged-in Windows session
  after provisioning, followed by real Vulkan/D3D11/D3D12 applications. A matching
  file receipt and an open display are not proof of graphics correctness.

## Validation

```sh
npm run test:helios
npm run test:virgl
npm run test:helios:host # requires the built local image; no physical GPU test
npx vue-tsc --noEmit -p src/renderer --skipLibCheck
npm run build
npm run build-guest-server
# Linux-side test of the platform-independent read-only status handler:
go test guest_server/helios_status.go guest_server/helios_status_test.go
```

Helios remains experimental, with upstream DX12 frame-ordering, recovery and
conformance gaps. This cloud machine has no KVM/GPU and no native Windows WDK;
it can validate WinBoat, compose generation, status handling and the host build,
but cannot establish Windows driver installation, GPU acceleration or game
compatibility. The Windows CI workflow and hardware acceptance must actually run
before calling the complete system ready. No fabricated driver binaries are
included in this repository.

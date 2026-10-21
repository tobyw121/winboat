# Graphics management, measured profiles and .302 symbol artifacts

The bundled stable installer remains **22.22.291.0**. The .301 Windows build
completed successfully; .302 is the new experimental source candidate with
separate Mesa debug artifacts. A successful build is not hardware acceptance.
The source version alone does not identify an installed stack: keep the CI
receipt, installer checksum, package manifest and source commit together.

## WinBoat Configuration

The graphics section now provides an on-demand status/recovery center. It shows
bound adapter versions separately from loaded module versions, the saved stable
and candidate transaction versions, configured host runtime/backend, and the
last acknowledged DMA-BUF/copy transport. Missing trace data stays unknown;
a transport older than ten seconds is marked historical. An ACK does not prove
that correct pixels reached the screen. This panel adds no background PowerShell
polling. Refreshing status does not change drivers or reboot Windows.

Recovery actions are explicit:

- Disable Helios while preserving VGA.
- Restart the existing VM with the verified VGA-only override.
- Restore the original host graphics configuration.
- Check the saved update transaction or prepare its recorded stable rollback.
- Enable bounded local DWM minidumps for 30 minutes, or disable that capture.

The guest exposes only fixed maintenance operations under `/graphics/maintenance`
with the explicit `X-WinBoat-Maintenance` header. No arbitrary executable,
installer, path or uploaded script is accepted. Operations serialize with guest
rescue and use the existing provisioning guards. The guest protocol is
`helios-watchdog-v17`; older services need the normal WinBoat guest update.

Host rescue can restart Windows; save work first. DriverStore cleanup still
requires physical Helios absence in the VGA-only boot and verified package
identity. Restoring the host configuration does not re-enable a guest-disabled
adapter. Existing timed trials remain the explicit route to test enabling it.

## Stable and experimental transactions

Windows **Helios Control** now includes folder selection for a complete installer
and receipt, plus an independently checked installer SHA-256 field. To establish
a stable rollback, first run the existing current-boot acceptance tests and
visually check color, window switching, resolution change and recovery. Then
record the matching complete bundle as stable.

Installing an experimental bundle verifies that the retained rollback executable
still exists and matches its saved checksum, and refuses to replace an unresolved
transaction. The retained state includes the previous verified package, manifest,
VM identity and driver option profile. Startup checks require a new boot and the
expected installed package; explicit acceptance still requires fresh automated
and visual evidence. An interruption in `prepared` or `restoring` becomes
`rollback-required` and requests isolation instead of implying success.

Rollback remains staged and explicit: use VGA-only rescue, prepare verified
cleanup, finish any required cleanup reboot, then restore host graphics and use
the transaction check to reinstall the recorded package. Complete its reboot
and acceptance. A cleanup restart is not silently treated as finished. A missing
stable record is not reconstructed by guessing from a version string.

## Performance experiments

WinBoat offers baseline, shader-cache, I/O-thread-without-busy-polling,
damage-readback and idle-refresh profiles. Applying one changes only the managed
performance keys and restarts this VM. Disk paths, ports, driver selection,
RAM/CPU allocation and the 85-percent VRAM policy remain unchanged. The first
application retains the original managed environment values in the Compose
extension `x-winboat-performance`; Restore returns those exact values, including
originally absent keys. Pending unrelated form edits are not applied. Applying profiles is refused during the managed VGA-only rescue boot; restore host graphics explicitly first.

Use the measurement controls with the same short workload/resolution key in
**A1/B1/A2/B2** order. They sample container CPU and available host GPU sensors
for about twenty seconds, save exclusive local JSON files, and compare four
selected results. They do not infer guest FPS. Existing CLI PresentMon CSV input
can add guest frame-time median/p95/p99 to a report.

Reports record selected GPU UUID, image ID and allowlisted launch settings before
and after sampling. A changed configuration during a measurement or within an
arm makes comparison invalid. Missing context stays explicitly unverified.
Actual Windows resolution and scene still have to be held constant by the user.
No profile is promoted based on a single faster observation.

## QEMU display behavior and contracts

`glvnd-v12` adds bounded idle polling: after sixteen quiet GL refreshes the poll
interval backs off to 100 ms. Damage restores the previous interval. Set
`HELIOS_IDLE_REFRESH=0` for the previous polling behavior when comparing results.
Copies remain damage-driven; an idle scan does not itself publish a frame.
Existing immutable snapshots, single-frame ACK backpressure and bounded import
cache are retained. Tests verify coalesced damage and that no second transfer
starts before ACK. These tests do not establish RTX 2070 latency or FPS.

The existing producer checks exported FD/blob bounds; QEMU checks the actual
Vulkan requirements and supported layout before import. Diagnostics now also
identify observed incompatible memory-type masks, alignment, plane count and
explicit LINEAR bounds. OPTIMAL/tiled layouts are never inferred from pitch ×
height, and no larger invented size is substituted for an FD's real backing.
No observed violation is not a proof of complete layout or synchronization
compatibility. The existing wire/producer completion ordering remains intact.

## Capability regression tool

The separate Windows validation-tools artifact includes
`helios-capabilities.exe`. Run it in the signed-in guest console, capturing its
output. It reads actual D3D11 feature level, threading/options, format/MSAA
queries, and Vulkan core features, selected limits and extension versions. It
refuses ambiguous adapters and emits a completion marker only after success.
It does not advertise new features or replace rendering tests.

On the host, record and compare identical probe bytes:

```bash
python3 scripts/helios/compare-capabilities.py baseline.txt --probe helios-capabilities.exe > baseline-caps.json
python3 scripts/helios/compare-capabilities.py candidate.txt --probe helios-capabilities.exe > candidate-caps.json
python3 scripts/helios/compare-capabilities.py candidate-caps.json --against baseline-caps.json
```

Every changed capability requires review and relevant pixel tests. Partial runs,
software WARP captures and different probe hashes cannot establish the comparison.
The tool covers selected queries, not the entire D3D/Vulkan specification.

## Local crash analysis

Helios Control can select a local `.dmp`, Windows SDK `cdb.exe`, and matching local
PDB directory. Analysis uses exact-symbol mode, ignores inherited symbol-server
paths and stores its output locally with restricted access. Inspect symbol-load
warnings; a completed debugger run is not proof of correct attribution. Dumps
and debugger output are never automatically included in support ZIPs.

Mesa's MinGW build uses DWARF rather than native PDBs. .302 builds keep release
optimization, generate DWARF, and strip bulky debug sections from runtime DLLs.
The separate symbols ZIP contains `mesa/x64` and `mesa/x86`, each with debug files
and `symbols.json` binding exact runtime/debug SHA-256 hashes and PE load bases.

For a faulting module RVA from a crash report:

```bash
python3 scripts/helios/symbolize-mesa.py --runtime /path/to/installed/vulkan_virtio.dll --symbols /path/to/symbols/mesa/x64 --module vulkan_virtio.dll --offset 0x38b141
```

Use `--addr2line` to select GNU binutils when needed. The tool checks both hashes
before lookup and adds the recorded PE load base to the RVA; ASLR addresses are
not accepted as RVAs. A mismatching or unresolved symbol remains an error/unknown.
The example offset is historical and not evidence against the new build.

## Activation and validation

Rebuild the app and host image from `work` for the new controls and runtime:

```bash
git pull --ff-only origin work
./scripts/build-helios.sh
```

The build preserves the .291 bundled installer; obtain experimental .302 and its
matching symbols/receipt from its successful Windows CI artifact when available.
Do not infer readiness while that build is still running.

Verification includes native Windows/WARP capability queries in GitHub CI,
actual EGL callback tests, Go API tests and Windows cross-compilation, transaction
interruption tests, a real local DWARF lookup with mismatch refusal, profile
preservation/restoration, packaged helper imports, support filtering, TypeScript
checks and app production compilation. Full QEMU/runtime and .302 assembly run
separately in CI. Physical GPU, DWM recovery and game validation remain required.

See [graphics evidence and recovery](helios-evidence-and-recovery.md) for verified offline backups, lifecycle checkpoints, on-demand guest load, transport trials and the atomic viewer resize handoff.

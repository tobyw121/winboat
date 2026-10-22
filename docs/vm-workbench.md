# Compatibility and performance workbench

Open **Configuration → VM integration → Compatibility and performance workbench**.
Rebuild the AppImage and Helios host image with `./scripts/build-helios.sh` and
update the Windows guest service. The added guest endpoints require
`helios-watchdog-v20`. No Helios kernel/UMD package or bundled .291 installer is
changed by these features.

## Measurements and application profiles

Metrics refresh on demand, or every five seconds while the page is open if
explicitly enabled. Docker CPU percentages are relative to **one host core**;
they can exceed 100%. NVIDIA sensors are optional. Viewer redraw rate is computed
only across matching process, console, resolution and transport generations; it
is not game FPS or proof of pixels reaching the screen. Import an existing
PresentMon CSV for a single application PID to inspect presentation intervals.
Collection of PresentMon itself is not started automatically.

Saved application profiles contain an absolute Windows EXE path, argument array,
resolution, viewer transport and process-local API mode. Display settings apply
to the VM, require an explicit restart and can be restored independently of
network/resource changes. The native mode uses driver defaults. Compatibility
currently means the existing Helios D3D11 feature-level 10 diagnostic override,
not installing Proton/DXVK DLLs. Unsupported installed UMDs reject the override.
Starting an application separately asks for confirmation in the signed-in Windows
console. The API passes JSON data, not dynamically assembled PowerShell source;
application arguments use Windows argument quoting. Only one confirmation request
can be pending. Profiles are stored privately under `.winboat/ApplicationProfiles`.

The background-work option sets the existing native viewer pacing to 5 updates/s
for hidden or inactive outputs. Reopen the viewer to apply it. Foreground frames
continue normally; no host GPU clocks or power settings are changed. Existing
bounded frame caches, shared VRAM accounting and damage-driven QEMU refresh remain
in place. No performance improvement is claimed without an A/B measurement.

## DMA-BUF and update evidence

Enable layout diagnostics explicitly, reproduce, compare layouts, then stop them.
This restarts the VM and adds logging overhead. The viewer records producer inode,
allocation size, extent, stride, offset, FourCC and modifier; QEMU already records
its Vulkan import requirements. The comparison joins bounded historical records
by inode and allocation extent, translates known Vulkan/FourCC format pairs and
flags allocation-size mismatches. An unmatched record stays unknown. INVALID
modifiers are never reinterpreted as LINEAR. Runtime imports still use the
existing EGL/Vulkan checks and bounded software-copy fallback; diagnostics do not
force unsafe imports or disable a driver.

Stack compatibility, timed Helios/VGA recovery and recorded stable rollback use
the existing graphics workflows. The workbench can request the fixed Windows
acceptance suite; confirm Windows UAC, allow it to finish and inspect the report.
It does not install or promote a candidate by itself.

For regression evidence, run acceptance, record a baseline, perform cold boot,
resize or logon, run fresh acceptance and capture the result. The release gate
requires matching driver manifest, machine/version and host image, fresh API
probe results and passed scenario evidence. It reports missing evidence or
failures instead of treating a successful build as acceptance. Visual observation
remains required. A .291 installation lacking the newer diagnostic probes will
correctly leave the broader gate incomplete. Evidence is private under
`.winboat/RegressionEvidence`.

## Resource and network profiles

CPU sets must cover the allocated virtual CPUs and refer to online Linux CPUs.
Hugepage mode uses **already reserved** free 2 MiB pages and preallocation; the UI
checks capacity and the QEMU wrapper verifies it again at boot. No host hugepage
reservation is created. Profiles retain their managed previous values; restoring
one preserves later unrelated settings and shared-folder mounts.

NAT uses the existing Docker management network. Isolated mode disables the guest
network, including API/RDP/shares. LAN mode uses an **existing Docker macvlan
network**, Windows DHCP and the current NIC model; it does not rename or emulate
a different adapter. Local Desktop must be configured first because macvlan host
isolation can break management port reachability. LAN mode exposes Windows on the
LAN; configure its firewall accordingly. No host interfaces/routes or Docker
networks are created automatically. Restore network returns the managed settings
to their recorded values with a restart.

## VSS live disk exports

Configure the agent channel and private backup mount, which restarts Windows.
Install the official Windows QEMU Guest Agent **with VSS support** and the serial
port driver in Windows. The new host capability is `qga-v1`. QGA and the separate
maintenance QMP socket exist only inside the container, not on a published TCP
port. The export worker does not compete with WinBoat's existing QMP connection.

Before export, the worker requires thawed Windows QGA freeze/thaw support, known
local writable `/storage` block nodes and enough free space for a full export.
It prepares QCOW2 target nodes, requests VSS freeze, briefly pauses QEMU, starts
all full-copy jobs atomically, resumes QEMU and verifies thaw **before** waiting
for copying. A bounded freeze window is enforced. Lost responses, job errors and
normal termination signals enter cleanup. The detached worker continues if the
WinBoat window closes. Thaw recovery is explicit; it cannot override an active
export's lock. Abrupt host/container failure is not a completed backup.

Only concluded jobs without errors are accepted. Target nodes are closed before
SHA-256 hashing. Status moves through preparing/copying/hashing/completed; an
incomplete or failed export must not be restored as a completed one. Files remain
private and owned by the owner of the mounted backup directory.

Exports live under `.winboat/LiveBackups/<id>`, with a private `<id>.container.json`
record containing the host image and container configuration. That record can
contain passwords; do not publish it. The export includes writable disk and
firmware block nodes, not RAM, GPU state, shared folders or every non-disk file in
`/storage`. TPM state and BitLocker recovery material are not included; retain
the original VM state and recovery keys, and keep a full offline checkpoint for
complete VM recovery. Restore **offline**, preserving the recorded mapping, firmware and
host configuration. Convert QCOW2 back to the original disk format into a new
storage directory, validate it, then switch the stopped VM; never overwrite a
running disk. The offline snapshot manager does not automatically import these
exports. Removing the export configuration keeps the saved files.

## Game mouse and validation limits

The relative-mouse option explicitly replaces one standard USB tablet with a USB
mouse and restarts Windows. Custom/multiple tablets are rejected. In the native
viewer, **Capture mouse** confines and recenters the X11 pointer; Ctrl+Alt+G,
focus loss, adapter changes or viewer exit release it. Physical-pixel centers
avoid motion drift on odd window dimensions and HiDPI. Wayland pointer capture
is not implemented; the viewer reports that limitation instead of pretending to
grab it. Restore mouse returns to the previous device configuration.

Validation includes portable profile/consent tests, Windows service cross-build,
policy restoration tests, failure-injected freeze/thaw tests, real QEMU full-copy
and exact disk comparison (with **simulated VSS**), GTK rendering/fallback tests
and relative-coordinate tests. Real Windows VSS writers, UAC, physical NVIDIA
rendering, LAN reachability and games still require validation on a desktop VM.

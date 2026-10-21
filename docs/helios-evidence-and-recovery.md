# Graphics evidence, regression and recovery

The bundled installer remains **22.22.291.0**. These changes extend the host,
viewer and guest-service investigation tools; they do not promote an experimental
Windows driver. Rebuild the app/host runtime and update the guest service to
`helios-watchdog-v18` to use the complete toolset. Building and software fixtures
cannot certify the RTX 2070/Windows installation or resolve its historical flicker.

## Configuration controls

Graphics status and recovery in Configuration now provides:

- Stack compatibility checks: host runtime, display protocol, guest protocols,
  viewer protocol, guest-source receipt and the actual bundled installer hash.
  Unknown/mismatched versions block a positive compatibility assessment.
- A recovery recommendation based on fresh native adapter observations. Disabled
  Helios still requires a VGA-only boot before DriverStore cleanup. Cleanup and
  stable rollback retain their existing exact-package and backup prerequisites.
- On-demand guest CPU/I/O deltas via `GET /graphics/diagnostics/load`. The API
  serializes collectors, limits execution and caches results for five seconds.
  There is no new background PowerShell polling loop. Process command lines are
  excluded. PID plus creation time prevents reused PIDs from inheriting CPU load.
  One-core CPU can exceed 100%; VM CPU is divided by logical processor count.
  I/O counters include transfers other than physical disk access; processes that
  start and exit between samples may be missed.
- Offline storage backup creation and verification.
- Measured A1/B1/A2/B2 comparisons, including explicit transport verification.

The check is observational. Windows Helios Control still owns installation,
retained stable-package validation, reboot checks and explicit acceptance.
A compatible version receipt does not prove feature correctness or visible pixels.

## Private offline backup

Shut Windows down normally and stop its container cleanly first. The tool refuses
running, paused, restarting or unsuccessfully exited containers. It supports one
bind-mounted `/storage`, including its disk files and firmware state, and saves
private container configuration. That configuration can contain passwords.
Shared host folders and external disks are outside this archive's scope. Named
volumes, QCOW2 external backing chains and custom external QEMU disk arguments
require a separate complete backup procedure and are refused.

```bash
python3 scripts/helios/backup-vm.py --create /backup/winboat-private.tar
```

Space must cover the logical size of an uncompressed archive, including sparse
disk files. Source contents, file set and container start/stop identity are checked
again, then archive hashes are verified before publishing a new private file.
Existing backups are never overwritten. Keep interrupted temporary files private.

```bash
python3 scripts/helios/backup-vm.py --verify /backup/winboat-private.tar
```

Restore only into a new, nonexistent directory; the parent must already exist:

```bash
python3 scripts/helios/backup-vm.py --verify /backup/winboat-private.tar --restore-to /recovery/windows-storage
```

This verifies every member before writing and never attaches or boots the result.
The existing VM stays untouched. An interrupted restore is marked incomplete.
Checksums detect corruption; they do not authenticate the archive's author.
Container configuration is retained for review, never executed during restoration.

## Pixel tests, features and longer runs

Obtain `tools.json` and its independently verified SHA-256 from the graphics
validation build. The five-tool bundle is supported, including the capability
probe. In an elevated, interactive Windows PowerShell session, run the existing
`Test-HeliosAcceptance.ps1` with `-ToolsPath` and `-ToolsManifestSha256`.
The same report records queried capabilities, exact probe hashes, installed
manifest, driver options, VM identity and boot identity.

On the Linux host, convert a saved diagnostic report (or its acceptance object)
to query evidence:

```bash
python3 scripts/helios/compare-capabilities.py graphics-report.json --acceptance-input > capabilities.json
```

Compare two captures with `--against baseline-capabilities.json`. Format/MSAA
changes carry their associated successful format-contract test hashes. Coverage
is explicitly a tested subset. Other feature changes remain uncovered and need
relevant rendering/compute tests; enumeration is not feature acceptance.

`Test-HeliosLifecycle.ps1` now accepts up to 1000 cycles and
`-IntervalSeconds 0..300`, persisting each completed cycle and stopping at the
first failed acceptance run. For example, use 20 cycles with a 30-second interval,
plus the same pinned external tools. Its default does not restart devices.
`-RestartAdapter` retains the explicit healthy-primary-VGA gate and only restarts
the verified Helios device. Run it inside the signed-in Windows desktop. Stop an active lifecycle suite before
guest driver maintenance; its provisioning lock protects the test stack. Host
VGA-only rescue remains available.

For hour/day sampling without changing devices:

```bash
python3 scripts/helios/soak-graphics.py --minutes 120 --interval 60 --viewer-log ~/.winboat/diagnostics/viewer-telemetry.log --output soak.jsonl
```

Use `--expect-animation` only while a continuously moving scene is running.
A static desktop is not a hang. Sampling gaps, process changes and memory growth
are observations, not automatic crash/leak diagnoses.

## Verified transition checkpoints

After a successful external-tool acceptance run, record a baseline on the host:

```bash
python3 scripts/helios/regression-graphics.py --output before.json
```

Perform the intended transition yourself, sign in and repeat the interactive
acceptance run. Wait for fresh runtime/adapter samples, then record the checkpoint:

```bash
python3 scripts/helios/regression-graphics.py --before before.json --scenario cold-boot --output after.json
```

Other scenarios are `logon`, `standby` and `resize`. Cold boot requires both a new
container start and a changed Windows boot. Logon requires a changed authentication
LUID in the same boot; a DWM restart or reused session number is insufficient.
Standby requires ordered Windows sleep/resume events, which do not certify host
suspend. Resize requires changed, positive Helios display dimensions. Every
positive assessment requires a new current-boot pixel/format acceptance run,
unchanged VM/package/profile/host image, fresh running adapters and no observed
DWM crash or display reset in the guest-clock window. Incomplete evidence stays
`inconclusive`; checkpoints perform no power, logoff or display changes.

## Copy versus DMA-BUF

The viewer has **Auto transfer**, **Copy test**, and **DMA-BUF test**. The two test
modes require the selected path on Helios. An unavailable path is not silently
accepted as the other one. VGA keeps its normal policy; a test-mode refusal does
not request guest driver recovery. Auto transfer restores normal fallback.
Selections are temporary. The optional `HELIOS_VIEWER_TRANSPORT` environment
variable accepts `auto`, `copy`, or `dmabuf` for a direct viewer launch.

Choose Copy test, keep a moving scene at the chosen resolution, and record A1 in
Configuration with **Verify Copy test**. Repeat B1/DMA-BUF, A2/Copy, B2/DMA-BUF.
The comparison requires matching actual Helios dimensions, host image, selected
GPU and unchanged settings, plus fresh completed reads exclusively on each
requested path. A fallback, rotated log, static workload or incomplete trace
cannot produce a verified transport comparison. Workload equality still requires
operator control; this is not a causal proof or automatic driver promotion.

Equivalent CLI measurement:

```bash
python3 scripts/helios/measure-performance.py --label A1 --comparison-key scene-1080p --transport-mode copy --viewer-log ~/.winboat/diagnostics/viewer-telemetry.log --output A1.json
```

The app stores only fixed numeric viewer counters in a private, bounded 0600 log.
Each measurement reads newly appended records, not historical statistics.

## Resource and frame investigation

Resource create/use/release timelines now flag possible duplicate creation,
use after release and repeated release. Bounded tails can start/end mid-lifetime,
and IDs may be reused after a process restart. An open tail is not a leak.
DMA-BUF bounds are interpreted as row-major only with explicit LINEAR layout;
unknown OPTIMAL/modifier layouts are never guessed from pitch times height.

The QEMU frame trace and viewer now log exact D-Bus peer GUID/message serial
pairs. Enable `HELIOS_FRAME_TRACE=1` in the container and viewer environment only
for a controlled capture. Viewer wire records are filtered and rate-limited;
large captures can be incomplete. Collect both sides with:

```bash
python3 scripts/helios/diagnose-graphics.py --viewer-log ~/.winboat/diagnostics/viewer-telemetry.log
```

The report separates resource/capture counters, listener ACKs, guest events and
viewer callbacks. Matching GUID/serial establishes QEMU-to-viewer message identity.
Viewer receive-to-ACK durations use its own monotonic clock. Guest versus host
UTC offset remains an interval. There is no invented common guest/renderer frame
number, GPU execution time or physical display-visibility guarantee.

DMA scanout geometry now remains pending until the first successful private copy.
A resized copy uses a candidate texture and commits pixels and extent together;
announcing a new producer size alone cannot reinterpret the previous frame.
Real GL/GLES tests exercise both this handoff and existing VGA/Helios isolation.

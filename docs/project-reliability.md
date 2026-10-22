# Reliability and integration improvements

Open **Configuration → VM integration → Host checks, backups and API permissions**
and the adjacent compatibility/performance workbench. Rebuild the AppImage and
host image with `./scripts/build-helios.sh`, then update the guest service to
`helios-watchdog-v21`. The default checksum-pinned `.291` installer and separate
candidate installers are preserved. This change does not publish a new KMD/UMD.

## The twenty project improvements

| # | Area | Implementation and practical boundary |
|---|---|---|
| 1 | VGA fallback | Existing confirmed-PnP containment now also handles three DWM crashes attributed to a Helios UMD/ICD within two minutes. Enable explicitly in elevated Helios Control. Requires healthy, active primary VGA; never enables VGA, changes primary or retries endlessly. Unknown telemetry cannot authorize isolation. |
| 2 | Transactional driver changes | Existing protected transaction journal, retained stable bundle, staged rollback and rescue prerequisites remain the driver-change route. New active-version diagnostics supplement the existing checksum/registration activation gate. DriverStore deletion is targeted, not a blanket provider purge. |
| 3 | Mixed versions | `graphics/diagnostics.driver.stackCoherence` compares bound miniport, API registration paths and loaded files. Unused older packages are not automatically labelled conflicting. Missing metadata remains unknown. |
| 4 | Windows control panel | Existing native Helios Control exposes driver options, process-local profiles and restoration. Added attributed-crash isolation and scoped-API enforcement controls. Machine-wide removal of Vulkan/OpenGL is deliberately not an API switch: it can break DWM and other software. |
| 5 | Graphics acceptance | Existing hashed D3D11, Vulkan, OpenGL, presentation, resize and lifecycle tests remain the acceptance suite. Added portable stack-coherence, image bounds, API permission and configuration rollback tests. A Linux build cannot certify Windows/NVIDIA rendering. |
| 6 | Compatibility catalogue | Workbench shows advisory observations for FurMark, Icarus and GPU-Z, explicitly separating user reports from verified compatibility. Existing saved profiles are applied manually. No unsupported game workaround is represented as a fix. |
| 7 | Buffer tracing | Existing exact D-Bus peer/message and inode/layout traces remain available; incident advice explains allocation mismatches. Guest KMD handles and renderer objects still do not share a universal frame ID. Cross-clock association remains evidence, not proven causality. |
| 8 | VRAM budgeting | Existing shared QEMU/renderer ledger, driver-budget checks and 85% ceiling remain intact. No fixed 16/500 MiB reinterpretation was introduced. Driver overhead and unrelated host processes are not fully represented by this ledger; physical total GPU usage is separately observed. |
| 9 | Bounded queues | Existing source-read acknowledgement, coalescing, bounded imports and damage refresh remain intact. Added a reversible two-entry readback-cache trial to compare memory/latency tradeoffs; no unmeasured speedup is promised. |
| 10 | Validated transport | Existing Auto mode imports supported DMA-BUFs, requests validated copy fallback after repeated import failure and preserves the other adapter. OPTIMAL/INVALID modifiers are never relabelled LINEAR. |
| 11 | Configuration trials | Resource, network and compact-cache changes start a five-minute host watchdog. Confirm the working configuration or restore immediately. The detached process survives closing the window; expired trials are recovered on the next status/change after a host restart. An active live export defers rollback. External compose edits cause a conflict instead of being overwritten; explicitly keeping them archives the original privately. Display application profiles retain their explicit restore path. |
| 12 | Guided restore | Verify completed export checksums, original disk mapping, QCOW2 structure and virtual sizes; convert into a new private directory and perform exact `qemu-img compare`. Never overwrite the running VM. Automatic boot remains blocked because live disk exports omit TPM state; use a complete offline checkpoint for full-machine recovery. |
| 13 | Backup management | Export inventory/free-space reporting, daily systemd **user** timer and retention for scheduled offline checkpoints. Running/unclean VMs and insufficient capacity are skipped; manual snapshots and live exports are not pruned. The worker is copied to a durable private directory, outside the temporary AppImage mount. |
| 14 | Clipboard | Direction-specific Windows consent; automatic text ≤256 KiB, manual text ≤4 MiB; explicit PNG ≤8 MiB and bounded uncompressed 24/32-bit DIB conversion. Images ≤4096 per dimension and ≤8 megapixels. PNG alpha can be lost through the opaque DIB read path. Palettes/RLE/bitfields are unsupported. Lock/logoff/disconnect clears the session. |
| 15 | Shared folders | Existing authenticated named shares, read-only settings and permission checks are exposed alongside the new tools. The reachability checker does not claim SMB authentication succeeded; use the dedicated share check. |
| 16 | Host preflight | On-demand KVM/render-node access, desktop presence, Docker server, OpenGL and Vulkan observations. GTK build metadata is advisory; use the dedicated viewer context probe to test GTK OpenGL. No packages/drivers are installed by preflight. |
| 17 | Network assistance | NAT/LAN/isolation policy UI, existing-macvlan validation, independent API/RDP/browser TCP checks and macvlan host-isolation warning. No host routes, interfaces or firewall rules are created. |
| 18 | Measurements | Private chronological CPU/GPU sample history, CPU chart and before/after deltas. Image, guest build, resource allocation, GPU selection, installed driver versions and resolution must match. Point samples and viewer redraws are not game FPS; retain workload/scene/thermal controls and PresentMon frame-time measurements. |
| 19 | API permissions | Optional locally enabled session enforcement, Windows matching-code consent, separate read/graphics/power/application/clipboard/maintenance scopes, ten-minute in-memory tokens and sign-out identity binding. Accepted scoped mutations are logged without tokens or payloads. This is authentication, not TLS. |
| 20 | Matched release set | Successful local packaging creates `RELEASE-SET.json` with artifact hashes, exact host image ID/capabilities, application build and driver receipt. Verification detects changed files or missing local images. Stage remains `built-not-hardware-accepted`; keep the preceding verified set for rollback. Hashes are identity checks, not publisher signatures. |

## API enforcement and recovery

In elevated Windows Helios Control, enable API session permissions. In WinBoat,
select only needed scopes and pair; compare the six-digit code before accepting
in Windows. A fresh pair is needed after expiry, service restart or sign-out.
Tokens remain in the renderer's memory; fixed diagnostic workers inherit them
only for the paired loopback endpoint. Ordinary remote downloads never receive
these headers. Sensitive requests refuse redirects. The feature remains opt-in
so existing independent recovery scripts are not silently locked out.

External Python clients can explicitly supply `WINBOAT_SESSION_TOKEN` and
`WINBOAT_SESSION_ORIGIN=http://127.0.0.1:<mapped-port>` from their own consent-paired
session. Do not put tokens into logs or screenshots. Legacy scripts without a
grant receive HTTP 401 while enforcement is enabled. Local elevated Helios
Control can disable enforcement if the desktop client is unavailable. Existing
Windows confirmation and elevation requirements remain in force after pairing.

## Backup restore and timers

Choose the export identity, verify checksums and select a separate staging
parent. Existing exports without original disk-format metadata are rejected;
do not guess formats. A new export from the updated host includes this metadata.
Failed staging remains marked failed for inspection; it is never labelled ready.
A successful stage contains `restore-plan.json`, with `bootBlocked: true` and the
missing state listed. Reconstruct TPM/encryption prerequisites or use the full
offline restore workflow before booting. No isolated clone is automatically
started from incomplete machine state.

The daily timer runs only while the systemd user manager is available. It never
shuts Windows down to manufacture a backup opportunity. A snapshot is marked
schedule-managed before it can participate in retention; reusing its display
label for a manual snapshot cannot make that snapshot eligible for deletion.
Disabling the timer keeps saved data. At least 10 GiB remains free beyond the
estimated complete archive size; retention follows a successful new backup.

## Verification

Portable Go tests and Windows service cross-build cover consent/scope/expiry,
text/image bounds and crash-breaker decisions. Native GL/GLES fixtures exercise
visible pixels, fallback, output isolation and resize. Real pinned QEMU tools
verify a synthetic live disk export and a separate conversion/compare restore;
Windows VSS is simulated in the export fixture. Host tests check rollback faults,
foreign edits, artifact tampering and measurement identity. Actual Windows UAC,
VSS writers, NVIDIA hardware output, driver installation and games still require
acceptance on a real VM. No new driver binary is claimed hardware-qualified.

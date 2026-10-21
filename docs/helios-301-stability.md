# Helios .301: failure evidence, shared-buffer accounting and bounded trials

The .301 source candidate improves failure isolation. It is not an RTX 2070
flicker fix certified on hardware. The bundled **22.22.291.0 remains the default**;
separate .294/.296 installers are unchanged. Windows CI builds .301 separately.
The accounting runtime was introduced as `glvnd-v11` (now `glvnd-v12`); rebuild the host image and app
for its shared-reference accounting and packaged recovery controls.

## Find the first failure

The UMD journal attaches scoped resource/view/shader operation data to the first
runtime failure. Nested callbacks restore their caller's context and other
threads cannot inherit it. Uninstrumented operations remain unknown rather than
being labelled with the previous operation. Device creation succeeding is not
proof that DWM rendered or presented a frame.

The external validation tools add pixel checks for advertised RGBA/BGRA
single-sample and MSAA paths: clear, resolve where necessary, staging readback,
and comparison of every pixel. Float/depth cases still check creation/views;
this is not a full D3D or Vulkan conformance suite. The shared-resource probe
also verifies importer readback after producer objects and its exported NT
handle have been released. Windows CI compiles the probes; meaningful rendering
acceptance requires running them in the signed-in guest console session.

`Capture flickering` records existing diagnostics. QEMU emits import contracts
and virglrenderer emits bounded export contracts with allocation size, inode,
format, pitch, offset, tiling/modifier and memory-type fields where available.
Correlation reports undersized, equal-sized or padded/different-layout buffers.
Equal sizes alone never establish compatible layouts. Multiple exports, missing
samples and host/guest clock uncertainty remain visible. Guest crash events
are kept separate from the buffer timeline.

## Compare .291 and the candidate reproducibly

Use the existing `bisect-graphics.py --help` workflow with four captures per
candidate, ordered A1/B1/A2/B2, identical external probe bytes and exact manifest
hashes. Change the guest package or host image separately. Resolution, backend,
GPU UUID, driver profile and host performance configuration must stay fixed.
Missing context is exposed as `contextVerified: false` and `missingContext`;
such a historical trial cannot establish a controlled regression boundary.
Non-monotonic or inconsistent outcomes require testing each candidate rather
than binary search. This tool neither installs nor automatically promotes a build.

For speed comparisons, use the existing `measure-performance.py` and
`compare-graphics.py` with the same scene and A/B/A/B order. Include frame-time
median/p95/p99, CPU, selected-GPU memory and copy/import observations. A driver
name, capability bit or successful device creation is not a speed measurement.

## Buffer lifetime and fallback

The per-VM 85-percent allocation ledger now retains charges for known DMA-BUF
backings across renderer contexts, global resources and QEMU imports. Releasing
the producer does not release the charge while a known importer remains.
Opaque/unknown aliases are charged conservatively instead of guessing identity.
Dead workers, unconfirmed non-worker cleanup and lost handoffs can retain charges until the next whole-VM launch;
this is preferable to undercounting live memory. The reference ledger has 256
backing slots. It does not observe every external alias or exact physical VRAM
residency. See [the memory policy](helios-vram-budget.md).

Existing safe fallback paths remain active: failed identities back off; changing
geometry/stride/offset/modifier permits a fresh attempt. Repeated viewer import
failure requests software copy. Known explicit layouts use validated EGL copy;
MOD_INVALID requires the validated Vulkan path. There is no implicit LINEAR
reinterpretation, truncation or invented allocation size. Copy fallback cannot
repair a DWM crash before any frame is produced. VGA remains a separate recovery
output, although both adapters still share Windows' compositor and kernel.

## Timed test and support ZIP in WinBoat

Configuration → Graphics diagnostics now offers:

- **Test installed Helios (60 seconds)**: requires an already installed, disabled
  Helios and fresh healthy primary VGA. A detached host watchdog enables Helios.
  Keeping it requires your visual confirmation plus a fresh adapter/topology
  check before the deadline. Without confirmation, the watchdog requests
  Helios disable. If the guest API cannot recover, it uses the existing VGA-only
  host rescue, pinned to the current image and verified Windows storage.
- **Create support ZIP**: records diagnostics, shows a filtered preview and saves
  a local ZIP with fixed entries and hashes. Raw logs, memory dumps and unknown
  fields are excluded. The preview hash must still match at export. Nothing is
  uploaded and an existing file is not silently overwritten.

Save work before a timed trial: fallback can restart this VM. Recovery begins
after timeout; Windows reboot completion can take longer. The watchdog survives
closing WinBoat; it does not guarantee recovery after host power loss, Docker
failure or its own termination. It tests enabling the current driver, not an
installer transaction or arbitrary settings rollback. A replaced container is
never targeted. A failed recovery requires the existing explicit rescue tools.

The same timed test is available from the Linux checkout:

```bash
python3 scripts/helios/graphics-trial.py --start
python3 scripts/helios/graphics-trial.py --status TOKEN_FROM_START
python3 scripts/helios/graphics-trial.py --confirm TOKEN_FROM_START
# Or request VGA recovery instead:
python3 scripts/helios/graphics-trial.py --cancel TOKEN_FROM_START
```

`--confirm` queues confirmation; only `phase: confirmed` in status means it was
accepted. Do not close a stable rescue session merely to collect more failures.

## Validation boundaries

Local verification covers real process/thread memory-ledger contention,
producer/importer lifetime, exact pinned renderer accounting code, compiled
renderer changes, QEMU callback fixtures, recovery timeout/cancellation races,
container replacement refusal, support filtering/ZIP integrity, copied packaging
imports, TypeScript/Vue checks and production app compilation. CI separately
compiles Windows drivers/probes and the complete QEMU/host runtime.

The physical NVIDIA guest remains necessary for cold boot, login, DWM recovery,
resize, Vulkan/D3D rendering and game acceptance. No performance increase or
elimination of the .292+ flicker is claimed without those measurements.

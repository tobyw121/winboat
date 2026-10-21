# Dynamic VM GPU-memory budget: at most 85 percent

The managed accelerated host runtime (`glvnd-v12`; accounting introduced in `glvnd-v11`) creates a private per-launch
ledger in `/dev/shm`. All Venus worker processes and QEMU's owned DEVICE_LOCAL
snapshot/staging allocations use this same ledger and the Vulkan device UUID.
VGA rescue and inspection-only commands do not require it. The existing .300
16-MiB LINEAR display floor is unchanged; no new Windows installer is needed
for the host-side budget itself.

For the selected GPU, the host sums DEVICE_LOCAL Vulkan heap sizes. The global
ceiling is `floor(totalBytes * 85 / 100)`. An existing lower
`VKR_DEVICE_MEMORY_LIMIT_BYTES` setting remains a lower cap. It cannot raise the
managed ceiling. With 8 GiB, the 85-percent ceiling is approximately 6.8 GiB.

Before allocating, each worker queries its own host Vulkan memory properties
and `VK_EXT_memory_budget`, when available. The live limit is the smaller of:

- the 85-percent hard ceiling;
- the driver's current heap budget minus a reserve of 15 percent of total heap size;
- an explicitly configured lower cap.

Without the memory-budget extension, the 85-percent ceiling still applies but
host-pressure adaptation is unavailable. Startup diagnostics report whether the
extension is present. An external preflight probe's heapUsage is not used as if
it measured the renderer process. Driver budgets are estimates and can change.

Reservations are serialized across processes/threads, including in-flight
allocations. Failed allocations return their reservation. Completed frees
release it. An oversized request returns `VK_ERROR_OUT_OF_DEVICE_MEMORY`; the
policy never kills a process, forcibly frees a live image, silently shrinks a
texture, or changes resolution. Existing buffers are not allocated up to the
ceiling merely because the budget is available. A falling live budget prevents
additional allocations until use drops; it does not evict resources behind the
application's back. Applications must handle allocation failure.

Known DMA-BUF backing references share the original allocation charge across
renderer imports/resources and QEMU. The charge survives producer teardown
until the last tracked reference is released. Unknown or opaque imports are
charged conservatively; they are not deduplicated by a guessed handle identity.
The private reference ledger has 256 backing slots and rejects overflow.

This ledger limits **accounted allocation bytes**, not exact physical VRAM
residency. Driver-internal memory, shader caches, host applications and external
aliases outside the instrumented paths are not fully measured. Lost handoffs
can retain charges until the next whole-VM launch. The 15-percent reserve and
live driver estimate provide headroom; this is not a guarantee that the
hardware's whole-device usage counter will always remain at 85 percent.

Dead-worker and unconfirmed non-worker teardown charges are retained conservatively: exported buffers can outlive
their producer. A new whole-VM launch gets a fresh ledger. Corrupt, insecure,
missing or full ledgers reject new allocations rather than disabling the cap.
The ledger has 128 process/device slots and uses tmpfs; it is touched on memory
allocation/free, not on every frame. Worker configurations that deny ledger
access must be adapted before enabling accelerated graphics.

The renderer overlay also fixes an existing accounting defect: unlimited mode
used to skip the increment but still decrement on free. Unlimited mode now
tracks allocations, and an invalid free no longer clears unrelated live charges.

## Activation and diagnostics

Rebuild both the host image and app from the updated `work` branch:

```bash
git pull --ff-only origin work
./scripts/build-helios.sh
```

After a normal controlled VM restart using the rebuilt app/image, collect:

```bash
python3 scripts/helios/diagnose-graphics.py
```

`host.gpuPreflight` includes `vramBudgetPercent` and `vramHardCapBytes`.
`vram-budget-refused` events report requested, previously accounted and current
limit bytes. A zero limit can also accompany an unavailable/corrupt ledger and
must not automatically be interpreted as exhausted VRAM. Existing readback
cache/byte-budget profiles remain independent, additional lower limits.

This change does not repair a DMA-BUF layout mismatch or certify the NVIDIA
black-screen/flicker problem as fixed. Keep the VGA rescue path available.

## Verification

Tests exercise real process/thread contention, isolation between GPU UUIDs,
ownership of frees, shrinking live limits, lower manual limits, corruption and
symlink refusal. The exact pinned renderer accounting functions are compiled
and tested for unlimited tracking, overflow, bounds and underflow retention.
The actual QEMU allocation wrapper is tested against Vulkan/Lavapipe, including
successful allocation, rollback after a second limit refuses, and invalid-ledger
rejection. Full host compilation checks both overlays and records the renderer
patchset and shared-policy hash. Physical RTX 2070 acceptance remains required.

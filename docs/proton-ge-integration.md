# Proton-GE compatibility integration

The stable bundled installer remains 22.22.291.0. These changes do not install
Wine, replace Windows system DLLs, or assert that the Helios DWM flicker is fixed.

## Opt-in engine candidate

`helios/compatibility/proton-ge.lock.json` pins GE commit
`88004a046c575af0b96131ff7b76dcd598da51ad`, each original patch, its checksum,
and the exact Helios engine revision it applies to. Original authorship is
retained in the patch headers. The changes are distributed with the licenses of
the target DXVK (zlib) and vkd3d-proton (LGPL-2.1) sources; builds retain their
upstream license files. Source links in the manifest provide patch provenance.

Select `compatibility_patches` when manually running **Build WinBoat Helios
Windows installer**. Ordinary push builds remain unpatched. The final artifact
name ends in `-ge-candidate`; a separate `compatibility-patches.json` and its
SHA-256 in `helios-build.json` identify the changes. Keep those receipts with the
installer. No automatic installer adoption or VM update occurs.

For a local Windows build, prepare a separate empty build tree:

```powershell
./scripts/helios/windows/Initialize-Sources.ps1 -Component driver -CompatibilityPatches
```

A reused patched tree cannot silently become an unpatched build. Hash, base
revision or patch conflicts abort preparation. Embedded source checksums remain
unchanged. Both patches apply to the pinned engines:

* DXVK retries `VK_NOT_READY`/`VK_TIMEOUT` without rebuilding an unchanged
  swapchain, and updates the real fence state rather than a copy. A fresh
  swapchain does not expose an image before acquisition succeeds.
* vkd3d-proton checks cancellation between 100 ms presentation waits during
  teardown. A timeout is still pending work; it does not retire GPU allocations.

These fixes affect regular engine WSI swapchains. Helios also uses its own
WDDM/scanout bridges; neither patch proves that path's producer/consumer or
DMA-BUF problems are solved. Windows/NVIDIA acceptance still requires actual
rendering, resize, minimize/restore, application exit and DWM stability tests.

`python3 tests/proton-ge-patches.py SOURCE_DIRECTORY` checks both patches and
compiles/runs the actual patched DXVK acquisition branch against transient,
fresh-swapchain, retry and device-loss cases. `SOURCE_DIRECTORY` contains the
pristine pinned engine files under `dxvk-helios/src/dxvk/dxvk_presenter.cpp` and
`vkd3d-proton-helios/libs/vkd3d/swapchain.c`. It is deliberately an explicit source
fixture, with no network or engine build hidden in the unit test.

## Components requiring separate work

GE's Linux Wine fullscreen/FSR, NTSync and Media Foundation changes do not
implement native Windows features. DXVK-NVAPI is intended for Wine and does not
make NVIDIA APIs available through a virtual adapter. Pyroveil needs a tested
native layer or a renderer-scoped shader policy; the Linux latency layer does
not control the guest's offscreen-to-WDDM presentation chain. D7VK requires a
separate native compatibility package and per-application validation. None of
these components is enabled or advertised as working by these patches. HDR
requires an end-to-end guest, scanout, viewer and host color pipeline.

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

## Persistent host shader caches

With the existing opt-in `HELIOS_SHADER_CACHE=1`, cache schema 2 includes the
selected Vulkan device UUID, driver UUID, API/device identity and host runtime
fingerprints. GPU changes, driver changes and host patch changes create a new
namespace. Current memory pressure and enumeration order do not. Missing UUIDs
fail explicitly rather than reusing another GPU's cache. Old cache directories
are retained; this change never purges them while processes might use them.

`HELIOS_SHADER_CACHE_NAMESPACE=icarus-v2` optionally isolates an A/B experiment
(maximum 64 letters, digits, dots, dashes or underscores). This host namespace
is VM/renderer-wide, not an assertion of per-game isolation inside a shared
renderer. The normal default is `default`. A new namespace may initially stutter
while shaders compile; a cache is not a substitute for driver correctness.

## Optional Linux host launch via UMU

`scripts/compatibility/host-game.py` runs a game **on the Linux host**, alongside
the existing Windows VM launch route. Install `umu-run`, its runtime and an
official GE-Proton release first. This script does not download or execute an
unverified build. Use normal desktop user permissions, not sudo.

Create a dedicated profile (replace paths with actual installed files):

```bash
python3 scripts/compatibility/host-game.py create --exe '/home/me/Games/MyGame/Game.exe' --proton '/home/me/.local/share/Steam/compatibilitytools.d/GE-Proton10-XX' --prefix '/home/me/.local/share/winboat-prefixes/mygame' --output '/home/me/mygame.json'
python3 scripts/compatibility/host-game.py run '/home/me/mygame.json' --dry-run
python3 scripts/compatibility/host-game.py run '/home/me/mygame.json'
```

Optional repeatable `--argument=VALUE` passes arguments without a shell. The JSON
profile has four boolean options: `log`, `wined3d`, `disableEsync`, `disableFsync`.
They map to Proton's process-local options; change one at a time for A/B tests.
Native DXVK/vkd3d is the default, WineD3D an explicit fallback. No graphics driver
is installed in Windows. No Wine setting is applied to DWM or Helios.

The launcher pins the game executable, Proton launcher and version file hashes.
After updating a game or runtime, create a new profile and use a new prefix;
it does not silently migrate an existing prefix. A prefix is private (0700),
owned by the current user and locked for the lifetime of `umu-run`. Existing
unmanaged prefixes and mismatched identities are refused. Removing a JSON
profile does not delete saves or its prefix. Keep saves separately backed up.
The launcher returns UMU's exit code; success in a fixture test is not a claim
that Icarus or FurMark works with this route. There is no GUI entry yet.

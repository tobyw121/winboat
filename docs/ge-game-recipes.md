# Targeted GE compatibility extensions

The existing .291 default and the separately published .302 installer are not
replaced. These additions belong to the updated WinBoat app/guest helpers and
the optional Linux host launcher. There is no new claim that Icarus, FurMark or
DWM flickering is fixed.

## Native Windows application recipes

VM integration → Applications → Compatibility & launch arguments offers two
versioned, process-local diagnostic recipes: `d3d11-fl10-v1` and
`d3d11-backend-caps-v1`. This uses the Protonfixes idea of scoped, versioned
recipes; Wine-specific Python fixes are not executed in Windows. These are
explicit diagnostic presets, not certified game-specific fixes.

The first Windows-approved launch records the executable SHA-256, recorded
Helios manifest/version and managed driver options in the signed-in user's
LocalAppData/WinBoat/RecipeBindings directory. A changed binding blocks the
recipe until **Rebind recipe in Windows** is confirmed. Rebinding records the
current versions without launching the game. Selecting **None** restores a
normal process launch; no registry or DWM setting was changed by the recipe.
The existing legacy compatibility option remains available independently.

Requires the rebuilt guest service protocol `helios-watchdog-v22` and its script
bundle. Older services reject the new fields; ordinary recipe-free profiles
remain compatible. Refresh/rebuild WinBoat's guest service using the project's
normal update workflow. Updating only the Helios driver EXE does not update it.
Recipe requests use the existing consent-protected application endpoint and
never execute as SYSTEM.

## Optional D7VK app-local package

In ordinary Windows PowerShell, beside the updated guest scripts:

```powershell
.\Set-WinBoatGameCompatibility.ps1 -GameExe 'C:\Games\Classic\game.exe' -Action D7VK
.\Set-WinBoatGameCompatibility.ps1 -GameExe 'C:\Games\Classic\game.exe' -Action Restore -Profile D7VK
```

This downloads the official D7VK **v2.3** ZIP, verifies its pinned SHA-256
`ed7eec7d622d81c3606e3a7e705de955da65aba9d16ea812aa88711980b1bb66`,
extracts exactly the x86 `ddraw.dll`, checks its PE architecture and installs it
only beside the selected executable. `-D7vkArchive` accepts the same verified
archive offline. No elevation or Windows system-DLL replacement is requested.
Windows system directories are refused. Existing wrappers are never overwritten.
Ownership and executable hashes permit repeat activation and guarded removal;
a missing DLL can still be cleaned up after an interrupted operation.

D7VK v2.3 supports x86 D3D3/5/6/7 immediate-mode games and requires a working
Vulkan driver. It does not add D3D retained-mode support or accelerate pure 2D
DirectDraw. Upstream documents app-local Windows deployment but explicitly does
not test it; our checks verify package handling, not game rendering. Original
license and source: https://github.com/WinterSnowfall/d7vk/tree/v2.3.

## Additional GE DXVK profiles on the Linux host

These use the existing UMU launch route, not the native Helios WDDM bridge.
Create a **new dedicated prefix and profile** using an installed GE-Proton that
contains the relevant patched DXGI. Missing support is rejected, not ignored.

```bash
python3 scripts/compatibility/host-game.py create --exe '/home/me/Games/game.exe' --proton '/home/me/GE-Proton' --prefix '/home/me/.local/share/winboat-prefixes/probe-test' --output '/home/me/probe-test.json' --ge-recipe dxgi-probe-v1
python3 scripts/compatibility/host-game.py run '/home/me/probe-test.json' --dry-run
python3 scripts/compatibility/host-game.py run '/home/me/probe-test.json'
```

- `dxgi-probe-v1`: defer initial fullscreen and surface creation for temporary
  probe swapchains, using `dxgi.deferInitialFullscreen` and
  `dxgi.deferSurfaceCreation`.
- `keep-fullscreen-v1`: retain DXGI fullscreen on focus loss, using
  `dxgi.keepFullscreenOnFocusLoss`. Explicit mode changes remain controlled by
  the upstream implementation.
- `--d7vk`: select GE's bundled D7VK for an x86 game. This is separate from the
  app-local Windows script above; no Windows VM files are changed.

Recipes carry a reference to GE source commit
`88004a046c575af0b96131ff7b76dcd598da51ad` and exact option-set hashes. This is
implementation provenance, not a claim that the user's installed runtime was
built from that commit. The selected runtime's actual affected file hashes are
recorded independently. Unsupported options, changed DLLs and wrong D7VK
architecture are rejected. WineD3D cannot be combined with these Vulkan options.
Arguments are still passed without a shell. Environment changes affect only the
UMU child. Nothing claims that these recipes fix Icarus or FurMark.

## Targeted Pyroveil shader roundtrips on the Linux host

Use an installed GE runtime containing its Pyroveil layer and a **reviewed,
game-version-appropriate** bundle with `pyroveil.json` and optional `cache/`.
Add `--pyroveil '/home/me/shader-fix'` when creating the profile above. Pyroveil
can be used without a fullscreen recipe and can be combined with GE D7VK.

The Linux launcher currently accepts x86-64 ELF layer binaries. It validates
config version 2/type pyroveil, bounded shader matches,
GLSL-roundtrip actions, extension names and the optional relative cache path
`cache`. Arbitrary file replacement actions/paths are not supported. It checks
GE's layer manifests, the layer binary/entrypoint and all original shader-bundle
hashes. A missing layer, changed config/asset or escaping path blocks launch.
The reference is upstream Pyroveil; no shader hack is automatically selected
for an unidentified game or GPU.

Assets are staged inside the game's private prefix. Generated cache files stay
there; the original fix directory is not the runtime cache. Existing pinned
staged assets must remain unchanged. The profile records EXE/runtime/recipe/
shader identities in its prefix ownership marker. Changing these features needs
a **new prefix/profile**, including an option-free profile for comparison.
Do not repurpose an existing prefix or delete saves to reset a test. Back up
saves separately and retain the previous profile/prefix for returning to it.

This enables the Linux GE layer only. It does not register Pyroveil globally,
in the Windows VM, or in the Helios host renderer. Log/fixture tests do not prove
that a shader match occurred; use the selected game's Proton log and inspect
Pyroveil's matched-shader messages on the actual GPU. No hardware rendering or
performance improvement is certified by the launcher tests.

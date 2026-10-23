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

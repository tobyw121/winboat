# Live Helios resolution changes

Helios **22.22.291.0** adds eleven selectable 60 Hz display modes:
1024×768, 1280×720, 1280×800, 1366×768, 1440×900, 1600×900,
1920×1080, 1920×1200, 2560×1440, 2560×1600 and 3840×2160.
A valid custom boot/EDID preference is also retained by the driver.

Install the updated `resources/helios/HeliosSetup.exe` as Administrator inside
an existing Windows VM, then perform the installer-requested restart. Merely
replacing the Linux AppImage does not replace an already installed Windows KMD.
Subsequent **resolution changes need no VM reboot**:

1. Open Windows **Settings → System → Display**.
2. Select the Helios display if Windows shows separate VGA and Helios displays.
3. Change **Display resolution**, then confirm the Windows confirmation dialog.

Local Desktop handles the new scanout dimensions automatically. **Fit** keeps
the whole desktop visible; fixed zoom uses physical pixels and can crop a
larger desktop. Viewer zoom and the Windows rendering resolution are separate.

The WinBoat Configuration selector still sets the **startup preference for both
adapters** and intentionally restarts the VM when saved. It is not a live-mode
control. The virtual EDID remains stable when Windows changes modes.

In duplicated-display topology Windows negotiates a mode common to **both**
adapters. This driver change expands Helios' modes; it cannot force Microsoft's
Basic Display driver to advertise every same mode. If Windows refuses a mode in
clone topology, select a common mode or test Helios as the sole active display.
Do not disable VGA solely to run this test; the existing fallback policy can
retain it as an available recovery output.

## Validation

`cargo test --locked --manifest-path helios/upstream/kmd_logic/Cargo.toml`
runs the production mode-list, cofunctionality and extent policy with the
existing kernel logic suite. The full Windows build compiles the real WDK
VidPn callbacks and packages the driver. These gates do not prove GPU scanout.

`tests/helios-display-modes.cpp` builds as x86/x64 in the **Test Helios live
display modes** workflow. On an actual logged-in Windows desktop:

```powershell
.\helios-display-modes-x64.exe
.\helios-display-modes-x64.exe --cycle
```

The first invocation enumerates Helios only and fails if any preset is absent.
The second temporarily switches through the enumerated modes upward and
downward, waits 2.5 seconds at each, verifies the Windows current dimensions,
and restores the original mode on success or handled failure. It never uses
`CDS_UPDATEREGISTRY`. Session 0, a missing active Helios display, missing modes,
rejected changes and failed restoration are errors, not skips or passing tests.
A forced process kill cannot run the restoration guard; run it interactively.

Record Local Desktop's displayed dimensions and inspect the picture during
this cycle. Windows accepting the mode alone is not evidence of an intact
visible frame. No physical Helios GPU/Windows display is available in the
cloud runner; visible resize, clone topology, repeated GPU allocation changes
and graphics-device recovery need that acceptance run.

Microsoft's callback contracts:
[EnumVidPnCofuncModality](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmddi/nc-d3dkmddi-dxgkddi_enumvidpncofuncmodality),
[CommitVidPn](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmddi/nc-d3dkmddi-dxgkddi_commitvidpn),
[RecommendMonitorModes](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmddi/nc-d3dkmddi-dxgkddi_recommendmonitormodes).

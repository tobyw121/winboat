# Helios 22.22.302.0 — neuester separater Testinstaller

Vollständiger Windows-Release-Installer aus dem erfolgreichen
[CI-Build 39809847396](https://github.com/tobyw121/winboat/actions/runs/39809847396),
Quellcommit `ce72993ed2daa9d9c41b177e226fab79fa82efc1`.
Artefakt: `helios-windows-x64-22.22.302.0-Release-ge-candidate`.
Seit diesem Build wurden keine Treiber-, Engine- oder Paketquellen geändert.

Enthalten sind der .302-Treiberquellstand und die beiden ausdrücklich gewählten
GE-Korrekturen: DXVK behält die Swapchain bei vorübergehend fehlenden Bildern;
vkd3d-proton kann Präsentationswartezeiten beim Beenden unterbrechen.
`compatibility-patches.json` dokumentiert die exakten Patch- und Engine-Pins
sowie die angewendeten Änderungen. Sein Byte-Hash steht in `helios-build.json`.
Die EXE ist unverändert aus CI übernommen; im Build-Beleg wurden nur die
Zeilenenden für den Git-Checkout auf LF vereinheitlicht. `SHA256SUMS` prüft alle
drei Dateien. Die Patch-Belegdatei bleibt bytegenau erhalten.

## Testen

1. `git pull --ff-only origin work` auf Linux ausführen.
2. `HeliosSetup.exe` aus diesem Verzeichnis nach Windows übertragen, etwa über
   den freigegebenen Ordner oder VM integration → Clipboard & files.
3. Den vollständigen Installer in Windows als Administrator ausführen und den
   angeforderten Neustart durchführen. Keine einzelnen DLLs austauschen.
4. Mit `python3 scripts/helios/diagnose-graphics.py` den tatsächlich gebundenen
   und geladenen Treiberstand prüfen. Bei Anzeigeproblemen den vorhandenen
   [VGA-Rettungsweg](../../docs/helios-recovery.md) verwenden.

Der erfolgreiche Paketbuild bestätigt keine stabile Ausgabe auf der RTX 2070
und keine Behebung des bisher beobachteten Flackerns. Die GE-Patches betreffen
reguläre Engine-Swapchains; Helios hat zusätzlich eigene WDDM-/Scanout-Bridges.
Ein Windows-Installer aktualisiert weder den Linux-Host noch QEMU. Für den
aktuellen Hostpfad ist auch ein aktuelles Helios-Hostimage nötig.

Der Standard unter `resources/helios/` bleibt **22.22.291.0**. AppImage-/OEM-Builds
verwenden weiterhin diesen Standard; dieses Paket wird nicht automatisch in
bestehende VMs installiert. `.294` und `.296` bleiben separat erhalten.

Weitere Hinweise: [.302-Funktionen](../../docs/helios-302-management.md),
[GE-Integration](../../docs/proton-ge-integration.md).

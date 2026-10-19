# Helios 22.22.296.0 — separater Diagnoseinstaller

Vollständiges, unverändertes Windows-CI-Paket aus
[Build 39275019139](https://github.com/tobyw121/winboat/actions/runs/39275019139),
Quellcommit `a4b32c4a6292db048566a437abafa0fc6e43ad6a`.
Der Build-Beleg und `SHA256SUMS` gehören zu dieser EXE.

Das Paket enthält Gerätejournale, genaue Shader-HRESULTs und einen expliziten
D3D11-Profilvergleich. Es ist **keine bestätigte Behebung des Flackerns**.
Eine vollständige Installation und der angeforderte Windows-Neustart sind
nötig; einzelne DLLs verschiedener Versionen nicht kombinieren.

Der Standardinstaller unter `resources/helios/` bleibt auf 22.22.291.0.
AppImage- und OEM-Builds verwenden weiterhin dieses Standardpaket.
`.294` bleibt separat unter `resources/helios-22.22.294.0/` erhalten.
Die zusätzliche QEMU-Korrektur benötigt einen neu gebauten Host mit
Runtime-Kennung `glvnd-v5`; diese Windows-EXE aktualisiert den Host nicht.

Anleitung und Grenzen: [Diagnosebuild](../../docs/helios-diagnostic-build.md).
Rettungsweg bei unbenutzbarer Anzeige:
[Helios-Wiederherstellung](../../docs/helios-recovery.md).

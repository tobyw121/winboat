# Helios 22.22.294.0 — separater Testinstaller

`HeliosSetup.exe` ist das unveränderte, vollständig geprüfte Windows-CI-Paket
aus Build 39179167310 / Quellcommit `4c08daa4f6ad388281d8f4052518e6aec6d47c99`.
Der Build-Beleg und `SHA256SUMS` gehören zu diesem Installer.

Der Standardinstaller bleibt unter `resources/helios/` auf 22.22.291.0.
AppImage- und OEM-Builds verwenden weiterhin ausschließlich dieses Standardpaket.
Für einen ausdrücklichen .294-Test genau die EXE aus diesem Ordner verwenden.
Die neue Bereinigungs-GUI des nächsten .295-Installers ist in .294 nicht enthalten.

Vor dem Test Paket-Deinstallation und die separate DriverStore-Bereinigung im
VGA-Rettungsstart verwenden. Danach die normale Host-Konfiguration wiederherstellen
und .294 vollständig im Gast installieren. Ablauf und Rettungsweg:
[Helios-Wiederherstellung](../../docs/helios-recovery.md).

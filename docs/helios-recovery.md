# Helios sicher wiederherstellen

22.22.293.0 korrigiert den `classKey`-Installationsabbruch. Der Installer ist
geprüft eingebunden; ein erfolgreicher Paketbuild belegt weder einen stabilen
Windows-Desktop noch eine Behebung des beobachteten NVIDIA-/DMA-BUF-Flackerns.

## Rettungsstart vom Linux-Host, ohne Windows-Anmeldung

WinBoat schließen. Im aktualisierten Repository ausführen:

```bash
python3 scripts/helios/rescue-graphics.py --rescue-boot
```

Das startet ausschließlich die vorhandene Compose-VM neu. Ein privates Override
unter `~/.winboat/recovery/` verwendet dieselbe Windows-Festplatte, Firmware,
Ports, Netzwerkkonfiguration und dasselbe Image, aber nur Standard-VGA und
Browser Display. Das Helios-PCI-Gerät fehlt für diesen Start vollständig;
GTK, EGL, Vulkan, der Render-Node und der Gastdienst sind dafür nicht nötig.
Die Original-Compose-Dateien werden nicht verändert. Der Helfer prüft vor dem
Neustart, dass die konfigurierte Festplatte mit der aktuell eingebundenen
Windows-Festplatte übereinstimmt. Er verwendet weder `down -v` noch Löschbefehle.

Browser Display unter der bisherigen Adresse öffnen. In Windows Helios
deaktivieren oder mit seinem Installer deinstallieren und regulär neu starten.
WinBoat während dieses Rettungsbetriebs geschlossen lassen: Sein eigener
Container-Neustart kann wieder die ursprüngliche Konfiguration verwenden.

Die ursprüngliche Host-Konfiguration lässt sich ausdrücklich wiederherstellen:

```bash
python3 scripts/helios/rescue-graphics.py --restore-host
```

Auch dies startet die VM neu. Ein im Gast deaktiviertes Helios-Gerät bleibt
deaktiviert. Den Treiber erst nach Auswertung der Fehler und mit verfügbarem
Rettungsweg wieder aktivieren. Eine Windows-/Atlas-Neuinstallation ist unnötig.

## Grenzen der Prüfung

Der Rettungs-Displaypfad wird ohne GPU ausgeführt getestet; die tatsächliche
Compose-Zusammenführung wird gegen unveränderte Datenträger, Ports und Geräte
geprüft. Anmeldung, Treiberdeaktivierung und Wiederanlauf auf der betroffenen
RTX 2070 müssen im echten Gast bestätigt werden.

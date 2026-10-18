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

## Gezielte Deaktivierung über die Guest API

Mit Gast-Protokoll `helios-watchdog-v8` ist keine Windows-Anmeldung nötig:

```bash
python3 scripts/helios/rescue-graphics.py --disable-helios
```

Die API akzeptiert nur festgelegte Operationen, keine Befehle oder Geräte-IDs.
Sie prüft den bekannten VGA-Adapter, aktiviert ihn nötigenfalls zuerst und
deaktiviert erst danach das eindeutig identifizierte Helios-Gerät. Bei laufender
Installation, unbekannten Adaptern oder nicht gesundem VGA wird abgebrochen.
Ein nötiger Neustart wird gemeldet, aber nicht automatisch ausgeführt.

Ein dauerhafter HKLM-Sperrwert pausiert automatische Helios-Einrichtung und
Anzeigeumschaltung auch nach Dienst-/Windows-Neustarts. Nur eine ausdrückliche
Wiederaktivierung hebt ihn nach erfolgreicher PnP-Prüfung auf:

```bash
python3 scripts/helios/rescue-graphics.py --enable-helios
```

Das bestätigt die Geräteaktivierung, nicht die fehlerfreie Grafikdarstellung.
Falls der Dienst fehlt oder nicht antwortet, den Host-Rettungsstart verwenden.

## Hintergrundabfragen

Der Gastdienst liest den normalen PnP-Status über Windows SetupAPI und
Configuration Manager. Im gesunden Zustand startet der Fünf-Sekunden-Monitor
dafür keine PowerShell-/WMI-Prozesse mehr. Eine notwendige VGA-Wiederherstellung
bleibt eine feste, serialisierte PowerShell-Aktion mit vorhandener Wartezeit.
Unbekannte oder mehrdeutige Geräte werden nicht als funktionsfähig ausgegeben.
Die Abfrage des angemeldeten Desktops bleibt ein separater nativer Worker;
die tatsächliche CPU-Entlastung muss im betroffenen Gast gemessen werden.

## Abschluss der Einrichtung

Ein vorhandener `install-state.json` ist kein Erfolgsnachweis: Er wird bereits
während der Installation geschrieben. Vor dem bestätigten Abschluss nach dem
Neustart führt der WinBoat-Gastdienst den vollständigen mitinstallierten
`Verify-Helios.ps1` erneut aus. Fehlende Laufzeitdateien oder API-Registrierungen
verhindern dadurch die Abschlussmeldung. Fehlgeschlagene Einrichtungen werden
bei einem Dienstneustart nicht automatisch erneut gestartet; Wiederholungen
bleiben ausdrückliche Aktionen. Atlas behält seinen eigenen Abschlussbeleg und
den bereits vorhandenen Neustart vor der ersten Helios-Installation.

Die Paketprüfung läuft ohne GUI-Smoke-Tests als SYSTEM. Sie beweist Dateien,
Registrierungen und Gerätezustand, aber keine sichtbaren Frames. Vulkan-WSI,
D3D-Ausgabe, Anmeldung und Wiederherstellung sind zusätzliche Hardwareprüfungen.

## Grenzen der Prüfung

Der Rettungs-Displaypfad wird ohne GPU ausgeführt getestet; die tatsächliche
Compose-Zusammenführung wird gegen unveränderte Datenträger, Ports und Geräte
geprüft. Anmeldung, Treiberdeaktivierung und Wiederanlauf auf der betroffenen
RTX 2070 müssen im echten Gast bestätigt werden.

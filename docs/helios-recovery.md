# Helios sicher wiederherstellen

Aktuell ist wieder das unveränderte Paket 22.22.291.0 aus `f0a662f` gebündelt.
Die Rücknahme ändert keine bereits installierten Windows-Treiber automatisch.
Die bestehenden Rettungsfunktionen bleiben verfügbar.

Der neuere Entwicklungsstand 22.22.293.0 korrigiert den `classKey`-Installationsabbruch;
22.22.294.0 ergänzt die korrigierte Auswahl des
umbenannten Vulkan-Geräts in der D3D11-Brücke. Der alte Gerätefilter konnte
das eigene Gerät ausschließen. Die NVIDIA-Hardwareabnahme und der getrennte
DMA-BUF-Größenkonflikt sind weiterhin offen; der Rettungsweg bleibt erforderlich.

## Rettungsstart vom Linux-Host, ohne Windows-Anmeldung

WinBoat schließen. Im aktualisierten Repository ausführen:

```bash
python3 scripts/helios/rescue-graphics.py --rescue-boot
```

Das startet ausschließlich die vorhandene Compose-VM neu. Ein privates Override
unter `~/.winboat/recovery/` verwendet dieselbe Windows-Festplatte, Firmware,
Ports, Netzwerkkonfiguration und dasselbe Image nach dessen Digest, aber nur Standard-VGA und
Browser Display. Das Helios-PCI-Gerät fehlt für diesen Start vollständig;
GTK, EGL, Vulkan, der Render-Node und der Gastdienst sind dafür nicht nötig.
Die Original-Compose-Dateien werden nicht verändert. Der Helfer prüft vor dem
Neustart, dass die konfigurierte Festplatte mit der aktuell eingebundenen
Windows-Festplatte übereinstimmt. Er verwendet weder `down -v` noch Löschbefehle.

Browser Display unter der bisherigen Adresse öffnen. In Windows Helios mit
seinem Installer deinstallieren und regulär neu starten. Das im Rettungsstart
fehlende Gerät kann im Geräte-Manager nur unter ausgeblendeten Geräten sichtbar
sein. Ein API-Sperrwert allein deaktiviert kein gerade abwesendes PCI-Gerät.
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

Mit Gast-Protokoll `helios-watchdog-v9` ist keine Windows-Anmeldung nötig:

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

Ab `v9` deaktiviert der Rettungsaufruf außerdem die bekannten untätigen
Installationsaufgaben, einschließlich `HeliosGraphicsProvisioning` des offiziellen
Installers. Dieser liest WinBoats HKLM-Sperrwert selbst nicht. Laufende
Installationen werden weiterhin nicht unterbrochen. Die Geräte-Reaktivierung
startet diese alten Aufgaben nicht automatisch; eine nötige Paket-Reparatur
bleibt eine separate ausdrückliche Aktion.

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

Der zusätzliche Live-QEMU-Test startet das lokal gebaute Image mit TCG, ohne
Windows-Festplatte, GPU, KVM und Netzwerk. Er prüft über QMP, dass Standard-VGA
vorhanden und das Helios-PCI-Gerät abwesend ist. VNC muss dabei initialisieren:

```bash
python3 tests/helios-rescue-qemu.py --image winboat/helios:d82ce565ac79
```

Dieser Test wurde mit dem vorhandenen gebauten Image erfolgreich ausgeführt;
er bestätigt keinen Windows-Anmelde- oder GPU-Rendering-Erfolg.

## Grafikbericht und Hardware-Abnahme

```bash
python3 scripts/helios/diagnose-graphics.py
```

Der Bericht enthält den aktiven Container/Image-Identifier, den lokalen
Installer-Beleg, Gast-/Treiberzustände und strukturierte Transportfehler aus
den letzten 300 Container-Logzeilen. Aus den Logs werden ausschließlich feste
numerische Fehlerfelder übernommen, keine beliebigen Meldungen oder Zugangsdaten.
Auch Fehlerantworten der Guest API bleiben erhalten. Die Terminal-Ausgabe zeigt
den vollständigen Bericht; die private JSON-Datei bleibt die Grundlage zum Teilen.

`driver.rescueHold` liest die dauerhafte Sperre unmittelbar während der Diagnose
(bei nicht möglicher Abfrage `null`). Der separat erhobene `adapters`-Eintrag kann
noch aus dem vorherigen Monitorlauf stammen; `sampleAgeMs` zeigt sein Alter.
`application.umdLogs` wertet die letzten acht Helios-Prozesslogs mit maximal
64 KiB pro Datei aus. Es werden nur feste Start-/Fehlersignale und API-Fehlercodes
ausgegeben, keine rohen Logzeilen. Eine im Ausschnitt vorhandene letzte
`UMD module:`-Grenze trennt ältere Treibergenerationen ab. Fehlt diese Grenze,
bleibt die Zuordnung ausdrücklich unsicher; auch PIDs können wiederverwendet sein.
Die Auswertung funktioniert bei deaktiviertem Helios und startet keinen Grafiktest.

Ein DMA-BUF-Größenkonflikt ist weiterhin ein abgewiesener Import. Die Änderung
interpretiert einen unbekannten Modifier nicht als LINEAR und erfindet keine
passende Speichergröße. Vor einer Transportkorrektur muss auf der betroffenen
GPU geklärt werden, welcher Produzent welchen Buffer tatsächlich exportiert.

Folgende Prüfungen sind getrennte Abnahmeschritte auf einem entbehrlichen
Windows-Testgast mit gesicherter Festplatte; sie werden nicht automatisch in
einer produktiven Benutzer-VM ausgeführt:

| Prüfung | Erfolgskriterium |
| --- | --- |
| Erstinstallation nach Atlas | AME abgeschlossen, anschließend Helios-Paketprüfung und bestätigter Neustart |
| Upgrade/Reparatur | Originale Registry-Restorepunkte erhalten, keine fremden Werte gelöscht |
| Abbruch während Einrichtung | Kein falscher Abschluss, keine automatische endlose Wiederholung |
| Anmeldung/DWM | Stabile VGA-Anmeldung, Helios-Ausgabe sichtbar, keine neuen DWM-Abstürze |
| Grafik-APIs | `Verify-Helios.ps1 -RunSmokeTests` aus einer angemeldeten Windows-Konsole, einschließlich x64/x86 und Vulkan-WSI |
| Deaktivierung/Neustart | VGA bleibt bedienbar, automatische Einrichtung respektiert den Sperrzustand |
| Gastdienst ausgefallen | Host-Rettungsstart bootet dieselbe Windows-Festplatte ohne Helios-Gerät |
| Rückkehr | Ursprüngliche Host-Konfiguration wiederhergestellt, Reaktivierung nur ausdrücklich |

Die Windows-CI führt die kontrollierten Zustands-/Registry-Tests unter
PowerShell 5.1 und 7 aus, testet die echte native PnP-Abfrage und kompiliert
den Gastdienst. WARP-Tests bleiben Softwarekontrollen. Diese Prüfungen sind
kein Ersatz für die obige Hardware-Abnahme oder FurMark-/Icarus-Spieltests.

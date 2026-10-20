# Helios 22.22.298.0: Änderungen und Abnahme

`.291` bleibt das unveränderte Standardpaket. `.298` ist ein separat gebauter
Diagnose-/Korrekturkandidat; erfolgreiches Kompilieren ersetzt keine Abnahme auf
der Windows-/NVIDIA-VM. Die Quellen behaupten keine Behebung des Flackerns.

## D3D11 und gemeinsame Ressourcen

Der neue `helios-format-contract.exe` wählt genau einen Helios-Adapter; es gibt
keinen automatischen WARP-Fallback. Er prüft sieben Farb-/Tiefenformate mit
1/2/4/8 Samples. Vom Backend tatsächlich angebotene Kombinationen müssen sich
als Textur und Render-Target-/Depth-Stencil-View erstellen lassen. Unterstützte
Shared-Resource-Funktionen werden durch Öffnen derselben Ressource, Clear,
Staging-Copy und exakten Pixelvergleich geprüft. Der Shared-Test bleibt auf
**einem Gerät**; ein Prozess-/Gerätewechsel ist damit noch nicht abgedeckt.

`--warp` ist nur ein ausdrücklicher CI-Kontrolllauf. Die bestehenden gemeldeten
Format-/Feature-Caps werden mit diesem Stand nicht pauschal geändert. Erst ein
fehlgeschlagener nativer Vertragstest auf Helios liefert dafür konkrete Evidenz.

Das GitHub-Artefakt `helios-validation-x64` enthält jetzt drei EXEs und die
gehashte `tools.json`. Im Helios Control das entpackte Verzeichnis und den
unabhängig geprüften Manifest-Hash angeben, dann die Grafiktests starten. Die
Abnahme ergänzt `D3D11 format contracts`. Alte geprüfte Zwei-EXE-Pakete bleiben
nutzbar, enthalten diesen neuen Test aber nicht. Das gespeicherte Manifest muss
jede ausführbare Datei abdecken; zusätzliche Dateien im Zielverzeichnis werden
nicht automatisch ausgeführt.

Neue Ressourcen werden bei bereits verlorenem DXVK-Gerät früh abgewiesen. Der
ursprüngliche Fehler wird auf den bestehenden legalen DDI-Fehler abgebildet.
Windows/D3D behält die Verantwortung für eine Geräte-Neuerstellung; die UMD
versucht keinen verdeckten Reset und gibt keine noch genutzten Ressourcen frei.
Subresource-Kardinalitäten werden vor Multiplikation/Traversal begrenzt:
maximal 15 Mip-Level, 2048 Array-Elemente und 30720 Open-Allokationen. Das ist eine
Schutzgrenze für D3D11-Strukturen, **kein globales VRAM-Limit**.

## Speicherbudgets

Der Vertragstest liest, soweit angeboten, `IDXGIAdapter3::QueryVideoMemoryInfo`
für lokale und nichtlokale Segmente. `graphics/validation` enthält bei dem Test
`memoryBudget` mit Budget, Nutzung und Reservierungswerten. Diese Werte gehören
zum Testprozess im Gast; sie sind keine direkte Messung des gesamten Host-VRAMs.
Fehlende DXGI-Unterstützung ergibt keine erfundenen Zahlen. Bestehende Docker-
und NVIDIA-Sensoren im Langzeittest ergänzen die Beobachtung auf dem Host.

## Begrenzte automatische Isolation

Im Helios Control gibt es einen ausdrücklich aktivierbaren Schutzschalter für
automatische Helios-Isolation. Er ist standardmäßig aus. Voraussetzungen:

- Drei bestätigte PnP-Zustände `failed` im selben verwalteten Konsolensitzungs-Kontext,
  mit mindestens fünf Sekunden Abstand und ohne Lücke über 30 Sekunden.
- VGA läuft, hat einen aktiven Desktop und bleibt primär.
- Keine fehlgeschlagene Desktop-Abfrage, kein aktiver Rettungshalt.

Dann wird höchstens einmal pro Service-Lauf der bestehende serialisierte
Helios-Disable-Pfad mit `-PreserveVga` aufgerufen. Er darf VGA nicht aktivieren oder
umkonfigurieren, startet Windows nicht neu und deinstalliert keinen Treiber.
Der persistente Rettungshalt verhindert späteres automatisches Wiederaktivieren.
Bei konkurrierender Rettung/Installation oder unbekannten Zuständen wird keine
Änderung erzwungen. PnP-gesundes schwarzes Bild, Viewer-Ausfall oder eine Serie von
DWM-Abstürzen allein lösen diesen Schalter **nicht** aus; dafür bleiben Diagnose
und explizite Rettung erforderlich.

Die Regeln werden nativ im bestehenden Monitor ausgewertet. Nur die tatsächliche
Rettungsoperation startet einmal PowerShell; es entstehen keine zusätzlichen
periodischen PowerShell-Abfragen.

## DMA-BUF und Software-Kopien

Der Viewer akzeptiert bei den unterstützten gepackten RGB-Formaten genau eine
Plane. Bei explizitem LINEAR-Modifier werden Mindeststride und, falls vom Exporter
angegeben, die FD-Länge vor dem EGL-Import geprüft. Ein INVALID-Modifier wird
weiterhin nicht als LINEAR interpretiert. Bei unbekannter FD-Länge bleibt der
EGL-Import für die abschließende Layout-Prüfung zuständig.

Bei GLES-Softwareframes ersetzt eine Ein-Pass-BGRA-Konvertierung die bisherige
Vollkopie mit anschließendem Kanaltausch; ungenutztes Zeilenpadding wird nicht
kopiert. Nur für diesen CPU-Pfad gibt es optional einen wiederverwendbaren,
durch die vorhandene 128-MiB-Framegrenze beschränkten Scratch-Puffer:

```bash
HELIOS_REUSE_SOFTWARE_BUFFER=1 ./dist/winboat-0.8.7-x86_64.AppImage
```

Ohne diese Variable wird pro Konvertierung ein temporärer Puffer verwendet. Die
DMA-BUF-GPU-Kopie und ihre Completion-/ACK-Regeln werden nicht umgangen. Nach
Wiederaufnahme fordert der bestehende Viewer weiterhin einen vollständigen
Scanout an; unvollständige Software-Deltas werden nicht auf eine alte Basis
angewendet.

Reproduzierbarer CPU-Vergleich auf dem eigenen Host:

```bash
cc -std=c11 -O2 scripts/helios/benchmark-software-copy.c -o /tmp/helios-copy-bench
/tmp/helios-copy-bench
```

Lokaler Cloud-Kontrolllauf, 1920×1080 mit Padding, A/B/A/B: bisheriger CPU-Pfad
1,117 / 1,093 ms, Ein-Pass-Pfad 0,505 / 0,741 ms pro Bild. Das misst nur die
Konvertierung auf dieser CPU, keine GPU-Leistung, Eingabelatenz oder Spiel-FPS.
Real-GL-/GLES-Pixeltests prüfen beide Pufferstrategien einschließlich ungerader
Zeilen, UHD-Größen und Wiederverbindung.

## QEMU-Importcache und CPU/I/O-Vergleiche

Das neue Host-Image meldet `glvnd-v8`. WinBoat verlangt damit einen neu gebauten
Host-Stand; ein vorhandenes `glvnd-v7`-Image wird nicht als aktuell akzeptiert.
Der neue QEMU-Patch begrenzt optional die Zahl aufbewahrter Vulkan-Readback-Imports:

```bash
python3 scripts/helios/performance-profile.py readback-small-cache --output small-cache.json
```

Dieses Compose-Vergleichsprofil setzt `HELIOS_READBACK_CACHE_ENTRIES=2`. Zulässig
sind 1/2/4/8, Standard bleibt 8. Der neue Import wird vor dem bisherigen
vollständigen Teardown erstellt: daher können kurzzeitig ein zusätzlicher Import
und dessen Ressourcen existieren. Das ist eine Zahlengrenze, kein Byte-Budget.
Weniger Imports können Speicher sparen, aber Rotation und Import-Neuerstellung
verteuern. Freigaben warten unverändert auf die bestehende Vulkan-Completion;
das Profil erzwingt niemals eine frühzeitige Freigabe.

CPU-Affinität, VirtIO-Multiqueue, I/O-Thread und dessen Polling bleiben die
bestehenden einzeln schaltbaren Vergleichsoptionen. Für gleiches Spiel, gleiche
Auflösung und gleiche Szene A/B/A/B messen. Container-CPU, GPU-Sensoren,
PresentMon-Perzentile und getrennte Capture-/Viewer-Zeiten gemeinsam auswerten.
Es werden weder CPU-Kerne blind reserviert noch QEMU-/Guest-Thread-Prioritäten
pauschal erhöht. Profile und Rückweg stehen in [Deep Diagnostics](helios-deep-diagnostics.md).

## Build und Grenzen

Guest Service: `helios-watchdog-v15`. Der Windows-Treiberbau verwendet die einzige
Versionsquelle `kmd_render/driver-version.env` und erzeugt `.298`; die
checksum-geprüften `.291`-/`.294`-/`.296`-Ressourcen bleiben erhalten.
Der Push startet `Build WinBoat Helios Windows installer` und den separaten
Validierungswerkzeug-Build. Das Host-Image und die App müssen ebenfalls neu gebaut
werden, damit die QEMU-/Viewer-Änderungen aktiv werden.

Automatische Kontrollen decken WARP-Verträge, Go-Containment-Regeln, echte
GL-/GLES-Pixel und D-Bus-Lebenszyklen, Puffergrenzen sowie die auf gepinnten Quellen
angewandten QEMU-Patches ab. Vollständige NVIDIA-DMA-BUF-Importe, Gast-Standby,
Treiber-Neustart und Spielelast bleiben Hardware-Abnahme. Ein automatischer
VGA-Primärwechsel, globales Entfernen von Vulkan oder Anheben von TDR-Zeitlimits
gehört nicht zu diesem Kandidaten.

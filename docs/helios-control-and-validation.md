# Helios Control, Treiberabnahme und Versionsvergleich

Live-Dashboard, Diagnoseknopf, geführten Vergleich, Anwendungsprofile und
Wiederaufnahmetests beschreibt [helios-investigation.md](helios-investigation.md).

Die neue Windows-Steuerung verbindet die vorhandenen Diagnosefunktionen mit
einem ausdrücklichen Update- und Abnahmeweg. **22.22.291.0 bleibt Standard.**
Die Installer-EXE-Dateien und der Kernel-Treibercode wurden dabei nicht geändert.
Die Funktionen sind kein Nachweis, dass der Flackerfehler neuerer Treiber behoben ist.

## Installation und Windows-Steuerung

Auf dem Linux-Host aktualisieren und WinBoat vollständig bauen:

```bash
git pull --ff-only origin work
./scripts/build-helios.sh
```

Die neue AppImage verwenden und den Gastdienst aktualisieren. Das neue
Grafikprotokoll lautet `helios-watchdog-v15`:

```bash
python3 scripts/atlas/diagnose-vm.py --update-guest
```

Bei einer neuen Gastinstallation und beim Gastdienst-Update wird im Windows-
Startmenü unter **WinBoat → Helios Control** eine Verknüpfung mit
Administratoranforderung angelegt. Alternativ im angemeldeten Windows-Desktop
die Datei `C:\Program Files\WinBoat\scripts\Show-HeliosControlPanel.ps1` mit
64-Bit-Windows-PowerShell als Administrator starten. Der Gastdienst startet
keine grafische Oberfläche in Sitzung 0.

Die Steuerung bietet:

- Treiberstatus, API-Registrierungen, geladene Grafikmodule und Teststatus.
- Dreistufige Einstellungen für `UmdD3D12`, `UmdCommandLists`, `UmdFreeThreaded`,
  `UmdAsyncPresentStream` und `UmdPresentBatchFold`: Treibervorgabe, aus, ein.
- Sicherung der ursprünglichen Werte vor dem ersten Speichern und deren
  Wiederherstellung. Andere Registry-Werte bleiben erhalten.
- Grafiktests, Export der Ergebnisse, explizite Update-Abnahme und VGA-Isolation.
- Hinterlegen eines geprüften stabilen Installers, Update und vorbereiteten
  DriverStore-Rollback.

Diese Treiberschalter werden pro Prozess gelesen. Nach Änderungen Windows
ausdrücklich neu starten. Ein automatischer Neustart wird nicht ausgelöst.
Vulkan/Mesa Venus ist auch Grundlage anderer Helios-Grafikpfade; das Entfernen
seiner globalen Registrierung wäre kein unabhängiges Abschalten von Vulkan.
Deshalb bietet die Steuerung diesen Schalter nicht an.

## Grafiktests und Grenzen der Abnahme

In Helios Control einen Laufnamen wie `A1` eingeben und die Grafiktests starten.
Sie laufen in einem separaten interaktiven PowerShell-Fenster. Ergebnisse werden
unter `C:\ProgramData\WinBoat\GraphicsValidation\acceptance.json` atomar gespeichert.
Die Verzeichnisse erlauben nur Administratoren und SYSTEM Zugriff.

Der Grundlauf prüft die installierten und anhand ihrer aufgezeichneten Hashes
verifizierten Probes für D3D11, Vulkan-Enumeration, Vulkan-Features, Vulkan-WSI
und OpenGL. Fehlende Programme, Zeitüberschreitungen und fehlerhafte Rückgabecodes
werden einzeln ausgewiesen. Gleichzeitig werden Paketversion, Manifest-Hash und
Windows-Bootzeit vor und nach dem Lauf verglichen sowie vorhandene DWM-Abstürze
und Display-Resets während des Laufs erfasst. Eine nicht verfügbare Ereignisabfrage
erlaubt keine automatische Erfolgsbehauptung.

Vor den Grafikprobes läuft der vollständige installierte Paketverifier für
Dateihashes und API-Registrierungen. Schlägt diese Prüfung fehl, werden die
Grafikprobes als `not-run` ausgewiesen und nicht gestartet.

Für stärkere Pixel- und MSAA-Prüfungen erzeugt der Workflow
**Build Helios graphics validation tools** das Artefakt `helios-validation-x64`:

- `helios-msaa-present.exe`: D3D11 mit 1x UNORM sowie 4x MSAA/sRGB, Pixel-Orakel,
  Präsentation und automatischen Änderungen der Testfenstergröße.
- `helios-opengl-pixels.exe`: verifiziertes Helios-WGL-Modul, rote/grüne
  Pixel-Readbacks über zwei ungerade Flächengrößen; kein GDI-Generic-Fallback.
- `tools.json` mit den EXE-Hashes und Quellcommit sowie dessen SHA-256-Beleg.

Das Artefakt aus dem vertrauenswürdigen Workflow beziehen und den Manifest-Hash
unabhängig anhand dieses Laufs prüfen. In der Steuerung optional Werkzeugordner
und `tools.json`-SHA-256 eintragen. Die Dateien werden vor und nach dem Kopieren
in einen geschützten Ordner geprüft. Für alle Vergleichsarme dasselbe Artefakt
verwenden. Alternativ:

```powershell
& 'C:\Program Files\WinBoat\scripts\Test-HeliosAcceptance.ps1' -Label A1 -ToolsPath C:\HeliosValidation -ToolsManifestSha256 MANIFEST_SHA256
```

Der CI-Selbsttest des MSAA-Pixel-Orakels ist ein CPU-Test. Erst der Lauf innerhalb
der Windows-VM prüft den Treiber. Die Probes bestätigen weiterhin nicht allein,
dass der Host-Viewer jedes Bild korrekt angezeigt hat. Farben, Fensterwechsel,
Anzeigeauflösungswechsel und Wiederherstellung müssen separat beobachtet werden.
Ein echter TDR/Geräteverlust wird nicht automatisch erzwungen. Die Checkbox zur
stabilen Ausgabe ist eine ausdrückliche menschliche Beobachtung, kein zusätzlicher
automatischer Test.

## Abgesicherter Updateweg

Dieser Weg ist für ausdrücklich gestartete Treiberupdates vorgesehen. Ein direkt
gestarteter historischer Installer und die bestehende OEM-Erstinstallation werden
dadurch nicht nachträglich transaktional.

1. Die funktionierende `.291` testen und deren Ergebnis ansehen. Installer und
   `helios-build.json` aus dem geprüften Repository-Bundle bereithalten.
2. In der Steuerung den Bundle-Ordner und die unabhängig geprüfte EXE-SHA-256
   eintragen. Nach den sichtbaren Prüfungen **Aktuelle Version als stabil
   hinterlegen** wählen. Version, Manifest und aufgezeichnete Treiberoptionen
   müssen zur aktuellen Installation passen. Änderungen an den Optionen machen
   eine ältere Testabnahme ungültig.
3. Für das Update den Kandidatenordner und dessen geprüften Hash angeben.
   **Geprüftes Treiberupdate installieren** hält die letzte stabile Version vor,
   pausiert bekannte OEM-Installationsaufgaben und speichert eine dauerhafte
   Transaktion. Ein ungeprüftes Paket wird nicht ausgeführt.
4. Windows selbst neu starten. Die geschützte Aufgabe `WinBoatHeliosValidation`
   prüft beim Start die gebundene Paketidentität. Derselbe Boot kann ein Update
   nicht bestätigen. Bei einer Fehlaktivierung wird, soweit gesundes VGA verfügbar
   ist, Helios isoliert; es wird kein aktiver Treiber gewaltsam gelöscht.
5. Nach dem Neustart erneut testen und beobachten. Erst **Update nach Neustart
   bestätigen** akzeptiert den Kandidaten. Erforderlich ist ein erfolgreicher
   Test des aktuellen Pakets und Boots, höchstens 30 Minuten alt, plus ausdrückliche
   sichtbare Abnahme. Bis dahin lautet der Zustand `awaiting-acceptance`.

Ein Abbruch hinterlässt einen sichtbaren Zustand statt eines falschen
`finished`. Es gibt keine eigenständige Folge erzwungener Neustarts und keine
periodische automatische Neuinstallation.

### Rückweg bei einem fehlerhaften Kandidaten

Ist Helios noch aktiv, zunächst die vorhandene VGA-Rettung verwenden. Für eine
vollständige DriverStore-Bereinigung muss Helios **auf QEMU-Ebene abgetrennt**
sein; bloßes Deaktivieren im Geräte-Manager genügt nicht:

```bash
python3 scripts/helios/rescue-graphics.py --rescue-boot
```

Im VGA-Rettungsstart in der Steuerung **Rollback vorbereiten** wählen. Die
bekannte Bereinigung prüft alle Pakete vorab, exportiert sie und entfernt
ausschließlich die verifizierten Helios-Display-Pakete. Unbekannte, fremde oder
bootkritische Treiber werden abgewiesen. Gemeinsame Loader und andere Treiber
werden nicht breit gelöscht.

Bei `rollback-cleanup-restart` zuerst im VGA-Rettungsmodus neu starten und die
Bereinigung erneut bestätigen. Bei `rollback-staged` mit dem bestehenden
Rettungswerkzeug die ursprüngliche Host-Konfiguration wiederherstellen; siehe
[helios-recovery.md](helios-recovery.md). Sobald die Helios-Hardware beim normalen
Start wieder vorhanden ist, versucht die Transaktionsaufgabe den hinterlegten,
erneut hashgeprüften stabilen Installer genau einmal. Danach sind wieder ein
ausdrücklicher Neustart und die Abnahme erforderlich. Fehler bleiben sichtbar;
es gibt keine unendliche Reparaturschleife.

Dabei werden auch die gespeicherten Treiberoptionen einschließlich geerbter
Vorgaben wiederhergestellt. Andere Registry-Werte bleiben erhalten.

Die physischen Rettungsumschaltungen erfolgen bewusst vom Host aus. Eine
Windows-Aufgabe kann keine sichere QEMU-Hardwareabtrennung vortäuschen.

Die Wiederherstellung der ursprünglichen Host-Konfiguration erfolgt mit
`python3 scripts/helios/rescue-graphics.py --restore-host` bei geschlossener
WinBoat-App. Windows-Volumes und ursprüngliches Compose-Projekt erhalten.

## Guest API und korrelierte Berichte

`GET /graphics/validation` liefert die gespeicherten Abnahme-, Transaktions- und
Baseline-Daten. Der Aufruf startet keine Programme und verändert keine Treiber.
Fehlende, ungültige oder zu große Dateien bleiben als solche erkennbar.

```bash
python3 scripts/helios/diagnose-graphics.py --samples 6 --interval 5
```

Der Bericht enthält zusätzlich eine `captureId`, Host-Zeiten der API-Abfragen,
Docker-Zeitstempel und einen Abschnitt `correlation`. Die Uhren werden nicht
als identisch angenommen: Die geschätzte Gast-minus-Host-Abweichung wird als
Intervall ausgewiesen. DWM-/Anwendungsabstürze, UMD-Dateisignale und numerische
Host-Transportereignisse bleiben getrennt erkennbar. Dateizeit und PID allein
beweisen keine Ursache; Rohlogs und beliebige Prozessargumente werden nicht
in die Zusammenfassung kopiert.

## `.291` gegen neuere Treiber vergleichen

Gleiche VM, Host-Laufzeit, Auflösung, Einstellungen und Prüfprogramme verwenden.
**A1/B1/A2/B2** durchführen, jeweils nach dem nötigen Neustart und derselben
Aufwärmzeit. Nach jedem Lauf das Ergebnis exportieren; die gespeicherte aktuelle
Abnahme wird beim nächsten Lauf ersetzt. Die Treiberwechsel bleiben ausdrücklich
und verwenden den oben beschriebenen Update-/Rettungsweg.

```bash
python3 scripts/helios/compare-graphics.py A1.json B1.json A2.json B2.json
```

Unterschiedliche Probe-Hashes werden mit `sameProbeBytes=false` ausgewiesen;
damit ist ein Unterschied nicht allein dem Treiber zuzuordnen. Die Treiberversion
muss innerhalb jedes Arms gleich bleiben. Der Vergleich installiert und
aktiviert nichts und erklärt keinen Kandidaten automatisch zum Standard.

## Performance mit Framezeiten

Die bestehenden Profile bleiben Vergleichskandidaten. Für denselben
reproduzierbaren Abschnitt einen identischen `--comparison-key` angeben:

```bash
python3 scripts/helios/measure-performance.py --label A1 --comparison-key scene1-1080p --output A1.json
```

Optional eine bereits aufgezeichnete PresentMon-CSV mit den Spalten
`Application`, `ProcessID`, `MsBetweenPresents` hinzufügen:

```bash
python3 scripts/helios/measure-performance.py --label A1 --comparison-key scene1-1080p --frame-csv frames.csv --frame-application Icarus.exe --output A1.json
```

Die Auswertung verlangt genau einen passenden Prozess und berichtet Median,
95. und 99. Perzentil in Millisekunden. Ungültige Werte werden gezählt; mehrere
PIDs und unbrauchbare Daten werden abgewiesen. Present-Intervalle sind weder
Eingabelatenz noch ein Nachweis tatsächlich angezeigter Frames. Die CSV wird
nicht automatisch aufgezeichnet. A/B/A/B-Vergleiche ergeben gepaarte CPU-Deltas;
es werden dadurch keine Performance-Schalter automatisch umgestellt.

## Validierung

Lokale Prüfungen umfassen echte Kindprozesse mit Fehlercode und Timeout,
Zustandsübergänge, Rückweisungen alter/falscher Abnahmen, Registry-Fixtures,
Zeitkorrelation, CSV-/Versionsvergleiche sowie Go-Race-Tests und Windows-Gastbuild.
Windows CI prüft zusätzlich den nativen Formularaufbau, reale geschützte
Dateiverzeichnisse und den Build der zusätzlichen Grafikprobes. Diese Tests
installieren auf den CI-Rechnern keinen Helios-Treiber.

Ein vollständiger Windows-/RTX-2070-Dauertest und die sichtbare Abnahme bleiben
noch erforderlich. Deshalb bleibt `.291` unverändert die Vorgabe.

Erweiterte Messwerkzeuge und das neue QEMU-I/O-Profil: [Helios Deep Diagnostics](helios-deep-diagnostics.md).

Aktueller Kandidat: [Helios .298, Vertragstests und QEMU-Speicherprofil](helios-298-validation.md).


Host/QEMU/guest additions, `.299` child-only capability comparisons, shared-process
validation and lifecycle gates: [cross-layer contracts](helios-299-cross-layer.md).

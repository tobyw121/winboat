# Helios 22.22.296.0: Diagnose der Geräteinitialisierung

Dieser Entwicklungsbuild erweitert die Fehlerdiagnose auf Basis des neueren
Treiberstands. Er ist **keine bestätigte Behebung des Flackerns**. Das gebündelte
Standardpaket bleibt .291. Ein erfolgreicher CI-Build bestätigt noch kein
sichtbares Bild auf NVIDIA-Hardware.

## Neue Treiberinformationen

Jedes D3D11-Gerät besitzt ein eigenes Journal mit Gerätekennung, Zeitkennung,
Reihenfolge und höchstens 96 Einträgen. Beim normalen Abbau und bei einem
Initialisierungs-Rollback wird es in `C:\ProgramData\Helios\umd-<PID>.log`
ausgegeben. Dafür muss `UmdTrace` nicht eingeschaltet werden.

Aufgezeichnet werden:

- Erstellungsinterface, Version, Flags und Rückkehr aus dem UMD-Callback;
- Formatkennung mit rohen Backend- und endgültigen DDI-Unterstützungsbits;
- Sample-Anzahl, Flags, Qualitätsstufen, Backend-HRESULT und Feature-Profil;
- verweigerte oder durch das Diagnoseprofil eingeschränkte MSAA-Abfragen;
- Ressourcen-, View- und Shader-Erstellung sowie Runtime-Fehlercallbacks;
- der erste Present-Eintritt, unabhängig von prozessweiten Zählern.

Ein separat gespeicherter erster Widerspruch bleibt auch erhalten, wenn spätere
Aufrufe den Ringpuffer überschreiben: FL11, als MSAA-fähig gemeldetes Format,
4 Samples, keine Tiled-Resource-Flags, aber null Qualitätsstufen. Dieser Hinweis
ist eine Capability-Inkonsistenz, kein Nachweis, dass genau diese Abfrage den
äußeren Windows-Aufruf abgelehnt hat. Ein Present-Eintritt beweist ebenfalls
noch keine erfolgreiche Ausgabe.

Die Shader-Brücke gibt tatsächliche Backend-HRESULTs bis zum Runtime-Callback
weiter. Ein ungültiger Shader, Device-Lost oder ein anderer Backendfehler wird
nicht mehr pauschal als Speichermangel gemeldet. Wo eine C++-Exception keinen
Backend-HRESULT liefert, bleibt ein ausdrücklich generischer Fehler erhalten.

## Äußeren Windows-Aufruf prüfen

Nach vollständiger Installation des Diagnosepakets und dem angeforderten
Windows-Neustart kann in einer administrativen **64-Bit-PowerShell der
angemeldeten Windows-Konsole** ausgeführt werden:

```powershell
& "$env:ProgramData\Helios\Test-HeliosDeviceProfiles.ps1"
```

Der Helfer verlangt einen aktiven Helios-Adapter und eine zum Paket passende
gebundene Treiberversion. Er prüft die Test-EXE gegen das gespeicherte
Paketmanifest und verweigert parallele Installer-/Wartungsaktionen. Er aktiviert
keinen Adapter, ändert die Anzeigeanordnung nicht und startet weder DWM noch
Windows neu. Bei unbenutzbarer Konsole genügt zunächst das neue Gerätejournal;
die Diagnose ist kein Grund, einen deaktivierten Treiber wiederholt zu aktivieren.

Vier frische Testprozesse vergleichen die bestehenden Profile in der Reihenfolge
**1 → 0 → 2 → 1**. Die Variable `HELIOS_DIAGNOSTIC_FEATURE_LEVEL` gilt nur im
jeweiligen Kindprozess. Globale `FeatureLevel11`-/`UmdTrace`-Werte bleiben dabei
unverändert. Profil 0 prüft FL10.0; Profile 1 und 2 prüfen FL11.0. Profil 2 ist
absichtlich ein Diagnoseprofil mit eingeschränkten MSAA-Antworten und kein
empfohlener Betriebsmodus.

Die native Probe ruft Windows' echtes `D3D11CreateDevice` mit BGRA-/Single-Thread-
Flags auf und erfasst den **äußeren** HRESULT, das angefragte und das erreichte
Feature Level. Es gibt keinen automatischen WARP-Fallback. Die vier Test-PIDs
erlauben die Zuordnung zu den jeweiligen UMD-Protokollen. Ein Prozess wird nach
30 Sekunden als Timeout beendet; es wird kein fremder Prozess beendet.

Das Ergebnis liegt unter `C:\ProgramData\Helios\device-probe-result.json`.
`registryRestored=true` bedeutet beim Standardtest mit
`profileScope=child-process`, dass keine globalen Registry-Werte verändert wurden.
Exitcode 1 bezeichnet fehlgeschlagene Geräteerstellung, 2 eine fehlgeschlagene
DXGI-Initialisierung/Enumeration, 3 eine mehrdeutige Adapterauswahl und 4 einen
fehlenden passenden Adapter. Fehlende Ergebniszeilen sind keine erfolgreiche
Geräteprüfung. Der separate `--warp`-Schalter dient ausschließlich CI-Kontrollen.

## Über die Guest API einsammeln

Den aktuellen Gastdienst einmal vom Linux-Host aktualisieren:

```bash
python3 scripts/atlas/diagnose-vm.py --update-guest
```

Der Aufruf benötigt keine OOBE-Recovery-Option. Anschließend:

```bash
python3 scripts/helios/diagnose-graphics.py
```

Der Bericht enthält die letzten Journalereignisse und den ersten Widerspruch,
bevorzugt die vier Test-PIDs und erfasst geladene Grafikmodule mit Versionen.
`device-ready` bezeichnet weiterhin nur den UMD-Callback, nicht die Annahme durch
Windows. Das native Testergebnis steht unter `deviceProbe`, neue Absturzereignisse
seit seinem Start unter `crashesSinceProbe`. Beide Zeitangaben stammen aus dem
Gast; historische Abstürze bleiben getrennt sichtbar. API-Daten und Dateizugriffe
sind begrenzt; ausgelassene Abschnitte werden gemeldet.

## QEMU-Backendprüfung

`host.qemuBackend` wird aus den Argumenten des tatsächlich laufenden QEMU-Prozesses
ermittelt. Geprüft werden GL/VNC-Verträglichkeit, Anzeige-Backend, Venus/Blob,
Render-Node und die Verdrahtung des gemeinsamen memfd-RAMs. Die Ausgabe enthält
festgelegte Grafikfelder, keine vollständige Kommandozeile oder SMB-Zugangsdaten.

Der OPTIMAL-Readback rekonstruiert den erwarteten Image-Typ und lehnt eine
abweichende Speichergröße ab. Ein unbekannter DRM-Modifier wird nicht als LINEAR
umgedeutet. Der bekannte Konflikt 4587520/4096000 Bytes bleibt ein eigener
Transportbefund; das neue Journal soll zeigen, ob ihm überhaupt ein normaler
Present vorausgeht. QEMU-Trace/Bildaufnahmen sind zusätzlich mit
`scripts/helios/capture-displays.py` möglich.

Startparameterprüfung, Software-EGL-Callbacktests und WARP-Kontrollen ersetzen
weder einen echten NVIDIA-DMA-BUF-Import noch einen sichtbaren Desktop. Nach
erfolgreicher äußerer Geräteerstellung müssen deshalb stabile VGA-/Helios-Ausgabe,
aktuelle Present-Zähler, Kaltstart und anschließend die Grafik-API-Tests folgen.

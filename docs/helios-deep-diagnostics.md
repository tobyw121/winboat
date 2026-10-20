# Helios: erste Fehler, Langzeitmessung und QEMU-Vergleich

Diese Werkzeuge ergänzen [Helios Control und die Testoberfläche](helios-investigation.md).
Der gebündelte Standard bleibt **22.22.291.0**. Keine dieser Änderungen belegt eine
Behebung des Flackerns; die neuen UMD-Diagnosen müssen zuerst als Windows-Treiber
gebaut und anschließend auf echter Hardware geprüft werden.

## Aktualisierung und unveränderte Rettung

WinBoat neu bauen und den Guest Service aktualisieren: neue Hilfsprogramme werden
mit `helios-watchdog-v14` ausgeliefert. Die Host-Messwerkzeuge können direkt aus dem
Repository auf dem Linux-Host gestartet werden. Das zusätzliche QEMU-Profil benötigt
ein aus diesem Stand neu gebautes Helios-Host-Image; ein bereits laufender Container
übernimmt geänderte Startparameter erst nach explizitem Neuerstellen mit denselben
VM-Datenträgern. Die Werkzeuge ändern oder starten keine bestehende VM selbst.

Bei Flackern bleibt der vorhandene Rettungsweg:

```bash
python3 scripts/helios/rescue-graphics.py --disable-helios
```

## Erster DDI-Fehler

Die UMD-Quellen halten beim ersten fehlerhaften `runtime-error`-HRESULT die letzten
16 numerischen Ereignisse fest. Dieser Ausschnitt bleibt auch nach Umlauf des
normalen 96-Ereignis-Puffers erhalten und wird einmal sofort protokolliert.
Bei Ressourcen enthalten die Ereignisse DXGI-Format, Breite, Höhe, MSAA-Anzahl,
Qualitätsindex und Bind-Flags. Format-/MSAA-Abfragen und der erste Present bleiben
im vorhandenen Journal. Es werden keine Pixel, Pointer oder Anwendungsstrings in
diesen Ausschnitt aufgenommen; Capability-Antworten und Synchronisation ändern
sich nicht.

`graphics/diagnostics/journals` liefert `journal.firstFailure` neben
`firstMismatch` und `events`. Ein Fehler kann außerhalb der erfassten DDIs auftreten;
ein leerer Ausschnitt beweist deshalb keine Fehlerfreiheit. Die bereits gebündelten
`.291`/`.294`/`.296`-EXEs erhalten diese Funktion durch einen Git-Pull **nicht**.
Der Windows-Build muss ein neues, geprüftes Paket erzeugen; kein automatischer
Austausch des Standardpakets findet statt.

## DWM-Minidumps, ausdrücklich zeitlich begrenzt

In **Helios Control**: „DWM-Minidumps 30 Minuten aktivieren“. Alternativ in einer
erhöhten Windows-PowerShell im Verzeichnis der Guest-Service-Skripte:

```powershell
.\Manage-HeliosCrashCapture.ps1 -Action Enable
.\Manage-HeliosCrashCapture.ps1 -Action Status
.\Manage-HeliosCrashCapture.ps1 -Action Disable
```

Nur `dwm.exe` erhält eine WER-LocalDumps-Regel mit `DumpType=1` und `DumpCount=3`.
Ein SYSTEM-Auftrag entfernt diese Regel nach 30 Minuten, bei ausgeschaltetem Gast
beim nächsten verfügbaren Start. Bereits vorhandene oder nachträglich veränderte
WER-Regeln werden nicht überschrieben beziehungsweise gelöscht. Vorhandene Dumps
bleiben nach dem Abschalten zur lokalen Untersuchung erhalten.

Speicherort: `%ProgramData%\WinBoat\GraphicsValidation\dwm-dumps`, ausschließlich
Administratoren/SYSTEM zugänglich. Die Anzahl wird von WER verwaltet, die Größe
einer einzelnen Datei nicht hart begrenzt. Auch Minidumps können private
Speicherinhalte enthalten. WER erstellt nicht für jeden DWM-/GPU-Fehler einen Dump.
`graphics/validation` enthält unter `dump-policy` nur den gespeicherten Status,
keine Speicherabbilder. Weder API noch Supportexport laden Dumps hoch.

## Langzeitmessung ohne dauernde PowerShell-Prozessstarts

Zum Beispiel zwei Stunden auf dem Linux-Host:

```bash
python3 scripts/helios/soak-graphics.py --minutes 120 --interval 60 --output soak.jsonl
```

Die Ausgabe wird exklusiv angelegt und nach jedem Datensatz geleert; existierende
Dateien werden nicht überschrieben. Strg+C beendet die Messung mit einem als
unvollständig markierten Abschlussbericht. Grenzen: 1–1440 Minuten, 15–300 Sekunden
Abstand. Die Laufzeit endet nach der Messperiode zuzüglich begrenzter laufender
API-Aufrufe. Die Datei bleibt auch bei einem harten Prozessabbruch lesbar.

Pro Messintervall werden Docker-CPU-/RAM-Prozentwerte, verfügbare NVIDIA-Sensoren
und der bereits gecachte native Adapterstatus gelesen. Nur alle fünf Minuten und
zum Abschluss wird der teurere Windows-Laufzeitbericht angefordert. Es werden keine
zusätzlichen Hintergrundaufträge oder periodischen PowerShell-Prozesse registriert.

Die Zusammenfassung enthält:

- CPU: 100 % entspricht einem Host-Kern; Werte darüber sind gültig.
- Container-RAM-Trend in Prozentpunkten/Stunde und GPU-Speichertrend in MiB/Stunde.
  Andere Host-Anwendungen können die GPU-Werte beeinflussen; Trends beweisen kein Leck.
- Deduplizierte beobachtete DWM-/Display-Reset-Ereignisse innerhalb der Messung,
  DWM-Prozess- und Boot-Identitäten sowie fehlende Messpunkte und Zeitlücken.
- Optional Viewer-Fortschritt, wenn ein vorhandenes Viewer-Statistiklog angegeben wird:

```bash
python3 scripts/helios/soak-graphics.py --minutes 120 --output soak-viewer.jsonl --viewer-log viewer.log --expect-animation
```

`--expect-animation` nur bei einer tatsächlich durchgehend bewegten Szene verwenden.
Frische Viewer-Zähler ohne neue Frames erzeugen Verdachtsintervalle; unveränderte
Telemetrie wird separat gezählt. Ein ruhender Desktop ist ohne diese Option kein
Hänger. Zusammengefasste Updates sind keine bewiesenen verlorenen Spielframes.
Die begrenzten Windows-Ereignisfenster machen Ereigniszahlen zu Untergrenzen;
fehlende Ereignisse beweisen keine Stabilität.

## Zeitanteile getrennt bewerten

`diagnose-graphics.py` ergänzt `host.framePhases` aus vorhandenen QEMU-Traces:
Submission, Warten auf Completion und CPU-Arbeit des Capture-Pfads sowie ACK-Zeit.
Fehlende Trace-Einträge bleiben unbekannt. Frame-Tracing muss explizit über das
bestehende Performance-Profil eingeschaltet werden.

`measure-performance.py --viewer-log ...` liefert außerdem `viewerPhases` mit
Zählerdifferenzen je Prozess und Konsole. Counter-Resets werden nicht negativ als
Leistungsgewinn verrechnet. Submission ist keine GPU-Renderzeit, ACK- und Capture-
Zeit können sich überlappen. Die Werkzeuge addieren sie deshalb nicht zu einer
angeblichen Gesamt- oder Eingabelatenz.

## Regressionssuche: immer nur Host oder Gast ändern

`bisect-graphics.py` plant eine binäre Suche. Es installiert keinen Treiber,
wechselt keinen Checkout und startet keine VM. Ausgangspunkt ist der bekannte
`.291`-Stack; Kandidaten müssen vom ältesten zum neuesten Build sortiert sein.

Eine `candidates.json` enthält ein JSON-Array mit exakten Identitäten:

- `--axis guest`: SHA-256 der jeweiligen installierten Paketmanifeste, 64 Hex-Zeichen.
- `--axis host`: Docker-Image-IDs `sha256:…`, keine veränderlichen Tags.

Zuerst Endpunkte prüfen, danach vorgeschlagenen Mittelpunkt testen. Für jeden
Kandidaten A1/B1/A2/B2 ausführen: A bleibt der ursprüngliche stabile Baseline-Stack.
Nach jedem Testlauf einen separaten `diagnose-graphics.py`-Bericht speichern.
Die Berichte enthalten sowohl die gespeicherte Abnahme als auch die Host-Image-ID.

```bash
python3 scripts/helios/bisect-graphics.py --axis guest --candidates candidates.json --probe "D3D11 4x MSAA resize"
python3 scripts/helios/bisect-graphics.py --axis guest --candidates candidates.json --probe "D3D11 4x MSAA resize" --trial A1.json B1.json A2.json B2.json
```

Weitere abgeschlossene Reihen als zusätzliche `--trial`-Vierergruppen angeben.
Für die ausgewählte Probe müssen dieselben EXE-Bytes benutzt werden, vorzugsweise
die separat gebauten und gepinnten Validierungswerkzeuge. Treibervorgaben,
VM-Identität, Workload-Schlüssel und die andere Stack-Seite bleiben konstant;
Auflösung und QEMU-Startoptionen müssen auch vom Bediener gleich gehalten werden.
Timeouts, fehlende Messungen, unterschiedliche B-Fehler oder widersprüchliche
Kandidatenergebnisse werden als ungeeignete Evidenz abgewiesen.

Die Suche grenzt nur das Verhalten der ausgewählten Probe ein. Sie setzt eine
monotone Regression voraus; gute spätere und schlechte frühere Builds erzwingen
stattdessen Einzeltests aller Kandidaten. Eine Grenze zwischen zwei Builds ist
kein Beweis für die genaue fehlerhafte Codezeile oder für eine visuelle Freigabe.

## QEMU: CPU-sparendes I/O-Profil vergleichen

`host.qemuBackend.performance` im Grafikbericht zeigt angeforderte CPU-Beschleunigung,
CPU-Modell/-Topologie, verfügbare logische CPUs, Storage-Cache/AIO-Modus,
I/O-Thread-Polling und Netzwerkkartenmodelle. Pfade, SMB-Zugangsdaten und VM-Namen
werden nicht übernommen. Warnungen betreffen unter anderem TCG, KVM ohne `host`-
CPU-Modell, `cache=unsafe`, emulierte NICs und mehr vCPUs als verfügbare CPUs.
Die Startargumente beweisen allein nicht, dass KVM tatsächlich aktiv ist.

Das neue Profil kombiniert einen separaten VirtIO-Storage-I/O-Thread mit
`poll-max-ns=0`, um aktives I/O-Polling zu vermeiden:

```bash
python3 scripts/helios/performance-profile.py io-thread-low-cpu --output io-low-cpu.json
```

Die erzeugte Compose-Ergänzung ausdrücklich zusammen mit der ursprünglichen
Compose-Datei verwenden. Erst sichern, dass der Dienstname passt (`--service`,
Standard `windows`). Wie bei den bestehenden Profilen erfolgt kein automatischer
Neustart. Zum Rückweg die Ergänzung weglassen. Disk-Cache/Flush-Verhalten,
Grafikpfad, Datenträger und QMP bleiben unverändert.

Für kontrollierte Polling-Vergleiche gibt es außerdem
`custom --io-thread --io-poll-ns 0|32768|65536`. Polling ohne I/O-Thread und schon
zugewiesene Controller werden abgewiesen. Niedrigeres Polling kann CPU sparen,
aber I/O-Latenz verändern. Vergleich A/B/A/B mit gleicher Last durchführen;
keine Leistungssteigerung oder geänderten Standards ohne Messwerte behaupten.
Vorhandene Cache-, Multiqueue-, Affinitäts- und Hugepage-Profile bleiben einzeln
aktivierbar. Netzwerkumbenennung ersetzt keine schnellere Netzwerktechnik.

## Gefilterte Exportvorschau

```bash
python3 scripts/helios/export-support.py graphics.json
```

Die Vorschau zeigt genau das spätere JSON und seinen SHA-256. Eine Positivliste
behält bekannte numerische Diagnosefelder, API-Fehlercodes und feste Zustände;
Pfade, freie Benutzer-/Anwendungstexte, unbekannte Felder und Dumps werden entfernt.
Durch die strikte Filterung können Details fehlen: Originalbericht lokal behalten.
Nach eigener Prüfung:

```bash
python3 scripts/helios/export-support.py graphics.json --output support.json --review-sha256 PRUEFSUMME_AUS_DER_VORSCHAU
```

Eine geänderte Vorschau oder vorhandene Zieldatei wird abgewiesen. Nichts wird
hochgeladen. Die Vorschau sollte vor einer Weitergabe trotzdem gelesen werden.

## Validierungsgrenzen

Die automatisierten Prüfungen testen Journalerhalt, reale Windows-Registry-Typen
in einem temporären HKCU-Testschlüssel, Filtergrenzen, Vergleichsentscheidungen,
Streaming/Unterbrechungslogik und echte QEMU-I/O-Thread-Eigenschaften via QMP.
Sie aktivieren keine DWM-Dump-Regel auf CI und installieren dort keinen Helios-
Treiber. Mehrstündige echte Windows-/NVIDIA-Tests, DWM-Abstürze, sichtbare Ausgabe
und Leistungsgewinne müssen auf der Ziel-VM geprüft werden.

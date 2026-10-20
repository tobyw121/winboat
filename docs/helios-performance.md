# Helios: QEMU-Transport und Performance vergleichen

Native Pixel-/MSAA-Prüfungen, A/B/A/B-Auswertung und Windows-Treibersteuerung:
[helios-control-and-validation.md](helios-control-and-validation.md).

Diese Änderungen betreffen QEMU, den nativen Viewer und den WinBoat-Gastdienst.
Der Standardinstaller bleibt **22.22.291.0**. Die mitgelieferten `.291`-, `.294`-
und `.296`-EXE-Dateien wurden dabei nicht verändert. Ein behobener Vulkan-/D3D-
Treiberfehler oder höhere Spiele-FPS sind damit noch nicht nachgewiesen.

## Aktualisieren

Auf dem Linux-Desktop im Repository:

```bash
git pull --ff-only origin work
./scripts/build-helios.sh
```

Anschließend die neue AppImage unter `dist/` starten. Der vollständige Build
aktualisiert auch das Host-Image. `--skip-host` eignet sich hier nicht, wenn das
lokale Image noch die alte Laufzeit enthält. Erwartet werden `glvnd-v8` und
Anzeigeprotokoll `dbus-v9`; die Quellrevision allein reicht zur Prüfung nicht.
Eine bereits laufende VM verwendet ihr bisheriges Image bis zum ausdrücklich
ausgelösten Neuerstellen des Containers mit der bestehenden Konfiguration.
Windows-Festplatte und Volumes müssen dabei erhalten bleiben.

Den Gastdienst einer laufenden VM unabhängig davon aktualisieren:

```bash
python3 scripts/atlas/diagnose-vm.py --update-guest
```

Das aktuelle Grafikprotokoll lautet `helios-watchdog-v15`. Eine alte AppImage
kann beim nächsten Start wieder ihren älteren Gastdienst einspielen.
Details zum Build stehen in [build-helios-local.md](build-helios-local.md).

## Transport und Hintergrundarbeit

- Fehlgeschlagene Vulkan-DMA-BUF-Imports werden pro Buffer und Geometrie
  begrenzt wiederholt: 250 ms bis höchstens 8 s Abstand. Ein neuer Buffer oder
  geänderte Metadaten erlauben sofort einen neuen Versuch. Gehaltene FDs
  verhindern, dass wiederverwendete Kernel-Identitäten verwechselt werden.
- Beschädigte Flächen eines Frames werden zu einer gemeinsamen Region
  zusammengefasst. Daraus entstehen ein Update und eine Abschlussbestätigung
  statt mehrerer Kopien desselben Frames. Direkte DMA-BUF-Ausgaben werden auch
  ohne zusätzliche Software-DisplaySurface aktualisiert.
- Nach wiederholten Importfehlern kann der Viewer beim Wiederverbinden einen
  Software-Kopiertransport anfordern. QEMU liefert diesen nur nach einem
  erfolgreichen EGL-Import und geprüftem Framebuffer-Readback. Unbekannte
  Modifier werden weiterhin nicht als LINEAR interpretiert. Bei Fehlern bleibt
  das letzte gültige Bild erhalten; VGA oder Windows-Treiber werden nicht
  automatisch umkonfiguriert. Die Kopie ist ein Kompatibilitätsfallback und
  kann mehr CPU/Bandbreite benötigen.
- Verdeckte Viewer-Ausgaben lösen keine unnötigen GTK-Neuzeichnungen aus.
  GPU-Leseabschluss und Bufferfreigabe bleiben Voraussetzung für die ACKs.
- Ausstehende vollständige Installationsprüfungen starten PowerShell nach
  30, 60, 120, 240 und anschließend höchstens alle 480 Sekunden. Ein geänderter
  Statusbeleg setzt diese Verzögerung zurück. Native PnP-Statusabfragen laufen
  weiterhin unabhängig davon.
- Erfolgreiche aufwendige API-Diagnosen werden fünf Sekunden zwischengespeichert.
  `collectorAgeMs` kennzeichnet ihr Alter; `adapters.sampleAgeMs` gehört zum
  separat gelesenen Adapterstatus. Fehler werden nicht als Erfolg gespeichert.
  Bereits vorhandene Cache-Antworten benötigen keinen neuen PowerShell-Prozess.

## Optionen für kontrollierte Vergleiche

Diese Optionen sind standardmäßig aus. Sie ändern weder die Treiberversion noch
automatisch die Windows-Anzeige. Der VGA-Rettungsstart überspringt sämtliche
optionalen Performance-Einstellungen.

| Variable | Wirkung und Voraussetzung |
|---|---|
| `HELIOS_SHADER_CACHE=1` | Persistente Mesa-/NVIDIA-Caches unter `/storage/.winboat-cache/graphics/`, getrennt nach verfügbarer GPU-/Laufzeitidentität. Verzeichnisse werden mit Modus 0700 angelegt; Symlink-Cachepfade werden abgewiesen. |
| `HELIOS_IO_THREAD=1` | Eigener QEMU-I/O-Thread für genau einen bisher unzugewiesenen VirtIO-SCSI-/Blockcontroller. Disk-Cache, AIO und Flush-Policy bleiben erhalten. |
| `HELIOS_CPU_AFFINITY=2-5` | Beschränkt QEMU und seine Renderer-Kinder auf verfügbare Container-CPUs. Reserviert keine Host-CPUs und ersetzt keine vCPU-Thread-Zuordnung. |
| `HELIOS_NET_QUEUES=2` | 2–8 Queues für genau einen VirtIO-Netzadapter mit TAP-Backend. User-Networking und vorhandene FD-/Queue-Konfigurationen werden nicht überschrieben. |
| `HELIOS_HUGEPAGES=2M` | Alternativ `1G`; benötigt ausreichend bereits reservierte Hugepages und passend ausgerichtete gemeinsame memfd-RAM-Größe. Keine automatische Hostreservierung. |
| `HELIOS_PREALLOC=1` | Allokiert das gemeinsame memfd-RAM vorab; kann Startzeit und sofortigen RAM-Bedarf erhöhen. |
| `HELIOS_FRAME_TRACE=1` | Aktiviert Frame-/ACK-Diagnose und das QEMU-Vulkan-Capture-Trace-Ereignis. Vorhandene eigene Trace-Einstellungen werden nicht überschrieben. |

Unpassende explizite Kombinationen werden mit einer Fehlermeldung abgewiesen.
Es gibt keine stillen Änderungen des Netzwerkmodells, der Festplatte oder von
QMP. Cache-, CPU-, Netzwerk- und Speicheroptionen sind Vergleichskandidaten;
ein allgemeiner Performancegewinn wurde auf der RTX 2070 noch nicht gemessen.

Der Helfer erzeugt ausschließlich eine neue Compose-Override-Datei mit Modus
0600. Er startet und stoppt keine VM:

```bash
python3 scripts/helios/performance-profile.py baseline --output /tmp/helios-A.json
python3 scripts/helios/performance-profile.py cache --output /tmp/helios-B.json
```

Weitere Profile: `io-thread` und `custom`. Beispiel für zwei explizite Optionen:

```bash
python3 scripts/helios/performance-profile.py custom --shader-cache --io-thread --output /tmp/helios-custom.json
```

Overrides müssen mit der **ursprünglichen Compose-Datei und demselben Projekt**
angewendet werden. Der Dienst heißt standardmäßig `windows`; abweichende Namen
über `--service` angeben. Vor einem geplanten Neustart die zusammengeführte
Konfiguration mit `docker compose -p PROJEKT -f ORIGINAL -f OVERRIDE config`
prüfen. Die Dateien ersetzen keine WinBoat-Einstellungen; ein späteres Starten
ohne Override nutzt wieder die ursprünglichen Optionen.

Viewer-Optionen gehören zum Linux-Prozess der AppImage, nicht zum Container:

- `HELIOS_VIEWER_BACKGROUND_FPS=5`: begrenzt Hintergrundkopien auf fünf pro
  Sekunde; zulässig sind 1–30, `0` erhält das normale Verhalten. Nach ausgelassenen
  Software-Deltas wird vor der Wiederanzeige ein vollständiger Frame angefordert.
- `HELIOS_VIEWER_COPY=1`: fordert den geprüften Kopiertransport bereits beim
  Verbindungsaufbau an. Auch dabei bleiben ungültige Modifier ausgeschlossen.

Die entsprechende Variable für den AppImage-Aufruf setzen und die App vorher
vollständig schließen, damit sie nicht an einen alten Prozess weitergereicht wird.

## Messen und Fehler zuordnen

Den gleichen Zustand mehrfach in der Reihenfolge **A/B/A/B** messen, etwa
ruhender Desktop, bewegtes Fenster und derselbe reproduzierbare Spieleabschnitt.
Vor jeder Messung dieselbe Aufwärmzeit und Auflösung verwenden. Cache-Warmup
getrennt von dauerhaftem Rendering bewerten.

```bash
python3 scripts/helios/measure-performance.py --label A1 --samples 10 --interval 2 --output /tmp/helios-A1.json
python3 scripts/helios/diagnose-graphics.py --samples 6 --interval 5
```

`measure-performance.py` liest Container-CPU/RAM und, sofern verfügbar,
NVIDIA-Sensoren. **100 % Container-CPU entspricht einem Host-CPU-Kern**; Werte
darüber sind zulässig. Fehlende Messwerte bleiben als solche erkennbar. Die
geschützte JSON-Ausgabe enthält CPU-Mittelwert/-Median, keine behaupteten FPS
oder Eingabelatenzen. Mit `--viewer-log PFAD` kann zusätzlich ein bereits
vorhandenes natives stderr-Protokoll ausgewertet werden.

Viewer-Statistiken erscheinen alle fünf Sekunden. Wichtig sind `pid`, `console`,
`monotonicUs`, `copySamples`, `sourceCopyWallUs`, `completionWaitUs`,
`renderedFrames`, `skippedRedraws` und `coalescedUpdates`. Nur Differenzen desselben
Prozesses und derselben Konsole vergleichen. `sourceCopyWallUs` enthält bereits
die Wartezeit; beide Zeiten nicht addieren. Neuzeichnungen sind keine Spiele-FPS.

Die Grafikdiagnose übernimmt begrenzte numerische QEMU-Daten in
`host.frameMetrics`: Source-/Sequenznummer, Import-/Capture- und ACK-Zeiten.
Trace-Daten müssen zeitlich und nach Quelle zugeordnet werden. Das begrenzte
Logfenster ist weder ein vollständiger Frame-Verlauf noch ein Beweis für ein
sichtbares Windows-Bild. Rettungs- und weitere API-Aufrufe stehen in
[helios-guest-diagnostics.md](helios-guest-diagnostics.md).

## Validierung und Grenzen

Die QEMU-Produktion wurde in GitHub Actions für `ad34b4f` erfolgreich gebaut
([Lauf 39332269245](https://github.com/tobyw121/winboat/actions/runs/39332269245));
die zugehörige Windows-Provisionierung bestand ebenfalls. Lokal wurden die
echten gepatchten QEMU-Callbacks mit Mesa/EGL, die nativen GTK-/D-Bus-Viewerpfade,
die Go-Race-Tests und der Windows-AMD64-Gastbuild geprüft. Die negativen
Regressionskontrollen müssen die alten Fehler weiterhin erkennen.

Diese Cloud-Tests ersetzen keinen Windows-/NVIDIA-Dauertest. Das ursprüngliche
DWM-/MSAA-Problem der neueren Treiber bleibt getrennt zu untersuchen; weder
Softwarekopie noch Umbenennen des Adapters beheben diesen Treibervertrag.

Erweiterte Messwerkzeuge und das neue QEMU-I/O-Profil: [Helios Deep Diagnostics](helios-deep-diagnostics.md).

Aktueller Kandidat: [Helios .298, Vertragstests und QEMU-Speicherprofil](helios-298-validation.md).

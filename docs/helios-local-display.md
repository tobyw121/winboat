# Lokaler Helios-Desktop (experimentell)

WinBoat bevorzugt für neue Helios-VMs ein natives GTK4-/OpenGL-Fenster, sofern
Viewer, GTK4, D-Bus, Host-Image und Desktop-Sitzung verfügbar sind. Die Einrichtung
bietet dafür die vorausgewählte Option **Prefer Local Desktop**; sie lässt sich
abwählen. Fehlen Voraussetzungen, wird Browser Display verwendet und der Grund
in der Einrichtung angezeigt. Vorhandene VMs werden nicht automatisch umgestellt. Browser Display und
RemoteApps bleiben verfügbar. Windows und die Grafiktreiber werden durch diesen
Viewer nicht ersetzt.

Die Auswahl wird unabhängig vom aktiven Anzeigetransport als
`localDisplayPreferred` in `winboat.config.json` gespeichert. Fehlt beim Speichern
eine Voraussetzung, bleibt die Auswahl eingeschaltet und Browser Display aktiv.
**Retry Local Desktop** prüft die Voraussetzungen erneut und übernimmt den
nativen Transport, sobald er verfügbar ist. Auch beim nächsten VM-Start prüft
WinBoat die gespeicherte Auswahl erneut. Ein vorübergehender Fehler setzt sie
nicht zurück. Der automatische Containerstart am Host-Boot bleibt bei dieser
Auswahl deaktiviert. Ältere Konfigurationen übernehmen zunächst den Compose-Modus.

Für diese Änderung muss die Linux-Anwendung neu gebaut und das neue AppImage
gestartet werden. `diagnose-vm.py --update-guest` aktualisiert nur den Windows-
Gastdienst und ersetzt keine laufende WinBoat-Anwendung.

## Bauen und einschalten

```bash
./scripts/build-helios.sh
```

Der Docker-Build baut den Viewer mit und nimmt ihn unter `resources/native/`
in die Linux-Anwendung auf. Für die Ausführung benötigt der Host GTK **4.8+**,
libepoxy, OpenGL 3.3 und `dbus-daemon`. Unter Debian/Ubuntu:

```bash
sudo apt install libgtk-4-1 libepoxy0 dbus-daemon
```

Für einen Build mit lokal installierter Werkzeugkette zusätzlich
`libgtk-4-dev`, `libepoxy-dev`, `pkg-config` und einen C-Compiler installieren.
`npm run build:linux-gs` baut den Viewer nach dem TypeScript-Build; einzeln geht
es mit `npm run build:helios:viewer`. `npm run build` allein baut weiterhin nur
die Electron-Anwendung und leert das Verzeichnis `build/`.

1. Den bestehenden Helios-Adapter und Windows-Treiber nach `helios.md` einrichten.
2. Unter **Settings → Container → Local desktop (experimental)** einschalten und
   speichern. Die VM wird dabei wie bei anderen Containeränderungen neu gestartet.
   Der Schalter deaktiviert den automatischen Containerstart am Host-Boot, weil
   der private Anzeigedienst an die Desktop-Sitzung gebunden ist.
3. **Windows Desktop** öffnen. **Ctrl+Alt+Enter** schaltet den Viewer auf Vollbild
   und zurück. Browser Display lässt sich jederzeit gesondert öffnen.

**Open Local Desktop** steht auch direkt in Einstellungen und Einrichtung zur
Verfügung. Der Verbindungsstatus zeigt Start, Verbindung und Fehler an; bei
Viewer-Fehlern öffnet WinBoat Browser Display. Mehrfaches Öffnen während des
Starts erzeugt nur einen Viewer. Normales Schließen beendet nur das Fenster.
Beim Stoppen der VM wird der Viewer absichtlich beendet, ohne Browser-Fallback.

Das native Fenster bietet außerdem **Fullscreen**, **Ctrl+Alt+Del** und einen
Hinweis, solange kein Windows-Bild empfangen wird. Gehaltene Tasten/Maustasten
werden beim normalen Schließen und beim Stoppsignal freigegeben. Anzeige und
Windows-Anmeldung sind unabhängig: Ein fehlender Windows-Benutzer oder eine
blockierte AME-OOBE wird durch den Wechsel des Anzeigefensters nicht repariert.

Die Einstellung prüft Viewer-Version und Image-Fähigkeitslabel `dbus-v3`.
Ein älteres Host-Image muss neu gebaut werden. Schlägt die Viewer-Anmeldung oder
Frame-Übernahme fehl, öffnet WinBoat Browser Display und protokolliert den Fehler.
Die VM und ihre Disk werden dabei nicht automatisch umkonfiguriert.

## Display-Bus und Container

Der Bus wird für diese Anwendung separat gestartet. Er liegt normalerweise unter
`$XDG_RUNTIME_DIR/winboat-helios`, sonst unter `/tmp/winboat-helios-<uid>`.
Das Verzeichnis muss dem Desktop-Benutzer gehören und Modus 0700 haben. Es wird
nur lesbar nach `/run/helios-display` in den VM-Container eingebunden. Es gibt
keinen TCP-Display-Port und keinen Docker-Socket im Viewer. Der normale
Desktop-Session-Bus wird nicht an den Container weitergegeben.

Die Bus-Konfiguration akzeptiert ausschließlich EXTERNAL-Authentifizierung für
Container-root und den Desktop-Benutzer. Den Namen `org.qemu` darf nur root
registrieren. Die optionale Erweiterung `RegisterListenerReverse` lässt QEMU ein
Socket-Paar erzeugen und einen seiner FDs an den Viewer zurückgeben. Dadurch
identifizieren auch die Socket-Credentials QEMU. QEMU meldet sich am Host-Listener an;
der Viewer vergleicht seine Kernel-UID mit dem von D-Bus bestätigten QEMU-Besitzer.
Dadurch kann GLib die Container-Peer-Credentials im Host-PID-Namespace prüfen.
Der ursprüngliche `RegisterListener`-Einstieg bleibt erhalten und prüft die UID
gegen seinen authentifizierten Aufrufer. Es gibt weder anonyme Anmeldung noch
deaktivierte Credential-Prüfungen oder einen Host-PID-Namespace für die VM.
Die Patch-Prüfsumme wird vor dem Anwenden kontrolliert. Die ursprünglichen
Helios-Quellen und Dependency-Commit-Pins bleiben erhalten.
Bei Software-Auflösungswechseln sendet der Patch ein vollständiges neues
Ausgangsbild, bevor weitere Teilaktualisierungen eintreffen. Das verhindert,
dass etwa 720 Pixel breite VGA-Updates noch in eine 640-Pixel-Textur gelangen.

Der Bus kann die WinBoat-Oberfläche überleben, solange eine VM ihn verwendet.
Die VM muss über WinBoat gestartet werden, damit der Benutzer-Bus vorher bereit
ist. Automatischer Docker-Containerstart ist für diesen experimentellen Modus
gesperrt; eine Boot-/Session-Serviceintegration ist noch nicht implementiert.
Nach einem Loginwechsel oder gelöschtem Runtime-Verzeichnis kann eine erneute
Übernahme der Einstellung samt VM-Neustart nötig sein. Ein erreichbarer, aber
nicht authentifizierbarer Bus wird nicht automatisch gelöscht oder ersetzt.

## Was der Viewer tatsächlich tut

- Software-`Scanout`/`Update` zeigt Firmware und frühe Windows-Bootbilder an.
- `ScanoutDMABUF` und `ScanoutDMABUF2` übernehmen bis zu vier Ebenen mit FD,
  Stride, Offset, Modifier, Ausschnitt und Orientierung. Unterstützt werden
  RGB-Formate XRGB8888, ARGB8888, XBGR8888 und ABGR8888. Andere Formate und nicht
  importierbare Modifier führen zu einer sichtbaren Fehlermeldung/Rückfall.
- EGL importiert das Bild. Bei `UpdateDMABUF` wird es auf der GPU in eine eigene
  Präsentationstextur kopiert. `glFinish` beendet diesen Quellzugriff, bevor die
  Antwort QEMUs blockierte GL-Konsole wieder freigibt. Spätere Fensterausgaben
  verwenden nur die eigene Textur, keinen bereits freigegebenen Scanout.
- Die Produzentenseite nutzt weiterhin die implizite DMA-BUF-Synchronisation des
  vorhandenen QEMU-/Treiber-Protokolls. Es wird noch kein expliziter Vulkan- oder
  Wayland-Release-Fence-Kanal hinzugefügt.
- Tastatur und Maus laufen über QEMUs Display1-Eingabeschnittstellen. Fokusverlust
  gibt gedrückte Tasten und Maustasten frei. Der Viewer skaliert mit schwarzen
  Rändern; er erzwingt noch keine neue Gastauflösung.

Das ist **kein durchgehend kopierfreier Direct-Scanout-Pfad**: Es gibt eine
bewusste GPU-Kopie und eine konservative Synchronisationsstelle. Der Viewer
vermeidet CPU-Readback für seinen DMA-BUF-Pfad. Dass auch QEMU/Renderer und ein
parallel verfügbarer VNC-Pfad keine Kopien mehr durchführen, ist damit nicht
nachgewiesen. Statistiken auf stderr unterscheiden `dmabufFrames`,
`softwareFrames` und `renderedFrames`.

## Grenzen und nächste Schritte

Wayland mit EGL ist der vorgesehene DMA-BUF-Pfad. Unter X11 hängt der Import davon
ab, ob GTK einen EGL-Kontext bereitstellt; bei GLX kann Softwareanzeige weiterhin
funktionieren, DMA-BUF-Import wird jedoch abgelehnt. Physische AMD-, Intel- und
NVIDIA-GPUs sowie Hybrid-Grafik brauchen gesonderte Tests.

Relative Mausbewegungen innerhalb des Fensters sind vorhanden, jedoch noch
keine Pointer-Lock-/Relative-Pointer-Protokolle für unbegrenzte Kamerabewegung.
Audio, Zwischenablage und Controller-Transport sind nicht Teil des Viewers;
bestehendes USB-Passthrough ist davon unabhängig. HDR, VRR, mehrere Monitore,
gezielte Frame-Pacing-/GLsync-Optimierung und Direct Scanout sind weitere Arbeit.
Es gibt keine Zusage für 144 Hz oder weniger als 1 ms Gesamtlatenz.

## Reproduzierbare Prüfungen

```bash
npm run test:helios
npm run test:virgl
npm run test:helios:host
npx vue-tsc --noEmit -p src/renderer --skipLibCheck

docker buildx build --target viewer-toolchain --load \
  -t winboat/viewer-toolchain:local .
npm run test:helios:viewer
```

Der Viewer-Test baut aus den aktuellen Quellen, prüft die tatsächlichen
Authentifizierungs-Callbacks aus dem Patch, startet einen privaten Bus und
QEMU/TCG mit VirtIO-VGA sowie einen GTK-Viewer unter Xvfb. Nur der Test-Viewer-Container
verwendet den Host-PID-Namespace, um einen nativen Host-Viewer nachzubilden.
Die VM behält ihren eigenen PID-Namespace. QEMU läuft als root, der Viewer als
Desktop-UID. Der Test verlangt erfolgreiche Registrierung, Softwareframes
und ausgeführte Fensterausgaben. Der Test nutzt keine GPU, kein KVM und kein
Windows. Er bestätigt keinen physischen DMA-BUF-Import oder Gamingbetrieb.

## VM endet direkt nach dem Start

Dockur kann beim Ende von QEMU `Shutdown completed` und Docker-Exitcode 0
melden. Das belegt noch keine erfolgreiche Windows-Installation. Die Dateien
unter `/run/shm` sind nach dem Container-Ende möglicherweise nicht mehr lesbar.
Für einen Mitschnitt auf dem Linux-Host im Repository ausführen:

```bash
python3 scripts/helios/diagnose-vm.py
```

Vor dem Mitschnitt die WinBoat-App und andere QMP-Clients schließen, damit der
Monitoranschluss frei ist. Der Recorder wiederholt Verbindungen, solange nach
einem offenen Docker-Port noch keine echte QMP-Begrüßung empfangen wurde.

Das Skript startet einen gestoppten Container `WinBoat` oder hängt sich an einen
laufenden Container an. Es sammelt für höchstens 120 Sekunden Docker-Ausgaben,
Snapshots der QEMU-Protokolle und Ereignisse vom veröffentlichten QMP-Port
7149 (Host-Port wird aus Docker ermittelt). Über QMP sendet es ausschließlich
die Protokollfreigabe und `query-status`. Es stoppt die VM am Ende nicht.
Die Ausgabe nennt den privaten Diagnoseordner unter `~/.winboat/diagnostics/`
und zeigt die letzten Protokollzeilen sowie Ereignisse wie `SHUTDOWN`/`RESET`.
Passwörter aus Dockers `Config.Env` werden nicht abgefragt oder exportiert.

`--container NAME`, `--seconds 180` und `--output /ein/neuer/ordner` passen den
Mitschnitt an. Dafür sind Python 3 und die lokale Docker-CLI erforderlich.
Der Recorder wurde mit einem echten QEMU/TCG-Container und kontrolliertem
`host-signal`-Shutdown geprüft; ein Windows-/GPU-Lauf ist eine gesonderte Prüfung.

### Fenstergröße und Bildpfad

**Resize guest** fordert nach Größenänderungen mit 300 ms Verzögerung die
Fensterauflösung über QEMUs `Console.SetUIInfo` an. Die Option ist zunächst aus;
der Windows-Grafiktreiber muss die Anfrage unterstützen. Eine bestätigte
D-Bus-Anfrage beweist noch keine Auflösungsänderung im Gast. **Keep aspect**
bewahrt das Seitenverhältnis; ausgeschaltet wird das Bild auf die Fensterfläche
gestreckt. Die Mauskoordinaten folgen derselben Darstellung. Klicks in schwarze Ränder
werden nicht an eine alte Mausposition im Gast weitergegeben.

Die Statuszeile nennt die tatsächlich empfangene Auflösung und den bisher
verwendeten Software-/DMA-BUF-Bildpfad. Der native Softwaretest verlangt auch
eine erfolgreich beantwortete Auflösungsanfrage. Audio, Zwischenablage, HDR/VRR
und unbeschränkte Gaming-Maussteuerung bleiben separate Erweiterungen.

### Screenshots

**Screenshot** öffnet einen lokalen Speicherdialog und speichert die sichtbare
Windows-Bildfläche einschließlich schwarzer Ränder als PNG. Der Viewer gibt vor
dem Dialog gehaltene Eingaben frei und fokussiert danach wieder das Windows-Bild.
Nur ein ausdrücklich angeforderter Screenshot liest Pixel zur CPU zurück; der
normale DMA-BUF-Anzeigeweg bleibt davon unberührt. Ohne aktives Bild oder bei
Dateifehlern zeigt die Statuszeile einen Fehler. Der native Funktionstest prüft
auch PNG-Erstellung und Bildabmessungen.

### Desktop-Sitzung im Produktionsbuild

Desktop-Variablen werden über Electrons Node-Laufzeit gelesen. Direkte
`process.env`-Zugriffe im Renderer werden von Vite bei Client-Produktionsbuilds
ersetzt und können eine vorhandene X11-/Wayland-Sitzung übersehen. Die Korrektur
benötigt einen neuen WinBoat-Anwendungsbuild; ein Gastdienst-Update allein ändert
die Desktop-Erkennung nicht. Ein Produktionstest mit Vite prüft DISPLAY,
WAYLAND_DISPLAY und XDG_RUNTIME_DIR ohne Zugriff auf die echte Benutzerumgebung.

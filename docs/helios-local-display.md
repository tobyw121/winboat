# Lokaler Helios-Desktop (experimentell)

WinBoat bevorzugt für neue Helios-VMs ein natives GTK4-/OpenGL-Fenster, sofern
Viewer, GTK4, D-Bus, Host-Image und Desktop-Sitzung verfügbar sind. Die Einrichtung
bietet dafür die vorausgewählte Option **Prefer Local Desktop**; sie lässt sich
abwählen. Fehlen Voraussetzungen, wird Browser Display verwendet und der Grund
in der Einrichtung angezeigt. Vorhandene VMs werden nicht automatisch umgestellt. Browser Display und Local Desktop sind getrennte Anzeigemodi.
RemoteApps bleiben unabhängig davon verfügbar. Windows und die Grafiktreiber werden durch diesen
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
libepoxy, OpenGL 3.3 oder OpenGL ES 3.0 und `dbus-daemon`. Unter Debian/Ubuntu:

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
   und zurück. Für Browser Display Local desktop ausschalten und speichern;
   dabei wird der Container mit derselben Windows-Festplatte neu gestartet.

Bei einer neuen Installation mit **Prefer Local Desktop** öffnet WinBoat den
nativen Viewer bereits bei **Installing Windows**. **Open Local Desktop** bleibt
im Installationsbildschirm verfügbar, auch wenn Windows-OOBE oder AME noch auf
Eingaben wartet. Der Windows-Gastdienst muss dafür noch nicht erreichbar sein.
Vor dem Start der Windows-Konsole bleibt die Schaltfläche deaktiviert.

Der Viewer entdeckt alle grafischen QEMU-Konsolen auf Monitor 0. Die Abfragen
und die Anmeldung der Listener laufen asynchron, damit QEMU während des
Verbindungsaufbaus auf den Viewer zugreifen kann, ohne das Fenster zu blockieren.
Während Setup zeigt er den Installations-VGA; sobald die Helios-GPU Bildupdates liefert,
wechselt er zu deren Konsole. Maus, Tastatur und Auflösungsanfragen folgen
dieser Auswahl. Späte VGA-Updates überschreiben das Helios-Bild nicht.
Bei einem Treiberneustart kann er vorübergehend auf eine noch aktive Konsole
zurückfallen und danach wieder zur Helios-Ausgabe wechseln. Dafür muss weder
der Basic Display Adapter manuell deaktiviert noch die VM neu erstellt werden.

### Bereits unvollständig installierter Helios-Treiber

Zuerst WinBoat einschließlich Viewer und Gastdienst aktualisieren. Für einen
bestehenden Gast kann `python3 scripts/atlas/diagnose-vm.py --update-guest` die
aktuellen Gastskripte und den neu gebauten Gastdienst übertragen.
Danach in einer **administrativen Windows-PowerShell** die automatische
Installation einmal anstoßen, sofern der ausgewählte OEM-Installer unter
`C:\Program Files\WinBoat\helios` vorhanden ist:

```powershell
& 'C:\Program Files\WinBoat\scripts\Start-HeliosProvisioning.ps1' -BundlePath 'C:\Program Files\WinBoat\helios'
```

Der Worker prüft das Paket und übernimmt die Test-Signing- und Treiber-Neustarts.
Exitcode 3010 ist eine Neustartanforderung und bestätigt allein keine fertige
Treiberinstallation. Erst der bestätigte Abschluss mit passender installierter
Revision beendet die Einrichtung. Der Basic Display Adapter kann währenddessen
aktiv bleiben; die Anzeige folgt automatisch der Helios-Konsole.

**Open Local Desktop** steht auch direkt in Einstellungen und Einrichtung zur
Verfügung. Der Verbindungsstatus zeigt Start, Verbindung und Fehler an; bei
Viewer-Fehlern zeigt WinBoat den Fehler und den Weg zum Browser-Modus an. Mehrfaches Öffnen während des
Starts erzeugt nur einen Viewer. Normales Schließen beendet nur das Fenster.
Beim Stoppen der VM wird der Viewer absichtlich beendet, ohne einen Browser zu öffnen.

Das native Fenster bietet außerdem **Fullscreen**, **Ctrl+Alt+Del** und einen
Hinweis, solange kein Windows-Bild empfangen wird. Gehaltene Tasten/Maustasten
werden beim normalen Schließen und beim Stoppsignal freigegeben. Anzeige und
Windows-Anmeldung sind unabhängig: Ein fehlender Windows-Benutzer oder eine
blockierte AME-OOBE wird durch den Wechsel des Anzeigefensters nicht repariert.

Die Einstellung prüft Viewer-Version und Image-Fähigkeitslabel `dbus-v6`.
Ein älteres Host-Image muss neu gebaut werden. Schlägt die Viewer-Anmeldung oder
Frame-Übernahme fehl, meldet WinBoat den Fehler und bietet einen erneuten
Verbindungsversuch. Ein laufender nativer GL-Modus besitzt keinen VNC-Listener.
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
vermeidet CPU-Readback für seinen DMA-BUF-Pfad. Dass auch QEMU/Renderer keine weiteren Kopien durchführen, ist damit nicht
nachgewiesen. VNC wird ausschließlich im separaten Browser-Modus verwendet. Statistiken auf stderr unterscheiden `dmabufFrames`,
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

WinBoat prüft zunächst Desktop-OpenGL 3.3. Meldet der NVIDIA-Kontext keinen
externen EGL-Bildsampler, prüft es zusätzlich OpenGL ES 3.0. GLES wird gewählt,
wenn sein externer Shader kompiliert und derselbe GL-Renderer gemeldet wird;
ein Wechsel auf einen anderen Renderer wie llvmpipe wird dabei abgelehnt.
Scheitert Desktop-GL vollständig, kann ein erfolgreicher GLES-Test es ersetzen.
Die Auswahl gilt vor der GTK-Initialisierung auch für den gemeinsamen
Display-Kontext. Die nötigen GTK-Schalter setzt nur der Viewer-Prozess;
unabhängige Diagnoseoptionen bleiben erhalten.
Die AppImage lässt sich direkt mit `./dist/winboat-0.8.7-x86_64.AppImage`
starten; `GDK_DEBUG=gl-disable-gles` ist dafür nicht erforderlich.
DMA-BUF-Bilder übernehmen QEMUs Bildausrichtung, ohne zusätzliche Drehung
oder Spiegelung. Der Software-Bildpfad behält seine eigene Zeilenorientierung.

`bash tests/helios-viewer-render.sh` prüft die tatsächlichen GL-Shader mit
Mesa/Xvfb ohne `GDK_DEBUG`: alle vier Bildecken, beide DMA-BUF-Ausrichtungen,
einen Ausschnitt aus einer größeren Textur und den Software-Bildpfad.
Zusätzlich startet er den echten Viewer an einem privaten D-Bus-Testserver mit
VGA- und virtio-Konsole. Der Server wartet vor weiteren Abfragen auf die
Listener-Anmeldung, um eine gegenseitige Blockade beim Start zu erkennen.
Der Test prüft den Wechsel zur Helios-Ausgabe, das Aus- und
Einschalten der Konsolen, Auflösungsanfragen an die ausgewählte Konsole sowie
die sichtbaren Bildecken direkt auf dem X11-Bildschirm. Die Frames sind
synthetisch; das ersetzt keinen Windows-/GPU-Hardwaretest.
Dafür werden die Entwicklungsbibliotheken GTK4 und libepoxy sowie Xvfb und
xauth benötigt; der Test ist auch im Viewer-Smoke-Test enthalten.

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

### High guest CPU usage and repeated PowerShell processes

The guest `/rdp/status` endpoint uses the Windows Terminal Services API directly.
It does not start PowerShell or parse localized `qwinsta` output. Metrics read the
base CPU frequency once from the Windows registry. Renderer metrics and RDP polls
skip ticks while a request is pending and time out after five seconds. Updating
only the guest removes the RDP subprocess; rebuilding and opening the new AppImage
also activates the renderer polling guard.

If PowerShell still repeats after the guest update, identify the script names
before stopping tasks. Atlas/Helios provisioning tasks may still be completing an
installation or a required reboot. Do not terminate every PowerShell process or
remove all startup tasks. The CPU reduction must be measured in the Windows VM;
a successful cross-build does not establish its runtime CPU usage.

### D-Bus GL und VNC

Ab `dbus-v4` startet der native Modus ausschließlich mit D-Bus/GL. Ein zusätzlicher
VNC-Listener wird dort nicht registriert: QEMUs D-Bus-GL-Kontext weist ihn mit
`Display vnc is incompatible with the GL context` zurück und beendet QEMU bereits
vor dem Windows-Start. Der Browser-Modus verwendet weiterhin EGL-headless mit
VNC/WebSocket und Helios. Der HTTP-Installationsstatus bleibt in beiden Modi aktiv.
Ein Wechsel des Modus startet den Container neu, ohne die Windows-Platte zu löschen.
Das Host-Image muss neu gebaut werden; ein Gastdienst-Update allein reicht nicht.

Der Regressionstest `tests/helios-gl-display.py` reproduziert mit dem echten
gepinnten QEMU und Mesa-Software-OpenGL zunächst den bisherigen Startfehler.
Danach prüft er erfolgreiche QMP-Antworten für D-Bus/GL ohne VNC und für
EGL-headless mit VNC. Er ist Teil von `test:helios:host`; der Null-Geräteknoten
ist ausschließlich eine Software-Testfixture. Diese Prüfung ersetzt keinen
DMA-BUF-/NVIDIA-Test mit einer physischen GPU.

Nach dem Neubauen verwendet ein bereits vorhandener Container weiterhin seine
alte Image-ID. Nach dem Start der neu gebauten WinBoat-Anwendung kann er mit
unveränderter Compose-Datei und denselben eingebundenen Windows-Daten neu erzeugt
werden:

```bash
docker compose -f "$HOME/.winboat/docker-compose.yml" up -d --force-recreate windows
```

Für den nativen Modus muss der private Display-Bus noch verfügbar sein. Die neue
WinBoat-Anwendung vor dem Containerstart auf derselben Desktop-Sitzung öffnen.

### GTK-OpenGL auf dem Host prüfen

Der native Viewer benötigt einen GTK-OpenGL-3.3-Kontext in der tatsächlichen
X11-/Wayland-Sitzung. `glxinfo -B` bestätigt unter X11 nur den GLX-Pfad und reicht
allein nicht als GTK-/EGL-Nachweis. Vor der Auswahl des nativen Transports startet
WinBoat deshalb `winboat-helios-viewer --check-gl` ohne Verbindung zur VM. Bei einem
Fehler wird vor der Einrichtung Browser Display gewählt; die gespeicherte
Local-Desktop-Präferenz bleibt für einen späteren Versuch erhalten.

Für Viewer und GL-Prüfung werden Bibliotheks-/Modulpfade innerhalb der AppImage
entfernt. Electron bringt eigene EGL-Bibliotheken mit, die beim Start eines
externen GTK-Prozesses nicht die Host-NVIDIA-/Mesa-Bibliotheken verdrängen dürfen.
Host-Bibliothekspfade, NVIDIA-EGL-Konfiguration, X11-/Wayland-Zugangsdaten und
explizite GDK-Einstellungen bleiben erhalten. Es wird kein Software-Rendering
erzwungen. Ein erfolgreicher Software-Test ersetzt weiterhin keinen Test mit
der physischen Host-GPU.

Diese Änderung benötigt nur eine neu gebaute Linux-Anwendung einschließlich des
nativen Viewers. Das Host-Image mit `dbus-v6` und die Windows-Installation müssen
dafür nicht ersetzt werden.

Wenn der neue Viewer weiterhin keinen GL-Kontext erstellen kann, liefert
folgender Befehl eine Host-Diagnose ohne weiteren Build und ohne VM-Änderung:

```bash
python3 scripts/helios/diagnose-local-display.py
```

Das Skript extrahiert nur den Viewer aus der zuletzt gebauten AppImage in `dist/`
in ein temporäres Verzeichnis und führt dessen GL-Prüfung außerhalb von Electron
aus. Es zeigt die Host-GTK-Version und prüft nur EGL-/GLX-Schalter, die diese
GTK-Version selbst anbietet. Die zusätzliche Cairo-Probe ändert ausschließlich
den Fenster-Compositor des Prüfprozesses; die GL-Fläche benötigt weiterhin
OpenGL. Diese Varianten sind Diagnosen, keine dauerhaft angewendeten Workarounds.
Für eine bestimmte AppImage gibt es `--appimage /pfad/zur/WinBoat.AppImage`.
Die VM kann während dieser Diagnose weiterlaufen; Passwörter und vollständige
Umgebungsvariablen werden nicht ausgegeben.

### QEMU-Abbruch beim Start des Windows-Installers

`dbus_scanout_texture: Assertion tex_id failed` stammt aus dem Host-QEMU.
Der D-Bus-Patch in `dbus-v5` bindet für Software-Oberflächen und ihren
Textur-Export den EGL-Anzeigekontext und stellt danach den vorherigen Kontext
wieder her. Oberflächen ohne GL-Textur erhalten eine vollständige Software-
Bildausgabe und Software-Updates. Beim Bildschirmwechsel verwirft QEMU alte
GL-Änderungsregionen, damit sie nicht die neue Software-Oberfläche betreffen.

Dafür das **Host-Image neu bauen**, einschließlich der QEMU-Patches:

```bash
./scripts/build-helios.sh
```

`--skip-host` und der Austausch allein des AppImages reichen für diesen
QEMU-Fix nicht. Das neue AppImage verlangt das Host-Label `dbus-v6`, sodass
ein altes Image vor dem nächsten lokalen VM-Start erkannt wird. Danach die
bestehende VM mit dem neuen Image erneut starten; die Windows-Festplatte
muss dafür nicht gelöscht werden.

`npm run test:helios:qemu-dbus` prüft beide Host-Patches gegen die gepinnten,
SHA-256-geprüften QEMU-Dateien und führt die betroffenen Funktionen mit
Mesa/EGL aus. Es benötigt Git, einen C-Compiler, pkg-config sowie die
Entwicklungspakete für GLib/GIO, libepoxy und pixman. Die ursprünglichen
Textur-Callbacks müssen im Regressionstest scheitern; die gepatchten Varianten
müssen mit und ohne pixman-Änderungsregionen bestehen. Windows und ein echter
DMA-BUF-Export über die physische GPU werden dadurch nicht getestet.

### Automatisches Öffnen, Wiederverbinden und VGA-Rückfall

Im lokalen Modus öffnet sich Local Desktop beim VM-Start und beim Erkennen einer
bereits laufenden VM. Die Windows-Installation startet denselben automatischen
Verbindungsaufbau, ohne auf den Gastdienst oder eine RDP-Sitzung zu warten.
Solange die VM läuft, werden Startfehler und unerwartete Viewer-Abbrüche mit
1 bis höchstens 10 Sekunden Abstand erneut versucht. Gleichzeitige Öffnungen
erzeugen nur ein Fenster. Ein absichtlich geschlossenes Fenster bleibt bis zum
nächsten VM-Start oder einem manuellen Öffnen geschlossen. Stoppen der VM beendet
Viewer und ausstehende Wiederverbindungen; eine Pause lässt das Fenster stehen.

Das Host-Image `dbus-v6` behält im lokalen Modus VGA auch nach abgeschlossener
Treiberinstallation bei. Bei `Disable`, fehlerhaften Helios-Bildern oder einem
verlorenen Adapter-Listener wechselt der Viewer zur verfügbaren VGA-Ausgabe.
Ein verlorener Listener wird im bestehenden Fenster erneut angemeldet. Sobald
Helios wieder gültige Scanout- und Update-Nachrichten liefert, wechselt das Bild
zurück. Die anderen Adapter-Listener bleiben währenddessen geöffnet.

Die VGA-Ausgabe muss in Windows aktiviert sein. Ein stiller Treiberhänger ohne
Fehler- oder Disable-Nachricht lässt sich allein an ausbleibenden Bildern nicht
zuverlässig von einem unveränderten Desktop unterscheiden. Ein vollständiger
Windows-/QEMU-Absturz benötigt weiterhin einen VM-Neustart.

FreeRDP ist für Local Desktop und Browser Display optional. Es startet erst bei
Nutzung einer RemoteApp oder eines RDP-Desktops. **RDP Monitoring** bleibt
standardmäßig ausgeschaltet. Der lokale Viewer startet keine RDP-Sitzung.

Für `dbus-v6` Host-Image und Anwendung über `./scripts/build-helios.sh`
aktualisieren und die bestehende VM neu starten, damit VGA wieder angehängt ist.
Eine ausdrücklich gesetzte `HELIOS_BOOTSTRAP_DISPLAY=0` bleibt ein Opt-out;
damit ist kein separater VGA-Rückfall möglich.

### Automatische Treiberwahl und Wiederherstellung

Der Guest Server überwacht die tatsächlichen Windows-PnP-Zustände von
`helios_kmd_render` auf der virtio-GPU und `BasicDisplay` auf WinBoats separater
QEMU-VGA. `GET /graphics/adapters` liefert beide Zustände und das Alter der
Messung. Der Viewer bevorzugt eine laufende Helios-Konsole auch bei einem
statischen Desktop ohne nachfolgendes Update. Die QEMU-Gerätenamen
`heliosgpu` und `helios-bootstrap` werden dabei unterschieden.

Bei einem Helios-Ausfall fällt dasselbe Viewer-Fenster auf die verfügbare VGA
zurück. Ist auch VGA deaktiviert, aktiviert die Guest API diesen Adapter;
bei einem PnP-Fehler startet sie ausschließlich diesen Adapter neu. Sie lässt
VGA in Ruhe, solange Helios läuft und gültige Bilder liefert, deaktiviert keine Adapter und führt für
solche Wiederherstellungen keinen Windows-Neustart aus. Erneute
Wiederherstellungsversuche sind auf einen Versuch pro 30 Sekunden begrenzt.
Nach einem neuen gültigen Helios-Bild und bestätigtem Treiberzustand wechselt
der Viewer zurück. Veraltete oder fehlende API-Daten gelten als unbekannt,
nicht als Treiberausfall. Die Altersprüfung verwendet keine synchronisierten
Gast-/Host-Uhren.

Vor der automatischen Helios-Installation prüft WinBoat den Testmodus im
laufenden Windows-Kernel. Falls nötig, aktiviert es `testsigning` für den
aktuellen Boot-Eintrag und startet Windows vor der Treiberinstallation neu.
Ein weiterer Neustart lädt den installierten Treiber. Beide Neustarts sind
begrenzt; eine Secure-Boot-Sperre wird als Fehler gemeldet. Atlas/AME muss
seine Installation und den eigenen Neustart vorher abgeschlossen haben.
Der Guest Server stellt fehlende oder veraltete Installationsaufgaben beim
Start wieder her, sofern Helios für diese VM ausgewählt wurde.

Die App aktualisiert ältere Guest APIs anhand der Kennung
`graphics_protocol=helios-watchdog-v2`, auch wenn beide noch Version `0.8.7`
melden. Für diese Änderung sind die neue AppImage und ihr Guest-API-Update
nötig. Die bestehende VM muss den separaten VGA-Adapter behalten (Host-Protokoll
`dbus-v6`). Ein vollständig abgestürztes Windows kann seine Guest API nicht
mehr ausführen; die Überwachung ersetzt daher keinen VM-Neustart nach einem
Bluescreen. PnP-Status und Viewer-Framefehler erkennen außerdem keinen beliebigen
GPU-Hänger, bei dem Windows den Treiber weiterhin als fehlerfrei meldet.

### Bildfehler beim Wechsel des Adapters

Der Viewer verwendet die vorab geprüfte GL-/GLES-API über **EGL**, auch unter X11.
Ein GLX-Kontext kann OpenGL anzeigen, aber keine EGL-DMA-BUFs importieren. Die
Vorprüfung kontrolliert deshalb zusätzlich den tatsächlichen EGL-Kontext.
Manuelle `GDK_DEBUG`-Optionen sind dafür nicht nötig.

Beim Import prüft der Viewer Texturaufbau und EGL-Bildbindung getrennt. Alte
Fehler im gemeinsam genutzten GTK-GL-Kontext werden vor der Bindung ausgelesen,
damit ein gültiges Bild nicht wegen eines fremden Fehlers verworfen wird.
Unterstützt der Treiber externe EGL-Texturen, versucht der Viewer bei einer
inkompatiblen 2D-Bindung zusätzlich `GL_TEXTURE_EXTERNAL_OES` mit dem passenden
Sampler. Die anschließende GPU-Kopie und die Adapterpriorität bleiben gleich.
Scheitern beide Wege, enthält die Meldung die tatsächlichen GL-Fehlercodes,
Format, Modifier, Ebenenzahl und den GL-Renderer.

Der Mesa/Xvfb-Test prüft eine echte EGLImage-Bindung, absichtlich hinterlassene
GL-Fehler und die vier Bildecken nach der GPU-Kopie. Der externe Sampler wird
nur getestet, wenn der GL-Kontext die Erweiterung anbietet; andernfalls meldet
der Test diesen Teil ausdrücklich als übersprungen. Ein erfolgreicher
Softwaretest belegt keinen Import eines DMA-BUFs von einer physischen GPU.

Viewer 7 versucht nach abgelehnten Texturbindungen außerdem
`glEGLImageTargetRenderbufferStorageOES`. Ist das Bild als Renderbuffer nutzbar
und sein Lese-Framebuffer vollständig, kopiert `glBlitFramebuffer` den Ausschnitt
mit der passenden Bildausrichtung in den vorhandenen Präsentationspuffer. Die
Kopie bleibt auf der GPU; auch hier wird QEMU erst nach Abschluss der Lesezugriffe
bestätigt. Der implizite Modifier `DRM_FORMAT_MOD_INVALID` wird dabei weiterhin
unverändert behandelt und niemals als lineares Layout ausgelegt.

Der Grafiktest erzwingt den gemeldeten 2D-Bindefehler `GL_INVALID_OPERATION`,
übernimmt anschließend ein echtes EGLImage als Renderbuffer und prüft beide
Ausrichtungen, Ausschnitte, wiederholte Updates, Framebuffer-Wiederherstellung
und Freigabe der Quellobjekte. Das validiert den Ausweichpfad mit Mesa, ersetzt
aber keinen Test mit dem NVIDIA-DMA-BUF des betroffenen Rechners. Scheitert auch
der Renderbuffer-Import, enthält die Meldung dessen eigenen Fehlercode.
Shader-Fehler werden im Terminal ausgegeben; `--check-gl` zeigt zusätzlich die
vorhandenen EGL-/GL-Importerweiterungen an.

Viewer 8 bietet eigene GLSL-ES-3.00-Shader mit
`GL_OES_EGL_image_external_essl3` und `samplerExternalOES`. Die GLES-Auswahl
erfolgt in WinBoat automatisch anhand der Vorabprüfung. Ein manueller
Diagnoseaufruf ist mit `WINBOAT_HELIOS_GL_API=gles winboat-helios-viewer --check-gl`
möglich. Software-Bilder des Basic Display Adapters werden ebenfalls unter
GLES unterstützt, einschließlich BGRA-Farbkanälen, Zeilenpadding und Screenshots.
Die Tests führen die tatsächlichen Shader, EGLImage-Bindungen, GPU-Kopien und
Adapterwechsel sowohl mit Desktop-GL als auch GLES aus. Ein simulierter
`GL_INVALID_OPERATION` bei der 2D-Bindung muss unter GLES über den echten
externen EGL-Sampler ein korrektes Bild liefern.

Meldet die Guest API einen zuvor deaktivierten/fehlgeschlagenen Adapter wieder
als verfügbar, fordert der Viewer für ihn einen vollständigen neuen Scanout
an, sofern noch kein gültiger neuer Puffer vorliegt. Der alte Backoff wird dabei
zurückgesetzt. Partielle Updates einer verworfenen Quelle bleiben gesperrt;
ein frischer Helios-Puffer erhält wieder Vorrang vor Basic. Derselbe Mechanismus
gilt für die Wiederherstellung des Basic-Adapters. Fenster und anderer Listener
bleiben bestehen.

Nach einem ungültigen Scanout/Update meldet sich nur die betroffene Konsole mit
begrenzter Wiederholungsrate erneut bei QEMU an. QEMU liefert dadurch wieder
einen vollständigen Scanout. Updates, die noch zur verworfenen Bildquelle
gehören, werden bis dahin ohne Zugriff auf deren Speicher verworfen und
bestätigt. Das Fenster und die andere Konsole bleiben geöffnet. Fehlerhafte
Cursor-Metadaten verwerfen keinen gültigen Desktop mehr.

Der ursprüngliche Fehlergrund (einschließlich EGL-Fehlercode, Format und
Modifier bei einem Importfehler) erscheint in WinBoat während der
Wiederherstellung und in der Terminal-Ausgabe. Sobald wieder ein gültiges Bild
vorliegt, verschwindet die Wiederherstellungsmeldung. Damit werden dauerhafte
GPU-/Importprobleme sichtbar, statt sie als allgemeines Umschaltproblem zu
melden.

Wenn Windows Helios weiterhin als `running` meldet, der Viewer aber keine
gültigen Helios-Bilder verarbeiten kann, meldet er dies ausdrücklich mit
`POST /graphics/adapters/recovery` und dem Header
`X-WinBoat-Recovery: display-fallback`. Die Guest API darf dann die deaktivierte
VGA auch bei fehlerfreiem PnP-Status wieder aktivieren. Nach einem gültigen
Helios-Bild hebt `display-ready` diesen zeitlich begrenzten Hinweis wieder auf.
Die API akzeptiert dabei keine Geräte-IDs oder Befehle aus der Anfrage; der
Watchdog bearbeitet ausschließlich den erkannten Bootstrap-VGA-Adapter.

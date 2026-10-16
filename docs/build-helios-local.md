# WinBoat und Helios lokal bauen

Der gemeinsame Einstieg ist `scripts/build-helios.sh`. Es baut auf deinem
Linux-Host mit Docker beide Komponenten: das Helios-VM-Image und WinBoat samt
Windows-Treiberinstaller. Node.js, Go, Rust und Compiler müssen dafür nicht auf
dem Host installiert sein. Die Linux-Anwendung startest du anschließend auf
deinem Desktop; der Build-Container ist kein Desktop- oder VM-Container.

## Voraussetzungen

- Linux x86_64, Bash, Git, Coreutils und Internetzugang.
- Docker Engine mit zugänglichem Daemon, Compose v2 und Buildx.
- Mindestens 20 GB freier Platz im Docker-Speicher, zusätzlich Platz für Pakete.
  Für die Compiler empfehlen wir mindestens 8 GB RAM und 4 CPU-Kerne.
  Docker mit dem Speicher-Treiber `vfs` benötigt wegen vollständiger Layer-Kopien
  deutlich mehr Platz als die üblichen Overlay-Treiber.
- Für das spätere Ausführen: Linux 6.13+, KVM, Vulkan 1.3 und ein zugängliches
  `/dev/dri/renderD*`. NVIDIA benötigt zusätzlich den zum Hosttreiber passenden
  NVIDIA Container Toolkit mit eingerichtetem Docker-Runtime `nvidia`.

Installiere Docker Engine, Compose und Buildx nach der offiziellen Anleitung für
deine Distribution: <https://docs.docker.com/engine/install/>. Unter Debian/Ubuntu
mit bereits eingerichtetem offiziellen Docker-Paketrepository beispielsweise:

```bash
sudo apt-get update
sudo apt-get install git docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
docker info
docker compose version
docker buildx version
```

Der Build installiert keine Host-Grafiktreiber, ändert keine Gruppen oder
Docker-Konfiguration und startet keine Windows-VM. Verwende einen Benutzer,
der bereits Zugriff auf Docker hat; starte das gesamte Skript nicht mit sudo.
Docker Desktop, Podman und rootless Docker werden von WinBoat nicht unterstützt.

## Ein Aufruf für beide Builds

```bash
git clone --branch work https://github.com/tobyw121/winboat.git
cd winboat
./scripts/build-helios.sh
```

Der Standardablauf:

1. Docker und Plugins prüfen.
2. Helios aus `helios/upstream/` und den festgelegten Abhängigkeiten kompilieren.
3. Image-Identität und QEMU-Steuerung mit gemeinsamem memfd-Speicher prüfen.
4. Den vorhandenen Windows-Installer unter `resources/helios/` prüfen oder den
   festgelegten Upstream-Installer mit SHA-256-Prüfung herunterladen.
5. WinBoat-Tests, Gaststatus-Tests und Vue-Typprüfung ausführen.
6. Windows-Gastserver und Linux-AppImage bauen und nach `dist/` exportieren.

Der Build enthält auch den optionalen nativen Helios-Viewer. Für dessen Ausführung
benötigt der Desktop GTK4 4.8+, libepoxy und dbus-daemon; siehe
[lokaler Helios-Desktop](helios-local-display.md). Die Standardanzeige bleibt noVNC.

Die Compiler laufen in Build-Containern ohne Docker-Socket-Mount und ohne
`--privileged`. Das fertige Image `winboat/helios:d82ce565ac79` wird in den
angesprochenen Host-Daemon geladen. WinBoat muss später denselben Daemon nutzen.

Für sämtliche Paketformate und ein übertragbares Host-Image:

```bash
HELIOS_BUILD_JOBS=4 ./scripts/build-helios.sh --all-packages --export-host-image
```

Das erzeugt AppImage, DEB, RPM und tar.gz sowie `HeliosSetup.exe`,
`helios-build.json`, `BUILD-INFO.json` und `SHA256SUMS` unter `dist/`.
Ein vorhandenes Image lässt sich bei reinen WinBoat-Änderungen wiederverwenden:

```bash
./scripts/build-helios.sh --skip-host
```

Diese Option prüft weiterhin Image-Revision, Display-Protokoll und QEMU, baut aber Änderungen
an `helios/host/` nicht ein. Nach Host-Änderungen immer ohne `--skip-host` bauen.
Ergebnisse werden erst nach erfolgreichem Build und Prüfsummenprüfung übernommen.
Ältere Pakete in `dist/` bleiben erhalten; `SHA256SUMS` gehört zum letzten Lauf.

## Windows-Installer aus einem eigenen Build

```bash
./scripts/build-helios.sh --installer-dir /pfad/zum/entpackten/windows-artefakt
```

Der Ordner muss `HeliosSetup.exe` und seine zugehörige `helios-build.json`
enthalten. Revision, Datei- und eingebettete Payload-Prüfsummen werden geprüft.
Ein ungültiger oder unvollständiger lokaler Installer führt zum Abbruch.

Falls das festgelegte GitHub-Actions-Artefakt abgelaufen ist oder sein Download
eine Anmeldung verlangt, nutze diesen Weg mit dem Artefakt des Workflows
**Build WinBoat Helios Windows installer** im eigenen Repository. Der native
Windows-Treiberbau benötigt Windows/MSVC/WDK; er wird nicht durch den Linux-
Docker-Build ersetzt. Die Quellen für Treiber, UMDs und Installer liegen trotzdem
mit WinBoat unter `helios/upstream/` im selben Repository. Der bestehende
Windows-Workflow verwendet weiterhin den kompatiblen, festgelegten Guest-Commit.

## Gemeinsame Quellen und Dockerfile

`helios/upstream/` enthält die 611 Originaldateien des festgelegten Helios-
Quellstands. `helios/source.lock.json` erfasst Herkunft, Commit, Git-Tree,
Dateiprüfsummen und die sieben ursprünglichen Dependency-Gitlinks. Helios selbst
ist kein Git-Submodul und benötigt keinen zweiten Checkout. Externe Projekte wie
QEMU, Mesa, Venus-Protokoll und virglrenderer werden während des Builds anhand
dieser Gitlinks heruntergeladen. Ein vollständig offline ausführbarer Build
benötigt darüber hinaus vorab gefüllte Docker- und Dependency-Caches.

Das Root-`Dockerfile` baut WinBoat und exportiert ausschließlich fertige Dateien:

```bash
docker buildx build --platform linux/amd64 --target artifacts \
  --build-arg WINBOAT_BUILD_COMMIT="$(git rev-parse --short=12 HEAD)" \
  --output type=local,dest=dist .
```

Das Helios-Host-Dockerfile liegt unter `helios/host/Dockerfile`. Das Bash-Skript
koordiniert beide Dockerfiles, sodass ein einzelner Aufruf genügt. Basis-Images,
Helios-Quellen und Windows-Artefakte sind festgelegt; Debian-Pakete werden aus den
aktuellen Paketquellen bezogen. Builds sind dadurch nicht bitidentisch.

## Proxy und Zertifikate

Docker kann seine normalen Proxy-Buildargumente weiterreichen. Falls dein Proxy
eine zusätzliche vertrauenswürdige CA benötigt, übergib eine PEM-Datei mit dem
vollständigen CA-Bundle:

```bash
HELIOS_PROXY_CA=/pfad/zu/ca-bundle.pem ./scripts/build-helios.sh
```

Das Bundle wird nur als BuildKit-Secret gemountet. TLS- und Artefaktprüfungen
bleiben aktiv; Zertifikate oder Zugangsdaten werden nicht ins Image kopiert.

## Starten und prüfen

```bash
cd dist
sha256sum -c SHA256SUMS
chmod +x winboat-*-x86_64.AppImage
./winboat-0.8.7-x86_64.AppImage
```

Auf einem anderen Rechner zuerst das optional exportierte Host-Image importieren:

```bash
docker load -i winboat-helios-host-d82ce565ac79.tar.gz
```

Bei einer neuen VM Helios wählen; WinBoat übernimmt die Treiberinstallation.
Bestehende VMs nach der [Migrationsanleitung](helios.md#existing-vms-and-rollback)
umstellen und vorher die Windows-Disk sichern.

Die Treiber sind test-signiert und benötigen deaktiviertes Secure Boot in der
VM. Helios ist experimentell. Ein bestandener Build oder QEMU-Test bestätigt
keine GPU-Beschleunigung, Windows-Treiberinstallation oder Spielekompatibilität.
Diese müssen auf dem Zielrechner geprüft werden. Die aktuelle Bildausgabe ist
noVNC; Details stehen in [helios.md](helios.md).

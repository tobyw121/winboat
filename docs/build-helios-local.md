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
4. Den vollständig im Git-Repository enthaltenen Windows-Installer unter
   `resources/helios/` gegen Receipt und festgelegte SHA-256-Prüfsumme prüfen.
5. WinBoat-Tests, Gaststatus-Tests und Vue-Typprüfung ausführen.
6. Windows-Gastserver und Linux-AppImage bauen und nach `dist/` exportieren.

`HeliosSetup.exe` und `helios-build.json` werden mit WinBoat geklont. Für den
Installer werden weder GitHub-Token noch Actions-Artefakt-Download benötigt.
Die Compiler laden weiterhin ihre festgelegten externen Abhängigkeiten; der
Gesamtbuild ist deshalb nicht vollständig offline.

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

## Windows-Installer aus den eingebetteten Quellen neu bauen

Der vollständige Installer und seine Treiber werden durch WinBoats eigenen
Workflow `.github/workflows/build-helios-windows.yml` gebaut. Alle Helios-
Eigenquellen stammen aus `helios/upstream/` dieses Checkouts. Der Workflow klont
kein separates Helios-Repository. MSVC-/WDK-Builds laufen weiterhin auf Windows.

Ein neues, geprüftes Paket aus diesem Workflow wird ausdrücklich übernommen:

```bash
npm run helios:adopt-installer -- /pfad/zum/entpackten/winboat-windows-artefakt
```

Das aktualisiert `resources/helios/HeliosSetup.exe`, die zugehörige Receipt und
`helios/stack.lock.json`. Diese drei Dateien gemeinsam prüfen und committen.
Der Import prüft Repository, WinBoat-Commit, Quellen-Snapshot, Quellen-Lockhash,
Gastkompatibilität und das vollständige Installer-Format samt Payload-Prüfsumme.

Danach genügt wieder:

```bash
./scripts/build-helios.sh --skip-host
```

`--installer-dir /pfad/zum/paket` bleibt für ein externes Arbeitsverzeichnis mit
**dem bereits festgelegten Paket** verfügbar. Ein Paket mit neuer Prüfsumme muss
zuerst ausdrücklich übernommen werden. Ein beschädigter oder fehlender Installer
führt zum Abbruch; der Build ersetzt ihn nicht durch einen Download.

Details, Herkunft des mitgelieferten Pakets und lokale Windows-Voraussetzungen:
[Windows-Treiber und Installer bauen](helios-windows-build.md).

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
Helios-Quellen und Windows-Installer sind festgelegt und mitgeliefert; Debian-Pakete werden aus den
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
Diese müssen auf dem Zielrechner geprüft werden. Die Standard-Bildausgabe ist
noVNC; ein optionaler lokaler Viewer ist ebenfalls enthalten. Details stehen in
[helios.md](helios.md).

# Windows-Treiber und Helios-Installer in WinBoat

Der vollständige Installer gehört zu diesem Repository:

- `helios/upstream/installer/`: Rust-Oberfläche, CLI und Payload-Container;
- `helios/upstream/packaging/windows/`: Installieren, Prüfen und Deinstallieren;
- `helios/upstream/ci/windows/`: native Komponenten bauen, signieren und bündeln;
- `resources/helios/HeliosSetup.exe` und `helios-build.json`: vollständiges,
  mit Git geklontes Installationspaket mit Herkunft und Prüfsumme;
- `.github/workflows/build-helios-windows.yml`: WinBoats eigener Windows-Build.

Der normale Linux-Build nutzt das mitgelieferte Paket. Er benötigt dafür keinen
GitHub-Token und greift nicht auf ablaufende Upstream-Actions-Artefakte zu.

## Herkunft und Versionsidentität

Das aktuelle Paket **22.22.291.0** wurde von WinBoats Windows-CI gebaut,
test-signiert und anschließend anhand des Artefakt-Digests, der EXE-Prüfsumme,
des eingebetteten Manifests und der Herkunftsreceipt übernommen. Es enthält die
WinBoat-Korrektur für D3D11-UAV-ClearView und die dynamische VidPn-Modusauswahl. Der zugehörige Build ist
[39151081085](https://github.com/tobyw121/winboat/actions/runs/39151081085)
auf WinBoat-Commit `4e2ee56a8088391838a3f1e1a8ce408faef64576`.

Das frühere Startpaket war ein unveränderter Upstream-Installer für Gast-Commit
`fecffde6`. Dieser Wert bleibt die ABI-/Stack-Kompatibilitätsidentität und ist
keine Behauptung, dass die aktuellen Quellen unverändert vom Upstream stammen.

Die eingebetteten Eigenquellen stammen aus dem Host-Snapshot `d82ce565`.
Installer, Windows-Buildskripte, Packaging, Metadaten, Werkzeuge sowie die
Gast-/Transportbäume sind zwischen beiden Commits identisch. Ihre gemeinsamen
Tree-/Dependency-IDs stehen in `sharedSources`. Deshalb bleibt `guestRevision`
die gemeinsame Gast-Kompatibilitätsidentität. Ein eigener CI-Build zeichnet
zusätzlich **den tatsächlichen WinBoat-Commit**, das Repository, den Snapshot
und dessen Lockdatei-Hash auf. Diese Angaben werden nicht gleichgesetzt.

Der aktuelle Quellstand enthält
zusätzlich die in `source.lock.json.localChanges` dokumentierten WinBoat-
Änderungen; die ursprünglichen Tree-IDs beschreiben deren Upstream-Basis.
Die Dateihashes und `sourceLockSha256` identifizieren die tatsächlich gebauten
Quellen einschließlich dieser Änderungen. Der Quellstand ist 22.22.291.0;
der mitgelieferte Installer wurde nach bestandenem Vollbuild auf diesen Stand
aktualisiert. Details: [Spielekompatibilität](helios-game-compatibility.md) und
[Auflösungswechsel im laufenden Windows](helios-display-modes.md).

## Vollständiger CI-Build

Der Workflow läuft bei relevanten Pushes auf `work`. Er ist außerdem für
`workflow_dispatch` vorbereitet; GitHub bietet den manuellen Start erst an,
wenn die Workflowdatei auch im Standardbranch liegt.

Die Jobs bauen separat:

1. WDDM-Miniport und D3D11-/D3D12-UMDs für x64 und WoW64;
2. Mesa Venus/Zink für x64 und x86;
3. CLVK/OpenCL mit eingebettetem Compiler;
4. Khronos-Loader und passende Prüfprogramme;
5. Kompatibilitäts-Shims;
6. Rust-Installer, Testsignierung und vollständigen selbstentpackenden Container.

Alle Jobs checken WinBoat aus. `Initialize-Sources.ps1` prüft sämtliche 611
eingebetteten Dateien und bereitet `temp/helios-windows` vor. Nur externe
Bibliotheken werden anhand ihrer festgelegten Dependency-Commits geholt. Der
ursprüngliche Snapshot wird durch Git-Checkouts und Compiler-Ausgaben nicht
verändert. CLVK-/Khronos- und Werkzeugversionen sind im Workflow festgelegt.

Der Paketjob exportiert das Artefakt `helios-windows-x64-…-Release` mit einer
vollständigen `HeliosSetup.exe` und `helios-build.json`. Er überschreibt keine
Repository-Dateien und veröffentlicht keinen Release. Die Entscheidung, einen
neuen Installer zu übernehmen, bleibt ein eigener überprüfbarer Schritt.

## Neues CI-Paket übernehmen

Das Artefakt aus einem vertrauenswürdigen WinBoat-CI-Lauf herunterladen und
entpacken. Beide losen Dateien im selben Verzeichnis lassen:

```bash
npm run helios:adopt-installer -- /pfad/zum/entpackten/artefakt
git diff -- helios/stack.lock.json resources/helios/helios-build.json
```

Der Import prüft das vollständige Format und den eingebetteten Container-Hash
sowie Repository, WinBoat-Commit, Workflow, Snapshot, Quellen-Lockhash und
Gast-Kompatibilität. Ein syntaktisch gültiger, aber fremder oder unpassender
Installer wird abgewiesen. Die Receipt selbst ist keine digitale Signatur;
verwende ausschließlich ein von dir geprüftes CI-Artefakt.

Diese drei Dateien gemeinsam prüfen und committen:

```bash
git add resources/helios/HeliosSetup.exe resources/helios/helios-build.json helios/stack.lock.json
```

Normale Paketbuilds und `electron-builder` erzwingen anschließend die neue
festgelegte EXE-Prüfsumme. Für einen Fork muss `installerBuild.repository` vor
dem CI-Build auf das eigene Repository gesetzt werden.

## Lokal unter Windows

Auf einer lokalen Windows-Platte arbeiten, beispielsweise `C:\src\winboat`.
Für den vollständigen Build werden Visual Studio 2022 mit C++-Tools, Windows
SDK/WDK, der festgelegte Rust-Nightly, LLVM, Vulkan SDK, Python/Meson/Ninja sowie
die MSYS2-Werkzeuge beider Architekturen benötigt. Die genauen Versionen und
Installationsschritte stehen im selben Workflow wie die CI-Befehle.

Die Quellen und Engine-Abhängigkeiten lassen sich lokal so vorbereiten:

```powershell
.\scripts\helios\windows\Initialize-Sources.ps1 -Component all
```

Die Build-Befehle aus dem Workflow anschließend mit
`-RepoRoot $env:HELIOS_SOURCE_ROOT` ausführen. Ein alleiniger Lauf von
`Build-Installer.ps1` erzeugt zunächst nur das Programmgerüst; das vollständige
Paket entsteht erst durch `Assemble-Package.ps1` mit allen Treiber-, Runtime-
und Loader-Artefakten. Ein Gerüst wird vom WinBoat-Paketbuild abgewiesen.

Die Integrationsprüfungen benötigen keinen WDK-Build:

```powershell
npm run test:helios:windows
```

Ein neuer nativer Windows-Build und Installation/Neustarts sind eigene Prüfungen.
Die mitgelieferten Treiber sind test-signiert; bestehende Einschränkungen für
Secure Boot, echte GPU-Tests und Spielekompatibilität bleiben bestehen.

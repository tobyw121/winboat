# Helios: Spielekompatibilität

## Installationskorrektur ab 22.22.293.0

22.22.292.0 konnte bei einer Erstinstallation oder einem älteren Installationsbeleg
nach dem erfolgreichen PnP-Schritt mit `The property 'classKey' cannot be found`
abbrechen. Ursache war ein leerer PowerShell-Wiederherstellungsdatensatz.
22.22.293.0 behandelt diesen Zustand korrekt; vorhandene Wiederherstellungswerte
bleiben bei einer Reparatur erhalten. Eine neue Windows-/Atlas-Installation ist
dafür nicht erforderlich. Nach einem fehlgeschlagenen Installations-/Deinstallationslauf
Windows zunächst neu starten und anschließend das korrigierte Paket installieren.

## Vulkan und native D3D-Abfragen ab Quellversion 22.22.292.0

Der mitgelieferte, in Windows-CI gebaute Installer 22.22.293.0 enthält diese
Änderungen und die Erstinstallationskorrektur. Ein AppImage-Neubau übernimmt
dieses Paket; eine vorhandene Windows-Installation benötigt anschließend die
Aktualisierung des Gasttreibers. Der Paketbuild ist kein Hardware-Erfolgsnachweis.

- Gastseitige Vulkan-WSI-/Speicher-Features werden vor dem Linux-Renderer aus
  dessen Gerätekette entfernt. Die vom Programm aktivierten Gast-Features
  bleiben erhalten; nicht unterstützte Funktionen werden weiterhin abgelehnt.
- Eine lokal abgelehnte Feature-Anforderung wird zusätzlich mit Prozess-ID und
  Feldnamen nach `%LOCALAPPDATA%\helios-vulkan-features.log` geschrieben.
  Ein vom Host abgelehntes Feature ist dadurch noch nicht automatisch lokalisiert.
- `runtime\smoke\vulkan-features.exe` prüft unter einer Vulkan-1.1-Instanz die
  gemeldeten Core-Feature-Gruppen bis zur tatsächlichen Geräteversion durch
  echte Geräteerstellung. Das ist kein vollständiger Vulkan-Konformitätstest.
- D3D11 fragt MSAA-Qualitäten einschließlich Tiled-Resource-Flags beim Backend
  ab. Der D3D-Smoke-Test versucht für gemeldete Kombinationen reale Texturen
  anzulegen; erfundene Sample-Unterstützung wird vermieden.
- x64 und x86 werden zusätzlich über `VulkanDriverName` und
  `VulkanDriverNameWow` am Windows-Adapter registriert. Reparatur erhält die
  ursprünglichen Sicherungen; Deinstallation bewahrt fremde Änderungen.
- Vulkan meldet `Helios vGPU (<Host-GPU>)` statt `Virtio-GPU Venus (...)`.
  Die virtuelle PCI-Identität und Mesa/Venus-Treiberkennung bleiben erhalten.
  NVIDIA-NVAPI, VBIOS und Sensoren werden nicht durch Umbenennen verfügbar;
  GPU-Z oder jedes beliebige Spiel kann daher nicht garantiert werden.

Weitere Diagnose und Regressionen:

- Frühe View-/Shader-Fehler melden den API-Fehler über den Laufzeit-Callback.
  Der neue Deskriptor-Guard verhindert Nullzugriffe bei View-/Sampler-Erstellung.
- `d3d11-smoke.exe` prüft Compute/UAV-Daten, Vertex-/Pixelshader, Tiefenprüfung
  und MSAA-Resolve durch exakten Daten-/Pixelvergleich. `--warp` ist nur die
  ausdrücklich ausgewählte Softwarekontrolle; ohne dieses Argument wird Helios
  verlangt. Der Test enthält den HLSL-Compiler, der Treiber selbst weiterhin nicht.
- Der aktualisierte Guest-Dienst ergänzt `/graphics/diagnostics` um feste
  API-Registrierungen, gefilterte Feature-Fehler, relevante Absturzfelder und
  ausgewählte geladene Grafik-DLLs. Es werden keine Befehle ausgeführt oder
  Passwörter, vollständigen Ereignismeldungen oder Prozessargumente ausgelesen.

Nach Aktualisierung des Guest-Dienstes genügt auf dem Linux-Host:

```bash
python3 scripts/helios/diagnose-graphics.py
```

Der Aufruf speichert einen Bericht unter `~/.winboat/diagnostics/` und benötigt
keine Zwischenablage in der VM. Er startet und stoppt die VM nicht. Fehlende
Teilinformationen bleiben als solche erkennbar; PID-basierte Feature-Logzeilen
können von einem früheren Prozess stammen.

Die beobachtete FurMark-Meldung `VK_ERROR_FEATURE_NOT_PRESENT (-8)` ist damit
noch kein nachweislich behobener FurMark-Fehler. Seine konkrete Feature-Anfrage
und Icarus müssen mit dem neu gebauten Treiber separat geprüft werden.

## Was geändert wurde

Der mitgelieferte Windows-Treiber 22.22.290.0 ergänzt `ClearView` für D3D11-UAVs.
Bisher wurden diese vorgeschriebenen Löschoperationen verworfen. Die neue
Weiterleitung erhält Rechtecke und verwendet den passenden Handle-Loader;
RTVs und UAVs haben unterschiedliche interne Speicherlayouts. Videoviews
bleiben ausdrücklich nicht unterstützt. Feature-Level und WDDM-Version werden
nicht künstlich angehoben. Die Abweichung vom Upstream-Snapshot ist mit
Original- und aktuellen Dateiprüfsummen in `helios/source.lock.json` dokumentiert.

`tests/helios-clear-view` kompiliert die tatsächliche geänderte DDI-Funktion
und führt sie unter Windows mit WARP aus: x86/x64, RTV/UAV, vollständige und
rechteckige Clears, leere Rechtecke, typisierte Buffer und pixelgenaue
Staging-Rücklesung. Geräte-/Handle-Auflösung und Diagnosezähler sind Fixtures.
Dies validiert weder einen geladenen Helios-Treiber noch Venus oder ein Spiel.
Der festgelegte [DXVK-Backendstand](https://github.com/winboat-org/dxvk/blob/6948271578bf2aa6481389a07b5070c95f911952/src/d3d11/d3d11_context.cpp)
unterstützt bereits `ClearImageView` und `ClearBufferView` für diese UAV-Aufrufe.
Der vollständige Windows-Build und der geprüfte Import sind abgeschlossen.
Ein Gasttest auf der tatsächlichen GPU bleibt ein eigener Prüfschritt.
`./scripts/build-helios.sh` baut die Windows-DLLs nicht: Es nutzt
die bereits eingebundene `resources/helios/HeliosSetup.exe`.

## Bestehende VM aktualisieren

Für eine vorhandene VM die neue `resources/helios/HeliosSetup.exe` nach Windows
kopieren, als Administrator ausführen und den angeforderten Neustart durchführen.
Die vorhandene Windows-Disk bleibt erhalten. Der Installer benötigt weiterhin
den Windows-Testsignierungsmodus. Die neu gebaute AppImage enthält dieses Paket
für die automatische Treibereinrichtung neuer Windows-Installationen.

Die zusätzlich mitgelieferten Spielwerkzeuge stehen nach Aktualisierung des
Guest Servers unter `C:\Program Files\WinBoat\scripts` bereit. Alternativ können
die beiden eigenständigen PowerShell-Skripte aus dem Checkout nach Windows
kopiert und dort ausgeführt werden.

## Prüfung mit dem tatsächlich installierten Helios-Treiber

Der Workflow „Test Helios game compatibility“ baut zusätzlich die Standalone-
Artefakte `helios-clearview-probe-x64` und `helios-clearview-probe-x86` aus
`tests/helios-game-clearview.cpp`. Die EXEs im angemeldeten Windows-Gast
starten. Der Probe wählt ausdrücklich den Helios-DXGI-Adapter und verweigert
einen WARP-/Basic-Ersatz. Er prüft vollständige und rechteckige RTV-/UAV-Clears
sowie typisierte Puffer mit Staging-Rücklesung. Jeder Unterschied führt zu einem
Fehlerstatus; ein fehlender Adapter ist kein übersprungener Erfolg.

Dies ist ein Test des geladenen Treibers und des Ressourcentransports. Ein
sichtbares Bild und ein laufendes Spiel bleiben separate Prüfungen. Ein noch
installierter älterer Treiber kann die neue UAV-Prüfung erwartungsgemäß
ablehnen.

## Icarus Phoenix (MMORPG)

Für den älteren Direct3D-9-Pfad gibt es ein **optionales Profil pro Spiel**.
Es verwendet die offizielle DXVK-Version 2.7.1, prüft deren SHA-256 und kopiert
nur die zur EXE passende x86-/x64-`d3d9.dll` neben die tatsächliche Spiel-EXE.
Launcher und Spiel können verschiedene Architekturen oder Verzeichnisse haben.
Das Profil ist kein nativer D3D9-WDDM-Treiber: D3D9 wird über Vulkan übersetzt.
Es braucht einen funktionierenden Helios/Venus-Vulkan-Pfad.

In Windows PowerShell, nach dem Beenden des Spiels, beispielsweise:

```powershell
& 'C:\Program Files\WinBoat\scripts\Set-WinBoatGameCompatibility.ps1' `
  -GameExe 'C:\Games\Icarus\Bin64\Client.exe' -Action Inspect

& 'C:\Program Files\WinBoat\scripts\Set-WinBoatGameCompatibility.ps1' `
  -GameExe 'C:\Games\Icarus\Bin64\Client.exe' -Action D3D9
```

Den Beispielpfad durch die **wirkliche Client-EXE** ersetzen. Im Checkout ist
das Werkzeug unter `guest_server/scripts/` vorhanden; eine aktualisierte
Guest-Server-Installation liefert es ebenfalls mit. Das Profil greift beim
nächsten Start des Spiels. Es ändert keine System-DLLs und überschreibt keine
bereits vorhandene `d3d9.dll`. In diesem Fall muss zuerst geklärt werden, ob die
Datei zum Client oder einem anderen Wrapper gehört. Ein DXVK-Wrapper kann vom
Client oder seinem Anti-Cheat abgelehnt werden; ein erfolgreicher Spieltest
wird hier nicht behauptet.

Rückgängig machen:

```powershell
& 'C:\Program Files\WinBoat\scripts\Set-WinBoatGameCompatibility.ps1' `
  -GameExe 'C:\Games\Icarus\Bin64\Client.exe' -Action Restore
```

Es wird nur die anhand des gespeicherten Hashes zugeordnete DLL entfernt.
Hat ein Updater die Datei verändert, verweigert das Werkzeug die Entfernung.
Eine unterbrochene Installation mit bereits vorhandenem Receipt lässt sich
mit Restore bereinigen. `-DxvkArchive` erlaubt ein lokal bereitgestelltes,
unverändertes Originalarchiv; die gleiche Hashprüfung bleibt verpflichtend.

## Minecraft Java

Minecraft Java verwendet OpenGL. Ein D3D9-Profil hilft dort nicht; Java-EXEs
werden von der D3D9-Aktivierung abgewiesen. Helios liefert den OpenGL-Pfad über
Zink → Venus → Host-Vulkan. Der tatsächliche Spielprozess muss diesen ICD
verwenden; ein Microsoft-Basic/GDI-Kontext genügt nicht.

Aus der **angemeldeten Windows-Sitzung** prüfen:

```powershell
& 'C:\Program Files\WinBoat\scripts\Test-WinBoatOpenGL.ps1'
```

Der Test erzeugt einen echten WGL-Kontext, versucht einen OpenGL-3.3-Core-
Kontext und liest Version, Renderer, Hersteller und Prozessarchitektur aus.
Es werden keine Versionsstrings erzwungen und keine Registry-Knöpfe geändert.
`openGl33Core=true` prüft diese konkrete Grundlage; es ist keine Zusage für
jede Minecraft-/Sodium-/Shader-Version. Java-Version und Anforderungen müssen
zur gewählten Minecraft-/Mod-Version passen.

Für ein 32-Bit-Java separat die 32-Bit-Windows-PowerShell verwenden:

```powershell
& "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile `
  -File 'C:\Program Files\WinBoat\scripts\Test-WinBoatOpenGL.ps1'
```

Der Probeprozess muss dieselbe Architektur und denselben Desktop wie das Spiel
nutzen. Session 0 wird abgewiesen. „GDI Generic“/OpenGL 1.1 oder ein gescheiterter
3.3-Core-Kontext geben einen konkreten Ansatz für ICD-/Adapterdiagnose. Das
Werkzeug testet nicht automatisch das tatsächlich von Java geladene Modul.

## Windows 11 IoT Enterprise LTSC ohne AME

Als zweite, unveränderte Testinstallation ist LTSC sinnvoll: weniger Änderungen
durch AME/Atlas erleichtern den Vergleich, und der feste Featurestand reduziert
Funktionswechsel. Weniger Hintergrundaktivität kann helfen; zusätzliche FPS
oder bessere Grafik-API-Kompatibilität folgen daraus nicht automatisch. Für
die Helios-Entwicklung ist zunächst unverändertes Windows 11 Pro eine gut
vergleichbare Basis. LTSC bietet eine weitere Vergleichsinstallation.

| Basis | Nutzen | Einschränkung |
|---|---|---|
| Windows 11 Pro ohne AME | Breite Spiele-/Launcher-Unterstützung, unveränderte Referenz | Reguläre Featureupdates |
| Windows 11 mit Atlas/AME | Anpassbare Dienste und Hintergrundkomponenten | Zusätzliche Änderungen bei der Fehlersuche berücksichtigen |
| Windows 11 IoT Enterprise LTSC 2024 ohne AME | Fester Featurestand auf 24H2-Basis, zehn Jahre Wartung | Für spezialisierte Geräte vorgesehen; passende Lizenz/Einsatzbedingungen beachten; Store-/Xbox-Komponenten und künftige Spielanforderungen separat prüfen |

Für Minecraft Java und klassische Win32-MMORPGs sind Store/Xbox-Komponenten
gewöhnlich keine Voraussetzung. Die konkrete Client-/Launcher-Unterstützung
muss dennoch geprüft werden. LTSC behebt weder Helios-Renderingfehler noch
Beschränkungen durch Testsignierung oder Anti-Cheat.

Die offizielle **Evaluierung läuft 90 Tage**. Nach Ablauf beschreibt Microsoft
unter anderem einen schwarzen Desktophintergrund und stündliches Herunterfahren.
Sie ist keine dauerhafte Gaming-Installation. Die ISO als **neue, separate VM**
installieren, Atlas/AME deaktivieren und vorhandene Windows-Daten behalten.
Helios, Guest API und VC++-Laufzeiten bleiben unabhängig von AME nutzbar.
Für Helios ist weiterhin der Testsignierungsmodus erforderlich.

Microsoft-Quellen:
- [IoT Enterprise LTSC Evaluierung und Ablaufverhalten](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-iot-enterprise-ltsc)
- [Windows 11 IoT Enterprise LTSC 2024](https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/whats-new/windows-11-iot-enterprise-ltsc-2024)
- [IoT Enterprise: Einsatz und Wartungsmodell](https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/overview)
- [D3D11.1 ClearView DDI](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3d10umddi/nc-d3d10umddi-pfnd3d11_1ddi_clearview)

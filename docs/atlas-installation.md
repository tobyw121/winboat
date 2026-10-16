# AtlasOS mit WinBoat

Unter **Setup → Windows Configuration → Installation mode** stehen Standard
Windows sowie zwei Atlas-Methoden zur Auswahl. Beide Methoden funktionieren mit
heruntergeladenem Windows und mit einer unter **Custom ISO → Select ISO File**
ausgewählten ISO. Die Auswahl einer ISO behält die Atlas-Methode bei; die
Reihenfolge der beiden Auswahlen spielt keine Rolle.

Unterstützt wird **Windows 11 Pro x64 24H2/25H2 (Build 26100/26200)**. WinBoat
prüft die tatsächlichen WIM-/ESD-Metadaten. Bei mehreren Editionen muss genau ein
passender Pro-Index enthalten sein; dieser wird in der Antwortdatei explizit
für Windows Setup ausgewählt. Home, Enterprise, ARM und ältere Builds werden
für Atlas abgewiesen. Der Gast prüft Edition/Build im nachträglichen CLI-Modus
vor der Playbook-Ausführung erneut.

Die eigene ISO wird nur lesbar als `/boot.iso` eingebunden. Dockur extrahiert
sie in eine Arbeitskopie, ergänzt Treiber und die unbeaufsichtigte Installation
und baut daraus die tatsächlich gebootete ISO. WinBoat ändert die ausgewählte
Originaldatei nicht. Vorhandene VM-Festplatten werden nicht nachträglich auf
Atlas umgestellt; diese Funktion ist für neue VMs vorgesehen.

WIM-Pfade werden auch unter Linux ohne Unterscheidung der Groß-/Kleinschreibung
aufgelöst (`oobe`/`OOBE`, `System32`/`system32`). Fehlt `msoobe.exe` tatsächlich,
bricht die ISO-Injection vor WIM-Änderungen mit einer konkreten Meldung ab.
Dann eine unveränderte Windows-ISO oder **apply after installation** wählen;
WinBoat zeigt die AME-Ursache auch bei einem zurückgesetzten HTTP-Zugriff an.

## ISO injection mit AMEs OOBE (experimentell, bevorzugt)

1. Atlas und die gewünschte ISO auswählen. Ohne Custom ISO wird Windows 11 Pro
   wie bisher von Dockur bezogen.
2. WinBoat prüft das mitgelieferte Playbook und lädt den festgelegten AME Wizard
   herunter. Die unveränderten OOBE-Binärdateien werden aus dessen .NET-Ressourcen
   gelesen; auf Linux wird kein Windows-Programm ausgeführt.
3. In der Pro-Edition werden die Offline-Hives SOFTWARE/SYSTEM vorbereitet:
   AMEs temporäre Defender-Vorbereitung, der Dienst `ameoobe` und die BitLocker-
   Einstellung. Die ursprünglichen Sicherheitswerte werden zur Wiederherstellung
   gespeichert. Die WinPE-SYSTEM-Hives erhalten AMEs Hardwareanforderungswerte.
4. AME Client, OOBE-Konfiguration und vollständiges Playbook werden in den
   Installationsindex eingebettet. Die originale `msoobe.exe` bleibt als
   `msoobeext.exe` erhalten; der originale AME-Shim übernimmt ihren Platz.
   `iso.conf` und `oobe.conf` entsprechen AMEs Datenformaten.
   Der gepinnte Shim benötigt den Dateinamen `AME.Client.exe`, der Dienst
   dagegen `OOBE.exe`. Beide Namen enthalten denselben unveränderten Client.
5. Die Antwortdateien wählen Pro aus und überlassen AME die Benutzererstellung.
   `SetupComplete.cmd` übernimmt die Installation des WinBoat-Gastdienstes;
   ein vorhandener WIM-SetupComplete-Hook wird vorher ausgeführt.
6. Beim ersten Start läuft **AMEs eigene OOBE**. Deren Windows-Oberfläche im
   Browser/VM-Fenster verfolgen und gegebenenfalls Eingaben abschließen. Erst
   dort wird das Atlas-Playbook angewendet; eine fertig gebaute ISO bedeutet
   noch keinen erfolgreichen Playbook-Lauf.
7. Eine SYSTEM-Aufgabe beobachtet AMEs frischen Applied-Playbook-Eintrag samt
   Version, ErrorLevel und ausgewählten Optionen. Sie stellt unveränderte
   temporäre Sicherheitswerte wieder her. Danach folgt Helios, falls ausgewählt,
   einschließlich seiner eigenen begrenzten Neustarts.

WinBoat wählt `defender-enable`, `mitigations-default` und `auto-updates-default`.
Bereits mit AME injizierte ISOs sowie kollidierende OEM-Panther-Antwortdateien
oder OEM-SetupComplete-Hooks werden abgewiesen, statt sie zu überschreiben.
Eigene unbeaufsichtigte Installationsdateien benötigen einen regulären
Windows-PE-/OSImage-Abschnitt. Unbekannte Medien dürfen bei ausgewähltem Atlas
nicht stillschweigend ohne Atlas gebootet werden.

## DISM und Offline-Grenzen

Die Portierung unter `resources/atlas-tools/` folgt dem
[ISO-Pfad von AME 0.8.4](https://github.com/Ameliorated-LLC/trusted-uninstaller-cli/blob/0.8.4/TrustedUninstaller.Shared/AmeliorationUtil.cs).
`wimlib` übernimmt die WIM-/ESD-Arbeit, `libhivex` die Offline-Registry.
Das festgelegte Atlas-Profil verlangt `DefenderToggled`, nicht `DefenderDisabled`.
Deshalb ist AMEs bedingtes Offline-DISM-NoDefender-CAB hier nicht erforderlich.
Andere Playbooks mit dieser Anforderung werden ausdrücklich nicht unterstützt.

Atlas-eigene DISM-Befehle wie DirectPlay, Capability-Entfernung und Component-
Cleanup laufen **nativ im Windows-Gast durch das originale Playbook während
AME OOBE**. Linux emuliert keine Windows-CBS-/DISM-Paketinstallation. Die
Windows-Anwendung des Playbooks ist weiterhin online; Atlas kann weitere
Dateien aus dem Internet beziehen. `playbookApplied=false` im ISO-Marker ist
absichtlich kein Erfolgsnachweis.

## Apply after installation

Im zweiten Modus prüft WinBoat ebenfalls die gewählte ISO und setzt den
Pro-Index. Das Installations-WIM und die normale Windows-OOBE bleiben dabei
unverändert. Nach Windows und gegebenenfalls Helios startet eine erhöhte
interaktive Aufgabe die originale AME CLI. In Windows anmelden und ihre
Vorbereitungs-/Neustartaufforderungen befolgen; WinBoat speist keine Antworten
in die CLI ein. Höchstens ein Versuch je Boot, auf höchstens drei Boots.

Die festgelegte CLI 0.8.4 schreibt bei Erfolg keinen GUI-Applied-Eintrag.
Deshalb prüft WinBoat zusätzlich ihre abschließende Erfolgsmeldung im frischen
Konsolenprotokoll und den Prozess-Exitcode. Vorbereitungsende oder Exitcode 0
allein gelten nicht als abgeschlossener Playbook-Lauf. Protokoll:
`C:\ProgramData\WinBoat\Atlas\cli-console.txt`.

## Mitgelieferte Dateien, Bau und Status

**Atlas 0.5.0-hotfix ist vollständig als offizielles `AtlasPlaybook.apbx` in Git
und im AppImage enthalten**, unter `resources/atlas/` einschließlich GPL-Lizenz
und Herkunftsbeleg. AME Wizard/CLI 0.8.4 werden nur für die ausgewählte Methode
von offiziellen Releases bezogen. URLs und SHA-256-Werte stehen in
`src/shared/atlas.ts`; OOBE-Ressourcen werden zusätzlich separat geprüft.
Ein GitHub-Actions-Token ist nicht nötig. AMEs OOBE-Client wird unverändert
verwendet; dessen Quellcode ist nicht Teil der öffentlichen CLI-Portierung.

`./scripts/build-helios.sh` baut das lokale Hilfsimage
`winboat/atlas:0.5.0-hotfix`, das aktualisierte Helios-Image mit Offline-Werkzeugen
und das AppImage. Nur das AppImage zu ersetzen aktualisiert vorhandene
Docker-Images nicht. Alte Helios-Images erfordern einen Neubau ohne `--skip-host`.

Zusätzlich zur VM mindestens 20 GB temporären Speicher für WIM-/ISO-Neubau
vorsehen, für große/mehrsprachige ISOs mehr. Unbeaufsichtigte Installationsmedien
enthalten die gewählten Windows-Anmeldedaten und sollten privat bleiben.

Status: `C:\ProgramData\WinBoat\Atlas\status.json`, API `/provisioning/atlas`.
OOBE-Dateien/AME-Logs: `C:\ProgramData\AME\OOBE`.
WinBoat wartet auf einen überprüften Abschluss, nicht nur auf kopierte Dateien.

### Normale Windows-Anmeldung mit „Other users“ nach ISO-Injection

Eine ältere Injection hat `AME.Client.exe` in `OOBE.exe` umbenannt. Der
mitgelieferte Shim prüft jedoch ausdrücklich `AME.Client.exe`; fehlt diese
Datei, wechselt er zur Microsoft-OOBE zurück, stellt die ursprüngliche
`msoobe.exe` wieder her und entfernt den AME-Dienst. Da die Antwortdatei die
Benutzererstellung AME überlässt, können dann auch die gewählten Windows-
Zugangsdaten fehlen. Die Korrektur behält beide benötigten Client-Dateinamen.

Sie gilt für neu vorbereitete Installationsmedien. Eine bereits installierte
Windows-Kopie wird durch einen Git-Pull oder Container-Neustart nicht erneut
injiziert. Bei einer neuen Einrichtung einen anderen VM-Speicherordner wählen
und die alte VM behalten; ein wiederverwendetes fertiges Installationsabbild
enthält weiterhin die alte Injection. WIM-Warnungen über fehlende optionale
Integritätstabellen sind kein Beleg für diesen OOBE-Fehler. AME-Ressourcen und
Atlas-Archiv werden unabhängig davon gegen festgelegte SHA-256-Werte geprüft.

Geprüft: echte WIM-/ESD-/Hive-Bearbeitung mit synthetischen Windows-Dateien,
Pro-Auswahl bei mehreren Editionen, unveränderte andere Editionen, beide Modi,
Konflikt-/Build-Abweisung, Original-AME-/Atlas-Ressourcen, PowerShell-Logik und
Paketbau. Eine vollständige Windows-/AME-OOBE-/Helios-Installation wurde in der
Cloud ohne passende Windows-/GPU-VM nicht ausgeführt. Der ISO-Modus bleibt
experimentell.

### Hängende AME-OOBE ohne Eingabeaufforderung untersuchen

Wenn Umschalt+F10 nicht funktioniert, kann der bereits erreichbare WinBoat-
Gastdienst feste Diagnosen liefern. Im Repository auf dem Linux-Host ausführen:

```bash
git pull --ff-only origin work
python3 scripts/atlas/diagnose-vm.py --update-guest
```

Benötigt Python 3, Docker mit Buildx und den ursprünglichen `/oem`-Bind-Mount.
Das Skript baut nur den Windows-Gastdienst und überträgt ihn über dessen
bestehenden Update-Endpunkt. Der Updater sichert das bisherige Programmverzeichnis
und startet den WinBoat-Gastdienst neu. Windows und AME werden nicht neu gestartet.
Vorhandene Helios-Installationsdateien bleiben im Update-Paket enthalten; fehlt
ein benötigtes OEM-Paket, wird kein Update übertragen. Dieser Helfer unterstützt
den ISO-/OOBE-Modus.

Anschließend liefert `/provisioning/atlas/diagnostics` AME-Dienststatus,
Prozessnamen, ausgewählte Setup-Zustände, Dateivorhandensein und fest gefilterte
Startmarkierungen aus `C:\ProgramData\AME\Logs\Log.yml`. Die Abfrage liest weder
`oobe.conf` noch Prozessbefehlszeilen aus und gibt keine vollständigen Logs aus.
Die Ausgabe wird privat unter `~/.winboat/diagnostics/atlas-*.json` gespeichert.
Bei weiteren Abfragen genügt `python3 scripts/atlas/diagnose-vm.py`.
Ein `waiting`- oder älterer `running`-Status allein beweist keinen laufenden
Playbook-Durchlauf. Der Diagnoseweg repariert einen blockierten AME-Client nicht.

Fehlen `Window Launched` und `WNF Published 104`, obwohl `ameoobe` läuft, ist der
Übergang zur AME-Oberfläche nicht bestätigt. Die erweiterte Diagnose klassifiziert
zusätzlich den Winlogon-Shell-Eintrag, prüft den Original-AME-Shim per SHA-256 und
liest die Berechtigungen von AME-Ordner, Client und Konfiguration. Dabei werden
nur Zugriffskategorien ausgegeben; Kontonamen, maschinenspezifische SIDs,
Shell-Befehlszeilen und Konfigurationsinhalte bleiben privat. Fehlertypen und
hexadezimale HRESULTs werden getrennt von vertraulichen Meldungstexten gefiltert.
Nach einem Git-Pull erneut `--update-guest` verwenden, um diese Skriptversion auf
der bestehenden VM zu installieren. Die Abfrage verändert weder Konten noch
Windows-Einrichtungszustände oder AME-Berechtigungen.

### `defaultuser0`: AME-Dienst beendet sich ohne Oberfläche

Ein Fehler in der bisherigen Registrierung hat auch dem AME-Laufzeitordner
ausschließlich SYSTEM-/Administratorrechte gegeben. Der GUI-Client liest seine
Konfiguration selbst im Einrichtungskonto; diesem fehlte der erforderliche
Zugriff. Die Registrierung und der persistente Beobachter gewähren jetzt nur
der SID des lokalen, aktiven `defaultuser0` Lese-/Ausführungsrechte auf AME.
Der private WinBoat-Verwaltungsordner bleibt auf SYSTEM/Administratoren beschränkt.
Diese Korrektur ist beim nächsten Paketbau auch in neuen Installationen enthalten.

Eine bereits abgebrochene OOBE kann gezielt wieder aufgenommen werden:

```bash
git pull --ff-only origin work
python3 scripts/atlas/diagnose-vm.py --update-guest --recover-oobe
```

**Dieser zusätzliche Schalter startet Windows neu.** Der feste Gastvorgang prüft
Original-Shim, AME-Shell, Einrichtungskonto, beendeten AME-Dienst und abgeschlossene
Windows-Setup-Zustände. Existieren der konfigurierte Benutzer oder ein angewendetes
Playbook bereits, wird der Wiederanlauf abgewiesen. Ebenso wird er bei aktiven
AME-/Setup-Prozessen abgewiesen. Es werden keine Passwörter gesetzt/zurückgesetzt,
keine Konten gelöscht und keine Datenträger neu angelegt.

Vor der Änderung wird die AME-Verzeichnis-ACL privat gesichert. Danach werden
Zugriff und Beobachter erneuert. Eine einmal auf Anforderung gestartete SYSTEM-
Aufgabe führt nach 15 Sekunden Windows' `Sysprep.exe /oobe /reboot /quiet` aus.
Es gibt keinen automatischen erneuten Reparaturversuch. Der Endpunkt verlangt
einen expliziten Recovery-Header und erlaubt nur einen gleichzeitigen Aufruf.

Nach dem Wiederanlauf die Windows-Konsole öffnen. Weitere Statusabfragen:
`python3 scripts/atlas/diagnose-vm.py` (ohne Reparaturschalter). `recoveryStatus`
enthält auch einen Sysprep-Fehlerstatus, Exitcode und gefilterte Fehlercodes, falls
Windows den Vorgang ablehnt. Geprüft sind Berechtigungslogik, Abbruchbedingungen,
HTTP-Aufruf, Fehlerbehandlung und Windows-Gastdienst-Build; ein echter Sysprep-/
AME-Wiederanlauf lässt sich in der Cloud ohne Windows-VM nicht testen.

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

### „Just a moment…“: AME gezielt in der vorhandenen Sitzung starten

Sind die Einrichtungskonto-Berechtigungen vorhanden, aber `AME.Client` fehlt
weiterhin, lässt sich der originale Client gezielt anstoßen:

```bash
git pull --ff-only origin work
python3 scripts/atlas/diagnose-vm.py --update-guest --launch-ame-ui
```

Dieser Schalter startet Windows nicht neu und erzeugt keine neue Anmeldung.
Der Helfer prüft das unveränderte Client-Original per SHA-256 und verifiziert
mit Windows' WTS-Sitzungstoken, dass an der Konsole tatsächlich `defaultuser0`
angemeldet ist. Eine andere oder fehlende Benutzersitzung wird abgewiesen.
Anschließend startet er nur den AME-Dienst neu, um dessen GUI-Wartezeit zu
erneuern, und führt `AME.Client.exe --oobe` mit dem Token und der Umgebung des
Einrichtungskontos auf `winsta0\default` aus. Der Client läuft nicht als SYSTEM.
Der WinBoat-Gastdienst muss dafür wie vorgesehen als SYSTEM laufen.

`launched` bedeutet, dass der gestartete Prozess die ersten zwei Sekunden
überlebt hat; es bestätigt weder ein sichtbares Fenster noch Atlas-Abschluss.
Ein früher Prozess-Exit oder ein Windows-API-Fehler wird mit numerischem Code
gemeldet. Fehler 1008 bedeutet, dass kein Token für eine angemeldete Sitzung
verfügbar ist. Der Helfer meldet außerdem nur die Kategorie des Konsolenbenutzers
und numerische AutoLogon-Zustände, keine Benutzernamen oder Kennwörter.

Geprüft sind C#-Kompilierung, native Strukturlayouts, Aufrufreihenfolge und
Abweisung ohne Sitzung sowie HTTP-/Pakettransport und der Windows-Gastdienst-
Build. Die WTS-/Prozess-APIs und der originale WinUI-Client können in der
Linux-Cloud nicht ausgeführt werden; ihr Zusammenspiel bleibt auf der VM zu prüfen.

### Korrektur der Setup-Anmeldung

WinBoats allgemeine RemoteApp-Registry-Datei darf `AutoAdminLogon` nicht während
AMEs Setup abschalten. Im ISO-Modus wird diese Richtlinie erst nach einem frischen,
fehlerfreien Atlas-Ergebnis und der Erstellung des konfigurierten Windows-Benutzers
angewendet. Ein beendeter AME-Dienst oder eine fehlende Setup-Anmeldung wird nach
einer Starttoleranz als Fehler gemeldet, statt weiter „Applying Atlas“ anzuzeigen.

Für eine bereits blockierte VM zuerst den Gast aktualisieren und diagnostizieren:

```bash
git pull --ff-only origin work
python3 scripts/atlas/diagnose-vm.py --update-guest
```

`logon.setupCredentialPresent` zeigt nur, ob Windows sein Setup-Kennwort noch
hinterlegt hat; dessen Inhalt wird nicht ausgegeben. Falls es vorhanden ist,
kann `--recover-oobe` nach den bisherigen Prüfungen die Setup-Anmeldung wieder
aktivieren und Windows per Sysprep neu starten. Es verändert kein Kennwort.
Fehlt das Setup-Kennwort, wird die Wiederherstellung abgelehnt. Dann eine neue
Installation mit dem korrigierten WinBoat-Build und frischem Windows-Medium
verwenden; die bestehende VM-Disk vorher sichern. Ein bloßes Update der Anwendung
ändert keine bereits installierten Windows-Anmeldedaten.

Die Regressionstests prüfen Windows-Abfragen mit Fixtures. Ein vollständiger
Windows-/AME-Installationslauf muss zusätzlich auf dem VM-Host verifiziert werden.

### Offline-Übergabe und Dateirechte (Host-Protokoll `ame-oobe-v2`)

Die Offline-Anpassung verwendet die existierenden ControlSets aus
`SYSTEM\Select\Default` und `Current`. Ohne diese Auswahl muss `ControlSet001`
bereits existieren. Ungültige oder fehlende ControlSets werden abgelehnt.

Im AME-Modus entfallen gezielt Dockurs bekannte OEM-Installer-Aufrufe und der
`Set-LocalUser ... -PasswordNeverExpires`-Aufruf für den aus der Antwortdatei
entfernten Benutzer. Eigene Befehle und zusammengesetzte Befehlszeilen bleiben
erhalten. Live-Modus, UAC- und OOBE-Seiteneinstellungen werden dabei nicht geändert.

Vor der Kontoübergabe dürfen lokale Benutzer nur die AME-Programmdateien lesen;
`oobe.conf` bleibt ausschließlich SYSTEM/Administratoren zugänglich. Sobald das
aktive Setup-Konto existiert, ersetzt der Observer sämtliche Runtime-DACLs durch
SYSTEM/Administratoren mit Vollzugriff und die konkrete Setup-SID mit RX. Es
bleiben keine geerbten oder alten expliziten Benutzerfreigaben übrig. Reparse-
Points werden vor ACL-Änderungen abgelehnt. Das WinBoat-Observer-Verzeichnis bleibt
privat. Der Observer prüft die Kontoverfügbarkeit während der Übergabe häufiger.

Das Host-Image muss mit `./scripts/build-helios.sh` neu gebaut werden; ältere
Offline-Tools werden anhand des Fähigkeitslabels abgelehnt. Bereits erzeugte
Installationsmedien und installierte Windows-Disks werden dadurch nicht rückwirkend
gepatcht. Ein vollständiger Windows-/AME-OOBE-Durchlauf bleibt zusätzlich zu den
WIM-, Hive- und ACL-Fixture-Tests erforderlich.

### AME-Prozess läuft, OOBE-Dienst meldet 1067

Ein laufender `AME.Client` beweist noch keine sichtbare Oberfläche oder einen
abgeschlossenen Playbook-Lauf. Der Dienstcode allein reicht ebenfalls nicht zur
Einordnung dieses Zustands. Die Diagnose ergänzt `crashEvents` aus den letzten
100 passenden Windows-Anwendungsereignissen (höchstens 20 AME-Ereignisse),
klassifiziert bekannte Fehlerfenster und vergleicht die gespeicherte
Observer-Datei mit der installierten Skriptversion. Ereignisse werden ohne
Zeitfilter gelesen, weil Windows Setup seine Uhr korrigieren kann. Rohmeldungen,
Fenstertitel, Benutzerpfade und Kennwörter werden nicht ausgegeben.

`setupCredentialPresent` prüft ausschließlich `Winlogon\\DefaultPassword`.
Ein `false` schließt eine funktionierende Setup-Anmeldung nicht aus; andere
Windows-Anmeldewege werden nicht ausgelesen. Ist `consoleAccount` bereits
`setup-account`, begründet dieser Wert keine Neuinstallation. Ein Gastdienst-
Update ersetzt außerdem nicht automatisch die bereits laufende private
Observer-Kopie. Zur weiteren Ursachenbestimmung reicht zunächst:

```bash
python3 scripts/atlas/diagnose-vm.py --update-guest
```

Der Collector erfasst auch die festen GUI-Meldungen des originalen AME 0.8.4:
`Window Loaded`, `Window Thread Started`, `Window InterLink Initialized`,
`Window Registered`, `Window Signaled` und `Waiting Anim`. Diese Meldungen
verwenden teilweise keinen Trenner zwischen Uhrzeit und Text.
`guiStartupPhase` zeigt den letzten gemeldeten GUI-Schritt seit dem letzten
Dienststart. `not-reported` beweist keinen fehlgeschlagenen Fensteraufbau: Der
Client könnte sein Log nicht schreiben können. Deshalb enthält `amePermissions`
zusätzlich die kategorisierten DACLs von `Logs-directory` und `Log.yml`, sofern
vorhanden. Der Collector verändert keine Rechte und startet keine Prozesse neu.

### Gast-Update eindeutig bestätigen

`Guest service update accepted` bestätigt nur die Upload-Annahme. Der bisherige
Gastdienst antwortet während der ersten Update-Sekunden möglicherweise noch.
Das Diagnose-Hilfsskript wartet deshalb auf die erwartete Commit-ID **und**
`diagnosticsVersion: 2` samt SHA-256 des tatsächlich hochgeladenen Collectors.
Erst dann erscheint `Verified updated guest and matching collector`. Ohne diese
Bestätigung wird nach dem Zeitlimit ein unbestätigtes Update gemeldet, statt alte
Diagnosen als neue auszugeben. Die Windows-VM wird dabei nicht neu gestartet.
Ein bereits entfernter Observer-Task wird als `not-registered` ausgewiesen; echte
Abfragefehler werden weiterhin separat gemeldet.

### Einmaliger Wiederanlauf nach beendetem UI-Handshake

Wenn ein Wiederanlauf `launched` meldet, aber die Konsole weiterhin „Just a
moment“ zeigt, keine neue VM anlegen und den Wiederanlauf nicht wiederholen.
`launched` bestätigt nur den Prozessstart. Zunächst rein lesend prüfen:

```bash
python3 scripts/atlas/diagnose-vm.py --update-guest
```

`clientInspection` zeigt für höchstens zwei AME-Prozesse den Besitzer als
Kategorie, die Übereinstimmung von Programmpfad und Konsolensitzung, Prozessalter,
bekannte Runtime-Module und Thread-Wartezustände. Die Wartekette des ältesten
Threads enthält nur numerische Objekttypen und Statuscodes; keine Locknamen,
fremden Prozess-IDs, Speicherinhalte oder Benutzerinformationen. Desktopnamen
werden auf `default`, `winlogon`, `other` oder `unavailable` begrenzt. Eine
fehlgeschlagene native Abfrage wird separat mit Fehlercode ausgewiesen. Diese
Prüfung beendet keine Prozesse und startet AME nicht erneut.

`uiRestartAttempted` zeigt die persistente Wiederanlaufsperre. Ein blockierter
Aufruf liefert nun zusätzlich `stage` und einen festen `reason` wie
`client-owner-mismatch`, `client-path-mismatch` oder
`client-younger-than-five-minutes`. Ein negatives Prozessalter wird als
`client-clock-inconsistent` abgelehnt. Keine dieser Prüfungen wird umgangen;
rohe Ausnahmemeldungen und Anmeldedaten werden nicht ausgegeben.

Der gepinnte AME-Dienst wartet bis zu vier Minuten auf die GUI-Rückmeldung.
`WNF Waited` ohne anschließendes `Window Launched` und ein beendeter Dienst
passen zu einem fehlgeschlagenen Handshake; Fehler 1067 allein beweist keinen
gewöhnlichen Prozessabsturz. `handoffPhase` wertet nur den letzten protokollierten
Dienststart aus. `windowKind: none` ist keine Desktop-übergreifende Sichtprüfung.

Bei einem verbliebenen AME-Client kann ausdrücklich ein Versuch gestartet werden:

```bash
python3 scripts/atlas/diagnose-vm.py --update-guest --restart-ame-ui
```

Dieser Aufruf kann den alten AME-Prozess beenden. Er verlangt einen beendeten
Handshake ohne protokollierten Fensterstart, Dienstcode 1067, genau einen Client,
keine anderen Windows-Setup-Prozesse und keinen registrierten Playbook-Abschluss.
Der native Helfer prüft aktive Konsolensitzung, exakten Exe-Pfad, Setup-SID als
Prozessbesitzer und mindestens fünf Minuten Prozessalter vor dem Beenden. Er
hält dabei den Prozesshandle und startet keine Programme als SYSTEM-Desktop-UI.
Danach startet der originale AME-Client über den vorhandenen Setup-Sitzungstoken
mit seinem Runtime-Verzeichnis als Arbeitsverzeichnis. Die aktuelle Observer-
Registrierung wird im Hintergrund angefordert. Alle AME-Aktionsrouten teilen
sich eine Sperre; eine persistente Markierung verhindert Wiederholungsschleifen.

Die Aktion startet Windows nicht neu, verändert keine Kennwörter und bestätigt
keinen Atlas-Erfolg. Ein `launched` bestätigt nur den Prozessstart; die Konsole
und ein späterer Diagnoseabruf müssen Oberfläche und Fortschritt bestätigen.
Die Tests prüfen Guards, Aktionsrouting und Kompilierung; die tatsächlichen
Windows-APIs benötigen zusätzlich einen Windows-VM-Lauf.

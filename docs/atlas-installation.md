# AtlasOS mit WinBoat

Unter **Setup → Windows Configuration → Installation mode** gibt es drei Wege:

- **Standard Windows**: bisherige Windows-Installation.
- **Windows 11 Pro + AtlasOS: ISO injection (experimental)**: der bevorzugte
  Atlas-Weg. Dockur lädt Windows wie bisher herunter und bereitet seine
  unbeaufsichtigte Installation vor. WinBoat ergänzt vor dem ISO-Neubau die
  Pro-Edition in `install.wim` um die geprüften AME-/Atlas-Dateien unter
  `ProgramData\WinBoat\AtlasMedia`. Die so erzeugte ISO wird automatisch gebootet.
- **Windows 11 Pro + AtlasOS: apply after installation**: Windows wird ohne
  Atlas-WIM-Änderung installiert; die gleichen Dateien kommen über den OEM-Ordner
  in den Gast. Danach startet dieselbe AME-CLI-Einrichtung.

Bei beiden Atlas-Wegen wird das eigentliche Playbook **im laufenden Windows**
angewendet. Unterstützt werden x64 Windows 11 Pro 24H2/25H2, Builds 26100/26200.
Andere Editionen/Builds werden abgewiesen. Vorhandene VM-Festplatten werden nicht
nachträglich umgebaut. Bei benutzerdefinierten ISOs bleibt die automatische
Atlas-Einrichtung aus; eine mit AME Wizard vorbereitete ISO lässt sich über
**Custom ISO** wählen. Deren eigene OOBE muss mit Dockurs unbeaufsichtigter
Installation kompatibel sein; diese Kombination ist nicht mit Windows getestet.

## Was aus AME übernommen wird

Die Linux-Implementierung unter `resources/atlas-tools/` orientiert sich am
[AME-ISO-Pfad in AmeliorationUtil.cs, Version 0.8.4](https://github.com/Ameliorated-LLC/trusted-uninstaller-cli/blob/0.8.4/TrustedUninstaller.Shared/AmeliorationUtil.cs):
WIM-/ESD-Unterscheidung, Medieneinbettung vor dem ISO-Neubau und anschließende
Einrichtung im Gast. Sie nutzt das bereits im Dockur-Image vorhandene `wimlib`.
Es wird nur der passende Pro-Index geändert; bestehende Image-Indizes, Namen,
Windows-Dateien und die BIOS-/UEFI-Erstellung durch Dockur bleiben erhalten.

Dies ist eine **WinBoat-Portierung der Medieneinbettung**, keine vollständige
Portierung des AME-ISO-Backends. Dessen Windows-Registry-/DISM-Aktionen,
Offline-Playbook-Ausführung und Austausch von `msoobe.exe` durch AME Client sind
nicht implementiert. Deshalb bleibt die normale Windows-OOBE erhalten und die
ISO enthält zunächst die Installationsdateien, kein bereits angewendetes Atlas.
Der Marker `winboat-atlas-iso.json` beschreibt ausdrücklich `playbookApplied=false`.
Die Original-AME-CLI wird unverändert verwendet; es gibt keine erfundenen
`--iso`-/`--silent`-Argumente.

## Ablauf im Windows-Gast

1. WinBoat installiert seinen Gastdienst und registriert eine erhöhte Aufgabe
   `WinBoatAtlasProvisioning` für den gewählten Windows-Benutzer.
2. Falls Helios ausgewählt ist, wartet Atlas auf dessen abgeschlossene Einrichtung.
3. Im Windows-Fenster anmelden, auch nach Helios-Neustarts. Die Aufgabe startet
   AME CLI automatisch; ohne angemeldeten Benutzer kann sie nicht interaktiv laufen.
4. AME kann das vorübergehende Ausschalten von Windows-Sicherheitsschaltern und
   einen Vorbereitungsneustart verlangen. Anweisungen in der Windows-Konsole
   befolgen. WinBoat automatisiert diese Eingaben nicht und umgeht keine Prüfungen.
5. Nach einem angeforderten Neustart erneut anmelden. Die Aufgabe versucht die
   Einrichtung höchstens einmal pro Windows-Boot und höchstens auf drei Boots.
6. Als Playbook-Optionen werden `defender-enable`, `mitigations-default` und
   `auto-updates-default` übergeben. Bei Abbruch muss ein gegebenenfalls manuell
   abgeschalteter Schutz in Windows wieder eingeschaltet werden.
7. WinBoat meldet Erfolg erst, wenn AME einen frischen Applied-Playbook-Eintrag
   mit Version `0.5.0` und `ErrorLevel=0` schreibt. Exitcode 0 allein genügt nicht.
   Anschließend Windows vor der Benutzung einmal neu starten.

Status: `C:\ProgramData\WinBoat\Atlas\status.json`, Versuchsgrenze: `attempts.json`.
AME-Dateien und Logs: `C:\ProgramData\WinBoat\Atlas\cli`.
Die Gast-API `/provisioning/atlas` liest nur den lokalen Status. WinBoat wartet
bis zu zwei Stunden und erklärt eine ausstehende Benutzereingabe nicht zum Erfolg.

## Downloads, Speicher und Grenzen

Festgelegt sind AME CLI `0.8.4` und Atlas `0.5.0-hotfix`.
URLs und SHA-256-Werte stehen in `src/shared/atlas.ts`; der Windows-Starter prüft
die beiden Archive erneut vor der Ausführung. Downloads erfolgen erst bei
ausgewähltem Atlas; für den normalen WinBoat-Build werden sie nicht benötigt.
Ein GitHub-Actions-Token ist nicht nötig. Atlas kann bei der Anwendung weitere
Software aus dem Internet beziehen. Die vollständige Einrichtung ist nicht offline.

Für den ISO-/ESD-Neubau zusätzlich zur VM-Festplatte mindestens 20 GB freien
temporären Speicher einplanen, bei großen/mehrsprachigen Images entsprechend mehr.
Die fertige Installations-ISO liegt im VM-Speicherordner; Windows wird daraus
automatisch installiert. Die Daten gehören nicht ins verteilte WinBoat-AppImage.

Geprüft sind echte WIM-Einbettung und ESD-Konvertierung an synthetischen Images,
Editions-/Build-Abweisung, Container-Hooks, Prüfsummen und Statusprüfung. Eine
vollständige Windows-/Atlas-/Helios-Installation und deren Gaming-Kompatibilität
sind in der Cloud ohne passende Windows-/GPU-Testumgebung nicht nachgewiesen.

Offizielle Anleitungen:
[Atlas ISO-Injection](https://docs.atlasos.net/getting-started/install/install-iso-injection/),
[AME CLI](https://github.com/Ameliorated-LLC/trusted-uninstaller-cli#cli-usage).

# Erweiterte Anzeige und Grafikdiagnose über die Guest API

Ab Gastprotokoll `helios-watchdog-v10` ist **Erweitern** die automatische
Anzeigevorgabe für vollständig eingerichtetes Helios. Ein bereits erweiterter
Desktop bleibt erhalten. Bei einem bestehenden geklonten Desktop versucht der
Dienst einmal pro Konsolensitzung, nur den physischen Helios-GDI-Adapter als
eigenen Bildschirm rechts neben VGA einzurichten. Die Registry-/Modusänderung
richtet sich ausschließlich an Helios; VGA bleibt auf seiner bisherigen
Auflösung, Position, Bildwiederholrate und Primärzuordnung.

Der Dienst prüft die VGA-Geometrie nach der Änderung. Fehler oder ein nicht
bestätigter erweiterter Desktop führen zu `extension-failed`, danach zu
`extension-held`. Es gibt keine periodischen Klon-/VGA-Umschaltungen und keine
automatischen PnP-Aktivierungen oder Neustarts des VGA-Adapters mehr. Ein
manuell deaktivierter oder nicht verfügbarer VGA-Adapter wird gemeldet.
Ein geklonter Desktop mit Helios als Primäradapter bleibt unter
`primary-layout-held` unangetastet: Eine automatische Verschiebung des
Primärursprungs könnte dabei VGA verändern. Diese vorhandene Anordnung muss
ausdrücklich in Windows umgestellt werden.
Eine neue Konsolensitzung beziehungsweise ein Dienstneustart erlaubt einen
neuen Versuch; den Dienst bei einem fehlerhaften Treiber nicht wiederholt neu
starten. Manuelle Änderungen in Windows bleiben während der Sitzung erhalten.
Die expliziten Rettungsbefehle stehen weiterhin zur Verfügung.

Diese Trennung verhindert Eingriffe durch die WinBoat-Automatik. **Sie isoliert
keine abstürzenden Grafiktreiber:** Windows verwendet einen gemeinsamen Desktop-
Compositor, und ein Fehler im Helios-/Vulkan-Pfad kann weiterhin DWM und damit
auch die VGA-Ausgabe stören. Die D3D11-Fähigkeitsregression ist dadurch nicht
behoben. Ein echter Treiberfix muss zusätzlich auf der Hardware geprüft werden.

## Verwendung vom Linux-Host

Bei laufender VM im WinBoat-Repository zunächst den Gastdienst aktualisieren:

```bash
git pull --ff-only origin work
python3 scripts/atlas/diagnose-vm.py --update-guest
```

Auch die WinBoat-App sollte aus dem aktuellen Repository-Stand gebaut sein.
Eine ältere AppImage kann beim nächsten Start wieder ihren älteren Gastdienst
einspielen. Der [lokale Build](build-helios-local.md) beschreibt die Aktualisierung.

Die Änderung benötigt keinen neuen Helios-Installer. Das Standardpaket bleibt
`.291`; für die Gerätejournale muss ein Treiber mit Journal-Unterstützung wie
`.296` bereits installiert sein. Ohne entsprechende Logeinträge wird `journal`
als nicht verfügbar gemeldet, nicht als erfolgreiche Geräteprüfung.

Während des Flackerns sammeln:

```bash
python3 scripts/helios/diagnose-graphics.py --samples 6 --interval 5
```

Die sechs Statusabfragen erfassen ungefähr 25 Sekunden Verlauf. Anschließend
werden die aufwendigeren Berichte einmal eingesammelt. Die JSON-Datei unter
`~/.winboat/diagnostics/` enthält sämtliche verfügbaren Abschnitte; eine
Zwischenablage in Windows ist dafür nicht erforderlich. Alte Gastdienste und
Teilfehler bleiben als ausdrückliche HTTP-/Diagnosefehler im Bericht sichtbar.
`--samples` erlaubt 1 bis 12 Abfragen, `--interval` 2 bis 30 Sekunden.

Danach kann Helios ausdrücklich deaktiviert werden:

```bash
python3 scripts/helios/rescue-graphics.py --disable-helios
```

## Neue Endpunkte

Alle folgenden Aufrufe sind GET-Abfragen an der vorhandenen Guest API.
Sie installieren keine Treiber, ändern keine Einstellungen und starten weder
DWM noch Windows neu. Nur ein PowerShell-Diagnosecollector darf gleichzeitig
laufen; weitere parallele Abfragen erhalten HTTP 409.

| Endpunkt | Inhalt |
| --- | --- |
| `/graphics/history` | Letzte 64 Beobachtungen des vorhandenen Monitors: Gastzeit, Sitzung, Helios-/VGA-Zustand, Topologie, Richtlinienzustand, Viewerfehler und Diagnosefehler. Der Ring liegt nur im Dienstspeicher und beginnt nach einem Dienstneustart neu. |
| `/graphics/diagnostics/journals` | Bis zu 96 strukturierte Ereignisse aus jeweils höchstens zwei UMD-Logdateien, bevorzugt für laufende DWM-Prozesse. Dateilesen und Antwortgröße sind begrenzt; beliebige Logtexte werden nicht exportiert. |
| `/graphics/diagnostics/runtime` | Windows-Bootzeit, DWM-PIDs/Sitzungen, Startzeiten, gesamte CPU-Zeit, Threads und Handles; vorhandene DWM-Abstürze und Display-Reset-Ereignisse 4101 aus maximal der letzten Stunde seit dem aktuellen Boot. Ereignismeldungen und Prozesskommandozeilen werden nicht exportiert. |

Die beiden ausführlichen Diagnoseendpunkte enthalten ihre Daten unter `driver`
und zusätzlich den aktuellen Adapterstatus. Der bestehende kompakte Endpunkt
`/graphics/diagnostics` bleibt erhalten. Der Verlauf verwendet die vorhandenen
nativen Statusabfragen; er erzeugt keine zusätzlichen PowerShell-Pollingschleifen.
Windows-Ereignisse werden nur auf ausdrückliche Anfrage gelesen. Ein fehlendes
Ereignis oder ein aktiver PnP-Adapter beweist noch keinen erfolgreichen Present
oder sichtbaren Frame. Host- und Gastzeit sind im Bericht getrennt erkennbar.

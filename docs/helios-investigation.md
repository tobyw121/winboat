# Helios: Live-Diagnose und geführte Untersuchung

Diese Erweiterungen benötigen eine aktuelle WinBoat-AppImage und den Gastdienst
mit `helios-watchdog-v13`. Der Standardinstaller bleibt `.291`; weder ein Build
noch eine lokale Testmarkierung ändert den Repository-Standard.

```bash
git pull --ff-only origin work
./scripts/build-helios.sh
python3 scripts/atlas/diagnose-vm.py --update-guest
```

Danach die neue AppImage verwenden. Die bestehende Windows-Installation bleibt
erhalten. Eine alte AppImage kann ihren älteren Gastdienst wieder einspielen.

## Flackern mit einem Knopf erfassen

In **WinBoat → Configuration → Graphics diagnostics → Capture flickering**
startet ein gemeinsamer Host-/Gastmitschnitt. Die VM weiterlaufen lassen.
Der Aufruf sammelt zwölf native Statusproben im Abstand von zwei Sekunden,
danach einmal die aufwendigeren Berichte und vorhandene Docker-Protokolle.
Er startet keine Installation und führt keinen VM-Neustart aus.

Nach Abschluss öffnet WinBoat den Ablageort der JSON-Datei unter
`~/.winboat/diagnostics/`. Der Knopf ist während des Mitschnitts gesperrt.
Python 3 auf dem Linux-Host und Docker-Zugriff sind erforderlich; die drei
benötigten Hilfsskripte werden mit der AppImage ausgeliefert. Eine Zwischenablage
zwischen Linux und Windows ist nicht nötig.

Der Bericht enthält die bekannte `captureId`, getrennte Host-/Gastzeiten,
Adapterverlauf, DWM-/UMD-Daten, Transportfehler und gespeicherte Abnahmen.
Fehlende API-Abschnitte oder ein veraltetes Image bleiben ausdrückliche Fehler,
auch wenn die Datei erfolgreich gespeichert wurde.

## Live-Dashboard unter Windows

**WinBoat → Helios Control** im Windows-Startmenü zeigt:

- native Adapterdaten und gespeicherte Zustände etwa alle fünf Sekunden;
- gebundene Treiberversion, geladene Grafikmodule und bestehende DWM-Ereignisse
  aus aufwendigeren Abfragen höchstens einmal pro Minute;
- deutliche Warnungen bei unterschiedlichen UMD-/Treiber- oder Laufzeitversionen;
- beobachtete Änderungen der DWM-PID-Menge während dieses Fensterlaufs.

Die Abfragen überlappen nicht. Ein Hintergrund-Runspace hält das Formular
bedienbar; es wird nicht alle fünf Sekunden ein neuer PowerShell-Prozess
gestartet. Während Minimierung beginnen keine neuen Abfragen. Beim Schließen
wird der laufende Abruf beendet.

PID-Wechsel sind keine sichere Anzahl von DWM-Abstürzen, etwa bei mehreren
Sitzungen. Zeitstempel, Fehler und Alter der langsamen Berichte beachten.
Eine ausstehende oder fehlgeschlagene Abfrage macht alte Daten nicht aktuell.

## Geführter `.291`-/Kandidatenvergleich

1. In Helios Control **A/B/A/B-Vergleich beginnen** wählen. Der nächste Lauf heißt A1.
2. Baseline und zusätzliche Prüfprogramme ausdrücklich auswählen, testen und
   das Ergebnis prüfen.
3. **Naechster Vergleichsschritt / Ergebnis** zeigt B1. Den Kandidaten über den
   [abgesicherten Updateweg](helios-control-and-validation.md) installieren,
   bei Bedarf neu starten und dieselben Prüfprogramme ausführen.
4. Für A2 zur Baseline zurückkehren und für B2 den Kandidaten erneut prüfen.
   Der Helfer wechselt oder installiert keinen Treiber selbst.
5. Nach vier Läufen zeigt der Ergebnis-Knopf die erste Abweichung pro Paar samt
   Exit-/API-Codes und ob sie in beiden Paaren wiederkehrt.

Gleiche VM, Host-Laufzeit, Szene, Auflösung und Aufwärmzeit verwenden.
Treiberversionen und aufgezeichnete Einstellungen dürfen sich innerhalb von A
beziehungsweise B nicht ändern. Unterschiedliche Prüfprogramm-Hashes werden
ausgewiesen; sie verhindern die eindeutige Zuordnung eines Unterschieds zum
Treiber. Ein wiederholter Unterschied ist noch kein Ursachenbeweis.

Die Abnahmen werden zusätzlich unter
`C:\ProgramData\WinBoat\GraphicsValidation\run-<ID>.json` archiviert. Eine Sitzung
verweist auf vier konkrete Dateien und vermischt keine zufälligen letzten Läufe.
Die Historie ist auf 64 Dateien begrenzt. Alte Dateien nach Export bewusst
archivieren; der Helfer löscht keine alten Belege automatisch.

`GET /graphics/validation` enthält auch den gespeicherten Vergleich. Der
Linux-Vergleicher liest nun auch Windows-UTF-8-Exporte mit BOM:

```bash
python3 scripts/helios/compare-graphics.py A1.json B1.json A2.json B2.json
```

## Profile für einzelne Anwendungen

In Helios Control das Profil wählen und **Anwendungs-Verknuepfung erstellen**
aufrufen. Angeboten werden:

| Profil | Wirkung |
|---|---|
| `driver-default` | Entfernt einen geerbten Diagnose-Feature-Level nur aus der Umgebung des neuen Prozesses; die Treibervorgaben gelten. |
| `d3d11-fl10` | Setzt im neuen Prozess den unterstützten Diagnose-Feature-Level auf FL10. Für Anwendungen, die FL11 voraussetzen, kann dies ausdrücklich fehlschlagen. |
| `d3d11-fl11` | Wählt den vollständigen FL11-Diagnosepfad nur für den neuen Prozess. |

Die Profile verändern weder HKLM-Einstellungen noch den laufenden DWM-Prozess.
Vor einem Diagnoseprofil werden Paketidentität, Hash der registrierten nativen
UMD und deren Prozessvariablen-Unterstützung geprüft. Ältere Binärdateien ohne
den Leser für `HELIOS_DIAGNOSTIC_FEATURE_LEVEL` werden abgewiesen; eine bloße
Versionsnummer gilt nicht als Fähigkeit. Der Standardtreiber `.291` erhält
dadurch keine nachträglich hinzugefügten Funktionen.

Der erste Launcher unterstützt ausschließlich x64-EXE-Dateien. Die Verknüpfung
vom normalen Desktop starten; sie fordert selbst keine Administratorrechte an.
Der EXE-Hash wird gespeichert. Nach einem Spielupdate die Verknüpfung neu
erstellen, statt unbemerkt eine andere Datei mit altem Profil auszuführen.
Es werden keine globalen Vulkan-, OpenGL- oder D3D12-Schalter als angebliche
Anwendungsprofile ausgegeben.

## Minimieren, Wiederverbinden und Standby

Das passende Szenario auswählen und **Wiederaufnahme beobachten und testen**
starten. Im separaten Testfenster beginnt eine begrenzte Beobachtung. Die
gewählte Aktion am Host beziehungsweise Viewer selbst durchführen und danach
die sichtbare Ausgabe prüfen. Die Schaltfläche löst keinen Standby aus und
trennt nicht selbst die Verbindung oder Hardware ab.

Die Prüfung erfasst Adapterzustände während des Fensters, Paket-/Bootidentität
vorher und nachher, vorhandene DWM-Abstürze/Display-Resets und einen anschließenden
Grafiktest. Zusätzliche Pixel-/MSAA-Werkzeuge können wie im normalen Testlauf
angegeben werden. Auch wenn anschließend keine Geräteerstellung möglich ist,
bleiben Beobachtungen und Fehler als `resume.json` erhalten.

Ein Zeitabstand beweist keinen Standby. Deshalb bleibt die tatsächliche
Szenariodurchführung als menschliche Beobachtung gekennzeichnet, getrennt von
`technicalChecksPassed`. Ein neuer Boot, geändertes Paket, fehlende Proben oder
ausgefallene Adapter werden nicht als erfolgreicher technischer Test gewertet.

## Freigabestufen

- **experimental:** keine passende lokale Abnahme vorhanden.
- **vm-tested:** auf dieser VM mit dem aktuellen Paket und den aufgezeichneten
  Einstellungen geprüft und ausdrücklich sichtbar abgenommen.
- **Repository-Standard:** separate Eigenschaft des festgelegten Standardbundles.
  Aktuell `.291`, anhand Version und Manifest-Hash identifiziert.

**Nur auf dieser VM als getestet markieren** verlangt dieselbe frische,
bootgebundene Abnahme wie der Updateweg plus sichtbare Prüfung. Eine geänderte
Paketidentität oder ein anderes Einstellungsprofil verliert diese lokale
Zuordnung. **Lokale Freigabe zuruecknehmen** verwirft die Markierung.

Die lokale Markierung ist keine allgemeine Treiberzertifizierung und kein
Live-Stabilitätsversprechen nach jedem späteren Neustart. Ein erfolgreicher
CI-Build setzt keine Freigabe. Für einen neuen Repository-Standard müssen Bundle
und `helios-release-policy.json` gemeinsam geprüft und aktualisiert werden;
ein Test erzwingt ihre Übereinstimmung. Die Windows-Steuerung bietet dafür
keinen globalen Promotionsknopf an.

Die Abnahme ist zusätzlich an einen Hash aus Windows-Maschinenkennung und
SMBIOS-UUID gebunden. Die Rohkennungen werden nicht exportiert. Eine andere
VM-Identität erhält weder die lokale Freigabe noch eine alte Abnahme; nach dem
Update von älteren Belegen ist daher ein frischer Test nötig.

Die gespeicherten Vergleichs-, Wiederaufnahme- und Freigabedaten sind über
`GET /graphics/validation` lesbar. Dieser Endpunkt startet keine Programme und
führt keine Tests oder Promotionsaktionen aus.

## Prüfstand

Automatische Tests prüfen Anwendungsidentität und Prozessumgebung, Vergleichs-
und Freigabegates, fehlende Wiederaufnahmedaten, geschützte Vergleichsarchive,
Dashboard-Abfrageaufteilung und die gebündelten Diagnosehilfen. Windows CI baut
auch das tatsächliche WinForms-Formular ohne Treiberänderung auf.
Reales Standby-Verhalten und sichtbare Ausgabe auf der RTX 2070 müssen weiterhin
in der VM abgenommen werden. Diese Erweiterungen ersetzen keinen Treiberfix.

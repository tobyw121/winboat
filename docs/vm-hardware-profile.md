# Hardware-Kompatibilitätsprofil für neue VMs

Im Einrichtungsassistenten ist **Hardware compatibility profile** standardmäßig
eingeschaltet. **Reduce hypervisor CPU identifiers** ist separat abschaltbar.
Bestehende VMs werden nicht automatisch umgestellt.

## Einmalige Identität

WinBoat liest nur öffentlich zugängliche Hersteller-/Modellnamen aus
`/sys/class/dmi/id`: Systemhersteller, Produktname/-version und
Mainboardhersteller, -modell und -version. Platzhalter und bekannte virtuelle
Herstellernamen werden verworfen. Sind die Boarddaten nicht verwendbar, nutzt
WinBoat ein ASUS-Desktop-Preset. Dieses Preset ist keine Aussage über die
tatsächlich verbaute Host-Hardware; die Herkunft steht als `source` im Profil.

System-, Board- und Gehäuseseriennummer entstehen unabhängig mit Web Crypto
(je 80 Zufallsbits), die UUID als UUIDv4. Host-Seriennummern und Host-UUID werden
nicht gelesen. Namen und erzeugte Kennungen stehen im Installationsordner in
`winboat-hardware.json` mit Dateimodus 0600. Die binären SMBIOS-Strukturen 1, 2
und 3 liegen daneben in `.winboat-hardware/`. QEMU liest sie über die bestehende
Storage-Zuordnung ein. Leerzeichen in Herstellernamen bleiben dabei erhalten.

Bei weiteren Starts, Container-Neuerstellungen und erneuten Setup-Versuchen
wird dasselbe Profil verwendet. Die SMBIOS-Dateien können aus dem gespeicherten
Profil wiederhergestellt werden. Eine fehlende oder beschädigte Identität wird
bei vorhandener Windows-Disk nicht durch neue Zufallswerte ersetzt. Sichere
immer den gesamten Installationsordner mit Disk, JSON-Profil und SMBIOS-Dateien.

Die CPU-Auswahl im Assistenten ist unabhängig von den gespeicherten Seriennummern.
Normale Einstellungen wie CPU-Kerne, RAM und Helios-Umschaltung erhalten die
Identität. Zurücksetzen oder erneutes Würfeln für ein bereits installiertes
Windows ist kein Bestandteil dieser Funktion.

## CPU-Option

Die zusätzliche Option setzt dockurs `HV=N` und ergänzt `CPU_FLAGS` um
`kvm=off,-hypervisor`. Damit werden Hyper-V-Erweiterungen ausgelassen, die
KVM-Kennung unterdrückt und das CPUID-Hypervisor-Bit ausgeblendet. Der tatsächliche
CPU-Hersteller und das Host-CPU-Modell werden nicht durch erfundene Werte ersetzt.
**KVM-Hardwarebeschleunigung bleibt aktiviert.** Windows kann dadurch weniger
Paravirtualisierungsoptimierungen nutzen; Leistung und Kompatibilität müssen auf
dem Zielhost geprüft werden. Für unveränderte CPU-Merkmale die Unteroption vor
der Einrichtung abschalten, während das Herstellerprofil eingeschaltet bleibt.

## Grenzen bei Helios und VirtIO

Helios-/VirtIO-PCI-Kennungen, INF-Zuordnung, signierte Treiber und die
Venus-Schnittstelle bleiben erhalten. Ein umbenannter Eintrag im Geräte-Manager
ändert diese Merkmale nicht. Andere PCI-IDs würden abgestimmte Änderungen an
Gerätemodell, Treiberpaket und Signierung erfordern. Auch danach bleiben weitere
Hinweise in Firmware, ACPI, Geräten und Zeitverhalten möglich.

Das Profil beeinflusst einfache SMBIOS-/CPU-Prüfungen. Es bietet weder eine
vollständig unsichtbare VM noch eine Garantie für Anti-Cheat oder Spiele.

## Prüfen

In Windows nach der Installation:

```powershell
Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, HypervisorPresent
Get-CimInstance Win32_ComputerSystemProduct | Select-Object Vendor, Name, IdentifyingNumber, UUID
Get-CimInstance Win32_BaseBoard | Select-Object Manufacturer, Product, SerialNumber
```

Entwicklungstests:

```bash
npm run test:helios
npm run test:vm-identity:qemu
```

Der QEMU-Test bootet einen kleinen Diagnose-Bootsektor mit SeaBIOS unter TCG, prüft das
CPUID-Bit direkt im Gast und liest die tatsächlichen Firmware-SMBIOS-Tabellen
über QMP aus. Er prüft beide CPU-Modi, Namen mit Leerzeichen, Seriennummern und
UUID. Er verwendet keine Windows-Disk, keine physische GPU und kein KVM und
bestätigt deshalb keine Windows-/Gaming-Kompatibilität.

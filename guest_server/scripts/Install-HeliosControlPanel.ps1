$ErrorActionPreference='Stop'
$folder=Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\WinBoat'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$shell=New-Object -ComObject WScript.Shell
$shortcut=$shell.CreateShortcut((Join-Path $folder 'Helios Control.lnk'))
$shortcut.TargetPath="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$shortcut.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Show-HeliosControlPanel.ps1')+'"'
$shortcut.Description='Helios graphics diagnostics and driver options. Run as Administrator.'
$shortcut.Save()
# Request elevation through the shortcut's documented run-as flag.
$path=Join-Path $folder 'Helios Control.lnk'
$bytes=[IO.File]::ReadAllBytes($path);$bytes[21]=$bytes[21] -bor 0x20
[IO.File]::WriteAllBytes($path,$bytes)

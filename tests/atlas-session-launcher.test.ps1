param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $RepoRoot 'guest_server/scripts/AtlasSessionLauncher.cs')
$flags = [Reflection.BindingFlags]::NonPublic
$startup = [WinBoat.AtlasSessionLauncher].GetNestedType('StartupInfo', $flags)
$process = [WinBoat.AtlasSessionLauncher].GetNestedType('ProcessInfo', $flags)
$expectedStartup = if ([IntPtr]::Size -eq 8) {104} else {68}
$expectedProcess = if ([IntPtr]::Size -eq 8) {24} else {16}
$sizeOf = [Runtime.InteropServices.Marshal].GetMethod('SizeOf', [type[]]@([Type]))
if ($sizeOf.Invoke($null, [object[]]@($startup)) -ne $expectedStartup -or
    $sizeOf.Invoke($null, [object[]]@($process)) -ne $expectedProcess) { throw 'Windows process structures have invalid native layouts.' }
Write-Host 'Actual C# session helper compiled; native Windows structure layouts passed. Windows APIs were not executed.'

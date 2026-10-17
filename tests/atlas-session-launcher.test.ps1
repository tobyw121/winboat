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
Add-Type -Path (Join-Path $RepoRoot 'guest_server/scripts/AtlasProcessDiagnostics.cs')
$node = [WinBoat.AtlasProcessDiagnostics].GetNestedType('WaitNode', $flags)
if ($sizeOf.Invoke($null, [object[]]@($node)) -ne 280) { throw 'WCT native union has invalid size.' }
if ([WinBoat.AtlasProcessDiagnostics]::ClassifyDesktop('Default') -ne 'default' -or
    [WinBoat.AtlasProcessDiagnostics]::ClassifyDesktop('Winlogon') -ne 'winlogon' -or
    [WinBoat.AtlasProcessDiagnostics]::ClassifyDesktop('private-user-name') -ne 'other') { throw 'Desktop labels exposed a custom name.' }
$guard = [WinBoat.AtlasSessionLauncher].GetMethod('Require', [Reflection.BindingFlags]'Static,NonPublic')
try { $guard.Invoke($null, [object[]]@($false,'client-owner-mismatch')); throw 'Expected guard rejection.' }
catch {
    $e=$_.Exception
    while ($null -ne $e.InnerException) {$e=$e.InnerException}
    if ($e.ReasonCode -ne 'client-owner-mismatch' -or $e.Message -match 'SID|private') {throw 'Guard lost its safe reason code.'}
}
Write-Host 'Read-only inspector compiled, native WCT union layout, desktop labels and guard reason propagation passed.'

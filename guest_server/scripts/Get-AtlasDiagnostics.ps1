# Fixed read-only diagnostics. Never return credentials, command lines or raw logs.
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Select-AtlasStartupLines([string[]]$Lines) {
    foreach ($line in $Lines) {
        # Return only AME's fixed startup messages, numeric WNF states and timestamps.
        if ($line -match '(?<phase>(?:\d{2}:\d{2}:\d{2}\.\d{4}: )?(?:Worker Start|WNF Wait(?:ed)?|Window Launched|WNF Published \d+|Monitor [123]: \d+|LogonComplete [123]: \d+))["'']?\s*$') {
            $Matches.phase
        }
    }
}
if ($LibraryOnly) { return }
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$result = [ordered]@{ collectedAtUtc = [DateTime]::UtcNow.ToString('o'); errors = @() }
$root = Join-Path $env:ProgramData 'AME'
try {
    $result.service = @(Get-CimInstance Win32_Service -Filter "Name='ameoobe'" |
        Select-Object Name, State, StartMode, ProcessId, ExitCode, ServiceSpecificExitCode)
} catch { $result.errors += 'AME service status unavailable' }
$result.processes = @(Get-Process -Name 'OOBE','AME.Client','msoobe','msoobeext','CloudExperienceHost','UserOOBEBroker','LogonUI' -ErrorAction SilentlyContinue |
    Select-Object ProcessName, Id, SessionId, Responding)
$result.files = @(foreach ($name in @('AME.Client.exe','OOBE.exe','oobe.conf','Playbook\playbook.conf')) {
    $file = Join-Path (Join-Path $root 'OOBE') $name
    [ordered]@{ name = $name; exists = (Test-Path -LiteralPath $file -PathType Leaf) }
})
try {
    $task = Get-ScheduledTask -TaskName 'WinBoatAtlasOOBE'
    $info = $task | Get-ScheduledTaskInfo
    $result.observer = [ordered]@{ state = $task.State.ToString(); lastResult = $info.LastTaskResult }
} catch { $result.errors += 'WinBoat Atlas observer status unavailable' }
try {
    $result.startup = @(Select-AtlasStartupLines (Get-Content -LiteralPath (Join-Path $root 'Logs\Log.yml') -Tail 400))
} catch { $result.errors += 'AME startup log unavailable' }
try {
    $key = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
    $result.windowsSetup = [ordered]@{}
    foreach ($name in @('OOBEInProgress','SystemSetupInProgress','SetupType')) {
        if ($null -ne $key.PSObject.Properties[$name]) { $result.windowsSetup[$name] = [int]$key.$name }
    }
} catch { $result.errors += 'Windows setup state unavailable' }
$result | ConvertTo-Json -Depth 6 -Compress

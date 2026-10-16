param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$script = Join-Path $RepoRoot 'guest_server/scripts/Start-AtlasProvisioning.ps1'
$parseErrors = $null; $tokens = $null
[Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
. $script -LibraryOnly
$now = [DateTime]::UtcNow
$ok = [pscustomobject]@{ Version = '0.5.0'; ErrorLevel = 0; AppliedTimeUTC = $now.ToBinary() }
if (-not (Test-AtlasApplied $ok $now.AddSeconds(-1))) { throw 'Valid completion rejected.' }
if (Test-AtlasApplied $ok $now.AddSeconds(1)) { throw 'Stale success accepted.' }
foreach ($bad in @($null, [pscustomobject]@{}, [pscustomobject]@{Version='0.5.0';ErrorLevel=1;AppliedTimeUTC=$now.ToBinary()}, [pscustomobject]@{Version='0.4.1';ErrorLevel=0;AppliedTimeUTC=$now.ToBinary()})) {
    if (Test-AtlasApplied $bad $now.AddSeconds(-1)) { throw 'Incomplete, failed or old playbook accepted.' }
}
Write-Host 'Atlas PowerShell parsing and fresh completion/error validation passed.'
$oobeScript = Join-Path $RepoRoot 'guest_server/scripts/Start-AtlasOOBE.ps1'
[Management.Automation.Language.Parser]::ParseFile($oobeScript, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
. $oobeScript -LibraryOnly
$ok | Add-Member SelectedOptions @('defender-enable','mitigations-default','auto-updates-default')
if (-not (Test-AtlasOOBEApplied $ok $now.AddSeconds(-1))) { throw 'Valid OOBE result rejected.' }
$ok.SelectedOptions = @('defender-disable')
if (Test-AtlasOOBEApplied $ok $now.AddSeconds(-1)) { throw 'Unexpected OOBE profile accepted.' }
$entry = [pscustomobject]@{ originalType = 4; originalBytes = @(5,0,0,0) }
if ((Convert-AtlasRegistryBackup $entry) -ne 5) { throw 'Registry DWORD backup was not preserved.' }
if (-not (Test-AtlasCliCompleted 0 "10% Starting...`r`nPlaybook completed successfully.`r`n")) { throw 'CLI success rejected.' }
foreach ($output in @('', 'Preparation finished. Please restart.', 'Playbook completed with errors.', "Playbook completed successfully.`nPlaybook completed with errors.")) {
    if (Test-AtlasCliCompleted 0 $output) { throw 'CLI preparation/errors mistaken for success.' }
}
if (Test-AtlasCliCompleted 1 'Playbook completed successfully.') { throw 'Failed process accepted.' }
Write-Host 'OOBE selected options, registry backup conversion and actual CLI completion validation passed.'
$diagnosticsScript = Join-Path $RepoRoot 'guest_server/scripts/Get-AtlasDiagnostics.ps1'
[Management.Automation.Language.Parser]::ParseFile($diagnosticsScript, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
. $diagnosticsScript -LibraryOnly
$lines = @(Select-AtlasStartupLines @('Message: "23:13:12.3456: Worker Start"', '  "Monitor 1: 101"', 'Password: private', 'Exception: net user test private', 'noise'))
if ($lines.Count -ne 2 -or $lines[0] -ne '23:13:12.3456: Worker Start' -or $lines[1] -ne 'Monitor 1: 101') { throw 'Startup diagnostic allowlist failed.' }
Write-Host 'Read-only diagnostic script parsing and startup-log allowlist passed.'
# Exercise the entire collector with OS-query fixtures; the real Windows state
# still needs to be collected on the affected VM.
function Get-CimInstance { param($ClassName, $Filter) [pscustomobject]@{ Name='ameoobe'; State='Running'; StartMode='Auto'; ProcessId=42; ExitCode=0; ServiceSpecificExitCode=0 } }
function Get-Process { [CmdletBinding()]param($Name) [pscustomobject]@{ProcessName='OOBE'; Id=42; SessionId=0; Responding=$true} }
function Get-ScheduledTask { param($TaskName) [pscustomobject]@{State='Running'} }
function Get-ScheduledTaskInfo { [pscustomobject]@{LastTaskResult=267009} }
function Get-Content { param($LiteralPath, $Tail) 'Message: "23:13:12.3456: Worker Start"'; 'Password: private' }
function Get-ItemProperty { param($Path) [pscustomobject]@{OOBEInProgress=1; SystemSetupInProgress=0; SetupType=0} }
$oldProgramData = $env:ProgramData
try {
    $env:ProgramData = [IO.Path]::GetTempPath()
    $json = & $diagnosticsScript
    $result = $json | ConvertFrom-Json
    if ($result.service[0].ProcessId -ne 42 -or $result.windowsSetup.OOBEInProgress -ne 1 -or $result.startup.Count -ne 1 -or $json -match 'private') { throw 'Full diagnostic collection failed or leaked log contents.' }
} finally { $env:ProgramData = $oldProgramData }
Write-Host 'Full diagnostic collection passed with Windows-query fixtures (not a Windows VM test).'

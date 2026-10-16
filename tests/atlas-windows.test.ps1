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
function Get-CimInstance {
    param($ClassName, $Filter)
    if ($ClassName -eq 'Win32_UserAccount') { return [pscustomobject]@{SID='S-1-5-21-1-2-3-1000'; Disabled=$false} }
    [pscustomobject]@{ Name='ameoobe'; State='Running'; StartMode='Auto'; ProcessId=42; ExitCode=0; ServiceSpecificExitCode=0 }
}
function Get-Process { [CmdletBinding()]param($Name) [pscustomobject]@{ProcessName='OOBE'; Id=42; SessionId=0; Responding=$true} }
function Get-ScheduledTask { param($TaskName) [pscustomobject]@{State='Running'} }
function Get-ScheduledTaskInfo { [pscustomobject]@{LastTaskResult=267009} }
function Get-Content { param($LiteralPath, $Tail) 'Message: "23:13:12.3456: Worker Start"'; 'Password: private' }
function Get-ItemProperty {
    param($Path)
    if ($Path -like '*Winlogon') { return [pscustomobject]@{Shell=('"{0}" --oobe' -f (Join-Path $env:ProgramData 'AME/OOBE/AME.Client.exe')); DefaultUserName='defaultuser0'} }
    [pscustomobject]@{OOBEInProgress=1; SystemSetupInProgress=0; SetupType=0}
}
function Get-Acl {
    param($LiteralPath)
    $acl = [pscustomobject]@{AreAccessRulesProtected=$true}
    $acl | Add-Member ScriptMethod GetAccessRules {
        param($Explicit, $Inherited, $Type)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-21-1-2-3-1000')) {
            [pscustomobject]@{IdentityReference=[pscustomobject]@{Value=$sid}; FileSystemRights=2032127; AccessControlType='Allow'; IsInherited=$false}
        }
    }
    $acl
}
function Get-FileHash { param($LiteralPath, $Algorithm) [pscustomobject]@{Hash='c2b4f73bc9615e2981b9c60bb51974ed67539873dbd3d29b97258e21fa3ada7d'} }
$oldProgramData = $env:ProgramData
$oldSystemRoot = $env:SystemRoot
try {
    $env:ProgramData = [IO.Path]::GetTempPath()
    $env:SystemRoot = [IO.Path]::GetTempPath()
    $json = & $diagnosticsScript
    $result = $json | ConvertFrom-Json
    if ($result.service[0].ProcessId -ne 42 -or $result.windowsSetup.OOBEInProgress -ne 1 -or $result.startup.Count -ne 1 -or $json -match 'private') { throw 'Full diagnostic collection failed or leaked log contents.' }
    if ($result.errors.Count -or $result.logon.shell -ne 'ame-oobe' -or -not $result.shim.originalAME -or
        -not $result.setupAccount.exists -or $result.amePermissions[0].rules[2].principal -ne 'setup-account' -or $json -match 'S-1-5-21') { throw 'Shell/permissions diagnostics failed or exposed machine identifiers.' }
} finally { $env:ProgramData = $oldProgramData; $env:SystemRoot = $oldSystemRoot }
$failureKinds = @(Select-AtlasFailureKinds @('System.UnauthorizedAccessException: private', 'HResult: 0x80070005', 'Password: private', 'System.UnauthorizedAccessException'))
if ($failureKinds.Count -ne 2 -or $failureKinds[0] -ne 'System.UnauthorizedAccessException' -or $failureKinds[1] -ne '0x80070005') { throw 'Failure-type allowlist failed.' }
if ((Get-AtlasShellKind 'explorer.exe' 'client.exe') -ne 'windows-explorer' -or
    (Get-AtlasShellKind 'unexpected private command' 'client.exe') -ne 'other') { throw 'Shell classification leaked an unknown command.' }
if ((Get-AtlasShellKind '"C:\ProgramData\\AME\\OOBE\\AME.Client.exe" --oobe' 'C:\ProgramData\AME\OOBE\AME.Client.exe') -ne 'ame-oobe') { throw 'Pinned shim shell path was not recognized.' }
Write-Host 'Full diagnostic collection passed with Windows-query fixtures (not a Windows VM test).'

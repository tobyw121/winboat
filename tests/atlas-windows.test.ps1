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
# Windows PowerShell 5.1 uses the external CodeDOM compiler. Compile the
# native helper before replacing SystemRoot and Windows query functions with
# fixtures; the collector's process list below cannot invoke its native APIs.
if ($env:OS -eq 'Windows_NT' -and -not ('WinBoat.AtlasProcessDiagnostics' -as [type])) {
    Add-Type -Path (Join-Path $RepoRoot 'guest_server/scripts/AtlasProcessDiagnostics.cs')
}
function Get-CimInstance {
    param($ClassName, $Filter)
    if ($ClassName -eq 'Win32_UserAccount') { return [pscustomobject]@{SID='S-1-5-21-1-2-3-1000'; Disabled=$false} }
    if ($ClassName -eq 'Win32_ComputerSystem') { return [pscustomobject]@{UserName='PRIVATE-PC\defaultuser0'} }
    [pscustomobject]@{ Name='ameoobe'; State='Running'; StartMode='Auto'; ProcessId=42; ExitCode=0; ServiceSpecificExitCode=0 }
}
function Get-Process { [CmdletBinding()]param($Name) [pscustomobject]@{ProcessName='OOBE'; Id=42; SessionId=0; Responding=$true} }
function Get-WinEvent { [CmdletBinding()]param($FilterHashtable,$MaxEvents) @() }
function Get-ScheduledTask { param($TaskName) [pscustomobject]@{State='Running'} }
function Get-ScheduledTaskInfo { [pscustomobject]@{LastTaskResult=267009} }
function Get-Content { param($LiteralPath, $Tail) 'Message: "23:13:12.3456: Worker Start"'; 'Password: private' }
function Get-ItemProperty {
    param($Path)
    if ($Path -like '*Winlogon') { return [pscustomobject]@{Shell=('"{0}" --oobe' -f (Join-Path $env:ProgramData 'AME/OOBE/AME.Client.exe')); DefaultUserName='defaultuser0'; DefaultPassword='private'; AutoAdminLogon='1'; AutoLogonCount=0; ForceAutoLogon='private'} }
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
    $checks=[ordered]@{
        errorsAbsent=($result.errors.Count -eq 0)
        ameShell=($result.logon.shell -eq 'ame-oobe')
        originalShim=[bool]$result.shim.originalAME
        setupAccount=[bool]$result.setupAccount.exists
        credentialPresence=[bool]$result.logon.setupCredentialPresent
        consoleAccount=($result.logon.consoleAccount -eq 'setup-account')
        permissionPrincipal=($result.amePermissions[0].rules[2].principal -eq 'setup-account')
        autoLogon=($result.logon.AutoAdminLogon -eq 1)
        logonCount=($result.logon.AutoLogonCount -eq 0)
        redaction=($json -notmatch 'S-1-5-21|PRIVATE-PC|private')
    }
    $failedChecks=@($checks.Keys | Where-Object {-not $checks[$_]})
    if($failedChecks.Count){throw ('Shell/permissions diagnostic checks failed: '+($failedChecks -join ', '))}
    if ($result.diagnosticsVersion -ne 2 -or $result.collectorHash.Length -ne 64) { throw 'Collector identity missing.' }
    function Get-ScheduledTask { param($TaskName) Write-Error -ErrorId 'NoMatchingMSFT_ScheduledTaskObjectsFound_TaskName' -Message 'private task detail' -ErrorAction Stop }
    $missingTask = & $diagnosticsScript | ConvertFrom-Json
    if ($missingTask.observer.state -ne 'not-registered' -or $missingTask.errors.Count) { throw 'Expected observer removal was mistaken for a collector failure.' }
} finally { $env:ProgramData = $oldProgramData; $env:SystemRoot = $oldSystemRoot }
$failureKinds = @(Select-AtlasFailureKinds @('System.UnauthorizedAccessException: private', 'HResult: 0x80070005', 'Password: private', 'System.UnauthorizedAccessException'))
if ($failureKinds.Count -ne 2 -or $failureKinds[0] -ne 'System.UnauthorizedAccessException' -or $failureKinds[1] -ne '0x80070005') { throw 'Failure-type allowlist failed.' }
if ((Get-AtlasShellKind 'explorer.exe' 'client.exe') -ne 'windows-explorer' -or
    (Get-AtlasShellKind 'unexpected private command' 'client.exe') -ne 'other') { throw 'Shell classification leaked an unknown command.' }
if ((Get-AtlasShellKind '"C:\ProgramData\\AME\\OOBE\\AME.Client.exe" --oobe' 'C:\ProgramData\AME\OOBE\AME.Client.exe') -ne 'ame-oobe') { throw 'Pinned shim shell path was not recognized.' }
Write-Host 'Full diagnostic collection passed with Windows-query fixtures (not a Windows VM test).'
if (-not (Get-AtlasHandoffFailure ([pscustomobject]@{State='Stopped';ExitCode=1067}) '')) { throw 'Stopped AME service was mistaken for progress.' }
if (Get-AtlasHandoffFailure ([pscustomobject]@{State='Running';ExitCode=0}) 'user') { throw 'Active user was mistaken for a blocked handoff.' }
function Get-ItemProperty { param($Path) [pscustomobject]@{DefaultUserName='defaultuser0';AutoAdminLogon='0'} }
if (-not (Get-AtlasHandoffFailure ([pscustomobject]@{State='Running';ExitCode=0}) '')) { throw 'Disabled setup autologon was mistaken for progress.' }
# Read through .NET: earlier diagnostic fixtures override Get-Content.
$reg = [IO.File]::ReadAllText((Join-Path $RepoRoot 'guest_server/RDPApps.reg'))
if ($reg -match 'AutoAdminLogon|Winlogon') { throw 'Early RemoteApp tweaks must not disable AME setup autologon.' }
Write-Host 'AME service/logon stalls and early RemoteApp registry policy passed.'
$events = @(
    [pscustomobject]@{Id=1026;ProviderName='.NET Runtime';TimeCreated=[DateTime]::UtcNow;Message='Application: OOBE.exe System.InvalidOperationException secret-password C:\Users\private 0x80004005'},
    [pscustomobject]@{Id=1000;ProviderName='Application Error';TimeCreated=[DateTime]::UtcNow;Message='unrelated.exe private'},
    [pscustomobject]@{Id=1000;ProviderName='unexpected';TimeCreated=[DateTime]::UtcNow;Message='OOBE.exe private'}
)
$events[0] | Add-Member ScriptMethod ToXml {
    '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><EventData><Data Name="ModuleName">C:\private\Microsoft.UI.Xaml.dll</Data><Data Name="ExceptionCode">c0000005</Data></EventData></Event>'
}
$filtered = @(Select-AtlasCrashEvents $events)
$json = $filtered | ConvertTo-Json -Depth 4
if ($filtered.Count -ne 1 -or $filtered[0].failureKinds.Count -ne 2 -or $filtered[0].module -ne 'Microsoft.UI.Xaml.dll' -or $filtered[0].exceptionCode -ne '0xc0000005' -or $json -match 'secret-password|Users|private') { throw 'Crash diagnostics did not filter unrelated events or exposed raw messages.' }
if ((Get-AtlasWindowKind 'An unexpected initialization error occured') -ne 'initialization-error' -or
    (Get-AtlasWindowKind 'private-password-in-title') -ne 'other') { throw 'Window-title classifier leaked custom text.' }
Write-Host 'Application crash event and window classification allowlists passed.'

if (Get-AtlasHandoffFailure ([pscustomobject]@{State='Stopped';ExitCode=1067}) 'user' $true) { throw 'A live AME client was treated as a failed playbook solely from the service exit code.' }
if ((Get-AtlasHandoffPhase @('Message: "06:41:05.2244: Worker Start"','Message: "23:45:08.7598: WNF Waited"')) -ne 'handshake-ended-without-window') {throw 'Ended UI handshake was not classified.'}
if ((Get-AtlasHandoffPhase @('06:41:05.2244: Worker Start','23:45:08.7598: WNF Waited','23:45:09.1111: Window Launched')) -ne 'window-launched') {throw 'A successful UI launch was mistaken for a stalled client.'}
if ((Get-AtlasHandoffPhase @('23:45:08.7598: L','23:46:01.1111: Worker Start')) -ne 'waiting-for-ui') {throw 'An earlier timeout was reused for a new service start.'}
$guiLines=@('Message: "04:26:24.9941: Worker Start"','Message: "04:26:27.1111Window Loaded"',
    'Message: "04:26:27.2222Window Thread Started"','Message: "04:26:27.3333Window InterLink Initialized"',
    'Message: "04:26:27.4444Window Registered"','Message: "04:26:27.5555Window Signaled"',
    'Message: "04:26:27.6666Waiting Anim"','Password: private','Message: "Window Registered private"')
$selected=@(Select-AtlasStartupLines $guiLines)
if ($selected.Count -ne 7 -or ($selected -join ' ') -match 'private') {throw 'GUI progress was filtered out or raw data was exposed.'}
if ((Get-AtlasGUIStartupPhase $guiLines) -ne 'waiting-for-first-logon-animation' -or
    (Get-AtlasGUIStartupPhase ($guiLines + '04:30:00.0000: Worker Start')) -ne 'not-reported' -or
    (Get-AtlasGUIStartupPhase @('Message: "Service event could not be opened."')) -ne 'service-event-unavailable') {throw 'GUI stage classification reused stale progress or missed a service-event failure.'}
Write-Host 'Original AME GUI milestone formats, latest-start boundaries and credential filtering passed.'
$oldProgramData=$env:ProgramData; $oldSystemRoot=$env:SystemRoot
try {
    $env:ProgramData=[IO.Path]::GetTempPath(); $env:SystemRoot=$env:ProgramData
    function Test-Path { param($LiteralPath,$PathType) return ($LiteralPath -match 'Logs(?:[/\\]Log\.yml)?$') }
    $withLogAccess=& $diagnosticsScript | ConvertFrom-Json
    $labels=@($withLogAccess.amePermissions | ForEach-Object {$_.file})
    if ($labels.Count -ne 5 -or 'Logs-directory' -notin $labels -or 'Log.yml' -notin $labels -or
        ($withLogAccess | ConvertTo-Json -Depth 10) -match 'private|S-1-5-21') {throw 'Log ACL inspection failed or leaked identities/log contents.'}
} finally {$env:ProgramData=$oldProgramData; $env:SystemRoot=$oldSystemRoot}
Write-Host 'Optional log directory/file ACL inspection passed with OS-query fixtures.'
$folder=Join-Path ([IO.Path]::GetTempPath()) 'AME/OOBE'
if ((Get-AtlasServiceExecutable ('"{0}" --service' -f (Join-Path $folder 'AME.Client.exe')) $folder) -ne 'shared-client' -or
    (Get-AtlasServiceExecutable ('"{0}" --service' -f (Join-Path $folder 'OOBE.exe')) $folder) -ne 'legacy-oobe' -or
    (Get-AtlasServiceExecutable 'private-executable --service' $folder) -ne 'other') {throw 'Service executable classification failed or exposed unknown commands.'}

if ((Get-AtlasShellKind '"C:/ProgramData/AME/OOBE/AME.Client.exe" --oobe' 'C:\ProgramData\AME\OOBE\AME.Client.exe') -ne 'ame-oobe') { throw 'Windows slash-separated AME path was not recognized.' }

param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$scriptFile = Join-Path $RepoRoot 'guest_server/scripts/Start-AtlasOOBEClient.ps1'
$parseErrors=$null; $tokens=$null
[Management.Automation.Language.Parser]::ParseFile($scriptFile, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
. $scriptFile -LibraryOnly
$state = [pscustomobject]@{mode='ame-oobe'; release='0.5.0-hotfix'; applied=$false;
    diagnostics=[pscustomobject]@{errors=@(); shim=@{originalAME=$true}; files=@(@{exists=$true},@{exists=$true},@{exists=$true},@{exists=$true});
        logon=@{shell='ame-oobe'}; setupAccount=@{exists=$true; disabled=$false}; processes=@(@{ProcessName='LogonUI'})}}
if ($null -ne (Test-AtlasUILaunchState $state)) { throw 'Incomplete setup was rejected.' }
foreach ($mutate in @({param($s) $s.applied=$true}, {param($s) $s.diagnostics.setupAccount.disabled=$true},
    {param($s) $s.diagnostics.processes += [pscustomobject]@{ProcessName='AME.Client';SessionId=1}},
    {param($s) $s.diagnostics.shim.originalAME=$false})) {
    $copy = $state | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    & $mutate $copy
    if (-not (Test-AtlasUILaunchState $copy)) { throw 'An unsafe UI launch was accepted.' }
}
# A separate fixture type tests orchestration; the real native helper is compiled
# independently in atlas-session-launcher.test.ps1, not executed on Linux.
Add-Type -TypeDefinition @'
namespace WinBoat {
 public static class AtlasSessionLauncher {
  public static bool ValidSession, ServiceStarted;
  public static int Stops;
  public static void ValidateStalled(uint pid,string exe,string sid) { ValidateSession(sid); }
  public static void StopStalled(uint pid,string exe,string sid) {
   ValidateSession(sid); if(ServiceStarted) throw new System.Exception("Stop must precede restart"); Stops++;
  }
  public static void ValidateSession(string sid) { if(!ValidSession) throw new System.ComponentModel.Win32Exception(1008); }
  public sealed class Result { public int ProcessId=123; public int SessionId=1; public uint? EarlyExitCode; }
  public static Result Start(string exe, string sid) {
   if(!ServiceStarted) throw new System.Exception("Service must be ready before GUI startup");
   return new Result();
  }
 }
}
'@
function Add-Type { param($Path) if ($Path -notlike '*AtlasSessionLauncher.cs') { throw 'Unexpected code path.' } }
$global:atlasUiServiceRestarts=0
function Restart-Service { [CmdletBinding()]param($Name) $global:atlasUiServiceRestarts++; [WinBoat.AtlasSessionLauncher]::ServiceStarted=$true }
function Get-Service {
    param($Name)
    $service = [pscustomobject]@{}
    $service | Add-Member ScriptMethod WaitForStatus {param($State, $Timeout) if ($State -ne 'Running') { throw 'Unexpected service wait.' }}
    $service
}
$blocked=$false
try { Invoke-AtlasSessionLaunch 'client.exe' 'setup-sid' | Out-Null } catch { $blocked=$true }
if (-not $blocked -or $global:atlasUiServiceRestarts) { throw 'Service changed before validating the signed-in setup user.' }
[WinBoat.AtlasSessionLauncher]::ValidSession=$true
$result = Invoke-AtlasSessionLaunch 'client.exe' 'setup-sid'
if ($result.ProcessId -ne 123 -or $result.SessionId -ne 1 -or $global:atlasUiServiceRestarts -ne 1) { throw 'UI was not started through the validated session and service handshake.' }
Write-Host 'UI launch preflight and no-session refusal passed with mocked Windows operations.'
$stalled = $state | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$stalled.diagnostics | Add-Member handoffPhase 'handshake-ended-without-window'
$stalled.diagnostics.logon | Add-Member consoleAccount 'setup-account'
$stalled.diagnostics | Add-Member service @(@{State='Stopped';ExitCode=1067})
$stalled.diagnostics.processes += [pscustomobject]@{ProcessName='AME.Client';Id=123;SessionId=1}
if (Test-AtlasUILaunchState $stalled $true) { throw 'Verified stalled client was rejected.' }
if (-not (Test-AtlasUILaunchState $stalled)) { throw 'Ordinary launch must not terminate an existing client.' }
foreach ($mutate in @(
    {param($s) $s.diagnostics.handoffPhase='window-launched'},
    {param($s) $s.diagnostics.service[0].State='Running'},
    {param($s) $s.diagnostics.logon.consoleAccount='other'},
    {param($s) $s.diagnostics.processes += [pscustomobject]@{ProcessName='AME.Client';SessionId=1}},
    {param($s) $s.applied=$true}
)) {
    $copy=$stalled | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    & $mutate $copy
    if (-not (Test-AtlasUILaunchState $copy $true)) { throw 'Restart accepted active UI, another user, multiple clients or applied playbook.' }
}
Write-Host 'Explicit stalled UI restart preflight guards passed; no processes were terminated.'
$serviceOnly=$state | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$serviceOnly.diagnostics.processes += [pscustomobject]@{ProcessName='AME.Client';SessionId=0}
if (Test-AtlasUILaunchState $serviceOnly) {throw 'The canonical service executable was mistaken for an active GUI.'}
$copy=$state | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$copy.diagnostics.errors=@('WinBoat Atlas observer status unavailable')
if (Test-AtlasUILaunchState $copy) {throw 'Missing observer incorrectly prevents verified original UI startup.'}
$copy.diagnostics.errors+= 'AME setup-account permissions unavailable'
if (-not (Test-AtlasUILaunchState $copy)) {throw 'A critical verification error was ignored.'}
# Execute the complete action against a temporary runtime with only Windows
# operations substituted. No Windows process or real service is touched.
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('atlas-ui-action-'+[Guid]::NewGuid().ToString('N'))
$oldData=$env:ProgramData; $oldRoot=$env:SystemRoot
try {
    $env:ProgramData=$temporary; $env:SystemRoot=$temporary
    $scripts=Join-Path $temporary 'scripts'
    $root=Join-Path $temporary 'WinBoat/Atlas'
    New-Item -ItemType Directory -Force $scripts,$root,(Join-Path $temporary 'AME/OOBE') | Out-Null
    Copy-Item $scriptFile (Join-Path $scripts 'Start-AtlasOOBEClient.ps1')
    'param([switch]$LibraryOnly) function Grant-AtlasSetupAccountAccess {return $true}' | Set-Content (Join-Path $scripts 'Start-AtlasOOBE.ps1')
    '$global:atlasActionDiagnostic' | Set-Content (Join-Path $scripts 'Get-AtlasDiagnostics.ps1')
    @{mode='ame-oobe';release='0.5.0-hotfix'} | ConvertTo-Json | Set-Content (Join-Path $root 'oobe-mode.json')
    $global:atlasActionDiagnostic=$stalled | Select-Object -ExpandProperty diagnostics | ConvertTo-Json -Depth 8
    function Get-ItemProperty { [CmdletBinding()]param($Path) $null }
    function Get-FileHash {param($LiteralPath,$Algorithm) [pscustomobject]@{Hash='7985a9d5fb1e40cf8840f35e5ecee6332f31d9279b30dfa06ef8d2435b417af6'} }
    function Get-CimInstance {param($ClassName,$Filter) [pscustomobject]@{SID='S-1-5-21-1-2-3-1000'} }
    function Get-Process { [CmdletBinding()]param($Name) @() }
    $global:atlasObserverRefreshes=0
    function Start-Process {
        param($FilePath,$ArgumentList)
        if ($ArgumentList -notmatch 'Start-AtlasOOBE.ps1.*-Register') {throw 'Unexpected background operation.'}
        $global:atlasObserverRefreshes++
    }
    [WinBoat.AtlasSessionLauncher]::ServiceStarted=$false
    $result=& (Join-Path $scripts 'Start-AtlasOOBEClient.ps1') -RestartStalled | ConvertFrom-Json
    if ($result.status -ne 'launched' -or [WinBoat.AtlasSessionLauncher]::Stops -ne 1 -or $global:atlasObserverRefreshes -ne 1) {throw ('Explicit UI retry did not stop/start/refresh in order: '+($result | ConvertTo-Json -Compress))}
    $repeat=& (Join-Path $scripts 'Start-AtlasOOBEClient.ps1') -RestartStalled | ConvertFrom-Json
    if ($repeat.status -ne 'blocked' -or [WinBoat.AtlasSessionLauncher]::Stops -ne 1) {throw 'A repeated action bypassed its persistent guard.'}
    Write-Host 'Complete retry dispatch, stop/start sequencing, observer refresh and one-attempt persistence passed with Windows API fixtures.'
    Remove-Item (Join-Path $root 'ui-restart-attempt.json')
    [WinBoat.AtlasSessionLauncher]::ValidSession=$false
    $stops=[WinBoat.AtlasSessionLauncher]::Stops
    $blocked=& (Join-Path $scripts 'Start-AtlasOOBEClient.ps1') -RestartStalled | ConvertFrom-Json
    if ($blocked.status -ne 'blocked' -or $blocked.stage -ne 'validate-stalled-client' -or
        $blocked.errorCode -ne 1008 -or $blocked.reason -ne 'operation-failed' -or
        [WinBoat.AtlasSessionLauncher]::Stops -ne $stops -or (Test-Path (Join-Path $root 'ui-restart-attempt.json'))) {throw 'Native refusal lost its stage or changed a client before validation.'}
    Write-Host 'Native validation failure preserves its stage/code and does not consume a retry or stop a client.'
    # Run the actual IPC repair against a legacy service fixture; native process
    # operations are still the guarded fixture type, not real Windows processes.
    Copy-Item (Join-Path $RepoRoot 'guest_server/scripts/Repair-AtlasIPC.ps1') $scripts
    Copy-Item $scriptFile (Join-Path $scripts 'Start-AtlasOOBEClient.ps1') -Force
    @'
param([switch]$LibraryOnly)
function Get-AtlasServiceExecutable($Command,$Folder) {
 if($Command -eq 'legacy') {return 'legacy-oobe'}
 if($Command -eq ('"{0}" --service' -f (Join-Path $Folder 'AME.Client.exe'))) {return 'shared-client'}
 return 'other'
}
if(-not $LibraryOnly) {$global:atlasActionDiagnostic}
'@ | Set-Content (Join-Path $scripts 'Get-AtlasDiagnostics.ps1')
    . (Join-Path $RepoRoot 'guest_server/scripts/Repair-AtlasIPC.ps1') -LibraryOnly
    $stalled.diagnostics | Add-Member serviceExecutable 'legacy-oobe'
    $stalled.diagnostics | Add-Member guiStartupPhase 'ipc-initialized'
    if (Test-AtlasIPCRepairState $stalled) {throw 'Verified IPC mismatch was rejected.'}
    foreach ($mutate in @({param($s) $s.diagnostics.serviceExecutable='shared-client'},
        {param($s) $s.diagnostics.guiStartupPhase='ipc-registered'}, {param($s) $s.applied=$true})) {
        $copy=$stalled | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        & $mutate $copy
        if (-not (Test-AtlasIPCRepairState $copy)) {throw 'Repair accepted a different or completed handoff.'}
    }
    $global:atlasActionDiagnostic=$stalled.diagnostics | ConvertTo-Json -Depth 8
    $global:atlasFixtureServicePath='legacy'; $global:atlasServiceChanges=0
    function Get-CimInstance {
        param($ClassName,$Filter)
        if ($ClassName -eq 'Win32_UserAccount') {return [pscustomobject]@{SID='S-1-5-21-1-2-3-1000'}}
        return [pscustomobject]@{Name='ameoobe';State='Stopped';StartName='LocalSystem';PathName=$global:atlasFixtureServicePath}
    }
    function Invoke-CimMethod {
        param($InputObject,$MethodName,$Arguments)
        if ($MethodName -ne 'Change' -or $Arguments.PathName -notlike '*AME.Client.exe" --service') {throw 'Unexpected service mutation.'}
        $global:atlasServiceChanges++; $global:atlasFixtureServicePath=$Arguments.PathName
        return [pscustomobject]@{ReturnValue=0}
    }
    $global:atlasObserverStops=0
    function Stop-ScheduledTask { [CmdletBinding()]param($TaskName) if($TaskName -ne 'WinBoatAtlasOOBE') {throw 'Unexpected task.'}; $global:atlasObserverStops++ }
    [WinBoat.AtlasSessionLauncher]::ValidSession=$true
    [WinBoat.AtlasSessionLauncher]::ServiceStarted=$false
    $beforeStops=[WinBoat.AtlasSessionLauncher]::Stops
    $result=& (Join-Path $scripts 'Repair-AtlasIPC.ps1') | ConvertFrom-Json
    if ($result.status -ne 'launched' -or $global:atlasServiceChanges -ne 1 -or $global:atlasObserverStops -ne 1 -or
        [WinBoat.AtlasSessionLauncher]::Stops -ne ($beforeStops+1)) {throw ('IPC repair did not perform the verified path change and single AME restart: '+($result | ConvertTo-Json -Compress))}
    $stalled.diagnostics.serviceExecutable='shared-client'
    $global:atlasActionDiagnostic=$stalled.diagnostics | ConvertTo-Json -Depth 8
    $repeat=& (Join-Path $scripts 'Repair-AtlasIPC.ps1') | ConvertFrom-Json
    if ($repeat.status -ne 'blocked' -or $global:atlasServiceChanges -ne 1) {throw 'An already repaired service was modified again.'}
    $rejected=$false
    try {Set-AtlasCanonicalService ([pscustomobject]@{Name='ameoobe';State='Running';StartName='LocalSystem'}) 'client.exe'} catch {$rejected=$true}
    if (-not $rejected -or $global:atlasServiceChanges -ne 1) {throw 'A running service was reconfigured.'}
    $stalled.diagnostics.serviceExecutable='legacy-oobe'
    $global:atlasActionDiagnostic=$stalled.diagnostics | ConvertTo-Json -Depth 8
    $global:atlasFixtureServicePath='legacy'
    Remove-Item (Join-Path $root 'ipc-path-repair.json')
    function Invoke-CimMethod {param($InputObject,$MethodName,$Arguments) return [pscustomobject]@{ReturnValue=5}}
    $beforeStops=[WinBoat.AtlasSessionLauncher]::Stops
    $failed=& (Join-Path $scripts 'Repair-AtlasIPC.ps1') | ConvertFrom-Json
    if ($failed.status -ne 'failed' -or $failed.stage -ne 'change-service-path' -or $failed.servicePathChanged -or
        $failed.clientStopped -or [WinBoat.AtlasSessionLauncher]::Stops -ne $beforeStops -or $global:atlasObserverStops -ne 1) {throw 'A failed service change stopped a client/observer or reported success.'}
    Write-Host 'Actual IPC repair dispatch, configuration verification, same-user restart and repeat refusal passed with Windows API fixtures.'
} finally {
    $env:ProgramData=$oldData; $env:SystemRoot=$oldRoot
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

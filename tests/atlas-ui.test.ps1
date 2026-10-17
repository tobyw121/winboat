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
    {param($s) $s.diagnostics.processes += [pscustomobject]@{ProcessName='AME.Client'}},
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
    {param($s) $s.diagnostics.processes += [pscustomobject]@{ProcessName='AME.Client'}},
    {param($s) $s.applied=$true}
)) {
    $copy=$stalled | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    & $mutate $copy
    if (-not (Test-AtlasUILaunchState $copy $true)) { throw 'Restart accepted active UI, another user, multiple clients or applied playbook.' }
}
Write-Host 'Explicit stalled UI restart preflight guards passed; no processes were terminated.'
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
} finally {
    $env:ProgramData=$oldData; $env:SystemRoot=$oldRoot
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

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
  public static void ValidateSession(string sid) { if(!ValidSession) throw new System.ComponentModel.Win32Exception(1008); }
  public sealed class Result { public int ProcessId=123; public int SessionId=1; }
  public static Result Start(string exe, string sid) {
   if(!ServiceStarted) throw new System.Exception("Service must be ready before GUI startup");
   return new Result();
  }
 }
}
'@
function Add-Type { param($Path) if ($Path -notlike '*AtlasSessionLauncher.cs') { throw 'Unexpected code path.' } }
$script:restarts=0
function Restart-Service { [CmdletBinding()]param($Name) $script:restarts++; [WinBoat.AtlasSessionLauncher]::ServiceStarted=$true }
function Get-Service {
    param($Name)
    $service = [pscustomobject]@{}
    $service | Add-Member ScriptMethod WaitForStatus {param($State, $Timeout) if ($State -ne 'Running') { throw 'Unexpected service wait.' }}
    $service
}
$blocked=$false
try { Invoke-AtlasSessionLaunch 'client.exe' 'setup-sid' | Out-Null } catch { $blocked=$true }
if (-not $blocked -or $script:restarts) { throw 'Service changed before validating the signed-in setup user.' }
[WinBoat.AtlasSessionLauncher]::ValidSession=$true
$result = Invoke-AtlasSessionLaunch 'client.exe' 'setup-sid'
if ($result.ProcessId -ne 123 -or $result.SessionId -ne 1 -or $script:restarts -ne 1) { throw 'UI was not started through the validated session and service handshake.' }
Write-Host 'UI launch preflight and no-session refusal passed with mocked Windows operations.'

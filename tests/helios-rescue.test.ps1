param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'guest_server/scripts/Set-HeliosRescue.ps1') -LibraryOnly
$script:hold=$false; $script:operations=@(); $script:running=$false; $script:pending=$false
$script:basic=22; $script:helios=0
$script:missing=$false
function Set-HeliosRescueHold([bool]$Disabled) { $script:hold=$Disabled }
function Get-ScheduledTask { param($TaskName,$ErrorAction) if($script:running){[pscustomobject]@{State='Running'}} }
function Get-HeliosRescueDevices {
    [pscustomobject]@{basic=@([pscustomobject]@{PNPDeviceID='VGA';ConfigManagerErrorCode=$script:basic});
        helios=@(if(-not $script:missing){[pscustomobject]@{PNPDeviceID='HELIOS';ConfigManagerErrorCode=$script:helios}})}
}
function pnputil.exe {
    if (-not $script:hold) {throw 'PnP changed before the durable hold'}
    $script:operations+=($args -join ' ')
    if($args[0] -eq '/enable-device' -and $args[1] -eq 'VGA'){$script:basic=0}
    if($args[1] -eq 'HELIOS'){
        if($script:basic -ne 0){throw 'Helios changed without working VGA'}
        $script:helios=if($args[0] -eq '/disable-device'){22}else{0}
    }
    $global:LASTEXITCODE=if($script:pending){3010}else{0}
}
$result=Invoke-HeliosRescue 'helios-disable'
if($result.status -ne 'disabled' -or -not $script:hold -or $script:operations.Count -ne 2 -or
    $script:operations[0] -ne '/enable-device VGA' -or $script:operations[1] -ne '/disable-device HELIOS'){throw 'Ordered rescue failed'}
$result=Invoke-HeliosRescue 'helios-enable'
if($result.status -ne 'enabled' -or $script:hold -or $script:helios -ne 0){throw 'Explicit restore failed'}
$script:running=$true; $script:operations=@()
if((Invoke-HeliosRescue 'helios-disable').status -ne 'blocked' -or $script:operations.Count){throw 'Active installer interrupted'}
$script:running=$false; $script:basic=31
if((Invoke-HeliosRescue 'helios-disable').status -ne 'blocked' -or $script:operations.Count){throw 'Unhealthy VGA allowed disable'}
$script:basic=22; $script:pending=$true
if((Invoke-HeliosRescue 'helios-disable').status -ne 'restart-required' -or $script:operations.Count -ne 1 -or -not $script:hold){throw 'VGA reboot need ignored'}
$script:missing=$true; $script:basic=0; $script:pending=$false; $script:operations=@()
if((Invoke-HeliosRescue 'helios-disable').status -ne 'held' -or $script:operations.Count){throw 'Absent hardware claimed a device disable'}
Write-Host 'Explicit rescue preserves VGA, serializes with installation, retains its hold and requires deliberate re-enable.'

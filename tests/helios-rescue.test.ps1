param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'guest_server/scripts/Set-HeliosRescue.ps1') -LibraryOnly
# Exercise real registry-provider parent creation on Windows, preserving an
# existing value on a second call. Never modify the production HKLM key.
if ($env:OS -eq 'Windows_NT') {
    $registryTest='HKCU:\Software\WinBoatRescueTests-'+[guid]::NewGuid().ToString('N')
    $nested=Join-Path $registryTest 'MissingParent\DisplayRecovery'
    try {
        Initialize-DisplayRecoveryKey $nested
        New-ItemProperty -LiteralPath $nested -Name ExistingValue -PropertyType DWord -Value 7 | Out-Null
        Initialize-DisplayRecoveryKey $nested
        if((Get-ItemProperty -LiteralPath $nested).ExistingValue -ne 7){throw 'Existing registry data erased'}
    } finally {Remove-Item -LiteralPath $registryTest -Recurse -Force -ErrorAction SilentlyContinue}
}
$script:hold=$false; $script:operations=@(); $script:running=$false; $script:pending=$false
$script:basic=22; $script:helios=0
$script:missing=$false
$script:taskStates=@{WinBoatHeliosReboots='Ready';WinBoatHeliosAfterAtlas='Disabled';HeliosGraphicsProvisioning='Ready'}
$script:pausedTasks=@(); $script:failPause=$false
function Set-HeliosRescueHold([bool]$Disabled) { $script:hold=$Disabled }
function Get-ScheduledTask { param($TaskName,$ErrorAction)
    if($script:running){return [pscustomobject]@{State='Running'}}
    if($script:taskStates.ContainsKey($TaskName)){return [pscustomobject]@{State=$script:taskStates[$TaskName]}}
}
function Disable-ScheduledTask { param($TaskName,$ErrorAction)
    if(-not $script:hold){throw 'Task changed before the persistent hold'}
    if($script:failPause){throw 'fixture scheduler unavailable'}
    $script:taskStates[$TaskName]='Disabled';$script:pausedTasks+=$TaskName
}
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
if($script:pausedTasks.Count -ne 2 -or $script:taskStates.HeliosGraphicsProvisioning -ne 'Disabled'){throw 'Official installer could reactivate Helios after rescue'}
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
$script:taskStates.HeliosGraphicsProvisioning='Ready';$script:failPause=$true;$blocked=$false
try {Invoke-HeliosRescue 'helios-disable'} catch {if($_.Exception.Message -notmatch 'scheduler unavailable'){throw};$blocked=$true}
if(-not $blocked -or $script:operations.Count -or -not $script:hold){throw 'Failed task suspension allowed device changes'}
if($script:rescueStage -ne 'pause-HeliosGraphicsProvisioning'){throw 'Rescue failure lost its stage'}
Write-Host 'Explicit rescue preserves VGA, serializes with installation, retains its hold and requires deliberate re-enable.'

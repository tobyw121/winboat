param([string]$RepoRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'guest_server/scripts/Get-DisplayAdapters.ps1') -LibraryOnly
$global:attempt=[long]0; $global:enables=@(); $global:failEnable=$false
function Get-WinBoatDisplayRecoveryTime {return $global:attempt}
function Set-WinBoatDisplayRecoveryTime($Ticks) {$global:attempt=$Ticks}
function Device($Id,$Service,$Code=0) {[pscustomobject]@{PNPDeviceID=$Id;Service=$Service;ConfigManagerErrorCode=$Code;Present=$true}}
$global:devices=@((Device 'PCI\VEN_1AF4&DEV_1050\HELIOS' 'helios_kmd_render'),(Device 'PCI\VEN_1234&DEV_1111\VGA' 'BasicDisplay' 22))
function Get-CimInstance {param($ClassName,$Filter) if($ClassName -ne 'Win32_PnPEntity' -or $Filter -ne "PNPClass='Display'"){throw 'Unexpected hardware query'};return $global:devices}
function pnputil.exe {
    if($args[1] -ne 'PCI\VEN_1234&DEV_1111\VGA'){throw 'Watchdog changed an unrelated adapter'}
    $global:enables+=($args -join ' ')
    if($global:failEnable){$global:LASTEXITCODE=1;return}
    $global:devices[1].ConfigManagerErrorCode=0
    $global:LASTEXITCODE=0
}
$state=Invoke-WinBoatDisplayCheck $true
if($state.helios.state -ne 'running' -or $state.basic.state -ne 'disabled' -or $global:enables.Count){throw 'Healthy Helios must preserve intentionally disabled VGA'}
$global:devices[0].ConfigManagerErrorCode=43
$state=Invoke-WinBoatDisplayCheck $false
if($global:enables.Count){throw 'Read-only diagnostics mutated Windows'}
$state=Invoke-WinBoatDisplayCheck $true
if($state.helios.state -ne 'failed' -or $state.basic.state -ne 'running' -or $state.recovery -ne 'basic-enabled' -or $global:enables.Count -ne 1){throw 'Both unavailable: bootstrap VGA was not restored'}
$global:devices[0].ConfigManagerErrorCode=0
$state=Invoke-WinBoatDisplayCheck $true
if($state.helios.state -ne 'running' -or $global:enables.Count -ne 1){throw 'Helios recovery unnecessarily reconfigured VGA'}
$global:devices[0].ConfigManagerErrorCode=43; $global:devices[1].ConfigManagerErrorCode=43
$state=Invoke-WinBoatDisplayCheck $true
if($state.recovery -ne 'cooldown' -or $global:enables.Count -ne 1){throw 'Recovery cooldown ignored'}
$global:attempt=0
$state=Invoke-WinBoatDisplayCheck $true
if($global:enables[-1] -notlike '/restart-device *' -or $state.basic.state -ne 'running'){throw 'Failed Basic Display driver was not restarted'}
$global:devices[1].ConfigManagerErrorCode=22; $global:attempt=0; $global:failEnable=$true
$state=Invoke-WinBoatDisplayCheck $true
if($state.recovery -ne 'failed' -or $state.helios.state -ne 'failed' -or $global:attempt -eq 0){throw 'Failed recovery lost known adapter state or was not rate-limited'}
$global:devices=@((Device 'PCI\VEN_10DE&DEV_1234\OTHER' 'BasicDisplay' 22))
$before=$global:enables.Count
$state=Invoke-WinBoatDisplayCheck $true
if($state.heliosPresent -or $global:enables.Count -ne $before){throw 'Non-Helios machine was modified'}
$global:devices=@((Device 'PCI\VEN_1AF4&DEV_1050\HELIOS' 'BasicDisplay'))
$state=Invoke-WinBoatDisplayCheck $true
if($state.helios.state -eq 'running'){throw 'Basic Display on virtio hardware was mistaken for installed Helios'}
Write-Host 'Adapter identity, disabled VGA preservation, failed Helios fallback, Basic restart, cooldown, failure reporting and unrelated GPU isolation passed.'

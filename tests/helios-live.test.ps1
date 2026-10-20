Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'guest_server/scripts/Get-HeliosLiveStatus.ps1') -LibraryOnly
$script:read=@()
$fast=Get-HeliosLiveStatus {param($endpoint) $script:read+=$endpoint;[pscustomobject]@{state='fixture'}} $false
if ($script:read.Count -ne 2 -or $script:read -contains 'graphics/diagnostics') {throw 'Fast dashboard starts expensive diagnostics'}
$slow=Get-HeliosLiveStatus {param($endpoint)
    if($endpoint -eq 'graphics/diagnostics') {
        return [pscustomobject]@{driver=[pscustomobject]@{
            controllers=@([pscustomobject]@{PNPDeviceID='PCI\VEN_1AF4&DEV_1050';DriverVersion='22.22.291.0'})
            application=[pscustomobject]@{loadedApplications=@([pscustomobject]@{modules=@([pscustomobject]@{
                name='helios_umd.dll';version='22.22.294.0';path='C:\Helios\helios-windows-x64-22.22.294.0-fec\runtime.dll'
            })})}
        }}
    }
    [pscustomobject]@{}
} $true
if (@($slow.warnings).Count -ne 2) {throw 'Mixed loaded and bound versions were hidden'}
if ($slow.boundDriverVersion -ne '22.22.291.0') {throw 'Bound version missing from dashboard summary.'}
$failed=Get-HeliosLiveStatus {throw 'offline'} $false
if ($failed.errors.Count -ne 2) {throw 'Offline API reported as healthy'}
Write-Host 'Dashboard fast/slow separation, mixed-version warnings and unavailable API passed.'

# Read-only: distinguish loaded miniport, display-half startup and scanout.
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false)
$diagnosticsLibraryOnly=$LibraryOnly
. (Join-Path $PSScriptRoot 'Start-HeliosProvisioning.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'Get-HeliosApplicationDiagnostics.ps1') -LibraryOnly
function Get-HeliosDriverDiagnostics {
    $values=[ordered]@{}
    $key=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\helios_kmd_render' -ErrorAction SilentlyContinue
    if ($null -ne $key) {
        foreach ($property in @($key.PSObject.Properties | Sort-Object Name)) {
            if ($values.Count -ge 256) {break}
            if ($property.Name -match '^(DisplayHalf|DiagLevel|Dsp.*|Sdg.*|Sc.*|Vp.*|St.*|Tr.*|Kmd.*|Umd.*)$' -and
                ($property.Value -is [int] -or $property.Value -is [long] -or $property.Value -is [uint32] -or $property.Value -is [uint64])) {
                $values[$property.Name]=$property.Value
            }
        }
    }
    $controllers=@(Get-CimInstance Win32_VideoController | Where-Object {
        $_.PNPDeviceID -like 'PCI\VEN_1AF4&DEV_1050*' -or $_.PNPDeviceID -like 'PCI\VEN_1234&DEV_1111*'
    } | Select-Object -First 8 Name,PNPDeviceID,DriverVersion,DriverDate,InfFilename,InstalledDisplayDrivers,ConfigManagerErrorCode,CurrentHorizontalResolution,CurrentVerticalResolution)
    $signing=$null
    try {$signing=Test-HeliosBootTestSigning} catch {} # Unsupported query is unknown, never false.
    # Read the durable hold now, independently of the asynchronous PnP sample.
    $hold=$null
    try {
        $rescue=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WinBoat\DisplayRecovery' -ErrorAction Stop
        $hold=($null -ne $rescue.PSObject.Properties['HeliosDisabled'] -and $rescue.HeliosDisabled -eq 1)
    } catch [System.Management.Automation.ItemNotFoundException] {$hold=$false} catch {}
    return [ordered]@{diagnosticsVersion=2;rescueHold=$hold;application=(Get-HeliosApplicationDiagnostics);testSigning=$signing;controllers=$controllers;driverRegistry=$values;updatedAtUtc=[DateTime]::UtcNow.ToString('o')}
}
if (-not $diagnosticsLibraryOnly) {Get-HeliosDriverDiagnostics | ConvertTo-Json -Depth 10 -Compress}

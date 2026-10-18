param([string]$RepoRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$previousData=$env:ProgramData
try {
    $env:ProgramData=[IO.Path]::GetTempPath()
    . (Join-Path $RepoRoot 'guest_server/scripts/Get-HeliosDiagnostics.ps1') -LibraryOnly
    function Get-ItemProperty {
        param($LiteralPath,$ErrorAction)
        if ($LiteralPath -eq 'HKLM:\SOFTWARE\WinBoat\DisplayRecovery') {return [pscustomobject]@{HeliosDisabled=1}}
        if ($LiteralPath -ne 'HKLM:\SYSTEM\CurrentControlSet\Services\helios_kmd_render') {throw 'Unexpected registry query'}
        return [pscustomobject]@{DisplayHalf=1;DspH=0;SdgDevX=1;ScErrors=4;VpCN=0;ImagePath='do-not-export';S0=123;Secret='do-not-export'}
    }
    function Get-CimInstance {
        param($ClassName)
        if ($ClassName -ne 'Win32_VideoController') {throw 'Unexpected hardware query'}
        return @([pscustomobject]@{Name='Helios';PNPDeviceID='PCI\VEN_1AF4&DEV_1050\0';DriverVersion='22.22';CurrentHorizontalResolution=$null},[pscustomobject]@{Name='Other';PNPDeviceID='PCI\VEN_10DE&DEV_1234\0'})
    }
    function Test-HeliosBootTestSigning {return $true}
    function Set-ItemProperty {throw 'Diagnostics changed the registry'}
    function Start-Process {throw 'Diagnostics launched an installer'}
    function pnputil.exe {throw 'Diagnostics changed a driver'}
    function bcdedit.exe {throw 'Diagnostics changed boot signing'}
    $result=Get-HeliosDriverDiagnostics
    if ($result.rescueHold -ne $true) {throw 'Live rescue hold was not reported'}
    if (-not $result.testSigning -or $result.controllers.Count -ne 1 -or $result.driverRegistry.DspH -ne 0 -or $result.driverRegistry.ScErrors -ne 4) {throw 'Driver/desktop evidence was lost'}
    $json=$result | ConvertTo-Json -Depth 6 -Compress
    if ($json -match 'do-not-export|"S0"|Other') {throw 'Unrelated/unbounded registry or GPU data exported'}
    function Test-HeliosBootTestSigning {throw 'unsupported kernel query'}
    if ($null -ne (Get-HeliosDriverDiagnostics).testSigning) {throw 'Unknown test-signing state was reported as disabled'}
    function Get-ItemProperty {
        param($LiteralPath,$ErrorAction)
        if ($LiteralPath -eq 'HKLM:\SOFTWARE\WinBoat\DisplayRecovery') {throw 'unavailable registry'}
        return $null
    }
    if ($null -ne (Get-HeliosDriverDiagnostics).rescueHold) {throw 'Unknown rescue hold was reported as clear'}
    Write-Host 'Read-only Helios diagnostics: active signing, display-half/scanout counters, controller identity and unknown-query handling passed.'
} finally {$env:ProgramData=$previousData}

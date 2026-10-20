param([switch]$IncludeSlow,[switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Get-HeliosLiveStatus([scriptblock]$Read,[bool]$Slow) {
    $report=[ordered]@{collectedAtUtc=[DateTime]::UtcNow.ToString('o');errors=@()}
    $endpoints=@('graphics/adapters','graphics/validation')
    if ($Slow) {$endpoints+=@('graphics/diagnostics','graphics/diagnostics/runtime')}
    foreach($endpoint in $endpoints) {
        try {$report[$endpoint]=& $Read $endpoint}
        catch {$report.errors+='Unavailable: '+$endpoint}
    }
    if ($Slow -and $report.Contains('graphics/diagnostics')) {
        $report.boundDriverVersion='unknown'
        try {
            $driver=$report['graphics/diagnostics'].driver
            $bound=@($driver.controllers | Where-Object {$_.PNPDeviceID -like 'PCI\VEN_1AF4&DEV_1050*'} | Select-Object -First 1)
            $warnings=@()
            if ($bound.Count -eq 1) {
                $version=[string]$bound[0].DriverVersion
                $report.boundDriverVersion=$version
                foreach($process in @($driver.application.loadedApplications)) {
                    foreach($module in @($process.modules)) {
                        if ($module.name -like 'helios_umd*' -and $module.version -and
                            ([string]$module.version -split ' ')[0] -ne $version) {$warnings+='UMD version differs from bound driver'}
                        if ([string]$module.path -match 'helios-windows-x64-(\d+\.\d+\.\d+\.\d+)-' -and $Matches[1] -ne $version) {$warnings+='Loaded runtime path differs from bound driver'}
                    }
                }
            } else {$warnings+='Bound Helios version unavailable'}
            $report.warnings=@($warnings | Sort-Object -Unique)
        } catch {$report.errors+='Module/version correlation unavailable'}
        $report.slowCollectedAtUtc=[DateTime]::UtcNow.ToString('o')
    }
    return $report
}
if ($LibraryOnly) {return}
Get-HeliosLiveStatus {param($Endpoint) Invoke-RestMethod -Uri ('http://127.0.0.1:7148/'+$Endpoint) -TimeoutSec 20} ([bool]$IncludeSlow)

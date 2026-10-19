# Explicit interactive test only. Does not enable adapters, restart DWM or reboot.
param([string]$InstallRoot, [switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Invoke-HeliosProfileArms([scriptblock]$RunProbe) {
    $key='HKLM:\SOFTWARE\Helios'
    $existed=Test-Path -LiteralPath $key
    $before=@{}
    if ($existed) {
        $item=Get-Item -LiteralPath $key
        foreach ($name in @('FeatureLevel11','UmdTrace')) {
            if ($item.GetValueNames() -contains $name) {
                if ($item.GetValueKind($name) -ne 'DWord') {throw "Unexpected registry type: $name"}
                $before[$name]=$item.GetValue($name)
            }
        }
    }
    try {
        if (-not $existed) {New-Item -Path $key | Out-Null}
        New-ItemProperty -LiteralPath $key -Name UmdTrace -Value 1 -PropertyType DWord -Force | Out-Null
        foreach ($mode in @(1,0,2,1)) {
            New-ItemProperty -LiteralPath $key -Name FeatureLevel11 -Value $mode -PropertyType DWord -Force | Out-Null
            & $RunProbe $mode
        }
    } finally {
        # Restore values and absence, including after probe failure/timeout.
        foreach ($name in @('FeatureLevel11','UmdTrace')) {
            if ($before.ContainsKey($name)) {
                New-ItemProperty -LiteralPath $key -Name $name -Value $before[$name] -PropertyType DWord -Force | Out-Null
            } else {Remove-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue}
        }
        if (-not $existed) {
            $item=Get-Item -LiteralPath $key
            if ($item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) {Remove-Item -LiteralPath $key}
        }
    }
}
if ($LibraryOnly) {return}
if (-not [Environment]::Is64BitProcess -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'Run from 64-bit PowerShell in the logged-in Windows console session.'
}
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Administrator required.'}
if (-not $InstallRoot) {
    $state=Get-Content (Join-Path $env:ProgramData 'Helios/install-state.json') -Raw | ConvertFrom-Json
    $InstallRoot=[string]$state.installRoot
}
. (Join-Path $PSScriptRoot 'Helios-PackageCommon.ps1')
# Verify the fixed probe against the installed package manifest.
$manifest=Read-HeliosManifest $PSScriptRoot
$probe=Join-Path $InstallRoot 'runtime/smoke/d3d11-device-probe.exe'
if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) {throw 'Device probe missing; install the diagnostic package first.'}
$entry=@($manifest.files | Where-Object {$_.path -eq 'payload/smoke/d3d11-device-probe.exe'})
if ($entry.Count -ne 1 -or (Get-HeliosSha256 $probe) -ne $entry[0].sha256 -or
    (Get-Item -LiteralPath $probe).Length -ne $entry[0].size) {throw 'Device probe package checksum mismatch.'}
$active=@(Get-PnpDevice -PresentOnly -Class Display | Where-Object {$_.InstanceId -like 'PCI\VEN_1AF4&DEV_1050*' -and $_.Status -eq 'OK'})
if ($active.Count -ne 1) {throw 'Exactly one active Helios adapter is required. This script will not enable it.'}
$mutex=New-Object Threading.Mutex($false,'Global\WinBoatHeliosProvisioning')
$held=$false
try {
    try {$held=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$held=$true}
    if (-not $held) {throw 'Helios installation or maintenance is active.'}
    $started=[DateTime]::UtcNow.ToString('o')
    $arms=@(Invoke-HeliosProfileArms {
        param($mode)
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$probe; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
        $process=New-Object Diagnostics.Process
        $process.StartInfo=$info
        try {
            [void]$process.Start()
            $stdout=$process.StandardOutput.ReadToEndAsync()
            $stderr=$process.StandardError.ReadToEndAsync()
            $timeout=-not $process.WaitForExit(30000)
            if ($timeout) {$process.Kill(); $process.WaitForExit()}
            $rows=@($stdout.Result -split '\r?\n' | Where-Object {$_ -match '^\{"schema":1,'} | ForEach-Object {$_ | ConvertFrom-Json})
            [ordered]@{mode=$mode;timedOut=$timeout;exitCode=$process.ExitCode;results=$rows}
        } finally {$process.Dispose()}
    })
    $report=[ordered]@{schema=1;probeVersion=[string]$manifest.version;probeSha256=(Get-HeliosSha256 $probe);
        startedAtUtc=$started;finishedAtUtc=[DateTime]::UtcNow.ToString('o');registryRestored=$true;arms=$arms}
    $path=Join-Path $env:ProgramData 'Helios/device-probe-result.json'
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    $report | ConvertTo-Json -Depth 8
} finally {
    if ($held) {$mutex.ReleaseMutex()}; $mutex.Dispose()
}

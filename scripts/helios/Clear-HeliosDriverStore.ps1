# Explicit driver-store removal; run elevated in the VGA-only rescue boot.
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Assert-HeliosAbsentWithVGA {
    $devices=@(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" | Where-Object {$_.Present})
    if (@($devices | Where-Object {$_.PNPDeviceID -like 'PCI\VEN_1AF4&DEV_1050*'}).Count) {
        throw 'Helios hardware is still attached. Use rescue-graphics.py --rescue-boot first; disabling the device is insufficient.'
    }
    $vga=@($devices | Where-Object {$_.PNPDeviceID -like 'PCI\VEN_1234&DEV_1111*' -and $_.Service -eq 'BasicDisplay' -and $_.ConfigManagerErrorCode -eq 0})
    if ($vga.Count -ne 1) {throw 'A healthy WinBoat VGA recovery device is required.'}
}
function Set-HeliosCleanupHold {
    $key=[Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\WinBoat\DisplayRecovery')
    try {$key.SetValue('HeliosDisabled',1,[Microsoft.Win32.RegistryValueKind]::DWord)} finally {$key.Dispose()}
    Pause-HeliosCleanupTasks
}
function Pause-HeliosCleanupTasks {
    # Query failure is not evidence that installation tasks are absent.
    $tasks=@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop)
    foreach($name in @('WinBoatHeliosReboots','WinBoatHeliosAfterAtlas','HeliosGraphicsProvisioning')) {
        $matching=@($tasks | Where-Object {$_.TaskName -eq $name})
        if (-not $matching.Count) {continue}
        if ($matching.Count -ne 1) {throw "Ambiguous installer task $name."}
        $task=$matching[0]
        if ($task.State.ToString() -eq 'Running') {throw "Installer task $name is running. No driver packages were removed."}
        Disable-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction Stop | Out-Null
        if ((Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction Stop).State.ToString() -ne 'Disabled') {throw "Cannot pause $name."}
    }
}
function Get-VerifiedHeliosPackages {
    $all=@(Get-WindowsDriver -Online -All)
    return @(foreach($package in $all) {
        $leaf=([string]$package.OriginalFileName -split '[\\/]')[-1]
        if ($package.ProviderName -ine 'WinBoat' -and $leaf -notlike 'helios*.inf') {continue}
        # Unknown WinBoat packages are not implicitly authorized as graphics.
        if ($leaf -ine 'helios_kmd_render.inf' -or $package.ProviderName -ine 'WinBoat' -or
            $package.ClassName -ine 'Display' -or $package.Driver -notmatch '^oem\d+\.inf$' -or $package.BootCritical) {
            throw "Unrecognized or boot-critical package $($package.Driver); no broad provider deletion is performed."
        }
        $published=Join-Path $env:windir ('INF\'+$package.Driver)
        $text=Get-Content -LiteralPath $published -Raw
        if ($text -notmatch '(?i)PCI\\VEN_1AF4&DEV_1050(?:[^0-9A-F]|$)' -or
            $text -notmatch '(?im)^\s*ClassGuid\s*=\s*\{4d36e968-e325-11ce-bfc1-08002be10318\}') {
            throw "Package $($package.Driver) does not identify the known Helios display hardware."
        }
        [pscustomobject]@{driver=[string]$package.Driver;version=[string]$package.Version;published=$published;
            sha256=(Get-FileHash -LiteralPath $published -Algorithm SHA256).Hash}
    })
}
function Invoke-HeliosDriverStoreCleanup {
    Assert-HeliosAbsentWithVGA
    Set-HeliosCleanupHold
    # Enumerate and verify ALL candidates before removing the first package.
    $packages=@(Get-VerifiedHeliosPackages)
    if (-not $packages.Count) {return @{status='already-clean';removed=@();message='No Helios packages remain; automatic setup stays paused.'}}
    $backup=Join-Path $env:ProgramData ('WinBoat\DriverStoreBackup\'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach($package in $packages) {
        & pnputil.exe /export-driver $package.driver $backup | Out-Host
        if ($LASTEXITCODE -ne 0) {throw "Backup failed for $($package.driver). No packages were removed."}
    }
    $removed=@();$pending=$false
    foreach($package in $packages) {
        Assert-HeliosAbsentWithVGA
        if ((Get-FileHash -LiteralPath $package.published -Algorithm SHA256).Hash -ne $package.sha256) {throw 'Published INF changed; cleanup stopped.'}
        Write-Host "Removing $($package.driver), Helios $($package.version)"
        & pnputil.exe /delete-driver $package.driver /uninstall /force | Out-Host
        if ($LASTEXITCODE -notin @(0,3010)) {throw "Package removal failed for $($package.driver). Backup: $backup. Automatic setup remains paused."}
        if ($LASTEXITCODE -eq 3010) {$pending=$true}
        $removed+=$package.driver
    }
    $remaining=@(Get-VerifiedHeliosPackages)
    if ($remaining.Count -and -not $pending) {throw "Helios packages remain. Backup: $backup. No successful cleanup is claimed."}
    return @{status=$(if($pending){'restart-required'}else{'removed'});removed=$removed;remaining=@($remaining | ForEach-Object {$_.driver});backup=$backup;
        message='Driver-store cleanup only; runtime files and shared loaders were preserved. Keep VGA rescue active and restart Windows normally.'}
}
if ($LibraryOnly) {return}
if (-not [Environment]::Is64BitProcess -or -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run with native 64-bit PowerShell as Administrator.'
}
$mutex=New-Object Threading.Mutex($false,'Global\WinBoatHeliosProvisioning');$owned=$false
try {
    try {$owned=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$owned=$true}
    if (-not $owned) {throw 'Helios provisioning is active; no packages removed.'}
    Invoke-HeliosDriverStoreCleanup | ConvertTo-Json -Depth 4
} finally {if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}

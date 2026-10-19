param([string]$RepoRoot=(Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'scripts/helios/Clear-HeliosDriverStore.ps1') -LibraryOnly
$previousData=$env:ProgramData;$previousWindows=$env:windir
$root=Join-Path ([IO.Path]::GetTempPath()) ('helios-store-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $root 'INF') -Force | Out-Null
try {
    $env:ProgramData=$root;$env:windir=$root
    $script:packages=@();$script:calls=@();$script:attached=$false;$script:held=$false;$script:mode='ok'
    function Get-CimInstance {
        [pscustomobject]@{Present=$true;PNPDeviceID='PCI\VEN_1234&DEV_1111\0';Service='BasicDisplay';ConfigManagerErrorCode=0}
        if($script:attached){[pscustomobject]@{Present=$true;PNPDeviceID='PCI\VEN_1AF4&DEV_1050\0';Service='helios_kmd_render';ConfigManagerErrorCode=22}}
    }
    function Set-HeliosCleanupHold {$script:held=$true}
    function Get-WindowsDriver {return $script:packages}
    function pnputil.exe {
        $script:calls+=, @($args)
        $global:LASTEXITCODE=0
        if($args[0] -eq '/export-driver' -and $script:mode -eq 'backup-failed') {$global:LASTEXITCODE=5;return}
        if($args[0] -eq '/delete-driver') {
            if(-not $script:held){throw 'Deleted before holding setup'}
            if($script:mode -eq 'delete-failed'){$global:LASTEXITCODE=5;return}
            if($script:mode -eq 'pending'){$global:LASTEXITCODE=3010;return}
            $target=$args[1]
            if($script:mode -ne 'lying-success') {$script:packages=@($script:packages | Where-Object {$_.Driver -ne $target})}
        }
    }
    function New-Fixture([string]$Name='oem17.inf',[string]$Provider='WinBoat',[string]$Original='helios_kmd_render.inf') {
        [IO.File]::WriteAllText((Join-Path $root ('INF\'+$Name)),"[Version]`nClassGuid={4d36e968-e325-11ce-bfc1-08002be10318}`n[Models]`nDevice=Install,PCI\VEN_1AF4&DEV_1050`n")
        [pscustomobject]@{Driver=$Name;ProviderName=$Provider;OriginalFileName=('C:\DriverStore\'+$Original);ClassName='Display';BootCritical=$false;Version='22.22.291.0'}
    }
    function Assert-Failure([scriptblock]$Action,[string]$Pattern) {
        $failed=$false
        try {& $Action} catch {if($_.Exception.Message -notmatch $Pattern){throw};$failed=$true}
        if(-not $failed){throw "Expected failure: $Pattern"}
    }
    $script:attached=$true
    Assert-Failure {Invoke-HeliosDriverStoreCleanup} 'still attached'
    if($script:calls.Count -or $script:held){throw 'Attached/disabled GPU allowed cleanup'}
    $script:attached=$false
    $script:packages=@((New-Fixture),(New-Fixture 'oem18.inf'),(New-Fixture 'oem19.inf' 'Microsoft' 'display.inf'))
    $result=Invoke-HeliosDriverStoreCleanup
    if($result.status -ne 'removed' -or $result.removed.Count -ne 2 -or $script:packages.Count -ne 1 -or $script:packages[0].ProviderName -ne 'Microsoft') {throw 'Exact package cleanup failed'}
    if($script:calls.Count -ne 4 -or $script:calls[0][0] -ne '/export-driver' -or $script:calls[1][0] -ne '/export-driver' -or
        ($script:calls[2] -join ' ') -ne '/delete-driver oem17.inf /uninstall /force') {throw 'Export-first/native removal contract failed'}
    if((Invoke-HeliosDriverStoreCleanup).status -ne 'already-clean'){throw 'Repeat cleanup failed'}
    $script:packages=@((New-Fixture),(New-Fixture 'oem99.inf' 'WinBoat' 'unknown.inf'));$script:calls=@()
    Assert-Failure {Invoke-HeliosDriverStoreCleanup} 'Unrecognized'
    if($script:calls.Count){throw 'Removed before validating all packages'}
    $script:packages=@((New-Fixture));$script:packages[0].BootCritical=$true
    Assert-Failure {Invoke-HeliosDriverStoreCleanup} 'boot-critical'
    $script:packages=@((New-Fixture));$script:mode='backup-failed';$script:calls=@()
    Assert-Failure {Invoke-HeliosDriverStoreCleanup} 'Backup failed'
    if(@($script:calls | Where-Object {$_[0] -eq '/delete-driver'}).Count){throw 'Deleted after failed backup'}
    $script:mode='lying-success'
    Assert-Failure {Invoke-HeliosDriverStoreCleanup} 'packages remain'
    $script:mode='pending'
    if((Invoke-HeliosDriverStoreCleanup).status -ne 'restart-required'){throw 'Pending removal reported as complete'}
    $script:mode='delete-failed'
    Assert-Failure {Invoke-HeliosDriverStoreCleanup} 'removal failed'
    if(-not $script:held){throw 'Failure cleared hold'}
    $script:mode='ok'
    [IO.File]::WriteAllText((Join-Path $root 'INF\oem17.inf'),'[Version] Class=Other')
    $script:calls=@()
    Assert-Failure {Invoke-HeliosDriverStoreCleanup} 'known Helios'
    if($script:calls.Count){throw 'Unverified INF was removed'}
    function Get-ScheduledTask {throw 'Scheduler unavailable'}
    Assert-Failure {Pause-HeliosCleanupTasks} 'Scheduler unavailable'
    $script:task=[pscustomobject]@{TaskName='HeliosGraphicsProvisioning';State='Running'}
    function Get-ScheduledTask {return $script:task}
    function Disable-ScheduledTask {$script:task.State='Disabled'}
    Assert-Failure {Pause-HeliosCleanupTasks} 'is running'
    $script:task.State='Ready'
    Pause-HeliosCleanupTasks
    if($script:task.State -ne 'Disabled'){throw 'Official installer was not paused'}
    Write-Host 'VGA-only cleanup, exact identity, export-first, foreign/boot-critical refusal, native failures and pending verification passed.'
} finally {
    $env:ProgramData=$previousData;$env:windir=$previousWindows
    Remove-Item -LiteralPath $root -Recurse -Force
}

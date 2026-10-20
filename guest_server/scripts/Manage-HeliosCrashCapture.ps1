# Opt-in WER minidumps for dwm.exe only. Never export dump contents via the API.
param([ValidateSet('Status','Enable','Disable')][string]$Action='Status',[switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Helios-ValidationCommon.ps1')
$script:heliosWerKey='HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\dwm.exe'
$script:heliosDumpTask='WinBoatHeliosCrashCaptureExpiry'
function Get-HeliosDumpValues([string]$Folder) {
    return @{DumpFolder=$Folder;DumpType=1;DumpCount=3}
}
function Test-HeliosDumpOwnership($Key,$Expected) {
    $names=@($Key.GetValueNames())
    if ($names.Count -ne 3 -or $Key.SubKeyCount -ne 0) {return $false}
    foreach($name in $Expected.Keys) {
        if ($names -notcontains $name -or [string]$Key.GetValue($name) -cne [string]$Expected[$name]) {return $false}
        $kind=if($name -eq 'DumpFolder'){'ExpandString'}else{'DWord'}
        if ([string]$Key.GetValueKind($name) -ne $kind) {return $false}
    }
    return $true
}
function Get-HeliosCrashCapture {
    $root=Get-HeliosValidationRoot
    $folder=Join-Path $root 'dwm-dumps'
    $result=[ordered]@{enabled=$false;owned=$false;dumps=@();scope='WER minidumps may contain private memory; never included in API or support exports'}
    if (Test-Path -LiteralPath $script:heliosWerKey) {
        $key=Get-Item -LiteralPath $script:heliosWerKey
        $result.owned=Test-HeliosDumpOwnership $key (Get-HeliosDumpValues $folder)
        $result.enabled=$result.owned
        if(-not $result.owned){$result.warning='Existing WER policy is managed elsewhere; unchanged'}
    }
    if (Test-Path -LiteralPath $folder) {
        if ((Get-Item -LiteralPath $folder -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Dump folder is a reparse point.'}
        $result.dumps=@(Get-ChildItem -LiteralPath $folder -Filter 'dwm.exe*.dmp' -File |
            Where-Object {-not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)} |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 3 | ForEach-Object {
                [ordered]@{bytes=$_.Length;updatedAtUtc=$_.LastWriteTimeUtc.ToString('o')}
            })
    }
    return $result
}
function Set-HeliosCrashCapture([string]$Operation) {
    $root=Initialize-HeliosValidationRoot
    $folder=Join-Path $root 'dwm-dumps'
    $expected=Get-HeliosDumpValues $folder
    if ($Operation -eq 'Disable') {
        if (Test-Path -LiteralPath $script:heliosWerKey) {
            $key=Get-Item -LiteralPath $script:heliosWerKey
            if (-not (Test-HeliosDumpOwnership $key $expected)) {throw 'WER policy differs; refusing to remove another configuration.'}
            Remove-Item -LiteralPath $script:heliosWerKey
        }
        Unregister-ScheduledTask -TaskName $script:heliosDumpTask -Confirm:$false -ErrorAction SilentlyContinue
        Write-HeliosValidationJson 'dump-policy.json' @{status='disabled';updatedAtUtc=[DateTime]::UtcNow.ToString('o')}
        return Get-HeliosCrashCapture
    }
    if (Test-Path -LiteralPath $script:heliosWerKey) {throw 'A dwm.exe WER policy already exists. Inspect Status; existing policies are preserved.'}
    if (Get-ScheduledTask -TaskName $script:heliosDumpTask -ErrorAction SilentlyContinue) {throw 'Crash capture expiry task already exists; inspect or disable capture first.'}
    if ((Test-Path -LiteralPath $folder) -and ((Get-Item -LiteralPath $folder -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Dump folder is a reparse point.'}
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    Protect-HeliosValidationPath $folder
    $expires=(Get-Date).AddMinutes(30)
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Action Disable'
    $taskAction=New-ScheduledTaskAction -Execute $exe -Argument $arguments
    $trigger=New-ScheduledTaskTrigger -Once -At $expires
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName $script:heliosDumpTask -Action $taskAction -Trigger $trigger -Settings $settings -User SYSTEM -RunLevel Highest | Out-Null
    try {
        New-Item -Path $script:heliosWerKey -Force | Out-Null
        foreach($name in $expected.Keys) {
            $kind=if($name -eq 'DumpFolder'){'ExpandString'}else{'DWord'}
            New-ItemProperty -LiteralPath $script:heliosWerKey -Name $name -Value $expected[$name] -PropertyType $kind | Out-Null
        }
        Write-HeliosValidationJson 'dump-policy.json' @{status='enabled';expiresAtUtc=$expires.ToUniversalTime().ToString('o');dumpType='minidump';maximumFiles=3}
    } catch {
        # Undo only this newly created policy; never a pre-existing policy.
        Remove-Item -LiteralPath $script:heliosWerKey -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $script:heliosDumpTask -Confirm:$false -ErrorAction SilentlyContinue
        throw
    }
    return Get-HeliosCrashCapture
}
if ($LibraryOnly) {return}
if ($Action -eq 'Status') {Get-HeliosCrashCapture | ConvertTo-Json -Depth 6}
else {Set-HeliosCrashCapture $Action | ConvertTo-Json -Depth 6}

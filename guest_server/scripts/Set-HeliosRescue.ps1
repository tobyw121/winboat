# Explicit, fixed PnP rescue. Never accept a caller-supplied device ID or command.
param([ValidateSet('helios-disable','helios-enable')][string]$Action, [switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Set-HeliosRescueHold([bool]$Disabled) {
    $key='HKLM:\SOFTWARE\WinBoat\DisplayRecovery'
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key | Out-Null }
    New-ItemProperty -LiteralPath $key -Name HeliosDisabled -PropertyType DWord -Value ([int]$Disabled) -Force | Out-Null
}
function Get-HeliosRescueDevices {
    $all=@(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'")
    return [pscustomobject]@{
        basic=@($all | Where-Object {$_.Present -and $_.PNPDeviceID -like 'PCI\VEN_1234&DEV_1111*' -and $_.Service -eq 'BasicDisplay'})
        helios=@($all | Where-Object {$_.Present -and $_.PNPDeviceID -like 'PCI\VEN_1AF4&DEV_1050*' -and $_.Service -eq 'helios_kmd_render'})
    }
}
function Invoke-HeliosRescue([string]$Operation) {
    if ($Operation -notin @('helios-disable','helios-enable')) { throw 'Unknown graphics recovery operation.' }
    $idleTasks=@()
    foreach ($name in @('WinBoatHeliosReboots','WinBoatHeliosAfterAtlas','HeliosGraphicsProvisioning')) {
        $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($null -ne $task -and $task.State.ToString() -eq 'Running') {
            return @{status='blocked';message='A graphics installation task is running. Wait for it to finish before rescue.'}
        }
        if ($null -ne $task -and $task.State.ToString() -ne 'Disabled') { $idleTasks+=$name }
    }
    $devices=Get-HeliosRescueDevices
    if ($devices.basic.Count -ne 1 -or $devices.helios.Count -gt 1) {
        return @{status='blocked';message='A unique WinBoat VGA recovery adapter could not be verified.'}
    }
    if ($Operation -eq 'helios-enable' -and $devices.helios.Count -ne 1) {
        return @{status='blocked';message='No installed Helios device is available to enable.'}
    }
    # Persist the hold before any device change; failures leave automatic setup
    # and topology changes suppressed across service and Windows restarts.
    Set-HeliosRescueHold $true
    if ($Operation -eq 'helios-disable') {
        # The official installer has its own startup task and does not read
        # WinBoat's hold. Pause all known idle continuations before changing PnP.
        foreach ($name in $idleTasks) {
            Disable-ScheduledTask -TaskName $name -ErrorAction Stop | Out-Null
            $paused=Get-ScheduledTask -TaskName $name -ErrorAction Stop
            if ($null -eq $paused -or $paused.State.ToString() -ne 'Disabled') { throw 'Installer continuation could not be paused.' }
        }
    }
    if ($devices.basic[0].ConfigManagerErrorCode -eq 22) {
        & pnputil.exe /enable-device $devices.basic[0].PNPDeviceID | Out-Null
        if ($LASTEXITCODE -eq 3010) { return @{status='restart-required';message='VGA needs a Windows restart; Helios was not changed.'} }
        if ($LASTEXITCODE -ne 0) { throw 'VGA could not be enabled.' }
        $devices=Get-HeliosRescueDevices
    }
    if ($devices.basic.Count -ne 1 -or $devices.basic[0].ConfigManagerErrorCode -ne 0) {
        return @{status='blocked';message='VGA is not healthy. Helios was not changed.'}
    }
    if ($devices.helios.Count -eq 0) {
        return @{status='held';message='Helios hardware is absent. Automatic setup is paused; no device was disabled. Uninstall its package before restoring host graphics if the driver is unstable.'}
    }
    $pending=$false
    if ($devices.helios.Count -eq 1) {
        $disable=$Operation -eq 'helios-disable'
        $code=[int]$devices.helios[0].ConfigManagerErrorCode
        if (($disable -and $code -ne 22) -or (-not $disable -and $code -eq 22)) {
            $verb=if($disable){'/disable-device'}else{'/enable-device'}
            & pnputil.exe $verb $devices.helios[0].PNPDeviceID | Out-Null
            if ($LASTEXITCODE -notin @(0,3010)) { throw 'Helios PnP operation failed; rescue hold remains active.' }
            $pending=$LASTEXITCODE -eq 3010
        }
    }
    $verified=Get-HeliosRescueDevices
    if ($verified.basic.Count -ne 1 -or $verified.basic[0].ConfigManagerErrorCode -ne 0) { throw 'VGA verification failed; rescue hold remains active.' }
    if ($pending) { return @{status='restart-required';message='Windows must restart to finish the device change; rescue hold remains active.'} }
    if ($Operation -eq 'helios-enable') {
        if ($verified.helios.Count -ne 1 -or $verified.helios[0].ConfigManagerErrorCode -ne 0) { throw 'Helios did not become healthy; rescue hold remains active.' }
        Set-HeliosRescueHold $false
        return @{status='enabled';message='Helios enabled explicitly. VGA remains available; rendering success is not yet confirmed.'}
    }
    if ($verified.helios.Count -and $verified.helios[0].ConfigManagerErrorCode -ne 22) { throw 'Helios did not become disabled; rescue hold remains active.' }
    return @{status='disabled';message='Helios disabled; VGA remains enabled. Automatic Helios setup stays paused until explicit re-enable.'}
}
if ($LibraryOnly) { return }
$lock=New-Object Threading.Mutex($false,'Global\WinBoatHeliosProvisioning')
$owned=$false
try {
    try { $owned=$lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned=$true }
    if (-not $owned) { @{status='blocked';message='Helios provisioning is active; no devices changed.'} | ConvertTo-Json -Compress; return }
    Invoke-HeliosRescue $Action | ConvertTo-Json -Compress
}
catch { @{status='failed';message='Graphics rescue failed. The persistent rescue hold, if set, was retained; no reboot or driver uninstall was requested.'} | ConvertTo-Json -Compress }
finally { if ($owned) {$lock.ReleaseMutex()}; $lock.Dispose() }

# Explicit, fixed PnP rescue. Never accept a caller-supplied device ID or command.
param([ValidateSet('helios-disable','helios-enable')][string]$Action, [switch]$LibraryOnly,[switch]$PreserveVga)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Initialize-DisplayRecoveryKey.ps1')
. (Join-Path $PSScriptRoot 'Assert-HeliosStackCoherence.ps1') -LibraryOnly
$script:rescueStage='preflight'
function Set-HeliosRescueHold([bool]$Disabled) {
    $key='HKLM:\SOFTWARE\WinBoat\DisplayRecovery'
    Initialize-DisplayRecoveryKey $key
    New-ItemProperty -LiteralPath $key -Name HeliosDisabled -PropertyType DWord -Value ([int]$Disabled) -Force | Out-Null
}
function Get-HeliosRescueDevices {
    $all=@(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'")
    return [pscustomobject]@{
        basic=@($all | Where-Object {$_.Present -and $_.PNPDeviceID -like 'PCI\VEN_1234&DEV_1111*' -and $_.Service -eq 'BasicDisplay'})
        helios=@($all | Where-Object {$_.Present -and $_.PNPDeviceID -like 'PCI\VEN_1AF4&DEV_1050*' -and $_.Service -eq 'helios_kmd_render'})
    }
}
function Invoke-HeliosRescue([string]$Operation,[bool]$NoVgaChange=$false) {
    if ($Operation -notin @('helios-disable','helios-enable')) { throw 'Unknown graphics recovery operation.' }
    $idleTasks=@()
    $script:rescueStage='inspect-installer-tasks'
    foreach ($name in @('WinBoatHeliosReboots','WinBoatHeliosAfterAtlas','HeliosGraphicsProvisioning')) {
        $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($null -ne $task -and $task.State.ToString() -eq 'Running') {
            return @{status='blocked';message='A graphics installation task is running. Wait for it to finish before rescue.'}
        }
        if ($null -ne $task -and $task.State.ToString() -ne 'Disabled') { $idleTasks+=$name }
    }
    $script:rescueStage='inspect-display-devices'
    $devices=Get-HeliosRescueDevices
    if ($devices.basic.Count -ne 1 -or $devices.helios.Count -gt 1) {
        return @{status='blocked';message='A unique WinBoat VGA recovery adapter could not be verified.'}
    }
    if ($Operation -eq 'helios-enable' -and $devices.helios.Count -ne 1) {
        return @{status='blocked';message='No installed Helios device is available to enable.'}
    }
    if($Operation -eq 'helios-enable') {
        $script:rescueStage='verify-stack-coherence'
        [void](Assert-HeliosStackCoherence)
    }
    # Persist the hold before any device change; failures leave automatic setup
    # and topology changes suppressed across service and Windows restarts.
    $script:rescueStage='persist-rescue-hold'
    Set-HeliosRescueHold $true
    if ($Operation -eq 'helios-disable') {
        # The official installer has its own startup task and does not read
        # WinBoat's hold. Pause all known idle continuations before changing PnP.
        foreach ($name in $idleTasks) {
            $script:rescueStage='pause-'+$name
            Disable-ScheduledTask -TaskName $name -ErrorAction Stop | Out-Null
            $paused=Get-ScheduledTask -TaskName $name -ErrorAction Stop
            if ($null -eq $paused -or $paused.State.ToString() -ne 'Disabled') { throw 'Installer continuation could not be paused.' }
        }
    }
    if ($devices.basic[0].ConfigManagerErrorCode -eq 22) {
        if ($NoVgaChange) {return @{status='blocked';message='Automatic isolation requires healthy VGA; no VGA change allowed.'}}
        $script:rescueStage='enable-vga'
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
    $script:rescueStage='change-helios-device'
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
    $script:rescueStage='verify-display-devices'
    $verified=Get-HeliosRescueDevices
    if ($verified.basic.Count -ne 1 -or $verified.basic[0].ConfigManagerErrorCode -ne 0) { throw 'VGA verification failed; rescue hold remains active.' }
    if ($pending) { return @{status='restart-required';message='Windows must restart to finish the device change; rescue hold remains active.'} }
    if ($Operation -eq 'helios-enable') {
        if ($verified.helios.Count -ne 1 -or $verified.helios[0].ConfigManagerErrorCode -ne 0) { throw 'Helios did not become healthy; rescue hold remains active.' }
        $script:rescueStage='clear-rescue-hold'
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
    Invoke-HeliosRescue $Action ([bool]$PreserveVga) | ConvertTo-Json -Compress
}
catch {
    $exception=$_.Exception
    while ($null -ne $exception.InnerException) {$exception=$exception.InnerException}
    # Fixed stage + numeric code only; never expose exception text or device/user paths.
    $code=if ($exception -is [ComponentModel.Win32Exception]) {$exception.NativeErrorCode} else {$exception.HResult}
    @{status='failed';stage=$script:rescueStage;errorCode=$code;
        message='Graphics rescue failed. The persistent rescue hold, if set, was retained; no reboot or driver uninstall was requested.'} | ConvertTo-Json -Compress
}
finally { if ($owned) {$lock.ReleaseMutex()}; $lock.Dispose() }

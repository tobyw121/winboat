# A fixed watchdog operation: only re-enable WinBoat's QEMU bootstrap VGA.
param([switch]$Recover, [switch]$LibraryOnly, [switch]$ViewerUnavailable, [switch]$MirrorDesired)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Get-WinBoatDisplayState {
    $devices=@(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'")
    $helios=@($devices | Where-Object {$_.PNPDeviceID -like 'PCI\VEN_1AF4&DEV_1050*'})
    $basic=@($devices | Where-Object {$_.PNPDeviceID -like 'PCI\VEN_1234&DEV_1111*'})
    function Describe($Candidates,[bool]$Native) {
        $states=@(foreach($device in $Candidates) {
            $code=[int]$device.ConfigManagerErrorCode
            $state=if (-not $device.Present) {'missing'} elseif ($code -eq 22) {'disabled'} elseif ($code -ne 0) {'failed'} elseif ($Native -and $device.Service -ne 'helios_kmd_render') {'missing'} elseif (-not $Native -and $device.Service -ne 'BasicDisplay') {'unknown'} else {'running'}
            [pscustomobject]@{instanceId=[string]$device.PNPDeviceID;state=$state;problemCode=$code;service=[string]$device.Service}
        })
        $running=@($states | Where-Object {$_.state -eq 'running'})
        if ($running.Count) {return $running[0]}
        if ($states.Count) {return $states[0]}
        return [pscustomobject]@{instanceId='';state='missing';problemCode=0;service=''}
    }
    return [pscustomobject]@{helios=(Describe $helios $true);basic=(Describe $basic $false);heliosPresent=($helios.Count -gt 0);recovery='none';updatedAtUtc=[DateTime]::UtcNow.ToString('o')}
}
function Get-WinBoatDisplayRecoveryTime {
    $item=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WinBoat\DisplayRecovery' -Name LastAttemptTicks -ErrorAction SilentlyContinue
    if ($null -eq $item) {return [long]0}
    return [long]$item.LastAttemptTicks
}
function Set-WinBoatDisplayRecoveryTime([long]$Ticks) {
    New-Item -Path 'HKLM:\SOFTWARE\WinBoat\DisplayRecovery' -Force | Out-Null
    New-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WinBoat\DisplayRecovery' -Name LastAttemptTicks -PropertyType QWord -Value $Ticks -Force | Out-Null
}
function Invoke-WinBoatDisplayCheck([bool]$Repair,[bool]$ViewerUnavailable=$false,[bool]$MirrorDesired=$false) {
    $state=Get-WinBoatDisplayState
    # Mirroring explicitly needs both devices enabled, including when Helios
    # vanished completely. Unmanaged/default callers preserve intentional VGA
    # disables. Never disable devices, re-install drivers or reboot here.
    if ($Repair -and ($state.heliosPresent -or $MirrorDesired) -and ($MirrorDesired -or $ViewerUnavailable -or $state.helios.state -notin @('running','unknown')) -and $state.basic.state -in @('disabled','failed')) {
        $now=[DateTime]::UtcNow.Ticks
        $elapsed=$now - (Get-WinBoatDisplayRecoveryTime)
        if ($elapsed -ge 0 -and $elapsed -lt [TimeSpan]::FromSeconds(30).Ticks) {$state.recovery='cooldown';return $state}
        Set-WinBoatDisplayRecoveryTime $now
        $operation=if($state.basic.state -eq 'disabled'){'/enable-device'}else{'/restart-device'}
        & pnputil.exe $operation $state.basic.instanceId | Out-Null
        if ($LASTEXITCODE -notin @(0,3010)) {$state.recovery='failed';return $state}
        $pending=$LASTEXITCODE -eq 3010
        $state=Get-WinBoatDisplayState
        $state.recovery=if($pending){'restart-required'}else{'basic-enabled'}
    }
    return $state
}
if ($LibraryOnly) {return}
Invoke-WinBoatDisplayCheck ([bool]$Recover) ([bool]$ViewerUnavailable) ([bool]$MirrorDesired) | ConvertTo-Json -Depth 5 -Compress

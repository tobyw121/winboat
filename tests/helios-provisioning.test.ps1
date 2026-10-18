# Execute the OEM state machine with Windows task/process operations substituted.
param([string]$RepoRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$previousData=$env:ProgramData; $previousSystem=$env:SystemRoot
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('helios-provisioning-'+[guid]::NewGuid().ToString('N'))
try {
    $env:ProgramData=$temporary; $env:SystemRoot=$temporary
    . (Join-Path $RepoRoot 'guest_server/scripts/Start-HeliosProvisioning.ps1') -LibraryOnly
    $source=Join-Path $temporary 'source'; New-Item -ItemType Directory -Force $source | Out-Null
    $vector=Join-Path $source 'sha256-vector'
    [IO.File]::WriteAllBytes($vector,[Text.Encoding]::ASCII.GetBytes('abc'))
    if ((Get-WinBoatFileSha256 $vector) -ne 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') {throw 'SHA-256 known-answer test failed.'}
    'MZ-fixture-not-an-executable' | Set-Content (Join-Path $source 'HeliosSetup.exe')
    @{revision='fecffde64fd32399a877b452332681ef0db7993e';sha256=(Get-WinBoatFileSha256 (Join-Path $source 'HeliosSetup.exe'))} |
        ConvertTo-Json | Set-Content (Join-Path $source 'helios-build.json')
    $global:heliosBoot=[DateTime]::UtcNow.AddMinutes(-30)
    $global:heliosOfficial=$null; $global:heliosPhase='driver-restart-required'
    $global:heliosTestSigning=$false; $global:heliosBcdCalls=0; $global:heliosBcdExit=0
    $global:heliosLaunches=0; $global:heliosRestarts=0; $global:heliosStarts=@(); $global:heliosRemoved=0; $global:heliosEnabled=0
    function Assert-HeliosAdministrator {}
    function Test-HeliosBootTestSigning {return $global:heliosTestSigning}
    function bcdedit.exe {
        if (($args -join ' ') -ne '/set {current} testsigning on') {throw 'Wrong boot entry or test-signing operation.'}
        $global:heliosBcdCalls++; $global:LASTEXITCODE=$global:heliosBcdExit
    }
    function Get-CimInstance {param($ClassName) [pscustomobject]@{LastBootUpTime=$global:heliosBoot}}
    function Get-Acl {
        param($LiteralPath)
        $acl=[pscustomobject]@{}
        $acl | Add-Member ScriptMethod SetSecurityDescriptorSddlForm {param($Sddl) if($Sddl -notin @('O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)','O:SYG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)')){throw 'Executable task payload is not protected.'}}
        $acl
    }
    function Set-Acl {param($LiteralPath,$AclObject)}
    function Get-ScheduledTask {[CmdletBinding()]param($TaskName) if($TaskName -eq 'HeliosGraphicsProvisioning'){return $global:heliosOfficial}}
    function New-ScheduledTaskAction {param($Execute,$Argument) if($Argument -notlike '*-NonInteractive* -Resume'){throw 'Wrong resume action.'}; 'action'}
    function New-ScheduledTaskTrigger {param([switch]$AtStartup,[switch]$AtLogOn) if($AtStartup){'startup'}else{'logon'}}
    function New-ScheduledTaskSettingsSet {param($MultipleInstances,$ExecutionTimeLimit,[switch]$StartWhenAvailable) if($MultipleInstances -ne 'IgnoreNew' -or -not $StartWhenAvailable){throw 'Worker can race or miss startup.'};'settings'}
    function Register-ScheduledTask {
        param($TaskName,$Action,$Settings,$Trigger,$User,$RunLevel,[switch]$Force)
        if($TaskName -ne 'WinBoatHeliosReboots' -or $Trigger.Count -ne 2 -or $User -ne 'SYSTEM'){throw 'First install is not durable across reboot/logon.'}
    }
    function Start-ScheduledTask {
        param($TaskName)
        $global:heliosStarts+= $TaskName
        if($TaskName -eq 'HeliosGraphicsProvisioning'){Write-HeliosProgress $global:heliosPhase 'official task fixture'}
    }
    function Enable-ScheduledTask {param($TaskName) $global:heliosEnabled++}
    function Unregister-ScheduledTask {[CmdletBinding()]param($TaskName,[switch]$Confirm) $global:heliosRemoved++}
    function Start-Process {
        param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru)
        if($FilePath -ne (Join-Path $root 'HeliosSetup.exe') -or ($ArgumentList -join ' ') -ne '--silent --automatic' -or -not $Wait){throw 'Wrong installer or GUI/repair invocation.'}
        $global:heliosLaunches++
        Write-HeliosProgress $global:heliosPhase 'installer fixture'
        [pscustomobject]@{ExitCode=3010}
    }
    function shutdown.exe {$global:heliosRestarts++;$global:LASTEXITCODE=0}
    function Start-Sleep {
        param($Seconds)
        if($global:heliosPhase -ne 'finished'){throw 'Worker failed to resume promptly.'}
        Write-HeliosProgress 'finished' 'verified driver fixture'
    }
    function Next-Boot {
        $state=Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        $state.updatedAtUtc=$global:heliosBoot.AddSeconds(1).ToString('o')
        $state | ConvertTo-Json | Set-Content -LiteralPath $statusPath
        $global:heliosBoot=$global:heliosBoot.AddMinutes(5)
    }
    $selectedInstall=Join-Path $temporary 'selected'
    New-Item -ItemType Directory -Force (Join-Path $selectedInstall 'helios') | Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'HeliosSetup.exe'),(Join-Path $source 'helios-build.json') -Destination (Join-Path $selectedInstall 'helios')
    Invoke-HeliosEnsure $selectedInstall
    if($global:heliosStarts.Count){throw 'An unselected VM installed Helios'}
    '1' | Set-Content (Join-Path $selectedInstall 'helios-enabled')
    Invoke-HeliosEnsure $selectedInstall
    if($global:heliosLaunches -or $global:heliosRestarts -or $global:heliosStarts.Count -ne 1 -or
        -not (Test-Path (Join-Path $root 'HeliosSetup.exe')) -or -not (Test-Path (Join-Path $root 'Start-HeliosProvisioning.ps1')) -or
        -not (Test-Path (Join-Path $root 'Get-WinBoatFileSha256.ps1'))){throw 'OEM caller ran the installer inline or did not persist its verified payload.'}
    Invoke-HeliosProvisioning '' $true
    if($global:heliosLaunches -ne 0 -or $global:heliosRestarts -ne 1 -or $global:heliosRemoved -or $global:heliosBcdCalls -ne 1){throw 'Test-signing must request a reboot, not completion.'}
    Invoke-HeliosProvisioning '' $true
    if($global:heliosLaunches -ne 0 -or $global:heliosRestarts -ne 1){throw 'Same-boot logon duplicated installation/reboot.'}
    Next-Boot
    $global:heliosTestSigning=$true; $global:heliosOfficial=$null; $global:heliosPhase='driver-restart-required'
    Invoke-HeliosProvisioning '' $true
    if($global:heliosLaunches -ne 1 -or $global:heliosRestarts -ne 2 -or $global:heliosBcdCalls -ne 1){throw 'Missed/disabled official task was not resumed, or a second installer raced it.'}
    Next-Boot
    $global:heliosOfficial=[pscustomobject]@{State='Disabled'}; $global:heliosPhase='finished'
    $starts=$global:heliosStarts.Count
    $installed=Join-Path $temporary 'Helios'
    '{}' | Set-Content (Join-Path $installed 'install-state.json')
    @{source=@{helios=$expectedRevision}} | ConvertTo-Json | Set-Content (Join-Path $installed 'manifest.json')
    Invoke-HeliosProvisioning '' $true
    if($global:heliosRemoved -ne 1 -or $global:heliosRestarts -ne 2 -or $global:heliosStarts.Count -ne ($starts+1) -or $global:heliosEnabled -ne 1){throw 'An active installer was duplicated or completion did not require the final boot.'}
    $savedGuard=Get-Content -LiteralPath $guardPath -Raw
    $savedStatus=Get-Content -LiteralPath $statusPath -Raw
    $global:heliosTestSigning=$false
    Invoke-HeliosEnsure $selectedInstall
    if(Test-Path -LiteralPath $guardPath){throw 'Completed installation reused its exhausted reboot budget after test-signing was turned off'}
    $savedGuard | Set-Content -LiteralPath $guardPath
    $savedStatus | Set-Content -LiteralPath $statusPath
    $global:heliosTestSigning=$true
    $global:heliosOfficial=[pscustomobject]@{State='Running'}
    Next-Boot
    Write-HeliosProgress 'driver-restart-required' 'repeated restart fixture'
    $blocked=$false
    try {Invoke-HeliosProvisioning '' $true} catch {if($_.Exception.Message -notmatch 'loop prevented'){throw};$blocked=$true}
    if(-not $blocked -or $global:heliosRestarts -ne 2){throw 'Unbounded reboot loop accepted.'}
    Remove-Item $guardPath
    Write-HeliosProgress 'finished' 'incomplete installation fixture'
    Remove-Item (Join-Path $installed 'install-state.json')
    $blocked=$false
    try {Invoke-HeliosProvisioning '' $true} catch {if($_.Exception.Message -notmatch 'without an installed'){throw};$blocked=$true}
    if(-not $blocked -or $global:heliosRemoved -ne 1){throw 'False completion accepted.'}
    $global:heliosTestSigning=$false; $global:heliosBcdExit=1
    $blocked=$false
    try {Invoke-HeliosProvisioning '' $true} catch {if($_.Exception.Message -notmatch 'refused test-signing'){throw};$blocked=$true}
    if(-not $blocked -or $global:heliosRestarts -ne 2){throw 'A failed BCD change restarted Windows or launched the installer.'}
    'tampered' | Set-Content (Join-Path $root 'HeliosSetup.exe')
    $blocked=$false
    try {Invoke-HeliosProvisioning '' $true} catch {if($_.Exception.Message -notmatch 'SHA-256 mismatch'){throw};$blocked=$true}
    if(-not $blocked -or $global:heliosLaunches -ne 1){throw 'Unverified recovery installer executed.'}
    # A missed installer continuation must not leave a healthy post-reboot
    # display permanently behind the installation-only topology policy.
    '{}' | Set-Content (Join-Path $installed 'install-state.json')
    $global:heliosBcdExit=0; $global:heliosTestSigning=$true; $global:heliosOfficial=$null
    $global:heliosDeviceCode=0; $global:heliosDisplayHalf=1
    function Get-CimInstance {
        param($ClassName,$Filter)
        if($ClassName -eq 'Win32_OperatingSystem'){return [pscustomobject]@{LastBootUpTime=$global:heliosBoot}}
        if($ClassName -ne 'Win32_PnPEntity' -or $Filter -ne "PNPClass = 'Display'"){throw 'Unbounded device query'}
        [pscustomobject]@{PNPDeviceID='PCI\VEN_1AF4&DEV_1050&SUBSYS_11001AF4';Service='helios_kmd_render';ConfigManagerErrorCode=$global:heliosDeviceCode}
    }
    function Get-ItemProperty {param($LiteralPath) [pscustomobject]@{DspH=$global:heliosDisplayHalf}}
    function Pending-PreviousBoot {
        @{status='driver-restart-required';updatedAtUtc=$global:heliosBoot.AddMinutes(-1).ToString('o')} |
            ConvertTo-Json | Set-Content -LiteralPath $statusPath
    }
    Pending-PreviousBoot
    $global:heliosDeviceCode=22
    if(Complete-HeliosRestart $global:heliosBoot){throw 'Disabled driver completed provisioning'}
    $global:heliosDeviceCode=0; $global:heliosDisplayHalf=0
    if(Complete-HeliosRestart $global:heliosBoot){throw 'Render-only driver completed display provisioning'}
    $global:heliosDisplayHalf=1; $global:heliosTestSigning=$false
    if(Complete-HeliosRestart $global:heliosBoot){throw 'Inactive test-signing completed provisioning'}
    $global:heliosTestSigning=$true; $global:heliosOfficial=[pscustomobject]@{State='Running'}
    if(Complete-HeliosRestart $global:heliosBoot){throw 'Recovery raced the active installer'}
    $global:heliosOfficial=$null
    Write-HeliosProgress 'driver-restart-required' 'same boot'
    if(Complete-HeliosRestart $global:heliosBoot){throw 'Requested reboot was skipped'}
    Pending-PreviousBoot
    @{source=@{helios='wrong'}} | ConvertTo-Json | Set-Content (Join-Path $installed 'manifest.json')
    if(Complete-HeliosRestart $global:heliosBoot){throw 'Wrong stack completed provisioning'}
    @{source=@{helios=$expectedRevision}} | ConvertTo-Json | Set-Content (Join-Path $installed 'manifest.json')
    $beforeLaunches=$global:heliosLaunches; $beforeRestarts=$global:heliosRestarts
    Invoke-HeliosEnsure $selectedInstall
    $completed=Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    if($completed.status -ne 'finished' -or $global:heliosLaunches -ne $beforeLaunches -or $global:heliosRestarts -ne $beforeRestarts){throw 'Missed restart receipt recovery reinstalled or rebooted Windows'}
    # Regression: a permanent AME OOBE marker plus a missing resume task used
    # to send an installed driver back to Atlas handoff before checking health.
    $atlas=Join-Path $env:ProgramData 'WinBoat/Atlas'
    New-Item -ItemType Directory -Force $atlas | Out-Null
    '{}' | Set-Content (Join-Path $atlas 'oobe-mode.json')
    '{"status":"applying"}' | Set-Content (Join-Path $atlas 'status.json')
    Pending-PreviousBoot
    if(Invoke-HeliosRestartVerification $selectedInstall){throw 'Restart verification bypassed active AME'}
    '{"status":"finished"}' | Set-Content (Join-Path $atlas 'status.json')
    $global:heliosResume=$null
    function Get-ScheduledTask {
        [CmdletBinding()]param($TaskName)
        if($TaskName -eq 'HeliosGraphicsProvisioning'){return $global:heliosOfficial}
        if($TaskName -eq 'WinBoatHeliosReboots'){return $global:heliosResume}
    }
    $global:heliosResume=[pscustomobject]@{State='Running'}
    if(Invoke-HeliosRestartVerification $selectedInstall){throw 'Restart verification raced its resume worker'}
    $global:heliosResume=$null
    Invoke-HeliosEnsure $selectedInstall
    $completed=Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    if($completed.status -ne 'finished' -or $global:heliosLaunches -ne $beforeLaunches -or $global:heliosRestarts -ne $beforeRestarts){throw 'Finished Atlas with a stale restart receipt did not unlock mirroring'}
    # A periodic verification is safe even after the startup check missed a
    # busy worker. It never invokes the installer or schedules another reboot.
    Pending-PreviousBoot
    if(-not (Invoke-HeliosRestartVerification $selectedInstall)){throw 'Idle post-boot verification did not recover a missed continuation'}
    if(Invoke-HeliosRestartVerification $selectedInstall){throw 'Completed receipt was rewritten again'}
    if($global:heliosLaunches -ne $beforeLaunches -or $global:heliosRestarts -ne $beforeRestarts){throw 'Verification installed or rebooted Windows'}
    Write-Host 'Provisioning, reboot bounds, false-completion rejection and verified stale restart recovery passed with Windows API fixtures.'
} finally {
    $env:ProgramData=$previousData; $env:SystemRoot=$previousSystem
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

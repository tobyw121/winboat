param([string]$RepoRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$previousData=$env:ProgramData; $previousFiles=$env:ProgramFiles; $previousSystem=$env:SystemRoot
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('atlas-helios-'+[Guid]::NewGuid().ToString('N'))
try {
    $env:ProgramData=Join-Path $temporary 'data'; $env:ProgramFiles=Join-Path $temporary 'programs'; $env:SystemRoot=$temporary
    $root=Join-Path $env:ProgramData 'WinBoat/Atlas'; $media=Join-Path $env:ProgramData 'WinBoat/AtlasMedia'
    New-Item -ItemType Directory -Force $root,$media | Out-Null
    $bundle=Join-Path $env:ProgramFiles 'WinBoat/helios'
    New-Item -ItemType Directory -Force $bundle | Out-Null
    'MZ-installer-fixture' | Set-Content (Join-Path $bundle 'HeliosSetup.exe')
    @{revision='fecffde64fd32399a877b452332681ef0db7993e';sha256=(Get-FileHash (Join-Path $bundle 'HeliosSetup.exe') -Algorithm SHA256).Hash.ToLowerInvariant()} | ConvertTo-Json | Set-Content (Join-Path $bundle 'helios-build.json')
    $script=Join-Path $RepoRoot 'guest_server/scripts/Start-AtlasHelios.ps1'
    . $script -LibraryOnly
    $now=[DateTime]::UtcNow
    $global:handoffApplied=[pscustomobject]@{Version='0.5.0';ErrorLevel=0;AppliedTimeUTC=$now.AddHours(-1).ToBinary();SelectedOptions=@('defender-enable','mitigations-default','auto-updates-default')}
    $global:handoffBoot=$now.AddHours(-2); $global:handoffActive=$false; $global:handoffResume=$null
    @{mode='ame-oobe';release='0.5.0-hotfix';waitForHelios=$true;createdAtUtc=$now.AddHours(-3).ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $root 'oobe-mode.json')
    @{username='ConfiguredUser'} | ConvertTo-Json | Set-Content (Join-Path $media 'atlas.json')
    '12345' | Set-Content (Join-Path $root 'helios-started') # obsolete PID must not suppress recovery
    $global:handoffRegistrations=0; $global:handoffLaunches=0; $global:handoffStarts=0; $global:handoffRemovals=0
    $global:handoffRestarts=0
    function shutdown.exe {
        if($global:handoffActive -or $global:handoffApplied.ErrorLevel -ne 0){throw 'Restart interrupted AME or unverified Atlas.'}
        $global:handoffRestarts++;$global:LASTEXITCODE=0
    }
    function Get-ItemProperty {[CmdletBinding()]param($Path) return $global:handoffApplied}
    function Get-CimInstance {
        param($ClassName,$Filter)
        if ($ClassName -eq 'Win32_OperatingSystem') {return [pscustomobject]@{LastBootUpTime=$global:handoffBoot}}
        return [pscustomobject]@{Disabled=$false}
    }
    function Get-Process {[CmdletBinding()]param($Name) if($global:handoffActive){[pscustomobject]@{SessionId=1}}}
    function Get-Acl {
        param($LiteralPath)
        $acl=[pscustomobject]@{}
        $acl | Add-Member ScriptMethod SetSecurityDescriptorSddlForm {param($Sddl) if($Sddl -notmatch '^O:SYG:SYD:P'){throw 'Unprotected receipt directory.'}}
        return $acl
    }
    function Set-Acl {param($LiteralPath,$AclObject)}
    function New-ScheduledTaskAction {param($Execute,$Argument) [pscustomobject]@{Execute=$Execute;Argument=$Argument}}
    function New-ScheduledTaskSettingsSet {param($MultipleInstances,$ExecutionTimeLimit,[switch]$StartWhenAvailable) if($MultipleInstances -ne 'IgnoreNew'){throw 'Parallel handoffs allowed.'};'settings'}
    function New-ScheduledTaskTrigger {param([switch]$AtStartup,[switch]$AtLogOn) if($AtStartup){'startup'}else{'logon'}}
    function Register-ScheduledTask {
        param($TaskName,$Action,$Settings,$Trigger,$User,$RunLevel,[switch]$Force)
        if($TaskName -ne 'WinBoatHeliosAfterAtlas' -or $Trigger.Count -ne 2 -or $User -ne 'SYSTEM'){throw 'Handoff is not durable across reboot/logon.'}
        $global:handoffRegistrations++
    }
    function Start-ScheduledTask {param($TaskName) $global:handoffStarts++}
    function Get-ScheduledTask {[CmdletBinding()]param($TaskName) return $global:handoffResume}
    function Unregister-ScheduledTask {[CmdletBinding()]param($TaskName,[switch]$Confirm) $global:handoffRemovals++}
    function Start-Process {
        param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru)
        if(-not $Wait -or $ArgumentList -notlike '*Start-HeliosProvisioning.ps1* -BundlePath*'){throw 'Unexpected installer invocation.'}
        $global:handoffLaunches++
        return [pscustomobject]@{ExitCode=0}
    }
    $registered=& $script -Register | ConvertFrom-Json
    if($registered.status -ne 'queued' -or $global:handoffRegistrations -ne 1 -or $global:handoffLaunches -or
        -not (Test-Path (Join-Path $env:ProgramData 'WinBoat/Helios/helios-build.json'))){throw 'Registration launched a driver before Atlas rebooted or did not stage the API receipt.'}
    $global:handoffActive=$true
    & $script
    if($global:handoffRestarts){throw 'An active AME client was interrupted.'}
    $global:handoffActive=$false
    & $script
    $state=Get-Content (Join-Path $root 'helios-handoff.json') -Raw | ConvertFrom-Json
    if($state.status -ne 'waiting' -or $global:handoffLaunches -or $global:handoffRestarts -ne 1){throw 'Same-boot Atlas completion did not queue its one required restart.'}
    & $script
    if($global:handoffRestarts -ne 1){throw 'Same-boot logon duplicated the Atlas restart.'}
    $global:handoffBoot=$now
    $global:handoffActive=$true
    & $script
    if($global:handoffLaunches){throw 'Installer raced an active AME GUI.'}
    $global:handoffActive=$false
    & $script
    if($global:handoffLaunches -ne 1){throw 'Legacy PID marker incorrectly suppressed post-reboot installation.'}
    $global:handoffResume=[pscustomobject]@{State='Running'}
    & $script
    if($global:handoffLaunches -ne 1 -or $global:handoffStarts -ne 1){throw 'A second worker raced the existing resume task.'}
    $helios=Join-Path $env:ProgramData 'Helios'
    New-Item -ItemType Directory -Force $helios | Out-Null
    '{}' | Set-Content (Join-Path $helios 'install-state.json')
    @{source=@{helios='fecffde64fd32399a877b452332681ef0db7993e'}} | ConvertTo-Json | Set-Content (Join-Path $helios 'manifest.json')
    @{status='finished'} | ConvertTo-Json | Set-Content (Join-Path $helios 'provisioning-status.json')
    & $script
    $state=Get-Content (Join-Path $root 'helios-handoff.json') -Raw | ConvertFrom-Json
    if($state.status -ne 'finished' -or $global:handoffLaunches -ne 1 -or $global:handoffRemovals -ne 1){throw 'An already installed matching manual driver was reinstalled.'}
    # Upgrade a partial installation left by the old worker: its receipt exists,
    # but it never cached HeliosSetup.exe. Stage the full bundle, not -Resume.
    $global:handoffResume=$null
    @{status='driver-restart-required'} | ConvertTo-Json | Set-Content (Join-Path $helios 'provisioning-status.json')
    & $script
    if($global:handoffLaunches -ne 2){throw 'A partial legacy installation did not restage its missing recovery installer.'}
    $global:handoffApplied.ErrorLevel=1
    $failed=& $script -Register | ConvertFrom-Json
    if($failed.status -ne 'failed' -or $global:handoffRegistrations -ne 1 -or $global:handoffLaunches -ne 2){throw 'Unconfirmed Atlas completion launched Helios.'}
    $global:handoffApplied.ErrorLevel=0
    $global:handoffBoot=$now.AddMinutes(-90)
    & $script
    $state=Get-Content (Join-Path $root 'helios-handoff.json') -Raw | ConvertFrom-Json
    if($state.status -ne 'failed' -or $state.message -notmatch 'reboot loop prevented' -or $global:handoffRestarts -ne 1){throw 'An unconfirmed post-Atlas reboot loop was accepted.'}
    Write-Host 'Durable post-Atlas handoff, one guarded reboot after AME exits, reboot ordering, old PID/cache recovery, resume ownership and installed-driver preservation passed with Windows API fixtures.'
} finally {
    $env:ProgramData=$previousData; $env:ProgramFiles=$previousFiles; $env:SystemRoot=$previousSystem
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

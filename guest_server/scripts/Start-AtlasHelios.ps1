# Durable Atlas -> Helios handoff. Never use a transient PID as completion.
param([switch]$Register, [switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Get-WinBoatFileSha256.ps1')
$handoffRegister=$Register; $handoffLibraryOnly=$LibraryOnly
$install=Join-Path $env:ProgramFiles 'WinBoat'
. (Join-Path $PSScriptRoot 'Start-AtlasOOBE.ps1') -LibraryOnly
function Get-AtlasHeliosPhase($Applied,[DateTime]$Created,[DateTime]$Boot,[bool]$AccountReady,[bool]$ClientActive) {
    if (-not (Test-AtlasOOBEApplied $Applied $Created) -or -not $AccountReady) {return 'blocked'}
    if ($ClientActive -or $Boot -le [DateTime]::FromBinary([long]$Applied.AppliedTimeUTC).ToUniversalTime()) {return 'waiting-for-atlas-reboot'}
    return 'ready'
}
if ($handoffLibraryOnly) {return}
$root=Join-Path $env:ProgramData 'WinBoat\Atlas'
$taskName='WinBoatHeliosAfterAtlas'
$expectedRevision='fecffde64fd32399a877b452332681ef0db7993e'
function Publish-Handoff([string]$State,[string]$Message) {
    $data=@{status=$State;message=$Message;updatedAtUtc=[DateTime]::UtcNow.ToString('o')}
    $path=Join-Path $root 'helios-handoff.json'
    $data | ConvertTo-Json | Set-Content -LiteralPath "$path.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
    return $data
}
try {
    $mode=Get-Content -LiteralPath (Join-Path $root 'oobe-mode.json') -Raw | ConvertFrom-Json
    if ($mode.mode -ne 'ame-oobe' -or $mode.release -ne '0.5.0-hotfix' -or -not $mode.waitForHelios) {throw 'Helios was not selected for this supported Atlas installation.'}
    $conf=Get-Content -LiteralPath (Join-Path $env:ProgramData 'WinBoat\AtlasMedia\atlas.json') -Raw | ConvertFrom-Json
    if ($conf.username -notmatch '^[a-zA-Z0-9]{2,}$') {throw 'Invalid configured account.'}
    $applied=Get-ItemProperty 'HKLM:\SOFTWARE\AME\Playbooks\Applied\{00000000-0000-4000-6174-6C6173203A33}' -ErrorAction SilentlyContinue
    $accounts=@(Get-CimInstance Win32_UserAccount -Filter ("LocalAccount=True AND Name='{0}'" -f $conf.username))
    $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    $active=@(Get-Process -Name 'AME.Client' -ErrorAction SilentlyContinue | Where-Object {$_.SessionId -gt 0}).Count -gt 0
    $phase=Get-AtlasHeliosPhase $applied ([DateTime]::Parse($mode.createdAtUtc).ToUniversalTime()) $boot ($accounts.Count -eq 1 -and -not $accounts[0].Disabled) $active
    if ($phase -eq 'blocked') {throw 'Atlas success/profile or configured Windows account is not confirmed. Helios was not started.'}
    if ($handoffRegister) {
        # Make the status API usable while waiting for the post-Atlas boot.
        $bundle=Join-Path $install 'helios'
        $receipt=Get-Content -LiteralPath (Join-Path $bundle 'helios-build.json') -Raw | ConvertFrom-Json
        if ($receipt.revision -ne $expectedRevision -or (Get-WinBoatFileSha256 (Join-Path $bundle 'HeliosSetup.exe')) -ne $receipt.sha256) {throw 'Selected Helios bundle identity or SHA-256 mismatch.'}
        $identityRoot=Join-Path $env:ProgramData 'WinBoat\Helios'
        New-Item -ItemType Directory -Force $identityRoot | Out-Null
        Set-AtlasTreeAccess $identityRoot '' $false
        Copy-Item -LiteralPath (Join-Path $bundle 'helios-build.json') -Destination $identityRoot -Force
        $script=Join-Path $install 'scripts\Start-AtlasHelios.ps1'
        $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $script)
        $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1) -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Trigger @((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -AtLogOn)) -User SYSTEM -RunLevel Highest -Force | Out-Null
        $queued=Publish-Handoff 'queued' 'Helios handoff saved. Installation continues after the Atlas restart.'
        Start-ScheduledTask -TaskName $taskName
        $queued | ConvertTo-Json -Compress
        exit 0
    }
    if ($phase -ne 'ready') {
        # The observer already confirmed the selected playbook and account.
        # AME may exit without rebooting. Finish that handoff once, but never
        # interrupt its GUI or start a driver in the pre-reboot Atlas session.
        if (-not $active) {
            $restartPath=Join-Path $root 'helios-reboot.json'
            if (Test-Path -LiteralPath $restartPath) {
                $restart=Get-Content -LiteralPath $restartPath -Raw | ConvertFrom-Json
                if ($restart.boot -ne $boot.ToString('o')) {throw 'Atlas-to-Helios reboot loop prevented. Inspect the Atlas completion record.'}
            } else {
                @{boot=$boot.ToString('o');createdAtUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $restartPath -Encoding UTF8
                Publish-Handoff 'waiting' 'Atlas completed and its client exited. Restarting Windows once before automatic Helios installation.' | Out-Null
                & shutdown.exe /r /t 15 /d p:2:4 /c 'WinBoat: completing Atlas before the selected Helios installation'
                if ($LASTEXITCODE -ne 0) {throw 'Windows refused the Atlas-to-Helios restart.'}
            }
        }
        Publish-Handoff 'waiting' 'Waiting for Atlas to finish its Windows restart before starting Helios.' | Out-Null
        exit 0
    }
    $statePath=Join-Path $env:ProgramData 'Helios\provisioning-status.json'
    $state=if (Test-Path -LiteralPath $statePath) {Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json} else {$null}
    $installed=Test-Path -LiteralPath (Join-Path $env:ProgramData 'Helios\install-state.json')
    if ($installed) {
        $manifest=Get-Content -LiteralPath (Join-Path $env:ProgramData 'Helios\manifest.json') -Raw | ConvertFrom-Json
        if ($manifest.source.helios -ne $expectedRevision) {throw 'Installed Helios source identity does not match this stack.'}
    }
    if ($installed -and $null -ne $state -and $state.status -eq 'finished') {
        Publish-Handoff 'finished' 'The matching Helios installation is already complete.' | Out-Null
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        exit 0
    }
    if ($null -ne $state -and $state.status -eq 'failed') {throw 'Helios already reported a failure. Inspect its installer log before retrying.'}
    $resume=Get-ScheduledTask -TaskName 'WinBoatHeliosReboots' -ErrorAction SilentlyContinue
    if ($null -ne $resume) {
        if ($resume.State.ToString() -ne 'Running') {Start-ScheduledTask -TaskName 'WinBoatHeliosReboots'}
        Publish-Handoff 'waiting' 'The existing Helios resume task owns installation and its bounded restarts.' | Out-Null
        exit 0
    }
    $script=Join-Path $install 'scripts\Start-HeliosProvisioning.ps1'
    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $script
    # Older workers retained only the receipt, not the installer. Stage a full
    # durable worker before resuming those partially installed machines.
    if ($installed -and (Test-Path -LiteralPath (Join-Path $env:ProgramData 'WinBoat\Helios\HeliosSetup.exe'))) {$arguments+=' -Resume'}
    else {$arguments+=(' -BundlePath "{0}"' -f (Join-Path $install 'helios'))}
    Publish-Handoff 'started' 'Starting the selected Helios installer/resume worker after Atlas.' | Out-Null
    $process=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {throw 'Helios provisioning failed; inspect its installer status and log.'}
    if (Test-Path -LiteralPath $statePath) {
        $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.status -eq 'finished' -and (Test-Path -LiteralPath (Join-Path $env:ProgramData 'Helios\install-state.json'))) {
            $manifest=Get-Content -LiteralPath (Join-Path $env:ProgramData 'Helios\manifest.json') -Raw | ConvertFrom-Json
            if ($manifest.source.helios -ne $expectedRevision) {throw 'Completed Helios source identity does not match.'}
            Publish-Handoff 'finished' 'The matching Helios installation completed.' | Out-Null
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    # Keep this demand/startup task until an installed matching manifest and
    # completed driver state are observed; a reboot may interrupt this worker.
} catch {
    if (-not $handoffRegister) {
        $statusRoot=Join-Path $env:ProgramData 'Helios'
        New-Item -ItemType Directory -Force $statusRoot | Out-Null
        @{status='failed';message='Post-Atlas Helios handoff failed. Inspect WinBoat/Atlas/helios-handoff.json.';updatedAtUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $statusRoot 'provisioning-status.json') -Encoding UTF8
    }
    Publish-Handoff 'failed' $_.Exception.Message | ConvertTo-Json -Compress
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    exit 0
}

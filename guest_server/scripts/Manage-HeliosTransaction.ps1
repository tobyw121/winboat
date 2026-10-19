param([ValidateSet('Status','RememberStable','Install','Check','Accept','Rollback')][string]$Action='Status',
    [string]$BundlePath,[string]$ExpectedSha256,[switch]$ObservedStable,[switch]$LibraryOnly)
. (Join-Path $PSScriptRoot 'Helios-ValidationCommon.ps1')
function Assert-HeliosAcceptance($Report,$Identity) {
    $finish=[DateTimeOffset]::Parse($Report.finishedAtUtc)
    if ($Report.schema -ne 1 -or $Report.automatedPassed -isnot [bool] -or -not $Report.automatedPassed -or $Report.identity.version -ne $Identity.version -or
        $Report.identity.manifestSha256 -ne $Identity.manifestSha256 -or $Report.identity.bootAtUtc -ne $Identity.bootAtUtc -or
        $finish -lt [DateTimeOffset]::UtcNow.AddMinutes(-30) -or $finish -gt [DateTimeOffset]::UtcNow.AddSeconds(30)) {throw 'A successful, current-boot acceptance run within 30 minutes is required.'}
    foreach($name in @('D3D11','Vulkan enumeration','Vulkan features','Vulkan presentation','OpenGL')) {
        $rows=@($Report.tests | Where-Object {$_.name -eq $name -and $_.status -eq 'passed' -and $_.sha256 -match '^[a-fA-F0-9]{64}$'})
        if ($rows.Count -ne 1) {throw 'Acceptance report is missing required probe evidence.'}
    }
}
function Enter-HeliosTransactionMaintenance {
    . (Join-Path $PSScriptRoot 'Clear-HeliosDriverStore.ps1') -LibraryOnly
    Pause-HeliosCleanupTasks
    Set-HeliosTransactionHold $true
}
function Set-HeliosTransactionHold([bool]$Enabled) {
    . (Join-Path $PSScriptRoot 'Set-HeliosRescue.ps1') -LibraryOnly
    Set-HeliosRescueHold $Enabled
}
function Protect-HeliosTransaction {
    . (Join-Path $PSScriptRoot 'Set-HeliosRescue.ps1') -LibraryOnly
    return Invoke-HeliosRescue 'helios-disable'
}
function Save-HeliosTransactionBundle([string]$Folder,[string]$Pin) {
    if ($Pin -notmatch '^[a-fA-F0-9]{64}$') {throw 'An independently verified installer SHA-256 is required.'}
    $receipt=Read-HeliosValidationJson (Join-Path $Folder 'helios-build.json')
    $exe=Join-Path $Folder 'HeliosSetup.exe'
    if ($receipt.sha256 -ine $Pin -or (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ine $Pin -or
        $receipt.driverVersion -notmatch '^22\.22\.\d+\.0$' -or $receipt.manifestSha256 -notmatch '^[a-fA-F0-9]{64}$') {throw 'Selected installer or receipt identity mismatch.'}
    $root=Initialize-HeliosValidationRoot
    $target=Join-Path $root $Pin.ToLowerInvariant()
    if ((Test-Path -LiteralPath $target) -and ((Get-Item $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Bundle directory is a reparse point.'}
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Protect-HeliosValidationPath $target
    foreach($name in @('HeliosSetup.exe','helios-build.json')) {
        $dest=Join-Path $target $name
        if ((Test-Path -LiteralPath $dest) -and ((Get-Item $dest -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Bundle file is a reparse point.'}
        Copy-Item -LiteralPath (Join-Path $Folder $name) -Destination $dest -Force
        Protect-HeliosValidationPath $dest $false
    }
    if ((Get-FileHash (Join-Path $target 'HeliosSetup.exe') -Algorithm SHA256).Hash -ine $Pin) {throw 'Staged installer checksum mismatch.'}
    return [ordered]@{sha256=$Pin.ToLowerInvariant();version=$receipt.driverVersion;manifestSha256=$receipt.manifestSha256}
}
function Invoke-HeliosTransactionInstaller($Bundle) {
    $exe=Join-Path (Get-HeliosValidationRoot) ($Bundle.sha256+'\HeliosSetup.exe')
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ine $Bundle.sha256) {throw 'Stored installer changed.'}
    # No automatic reboot. The transaction owns the next state, not an OEM repair loop.
    $process=Start-Process -FilePath $exe -ArgumentList '--silent' -Wait -PassThru
    if ($process.ExitCode -notin @(0,3010)) {throw "Installer failed: $($process.ExitCode)"}
}
function Invoke-HeliosTransaction([string]$Operation) {
    $root=Get-HeliosValidationRoot
    $path=Join-Path $root 'transaction.json'
    if ($Operation -eq 'Status') {
        if (Test-Path -LiteralPath $path) {return Read-HeliosValidationJson $path}
        return @{status='none'}
    }
    if ($Operation -eq 'RememberStable') {
        $identity=Get-HeliosValidationIdentity
        $report=Read-HeliosValidationJson (Join-Path $root 'acceptance.json')
        Assert-HeliosAcceptance $report $identity
        if (-not $ObservedStable) {throw 'Observe colors, window switching, resolution change and recovery before recording stable.'}
        $bundle=Save-HeliosTransactionBundle $BundlePath $ExpectedSha256
        if ($bundle.version -ne $identity.version -or $bundle.manifestSha256 -ine $identity.manifestSha256) {throw 'Stable bundle does not match the installed package.'}
        Write-HeliosValidationJson 'last-good.json' $bundle
        return @{status='stable-recorded';version=$bundle.version;runId=$report.runId;manualObservation=$true}
    }
    if ($Operation -eq 'Install') {
        $stable=Read-HeliosValidationJson (Join-Path $root 'last-good.json')
        $identity=Get-HeliosValidationIdentity
        if ($stable.version -ne $identity.version -or $stable.manifestSha256 -ine $identity.manifestSha256) {throw 'Current package must match the recorded stable baseline.'}
        $bundle=Save-HeliosTransactionBundle $BundlePath $ExpectedSha256
        Enter-HeliosTransactionMaintenance
        $state=[ordered]@{schema=1;id=[guid]::NewGuid().ToString('N');status='prepared';candidate=$bundle;previous=$stable;
            installBoot=$identity.bootAtUtc;reason='';startedAtUtc=[DateTime]::UtcNow.ToString('o')}
        Write-HeliosValidationJson 'transaction.json' $state
        $script=$PSCommandPath
        $task=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Action Check"
        Register-ScheduledTask -TaskName 'WinBoatHeliosValidation' -Action $task -Trigger (New-ScheduledTaskTrigger -AtStartup) -User SYSTEM -RunLevel Highest -Settings (New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20)) -Force | Out-Null
        try {Invoke-HeliosTransactionInstaller $bundle;$state.status='pending-reboot'}
        catch {
            $state.status='rollback-required';$state.reason='installer-failed'
            Write-HeliosValidationJson 'transaction.json' $state
            Protect-HeliosTransaction | Out-Null
            throw
        }
        Write-HeliosValidationJson 'transaction.json' $state
        return $state
    }
    $state=Read-HeliosValidationJson $path
    if ($Operation -eq 'Rollback') {
        # Only verified Helios packages, only with Helios physically absent.
        . (Join-Path $PSScriptRoot 'Clear-HeliosDriverStore.ps1') -LibraryOnly
        $result=Invoke-HeliosDriverStoreCleanup
        $state.status=if($result.status -eq 'restart-required'){'rollback-cleanup-restart'}else{'rollback-staged'}
        Write-HeliosValidationJson 'transaction.json' $state
        return $state
    }
    if ($Operation -eq 'Check' -and $state.status -eq 'rollback-cleanup-restart') {
        throw 'Finish the VGA-only cleanup restart, then invoke Rollback again to confirm DriverStore is clean.'
    }
    if ($Operation -eq 'Check' -and $state.status -eq 'rollback-staged') {
        $devices=@(Get-CimInstance Win32_PnPEntity | Where-Object {$_.Present -and $_.PNPDeviceID -like 'PCI\VEN_1AF4&DEV_1050*'})
        if ($devices.Count -ne 1) {return $state}
        $state.status='restoring';Write-HeliosValidationJson 'transaction.json' $state
        try {
            Invoke-HeliosTransactionInstaller $state.previous
            $state.candidate=$state.previous
            $state.installBoot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            $state.status='pending-reboot'
        } catch {$state.status='rollback-required';$state.reason='restore-failed'}
        Write-HeliosValidationJson 'transaction.json' $state;return $state
    }
    if ($state.status -notin @('pending-reboot','awaiting-acceptance')) {return $state}
    try {
        $identity=Get-HeliosValidationIdentity
        if ($identity.bootAtUtc -eq $state.installBoot) {return $state}
        if ($identity.version -ne $state.candidate.version -or $identity.manifestSha256 -ine $state.candidate.manifestSha256) {throw 'Post-reboot package mismatch'}
        $state.status='awaiting-acceptance'
        if ($Operation -eq 'Accept') {
            $report=Read-HeliosValidationJson (Join-Path $root 'acceptance.json')
            Assert-HeliosAcceptance $report $identity
            if (-not $ObservedStable) {throw 'Explicit visual and recovery observation required.'}
            $state.status='accepted'
            Write-HeliosValidationJson 'last-good.json' $state.candidate
            Set-HeliosTransactionHold $false
            Unregister-ScheduledTask -TaskName 'WinBoatHeliosValidation' -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch {
        if ($Operation -eq 'Accept') {throw}
        $state.status='rollback-required'
        # Stop automatic provisioning and isolate the bad adapter if healthy VGA
        # is available. Never purge a live display driver or force a reboot.
        $rescue=Protect-HeliosTransaction
        $state | Add-Member NoteProperty recovery $rescue.status -Force
    }
    Write-HeliosValidationJson 'transaction.json' $state
    return $state
}
if ($LibraryOnly) {return}
if ($Action -ne 'Status') {
    if (-not [Environment]::Is64BitProcess -or -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Run native 64-bit PowerShell as Administrator.'}
}
$lock=New-Object Threading.Mutex($false,'Global\WinBoatHeliosProvisioning');$owned=$false
try {
    try {$owned=$lock.WaitOne(0)} catch [Threading.AbandonedMutexException] {$owned=$true}
    if (-not $owned) {throw 'Graphics maintenance is already active.'}
    Invoke-HeliosTransaction $Action | ConvertTo-Json -Depth 10
} finally {if($owned){$lock.ReleaseMutex()};$lock.Dispose()}

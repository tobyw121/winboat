param([ValidateSet('Status','RememberStable','Install','Check','Accept','Rollback')][string]$Action='Status',
    [string]$BundlePath,[string]$ExpectedSha256,[switch]$ObservedStable,[switch]$LibraryOnly)
. (Join-Path $PSScriptRoot 'Helios-ValidationCommon.ps1')
function Assert-HeliosAcceptance($Report,$Identity) {
    $finish=[DateTimeOffset]::Parse($Report.finishedAtUtc)
    if ($Report.schema -ne 1 -or $Report.automatedPassed -isnot [bool] -or -not $Report.automatedPassed -or $Report.identity.version -ne $Identity.version -or
        $Report.identity.manifestSha256 -ne $Identity.manifestSha256 -or $Report.identity.bootAtUtc -ne $Identity.bootAtUtc -or
        $finish -lt [DateTimeOffset]::UtcNow.AddMinutes(-30) -or $finish -gt [DateTimeOffset]::UtcNow.AddSeconds(30)) {throw 'A successful, current-boot acceptance run within 30 minutes is required.'}
    if (($Report.identity.profile | ConvertTo-Json -Compress) -ne ($Identity.profile | ConvertTo-Json -Compress)) {throw 'Driver options changed since the acceptance run.'}
    if ($Report.identity.machineId -ne $Identity.machineId) {throw 'Acceptance belongs to a different VM identity.'}
    foreach($name in @('Package integrity','D3D11','Vulkan enumeration','Vulkan features','Vulkan presentation','OpenGL')) {
        $rows=@($Report.tests | Where-Object {$_.name -eq $name -and $_.status -eq 'passed' -and $_.sha256 -match '^[a-fA-F0-9]{64}$'})
        if ($rows.Count -ne 1) {throw 'Acceptance report is missing required probe evidence.'}
    }
}
function Save-HeliosStableRecord($Bundle,$Identity,[string]$RunId) {
    Restore-HeliosStableProfile ($Identity.profile | ConvertTo-Json | ConvertFrom-Json) -ValidateOnly
    Write-HeliosValidationJson 'last-good.json' ([ordered]@{sha256=$Bundle.sha256;version=$Bundle.version;machineId=$Identity.machineId;manifestSha256=$Bundle.manifestSha256;profile=$Identity.profile;
        acceptanceRunId=$RunId;manuallyObservedAtUtc=[DateTime]::UtcNow.ToString('o')})
}
function Restore-HeliosStableProfile($Profile,[switch]$ValidateOnly) {
    $names=@('UmdD3D12','UmdCommandLists','UmdFreeThreaded','UmdAsyncPresentStream','UmdPresentBatchFold','FeatureLevel11')
    foreach($name in $names) {
        $property=$Profile.PSObject.Properties[$name]
        if ($null -eq $property -or ($null -ne $property.Value -and
            (($property.Value -isnot [int] -and $property.Value -isnot [long]) -or $property.Value -lt 0 -or
             $property.Value -gt $(if($name -eq 'FeatureLevel11'){2}else{1})))) {throw 'Invalid saved stable profile.'}
    }
    if ($ValidateOnly) {return}
    if (-not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Helios')) {New-Item -Path 'HKLM:\SOFTWARE\Helios' | Out-Null}
    foreach($name in $names) {
        if ($null -eq $Profile.$name) {Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Helios' -Name $name -ErrorAction SilentlyContinue}
        else {New-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Helios' -Name $name -Value ([int]$Profile.$name) -PropertyType DWord -Force | Out-Null}
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
        Save-HeliosStableRecord $bundle $identity $report.runId
        return @{status='stable-recorded';version=$bundle.version;runId=$report.runId;manualObservation=$true}
    }
    if ($Operation -eq 'Install') {
        $stable=Read-HeliosValidationJson (Join-Path $root 'last-good.json')
        $identity=Get-HeliosValidationIdentity
        if ($stable.version -ne $identity.version -or $stable.manifestSha256 -ine $identity.manifestSha256) {throw 'Current package must match the recorded stable baseline.'}
        if (-not $stable.PSObject.Properties['machineId'] -or $stable.machineId -ne $identity.machineId) {throw 'Record a stable baseline for this VM identity before updating.'}
        if (-not $stable.PSObject.Properties['profile'] -or
            ($stable.profile | ConvertTo-Json -Compress) -ne ($identity.profile | ConvertTo-Json -Compress)) {throw 'Record a stable baseline with the current driver options before updating.'}
        # Verify the retained rollback executable before touching the running stack.
        $stableExe=Join-Path $root ($stable.sha256+'\HeliosSetup.exe')
        if($stable.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
            (Get-FileHash -LiteralPath $stableExe -Algorithm SHA256).Hash -ine $stable.sha256){throw 'Recorded rollback installer is missing or changed.'}
        $existing=Invoke-HeliosTransaction 'Status'
        if($existing.status -notin @('none','accepted')){throw 'Resolve the previous driver transaction before installing another candidate.'}
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
    if($Operation -eq 'Check' -and $state.status -in @('prepared','restoring')) {
        # A process/host interruption must not leave an apparently successful update.
        $state.status='rollback-required';$state.reason='interrupted-installation'
        $rescue=Protect-HeliosTransaction
        $state | Add-Member NoteProperty recovery $rescue.status -Force
        Write-HeliosValidationJson 'transaction.json' $state
        return $state
    }
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
            if ($state.previous.PSObject.Properties['profile']) {Restore-HeliosStableProfile $state.previous.profile}
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
            Save-HeliosStableRecord $state.candidate $identity $report.runId
            $state | Add-Member NoteProperty acceptedRunId $report.runId -Force
            $state | Add-Member NoteProperty manuallyObservedAtUtc ([DateTime]::UtcNow.ToString('o')) -Force
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

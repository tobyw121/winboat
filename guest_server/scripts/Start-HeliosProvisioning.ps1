# OEM-only orchestrator. The pinned official installer owns driver installation.
param([string]$BundlePath, [switch]$Resume, [switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskName = 'WinBoatHeliosReboots'
$root = Join-Path $env:ProgramData 'WinBoat\Helios'
$statusPath = Join-Path $env:ProgramData 'Helios\provisioning-status.json'
$guardPath = Join-Path $root 'reboots.json'
$expectedRevision = 'fecffde64fd32399a877b452332681ef0db7993e'
function Write-HeliosProgress([string]$Status,[string]$Message) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statusPath) | Out-Null
    @{status=$Status;message=$Message;updatedAtUtc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json | Set-Content -LiteralPath "$statusPath.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$statusPath.tmp" -Destination $statusPath -Force
}
function Assert-HeliosBundle([string]$Folder) {
    $receipt = Get-Content -LiteralPath (Join-Path $Folder 'helios-build.json') -Raw | ConvertFrom-Json
    if ($receipt.revision -ne $expectedRevision -or
        (Get-FileHash -LiteralPath (Join-Path $Folder 'HeliosSetup.exe') -Algorithm SHA256).Hash.ToLowerInvariant() -ne $receipt.sha256) {
        throw 'Helios installer identity or SHA-256 mismatch.'
    }
}
function Assert-HeliosAdministrator {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Helios provisioning requires administrator rights.'
    }
}
function Assert-HeliosInstalled {
    if (-not (Test-Path -LiteralPath (Join-Path $env:ProgramData 'Helios\install-state.json') -PathType Leaf)) {
        throw 'Helios reported completion without an installed driver state.'
    }
    $manifest = Get-Content -LiteralPath (Join-Path $env:ProgramData 'Helios\manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.source.helios -ne $expectedRevision) {throw 'Installed Helios source identity does not match the selected stack.'}
}
function Invoke-HeliosProvisioning([string]$Source,[bool]$Continue) {
    Assert-HeliosAdministrator
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    if (-not $Continue) {
        Assert-HeliosBundle $Source
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($null -ne $existing -and $existing.State.ToString() -eq 'Running') {return}
        foreach ($target in @($root,(Join-Path $root 'HeliosSetup.exe'),(Join-Path $root 'helios-build.json'),(Join-Path $root 'Start-HeliosProvisioning.ps1'))) {
            if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Helios provisioning path contains a reparse point.'
            }
        }
        # A SYSTEM startup task must never execute a user-writable payload.
        $acl = Get-Acl -LiteralPath $root
        $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
        Set-Acl -LiteralPath $root -AclObject $acl
        foreach ($name in @('HeliosSetup.exe','helios-build.json')) {
            Copy-Item -LiteralPath (Join-Path $Source $name) -Destination $root -Force
        }
        $script = Join-Path $root 'Start-HeliosProvisioning.ps1'
        Copy-Item -LiteralPath $PSCommandPath -Destination $script -Force
        foreach ($name in @('HeliosSetup.exe','helios-build.json','Start-HeliosProvisioning.ps1')) {
            $target=Join-Path $root $name
            $acl=Get-Acl -LiteralPath $target
            $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)')
            Set-Acl -LiteralPath $target -AclObject $acl
        }
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -Resume"
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Trigger @((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -AtLogOn)) -User SYSTEM -RunLevel Highest -Force | Out-Null
        Write-HeliosProgress 'waiting' 'Helios installation queued; Windows test-signing and driver restarts are handled automatically.'
        # SetupComplete/AME may end its session. The durable SYSTEM task owns
        # the very first invocation as well as both post-reboot continuations.
        Start-ScheduledTask -TaskName $taskName
        return
    }
    Assert-HeliosBundle $root
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    $guard = if (Test-Path -LiteralPath $guardPath) {Get-Content -LiteralPath $guardPath -Raw | ConvertFrom-Json} else {[pscustomobject]@{count=0;boot='';state=''}}
    # A second logon trigger must not rerun the installer before a queued reboot.
    if ($guard.boot -eq $boot.ToString('o')) {return}
    $official = Get-ScheduledTask -TaskName 'HeliosGraphicsProvisioning' -ErrorAction SilentlyContinue
    if ($null -ne $official) {
        if ($official.State.ToString() -ne 'Running') {
            if ($official.State.ToString() -eq 'Disabled') {Enable-ScheduledTask -TaskName 'HeliosGraphicsProvisioning' | Out-Null}
            Start-ScheduledTask -TaskName 'HeliosGraphicsProvisioning'
        }
    } else {
        # Recover if the official task was lost or never created. Reuse the
        # verified persistent installer, never launch the GUI or a repair loop.
        $process = Start-Process -FilePath (Join-Path $root 'HeliosSetup.exe') -ArgumentList '--silent','--automatic' -Wait -PassThru
        if ($process.ExitCode -notin @(0,3010)) {throw "HeliosSetup.exe failed with exit code $($process.ExitCode)."}
    }
    $deadline = [DateTime]::UtcNow.AddMinutes(20)
    do {
        if (Test-Path -LiteralPath $statusPath) {
            $state = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            $fresh = ([DateTime]::Parse($state.updatedAtUtc).ToUniversalTime() -ge $boot)
            if ($state.status -eq 'failed') {throw $state.message}
            if ($fresh -and $state.status -eq 'finished') {
                Assert-HeliosInstalled
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                return
            }
            if ($fresh -and $state.status -in @('test-signing-restart-required','driver-restart-required')) {
                if ($guard.count -ge 2 -or $guard.state -eq $state.status) {throw 'Helios reboot loop prevented. Inspect the setup log in Windows.'}
                @{count=$guard.count+1;boot=$boot.ToString('o');state=$state.status} | ConvertTo-Json | Set-Content -LiteralPath $guardPath -Encoding UTF8
                & shutdown.exe /r /t 15 /d p:2:4 /c 'WinBoat: completing the selected Helios driver installation'
                if ($LASTEXITCODE -ne 0) {throw 'Windows refused the Helios provisioning restart.'}
                return
            }
        }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Timed out waiting for the Helios installer resume task.'
}
if ($LibraryOnly) {return}
$lock = $null; $owned = $false
try {
    # Registration must not hold the worker lock while starting that worker.
    if ($Resume) {
        $lock = New-Object Threading.Mutex($false,'Global\WinBoatHeliosProvisioning')
        try {$owned=$lock.WaitOne(0)} catch [Threading.AbandonedMutexException] {$owned=$true}
        if (-not $owned) {exit 0}
    }
    Invoke-HeliosProvisioning $BundlePath ([bool]$Resume)
} catch {
    Write-HeliosProgress 'failed' $_.Exception.Message
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Error $_
    exit 1
} finally {
    if ($owned) {$lock.ReleaseMutex()}
    if ($null -ne $lock) {$lock.Dispose()}
}

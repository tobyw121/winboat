# OEM-only orchestrator. The pinned official installer owns driver installation.
param([string]$BundlePath, [switch]$Resume, [switch]$LibraryOnly, [switch]$Ensure, [switch]$VerifyRestart)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Get-WinBoatFileSha256.ps1')
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
        (Get-WinBoatFileSha256 (Join-Path $Folder 'HeliosSetup.exe')) -ne $receipt.sha256) {
        throw 'Helios installer identity or SHA-256 mismatch.'
    }
}
function Assert-HeliosAdministrator {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Helios provisioning requires administrator rights.'
    }
}
function Test-HeliosBootTestSigning {
    # BCD describes the next boot. Query the running kernel before installing.
    if (-not ('WinBoat.CodeIntegrity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WinBoat {
    public static class CodeIntegrity {
        [StructLayout(LayoutKind.Sequential)]
        private struct Information { public UInt32 Length; public UInt32 Options; }
        [DllImport("ntdll.dll")]
        private static extern UInt32 NtQuerySystemInformation(UInt32 kind, ref Information info, UInt32 length, IntPtr returned);
        public static bool TestSigning() {
            var info = new Information(); info.Length = (UInt32)Marshal.SizeOf(info);
            var result = NtQuerySystemInformation(103, ref info, info.Length, IntPtr.Zero);
            if (result != 0) throw new InvalidOperationException("Cannot query active Windows code integrity: " + result.ToString("X8"));
            return (info.Options & 2U) != 0;
        }
    }
}
'@
    }
    return [WinBoat.CodeIntegrity]::TestSigning()
}
function Restart-HeliosProvisioning($Guard,[DateTime]$Boot,[string]$State) {
    if ($Guard.count -ge 2 -or $Guard.state -eq $State) {throw 'Helios reboot loop prevented. Inspect the setup log in Windows.'}
    @{count=$Guard.count+1;boot=$Boot.ToString('o');state=$State} | ConvertTo-Json | Set-Content -LiteralPath $guardPath -Encoding UTF8
    & shutdown.exe /r /t 15 /d p:2:4 /c 'WinBoat: completing the selected Helios driver installation'
    if ($LASTEXITCODE -ne 0) {throw 'Windows refused the Helios provisioning restart.'}
}
function Invoke-HeliosPackageVerification([string]$Verify) {
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Verify | Out-Null
    return $LASTEXITCODE -eq 0
}
function Assert-HeliosInstalled {
    if (-not (Test-Path -LiteralPath (Join-Path $env:ProgramData 'Helios\install-state.json') -PathType Leaf)) {
        throw 'Helios reported completion without an installed driver state.'
    }
    $manifest = Get-Content -LiteralPath (Join-Path $env:ProgramData 'Helios\manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.source.helios -ne $expectedRevision) {throw 'Installed Helios source identity does not match the selected stack.'}
    # A state file is written before registry setup finishes. It is not a
    # completion receipt: re-run the installed package's full read-only verifier.
    $verify=Join-Path $env:ProgramData 'Helios\Verify-Helios.ps1'
    if (-not (Test-Path -LiteralPath $verify -PathType Leaf)) {throw 'The completed Helios package verifier is missing.'}
    if (-not (Invoke-HeliosPackageVerification $verify)) {throw 'Helios package, API registration or driver verification failed; installation is not complete.'}
}
function Complete-HeliosRestart([DateTime]$Boot) {
    # Recover only a restart receipt from an earlier boot. A loaded miniport
    # during the install boot does not prove that the requested reboot happened.
    try {
        $state=Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        if ($state.status -ne 'driver-restart-required' -or
            [DateTime]::Parse($state.updatedAtUtc).ToUniversalTime() -ge $Boot -or
            -not (Test-HeliosBootTestSigning)) {return $false}
        Assert-HeliosInstalled
        $official=Get-ScheduledTask -TaskName 'HeliosGraphicsProvisioning' -ErrorAction SilentlyContinue
        if ($null -ne $official -and $official.State.ToString() -eq 'Running') {return $false}
        $devices=@(Get-CimInstance Win32_PnPEntity -Filter "PNPClass = 'Display'" | Where-Object {
            $_.PNPDeviceID -like 'PCI\VEN_1AF4&DEV_1050*' -and
            $_.Service -eq 'helios_kmd_render' -and $_.ConfigManagerErrorCode -eq 0
        })
        $driver=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\helios_kmd_render' -ErrorAction Stop
        if ($devices.Count -ne 1 -or $driver.DspH -ne 1) {return $false}
    } catch {return $false} # Missing/unknown evidence stays with the installer.
    Write-HeliosProgress 'finished' 'Helios restart verified: selected driver and display function are running in the new Windows boot.'
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    return $true
}
function Test-HeliosAtlasReady([string]$Install) {
    $atlas = Join-Path $env:ProgramData 'WinBoat\Atlas'
    if (-not (Test-Path -LiteralPath (Join-Path $Install 'atlas-enabled')) -and
        -not (Test-Path -LiteralPath (Join-Path $atlas 'oobe-mode.json'))) {return $true}
    try {
        $state = Get-Content -LiteralPath (Join-Path $atlas 'status.json') -Raw | ConvertFrom-Json
        return $state.status -eq 'finished'
    } catch {return $false}
}
function Test-HeliosSelected([string]$Install) {
    if (Test-Path -LiteralPath (Join-Path $Install 'helios-enabled')) {return $true}
    try {
        $receipt = Get-Content -LiteralPath (Join-Path $root 'helios-build.json') -Raw | ConvertFrom-Json
        return $receipt.revision -eq $expectedRevision
    } catch {return $false}
}
function Invoke-HeliosRestartVerification([string]$Install) {
    # This operation can finish a stale receipt, never install or reboot.
    # An AME marker may remain forever; its presence alone must not suppress
    # verification after the playbook has actually completed.
    if (-not (Test-HeliosSelected $Install) -or
        -not (Test-HeliosAtlasReady $Install)) {return $false}
    $verificationLock = New-Object Threading.Mutex($false,'Global\WinBoatHeliosProvisioning')
    $verificationOwned = $false
    try {
        try {$verificationOwned=$verificationLock.WaitOne(0)} catch [Threading.AbandonedMutexException] {$verificationOwned=$true}
        if (-not $verificationOwned) {return $false}
        foreach ($name in @($taskName, 'HeliosGraphicsProvisioning')) {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            if ($null -ne $task -and $task.State.ToString() -eq 'Running') {return $false}
        }
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
        return Complete-HeliosRestart $boot
    } finally {
        if ($verificationOwned) {$verificationLock.ReleaseMutex()}
        $verificationLock.Dispose()
    }
}
function Invoke-HeliosProvisioning([string]$Source,[bool]$Continue) {
    Assert-HeliosAdministrator
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    if (-not $Continue) {
        Assert-HeliosBundle $Source
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($null -ne $existing -and $existing.State.ToString() -eq 'Running') {return}
        foreach ($target in @($root,(Join-Path $root 'HeliosSetup.exe'),(Join-Path $root 'helios-build.json'),(Join-Path $root 'Start-HeliosProvisioning.ps1'),(Join-Path $root 'Get-WinBoatFileSha256.ps1'))) {
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
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Get-WinBoatFileSha256.ps1') -Destination $root -Force
        foreach ($name in @('HeliosSetup.exe','helios-build.json','Start-HeliosProvisioning.ps1','Get-WinBoatFileSha256.ps1')) {
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
    if (-not (Test-HeliosBootTestSigning)) {
        if ($guard.count -ge 2 -or $guard.state -eq 'test-signing-restart-required') {throw 'Helios reboot loop prevented: Windows test-signing did not become active.'}
        & bcdedit.exe /set '{current}' testsigning on | Out-Null
        if ($LASTEXITCODE -ne 0) {throw 'Windows refused test-signing. Disable Secure Boot in the VM firmware before installing the test-signed Helios driver.'}
        Write-HeliosProgress 'test-signing-restart-required' 'Windows test-signing configured. Restarting before automatic Helios installation.'
        Restart-HeliosProvisioning $guard $boot 'test-signing-restart-required'
        return
    }
    if (Complete-HeliosRestart $boot) {return}
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
            if ($fresh -and $state.status -eq 'failed') {throw $state.message}
            if ($fresh -and $state.status -eq 'finished') {
                Assert-HeliosInstalled
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                return
            }
            if ($fresh -and $state.status -in @('test-signing-restart-required','driver-restart-required')) {
                Restart-HeliosProvisioning $guard $boot $state.status
                return
            }
        }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Timed out waiting for the Helios installer resume task.'
}
function Invoke-HeliosEnsure([string]$Install) {
    # Service startup recovers a missed OEM registration. Atlas owns its handoff
    # until OOBE is complete; never restart Windows in the middle of AME.
    if (-not (Test-HeliosSelected $Install)) {return}
    if (Test-Path -LiteralPath $statusPath) {
        $prior=Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        if ($prior.status -eq 'failed') {return} # Explicit recovery owns retries.
    }
    # Verify before the legacy Atlas handoff branch: an already installed
    # driver with no resume task otherwise never reaches this completion check.
    if (Invoke-HeliosRestartVerification $Install) {return}
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath (Join-Path $env:ProgramData 'WinBoat\Atlas\oobe-mode.json')) {
        # Only an already registered handoff worker proves Atlas authorized the
        # driver stage. An incomplete AME session must not be interrupted.
        if ($null -eq $existing) {
            # Recover a missed/failed handoff only after Atlas itself confirms
            # its playbook, account and post-Atlas boot. The called script is a
            # no-op while AME is still installing and revalidates before work.
            & (Join-Path $install 'scripts\Start-AtlasHelios.ps1') -Register -OnlyWhenReady -RetryFailed
            return
        }
    }
    if ($null -ne $existing -and $existing.State.ToString() -eq 'Running') {return}
    # Re-stage an idle legacy worker from the updated API scripts before starting
    # it, so an old protected copy does not keep the previous boot logic.

    if (Test-Path -LiteralPath $statusPath) {
        $state = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        if ($state.status -eq 'finished') {
            Assert-HeliosInstalled
            if (Test-HeliosBootTestSigning) {return}
            # A previously completed installation is a new maintenance attempt,
            # not a continuation of its already exhausted two-reboot budget.
            Remove-Item -LiteralPath $guardPath -Force -ErrorAction SilentlyContinue
        }
    }
    Invoke-HeliosProvisioning (Join-Path $install 'helios') $false
}
if ($LibraryOnly) {return}
$rescue=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WinBoat\DisplayRecovery' -Name HeliosDisabled -ErrorAction SilentlyContinue
if ($null -ne $rescue -and $rescue.PSObject.Properties['HeliosDisabled'] -and $rescue.HeliosDisabled -eq 1) {return}
$lock = $null; $owned = $false
try {
    if ($VerifyRestart) {Invoke-HeliosRestartVerification (Split-Path -Parent $PSScriptRoot) | Out-Null;return}
    if ($Ensure) {Invoke-HeliosEnsure (Split-Path -Parent $PSScriptRoot);return}
    # Registration must not hold the worker lock while starting that worker.
    if ($Resume) {
        $lock = New-Object Threading.Mutex($false,'Global\WinBoatHeliosProvisioning')
        try {$owned=$lock.WaitOne(0)} catch [Threading.AbandonedMutexException] {$owned=$true}
        if (-not $owned) {exit 0}
    }
    Invoke-HeliosProvisioning $BundlePath ([bool]$Resume)
} catch {
    if (-not $VerifyRestart) {
        Write-HeliosProgress 'failed' $_.Exception.Message
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Error $_
    exit 1
} finally {
    if ($owned) {$lock.ReleaseMutex()}
    if ($null -ne $lock) {$lock.Dispose()}
}

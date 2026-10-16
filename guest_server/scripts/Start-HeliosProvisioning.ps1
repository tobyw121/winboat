# OEM-only orchestrator. Interactive users run the official HeliosSetup.exe GUI.
param([string]$BundlePath, [switch]$Resume)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskName = 'WinBoatHeliosReboots'
$root = Join-Path $env:ProgramData 'WinBoat\Helios'
$statusPath = Join-Path $env:ProgramData 'Helios\provisioning-status.json'
$guardPath = Join-Path $root 'reboots.json'
$expectedRevision = 'fecffde64fd32399a877b452332681ef0db7993e'
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
function Publish-Failure([string]$Message) {
    $parent = Split-Path -Parent $statusPath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    @{ status = 'failed'; message = $Message; updatedAtUtc = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
}
try {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Helios provisioning requires administrator rights.'
    }
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    if (-not $Resume) {
        $receipt = Get-Content -LiteralPath (Join-Path $BundlePath 'helios-build.json') -Raw | ConvertFrom-Json
        $exe = Join-Path $BundlePath 'HeliosSetup.exe'
        if ($receipt.revision -ne $expectedRevision -or (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $receipt.sha256) {
            throw 'Helios installer identity or SHA-256 mismatch.'
        }
        Copy-Item -LiteralPath (Join-Path $BundlePath 'helios-build.json') -Destination $root -Force
        # The official installer owns driver backup, signing checks and resume.
        $script = Join-Path $root 'Start-HeliosProvisioning.ps1'
        Copy-Item -LiteralPath $PSCommandPath -Destination $script -Force
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Resume"
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -User SYSTEM -RunLevel Highest -Force | Out-Null
        $process = Start-Process -FilePath $exe -ArgumentList '--silent', '--automatic' -Wait -PassThru
        if ($process.ExitCode -notin @(0,3010)) { throw "HeliosSetup.exe failed with exit code $($process.ExitCode)." }
    }
    # On subsequent boots the official HeliosGraphicsProvisioning task runs.
    # Wait for its fresh result, never launch a second installer concurrently.
    $deadline = [DateTime]::UtcNow.AddMinutes(20)
    do {
        if (Test-Path -LiteralPath $statusPath) {
            $state = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            $fresh = ([DateTime]::Parse($state.updatedAtUtc).ToUniversalTime() -ge $boot)
            if ($state.status -eq 'failed') { throw $state.message }
            if ($fresh -and $state.status -eq 'finished') {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                exit 0
            }
            if ($fresh -and $state.status -in @('test-signing-restart-required','driver-restart-required')) {
                $guard = if (Test-Path -LiteralPath $guardPath) { Get-Content -LiteralPath $guardPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{ count = 0; boot = ''; state = '' } }
                if ($guard.boot -eq $boot.ToString('o')) { exit 0 }
                if ($guard.count -ge 2 -or $guard.state -eq $state.status) { throw 'Helios reboot loop prevented. Inspect the setup log in Windows.' }
                @{ count = $guard.count + 1; boot = $boot.ToString('o'); state = $state.status } | ConvertTo-Json | Set-Content -LiteralPath $guardPath -Encoding UTF8
                # Explicit OEM mode only: two bounded VM reboots, no host reboot.
                & shutdown.exe /r /t 15 /d p:2:4 /c 'WinBoat: completing the selected Helios driver installation'
                if ($LASTEXITCODE -ne 0) { throw 'Windows refused the Helios provisioning restart.' }
                exit 0
            }
        }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Timed out waiting for the Helios installer resume task.'
} catch {
    Publish-Failure $_.Exception.Message
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Error $_
    exit 1
}

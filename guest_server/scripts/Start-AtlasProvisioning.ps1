# AME's documented CLI runs in an elevated interactive Windows session.
# It may ask for preparation/reboots. Do not feed keystrokes or bypass its checks.
param([switch]$Register, [string]$BundlePath, [switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-AtlasApplied($Applied, [DateTime]$StartedAt) {
    if ($null -eq $Applied) { return $false }
    foreach ($name in @('Version', 'ErrorLevel', 'AppliedTimeUTC')) {
        if ($null -eq $Applied.PSObject.Properties[$name]) { return $false }
    }
    try {
        return $Applied.Version -eq '0.5.0' -and [int]$Applied.ErrorLevel -eq 0 -and
            [DateTime]::FromBinary([long]$Applied.AppliedTimeUTC).ToUniversalTime() -ge $StartedAt
    } catch { return $false }
}

function Assert-AtlasMedia([string]$Folder) {
    $hashes = @{
        'CLI-Standalone.zip' = '70e4946b52c9384ca88730c0dd25646defc63affdef7acadd69cb6317f21825a'
        'AtlasPlaybook.apbx' = '13c4d8e7fc0ed38c37c5942ebcabf7f636389972e6de391a192ae649967602d8'
    }
    foreach ($name in $hashes.Keys) {
        if ((Get-FileHash -LiteralPath (Join-Path $Folder $name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hashes[$name]) {
            throw "Atlas media SHA-256 mismatch: $name"
        }
    }
}

if ($LibraryOnly) { return }
$taskName = 'WinBoatAtlasProvisioning'
$root = Join-Path $env:ProgramData 'WinBoat\Atlas'
$statusPath = Join-Path $root 'status.json'
$guardPath = Join-Path $root 'attempts.json'
$options = @('defender-enable', 'mitigations-default', 'auto-updates-default')
function Publish-Atlas([string]$Status, [string]$Message) {
    $temporary = "$statusPath.tmp"
    @{ status = $Status; message = $Message; release = '0.5.0-hotfix'; updatedAtUtc = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $statusPath -Force
}
try {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Atlas provisioning requires an elevated Windows session.'
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    if ($Register) {
        # Protect code/media used by the elevated logon task from ordinary users.
        & icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Cannot protect the Atlas provisioning directory.' }
        $conf = Get-Content -LiteralPath (Join-Path $BundlePath 'atlas.json') -Raw | ConvertFrom-Json
        if ($conf.release -ne '0.5.0-hotfix' -or $conf.cliRelease -ne '0.8.4' -or $conf.mode -notin @('iso','live') -or $conf.username -notmatch '^[a-zA-Z0-9]{2,}$') {
            throw 'Unsupported Atlas media configuration.'
        }
        if ($conf.mode -eq 'iso') {
            $BundlePath = Join-Path $env:ProgramData 'WinBoat\AtlasMedia'
            if (-not (Test-Path -LiteralPath $BundlePath)) { throw 'Atlas WIM payload was not installed. ISO injection did not finish.' }
        }
        Assert-AtlasMedia $BundlePath
        $destination = Join-Path $root 'media'
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        foreach ($name in @('CLI-Standalone.zip', 'AtlasPlaybook.apbx', 'atlas.json')) {
            Copy-Item -LiteralPath (Join-Path $BundlePath $name) -Destination $destination -Force
        }
        $script = Join-Path $root 'Start-AtlasProvisioning.ps1'
        Copy-Item -LiteralPath $PSCommandPath -Destination $script -Force
        $user = "$env:COMPUTERNAME\$($conf.username)"
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2) -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) -Force | Out-Null
        Publish-Atlas 'waiting' 'Log in to Windows to continue Atlas. AME may request security preparation and restarts; follow its console prompts.'
        # The first interactive session may already exist. Otherwise the logon trigger owns startup.
        try { Start-ScheduledTask -TaskName $taskName } catch { Write-Warning 'Atlas will start at the next Windows logon.' }
        exit 0
    }
    $media = Join-Path $root 'media'
    Assert-AtlasMedia $media
    $conf = Get-Content -LiteralPath (Join-Path $media 'atlas.json') -Raw | ConvertFrom-Json
    if ($conf.waitForHelios) {
        Publish-Atlas 'waiting-helios' 'Waiting for Helios. Log in again after its driver restarts to continue Atlas.'
        $deadline = [DateTime]::UtcNow.AddMinutes(60)
        do {
            $helios = Join-Path $env:ProgramData 'Helios\provisioning-status.json'
            if (Test-Path -LiteralPath $helios) {
                $state = Get-Content -LiteralPath $helios -Raw | ConvertFrom-Json
                if ($state.status -eq 'failed') { throw "Helios failed: $($state.message)" }
                if ($state.status -eq 'finished') { break }
            }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Helios is still pending. Inspect its Windows logs before retrying Atlas.' }
            Start-Sleep -Seconds 5
        } while ($true)
    }
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    $guard = if (Test-Path -LiteralPath $guardPath) { Get-Content -LiteralPath $guardPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{ count = 0; boot = '' } }
    if ($guard.boot -eq $boot) { exit 0 } # Never retry the same boot automatically.
    if ($guard.count -ge 3) { throw 'Atlas preparation did not finish within three Windows boots. Automatic retries stopped.' }
    $version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    if ($version.CurrentBuildNumber -notin @('26100','26200') -or $version.EditionID -ne 'Professional' -or -not [Environment]::Is64BitOperatingSystem) {
        throw 'Atlas 0.5.0 requires x64 Windows 11 Pro 24H2/25H2. Unsupported editions/builds are not modified.'
    }
    @{ count = $guard.count + 1; boot = $boot } | ConvertTo-Json | Set-Content -LiteralPath $guardPath -Encoding UTF8
    $cli = Join-Path $root 'cli'
    $playbook = Join-Path $root 'playbook'
    # Always extract clean, verified input. CLI may modify its own resources during preparation.
    Remove-Item -LiteralPath $cli, $playbook -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath (Join-Path $media 'CLI-Standalone.zip') -DestinationPath $cli -Force
    Add-Type -Path (Join-Path $cli 'SharpSevenZip.dll')
    [SharpSevenZip.SharpSevenZipBase]::SetLibraryPath((Join-Path $cli 'x64\7z.dll'))
    $extractor = [SharpSevenZip.SharpSevenZipExtractor]::new((Join-Path $media 'AtlasPlaybook.apbx'), 'malte')
    try { $extractor.ExtractArchive($playbook) } finally { $extractor.Dispose() }
    # Pass explicit options: AME CLI does not merge them with radio-page defaults.
    $started = [DateTime]::UtcNow
    Publish-Atlas 'running' 'AME CLI is running in Windows. Follow preparation prompts and log in after any restart. Atlas has not finished yet.'
    $arguments = @('"' + $playbook + '"') + $options
    $process = Start-Process -FilePath (Join-Path $cli 'TrustedUninstaller.CLI.exe') -WorkingDirectory $cli -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "AME CLI exited with code $($process.ExitCode). Inspect the Windows AME logs in $cli." }
    $applied = Get-ItemProperty 'HKLM:\SOFTWARE\AME\Playbooks\Applied\{00000000-0000-4000-6174-6C6173203A33}' -ErrorAction SilentlyContinue
    if (-not (Test-AtlasApplied $applied $started)) {
        # Preparation can exit 0 before reboot; a completed playbook can also report errors with exit 0.
        if ($null -ne $applied -and $null -ne $applied.PSObject.Properties['ErrorLevel'] -and [int]$applied.ErrorLevel -ne 0) {
            throw 'AME recorded Atlas playbook errors. A zero CLI exit code does not mean success.'
        }
        Publish-Atlas 'awaiting-user' "AME has not recorded a completed playbook. Check its console/logs in $cli and log in after its requested restart."
        exit 0
    }
    # Keep WinBoat's guest API available after the selected system changes.
    Start-Service -Name WinBoatGuestServer
    Publish-Atlas 'finished' 'Atlas 0.5.0 completed successfully. Restart Windows once before using the optimized desktop.'
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
} catch {
    Publish-Atlas 'failed' $_.Exception.Message
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Error $_
    exit 1
}

# AME's original OOBE owns playbook execution. This task only observes its result.
param([switch]$Register, [switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$oobeRequestedRegister = $Register
$oobeLibraryOnly = $LibraryOnly
. (Join-Path $PSScriptRoot 'Start-AtlasProvisioning.ps1') -LibraryOnly

function Test-AtlasOOBEApplied($Applied, [DateTime]$CreatedAt) {
    if (-not (Test-AtlasApplied $Applied $CreatedAt)) { return $false }
    if ($null -eq $Applied.PSObject.Properties['SelectedOptions']) { return $false }
    foreach ($option in @('defender-enable', 'mitigations-default', 'auto-updates-default')) {
        if ($option -notin $Applied.SelectedOptions) { return $false }
    }
    return $true
}

function Get-AtlasHandoffFailure($Service, [string]$ConsoleUser) {
    if ($null -ne $Service -and $Service.State -eq 'Stopped' -and [int]$Service.ExitCode -ne 0) {
        return ('AME OOBE service stopped with code {0}. Atlas is not complete; collect diagnostics before recovery.' -f $Service.ExitCode)
    }
    if (-not $ConsoleUser) {
        $key = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        if ($key.DefaultUserName -ieq 'defaultuser0' -and [string]$key.AutoAdminLogon -eq '0') {
            return 'AME setup has no console user and setup autologon is disabled. Atlas completion is not confirmed; guarded OOBE recovery is required.'
        }
    }
    return $null
}

function Convert-AtlasRegistryBackup($Entry) {
    $bytes = [byte[]]$Entry.originalBytes
    switch ([int]$Entry.originalType) {
        0 { return ,$bytes }
        1 { return [Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0) }
        2 { return [Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0) }
        3 { return ,$bytes }
        4 { return [BitConverter]::ToInt32($bytes, 0) }
        7 { return ,([Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0).Split([char]0)) }
        11 { return [BitConverter]::ToInt64($bytes, 0) }
        default { throw 'Unsupported registry backup type; restore Windows security manually.' }
    }
}

function Grant-AtlasSetupAccountAccess {
    # The GUI runs in the temporary user's session and reads oobe.conf itself.
    # Keep the observer/admin scripts private; grant only this setup SID RX.
    $folder = Join-Path $env:ProgramData 'AME\OOBE'
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return $false }
    $accounts = @(Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True AND Name='defaultuser0'")
    if ($accounts.Count -ne 1 -or $accounts[0].Disabled) { return $false }
    $sid = [string]$accounts[0].SID
    if ($sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'Unexpected Windows setup account SID.' }
    & icacls.exe $folder /grant:r (('*{0}:(OI)(CI)RX' -f $sid)) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot grant the temporary setup account access to AME.' }
    return $true
}

function Restore-AtlasPreparation([string]$BackupPath) {
    foreach ($entry in (Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json)) {
        # Restore only the six known preparation values, and only if unchanged by AME.
        if ($entry.path -notmatch '^(Policies\\)?Microsoft\\Windows Defender\\' -or
            $entry.name -notin @('DisableRealtimeMonitoring','DisableAsyncScanOnOpen','SpyNetReporting','SubmitSamplesConsent','TamperProtection')) {
            throw 'Unexpected security backup entry.'
        }
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\$($entry.path)", $true)
        if ($null -eq $key) { continue }
        try {
            $current = $key.GetValue($entry.name, $null)
            if ($null -eq $current -or $key.GetValueKind($entry.name) -ne [Microsoft.Win32.RegistryValueKind]::DWord -or
                [int]$current -ne [int]$entry.prepared) { continue }
            if ($null -eq $entry.originalType) { $key.DeleteValue($entry.name, $false) }
            else { $key.SetValue($entry.name, (Convert-AtlasRegistryBackup $entry), [Microsoft.Win32.RegistryValueKind][int]$entry.originalType) }
        } finally { $key.Dispose() }
    }
}

if ($oobeLibraryOnly) { return }
$root = Join-Path $env:ProgramData 'WinBoat\Atlas'
$statusPath = Join-Path $root 'status.json'
$taskName = 'WinBoatAtlasOOBE'
function Publish-AtlasOOBE([string]$Status, [string]$Message) {
    @{ status = $Status; message = $Message; release = '0.5.0-hotfix'; updatedAtUtc = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath "$statusPath.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$statusPath.tmp" -Destination $statusPath -Force
}
try {
    $mode = Get-Content -LiteralPath (Join-Path $root 'oobe-mode.json') -Raw | ConvertFrom-Json
    if ($mode.mode -ne 'ame-oobe' -or $mode.release -ne '0.5.0-hotfix') { throw 'Invalid AME OOBE installation marker.' }
    if ($oobeRequestedRegister) {
        foreach ($folder in @($root, (Join-Path $env:ProgramData 'AME\OOBE'))) {
            & icacls.exe $folder /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Cannot protect AME setup files.' }
        }
        Grant-AtlasSetupAccountAccess | Out-Null
        foreach ($name in @('Start-AtlasOOBE.ps1', 'Start-AtlasProvisioning.ps1')) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $root -Force
        }
        $script = Join-Path $root 'Start-AtlasOOBE.ps1'
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2) -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Trigger (New-ScheduledTaskTrigger -AtStartup) -User SYSTEM -RunLevel Highest -Force | Out-Null
        Publish-AtlasOOBE 'waiting' 'Waiting for AME setup to finish in the Windows console. Atlas completion has not been confirmed yet.'
        Start-ScheduledTask -TaskName $taskName
        exit 0
    }
    $conf = Get-Content -LiteralPath (Join-Path $env:ProgramData 'WinBoat\AtlasMedia\atlas.json') -Raw | ConvertFrom-Json
    if ($conf.username -notmatch '^[a-zA-Z0-9]{2,}$') { throw 'Invalid configured Atlas username.' }
    $created = [DateTime]::Parse($mode.createdAtUtc).ToUniversalTime()
    $deadline = [DateTime]::UtcNow.AddMinutes(110)
    $setupAccessGranted = $false
    $handoffFailures = 0
    do {
        # On a fresh boot the temporary account may be created after this task.
        if (-not $setupAccessGranted) { $setupAccessGranted = Grant-AtlasSetupAccountAccess }
        $applied = Get-ItemProperty 'HKLM:\SOFTWARE\AME\Playbooks\Applied\{00000000-0000-4000-6174-6C6173203A33}' -ErrorAction SilentlyContinue
        if (Test-AtlasOOBEApplied $applied $created) {
            $user = @(Get-CimInstance Win32_UserAccount -Filter ("LocalAccount=True AND Name='{0}'" -f $conf.username))
            if ($user.Count -eq 1 -and -not $user[0].Disabled) { break }
            # AME can publish its playbook result before finishing user creation.
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Atlas completed, but AME did not create the configured Windows user.' }
            Start-Sleep -Seconds 5
            continue
        }
        if ($null -ne $applied -and $null -ne $applied.PSObject.Properties['ErrorLevel'] -and [int]$applied.ErrorLevel -ne 0) {
            throw 'AME OOBE recorded playbook errors. Inspect the AME logs in Windows.'
        }
        $service = Get-CimInstance Win32_Service -Filter "Name='ameoobe'"
        $consoleUser = [string](Get-CimInstance Win32_ComputerSystem).UserName
        $failure = Get-AtlasHandoffFailure $service $consoleUser
        if ($failure) { $handoffFailures++ } else { $handoffFailures = 0 }
        # Allow startup transitions, but do not display 'applying' for 110 minutes.
        if ($handoffFailures -ge 12) { throw $failure }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'AME OOBE did not record successful completion. Inspect the Windows setup console.' }
        Start-Sleep -Seconds 5
    } while ($true)
    # Disable setup autologon only after the original AME result is verified.
    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -Value '0'
    Restore-AtlasPreparation (Join-Path $root 'security-backup.json')
    Start-Service -Name WinBoatGuestServer
    # The playbook result is authoritative; copying files never marks Atlas as finished.
    Publish-AtlasOOBE 'finished' 'AME OOBE completed Atlas successfully. Helios setup follows if selected.'
    if ($mode.waitForHelios -and -not (Test-Path -LiteralPath (Join-Path $root 'helios-started'))) {
        $install = Join-Path $env:ProgramFiles 'WinBoat'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}\scripts\Start-HeliosProvisioning.ps1" -BundlePath "{0}\helios"' -f $install
        # Helios owns its own persistent resume task and bounded restarts.
        $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -PassThru
        Set-Content -LiteralPath (Join-Path $root 'helios-started') -Value $process.Id
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
} catch {
    $failureMessage = $_.Exception.Message
    # Undo our temporary security preparation on failure as well; retain logs/media.
    try { Restore-AtlasPreparation (Join-Path $root 'security-backup.json') } catch { Write-Warning $_ }
    Publish-AtlasOOBE 'failed' $failureMessage
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Error $_
    exit 1
}

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

function Get-AtlasHandoffFailure($Service, [string]$ConsoleUser, [bool]$ClientActive = $false) {
    if ($null -ne $Service -and $Service.State -eq 'Stopped' -and [int]$Service.ExitCode -ne 0 -and -not $ClientActive) {
        return ('AME OOBE service stopped with code {0}. Atlas is not complete; collect diagnostics before recovery.' -f $Service.ExitCode)
    }
    if (-not $ConsoleUser) {
        $key = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        if ($null -ne $key.PSObject.Properties['DefaultUserName'] -and $null -ne $key.PSObject.Properties['AutoAdminLogon'] -and
            $key.DefaultUserName -ieq 'defaultuser0' -and [string]$key.AutoAdminLogon -eq '0') {
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

function Get-AtlasRuntimeSddl([string]$Sid, [bool]$Directory, [bool]$PublicRead, [bool]$Secret) {
    if ($Sid -and $Sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'Unexpected Windows setup account SID.' }
    $flags = if ($Directory) { 'OICI' } else { '' }
    $sddl = "O:SYG:SYD:P(A;$flags;FA;;;SY)(A;$flags;FA;;;BA)"
    if ($Sid) { $sddl += "(A;$flags;0x1200a9;;;$Sid)" }
    elseif ($PublicRead -and -not $Secret) { $sddl += "(A;$flags;0x1200a9;;;BU)" }
    return $sddl
}

function Set-AtlasTreeAccess([string]$Folder, [string]$Sid, [bool]$PublicRead) {
    $items = @(Get-Item -LiteralPath $Folder -Force)
    # Inspect before changing any ACL, and never follow junctions/symlinks.
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i].Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'AME runtime contains a reparse point.' }
        if ($items[$i].PSIsContainer) { $items += @(Get-ChildItem -LiteralPath $items[$i].FullName -Force) }
    }
    # Protect the password first, before making binaries readable for startup.
    foreach ($item in ($items | Sort-Object @{Expression={if ($_.Name -ieq 'oobe.conf') {0} else {1}}})) {
        $sddl = Get-AtlasRuntimeSddl $Sid $item.PSIsContainer $PublicRead ($item.Name -ieq 'oobe.conf')
        $acl = Get-Acl -LiteralPath $item.FullName
        # Replace the complete DACL: /grant:r alone leaves other explicit ACEs.
        $acl.SetSecurityDescriptorSddlForm($sddl)
        Set-Acl -LiteralPath $item.FullName -AclObject $acl
    }
}

function Set-AtlasRuntimeAccess([string]$Sid = '') {
    Set-AtlasTreeAccess (Join-Path $env:ProgramData 'AME\OOBE') $Sid (-not $Sid)
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
    Set-AtlasRuntimeAccess $sid
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
        Set-AtlasTreeAccess $root '' $false
        if (-not (Grant-AtlasSetupAccountAccess)) { Set-AtlasRuntimeAccess }
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
        $clientActive = @(Get-Process -Name 'AME.Client' -ErrorAction SilentlyContinue | Where-Object {$_.SessionId -gt 0}).Count -gt 0
        $failure = Get-AtlasHandoffFailure $service $consoleUser $clientActive
        if ($clientActive -and $null -ne $service -and $service.State -eq 'Stopped') {
            Publish-AtlasOOBE 'waiting' 'AME client is running but its OOBE service stopped. Inspect the Windows console and crash diagnostics; Atlas completion is not confirmed.'
        }
        if ($failure) { $handoffFailures++ } else { $handoffFailures = 0 }
        # Allow startup transitions, but do not display 'applying' for 110 minutes.
        if ($handoffFailures -ge 12) { throw $failure }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'AME OOBE did not record successful completion. Inspect the Windows setup console.' }
        if ($setupAccessGranted -or $failure) { Start-Sleep -Seconds 5 } else { Start-Sleep -Milliseconds 200 }
    } while ($true)
    # Disable setup autologon only after the original AME result is verified.
    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -Value '0'
    Restore-AtlasPreparation (Join-Path $root 'security-backup.json')
    Start-Service -Name WinBoatGuestServer
    if ($mode.waitForHelios) {
        $install = Join-Path $env:ProgramFiles 'WinBoat'
        # Registration must finish before this observer exits. The durable task
        # waits for Atlas' reboot and ignores obsolete helios-started PID files.
        $handoff = & (Join-Path $install 'scripts\Start-AtlasHelios.ps1') -Register | ConvertFrom-Json
        if ($handoff.status -ne 'queued') {throw 'Cannot register the post-Atlas Helios handoff; inspect helios-handoff.json.'}
    }
    # Confirm the durable handoff before the host advances to its Helios monitor.
    Publish-AtlasOOBE 'finished' 'AME OOBE completed Atlas successfully. Helios setup follows if selected.'
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

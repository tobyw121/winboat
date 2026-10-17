# Fixed recovery for the verified defaultuser0/AME handoff failure only.
param([switch]$RunSysprep, [switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Test-AtlasRecoveryState($State) {
    $d = $State.diagnostics
    if ($State.mode -ne 'ame-oobe' -or $State.release -ne '0.5.0-hotfix') { return 'Not a supported AME ISO installation.' }
    if ($State.applied -or $State.configuredUserExists) { return 'Windows account or applied playbook already exists; automatic OOBE recovery refused.' }
    if ($d.errors.Count -or -not $d.shim.originalAME -or -not $d.shim.microsoftBackupExists) { return 'AME payload or diagnostic verification failed.' }
    if ($d.files.Count -ne 4 -or @($d.files | Where-Object { -not $_.exists }).Count) { return 'Required AME payload files are missing.' }
    if ($d.logon.shell -ne 'ame-oobe' -or -not $d.logon.defaultIsSetupAccount -or
        -not $d.setupAccount.exists -or $d.setupAccount.disabled) { return 'Not the expected temporary setup-account handoff.' }
    if (-not $d.logon.setupCredentialPresent) { return 'Windows setup logon credential is missing. Automatic recovery cannot recreate it; use a fresh installation with the corrected setup logic.' }
    if ($d.windowsSetup.OOBEInProgress -ne 0 -or $d.windowsSetup.SystemSetupInProgress -ne 0 -or $d.windowsSetup.SetupType -ne 0) { return 'Windows setup is still active; automatic recovery refused.' }
    if ($d.service.Count -ne 1 -or $d.service[0].State -ne 'Stopped' -or
        @($d.processes | Where-Object { $_.ProcessName -ne 'LogonUI' }).Count) { return 'AME or Windows setup processes are still active; wait for their exit.' }
    return $null
}
function Restore-AtlasSetupAutologon {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $key = Get-ItemProperty $path
    if ($key.DefaultUserName -ine 'defaultuser0') { throw 'Setup autologon belongs to another user.' }
    # Reuse the setup secret only if Windows still has it. Never guess/reset it
    # or substitute the configured final user's password for defaultuser0.
    if ($null -eq $key.PSObject.Properties['DefaultPassword'] -or [string]::IsNullOrEmpty([string]$key.DefaultPassword)) {
        throw 'Windows setup autologon credential is missing. Use a fresh installation with the corrected setup logic.'
    }
    Set-ItemProperty $path -Name AutoAdminLogon -Value '1'
}
if ($LibraryOnly) { return }
$root = Join-Path $env:ProgramData 'WinBoat\Atlas'
$status = Join-Path $root 'recovery.json'
$taskName = 'WinBoatAtlasRecovery'
function Publish-Recovery([string]$State, [string]$Message, [Nullable[int]]$ExitCode = $null) {
    $data = @{status=$State; message=$Message; updatedAtUtc=[DateTime]::UtcNow.ToString('o')}
    if ($null -ne $ExitCode) {
        $data.exitCode = $ExitCode
        $errorLog = Join-Path $env:SystemRoot 'System32\Sysprep\Panther\setuperr.log'
        $codes = @()
        if (Test-Path -LiteralPath $errorLog -PathType Leaf) {
            $codes = @((Get-Content -LiteralPath $errorLog -Tail 40 | ForEach-Object {
                foreach ($match in [regex]::Matches($_, '\b0x[0-9a-fA-F]{8}\b')) { $match.Value }
            }) | Select-Object -Unique)
        }
        $data.failureCodes = $codes
    }
    $data | ConvertTo-Json | Set-Content -LiteralPath "$status.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$status.tmp" -Destination $status -Force
    return $data
}
try {
    if ($RunSysprep) {
        $pending = Get-Content -LiteralPath $status -Raw | ConvertFrom-Json
        if ($pending.status -ne 'queued') { throw 'No queued recovery attempt.' }
        # Run independently of the HTTP request and allow its response to arrive.
        Start-Sleep -Seconds 15
        Publish-Recovery 'restarting-oobe' 'Windows Sysprep is restarting OOBE. No passwords were reset.' | Out-Null
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\Sysprep\Sysprep.exe') -ArgumentList '/oobe /reboot /quiet' -PassThru -Wait
        if ($process.ExitCode -ne 0) {
            Publish-Recovery 'failed' 'Windows Sysprep refused to restart OOBE. Check its exit code and filtered failure codes.' $process.ExitCode | ConvertTo-Json -Compress
            exit 1
        }
        exit 0
    }
    if (Test-Path -LiteralPath $status) {
        $previous = Get-Content -LiteralPath $status -Raw | ConvertFrom-Json
        if ($previous.status -in @('queued','restarting-oobe')) {
            # Preserve the queued worker's state on a repeated HTTP request.
            @{status='blocked'; message='A recovery attempt is already pending.'} | ConvertTo-Json -Compress
            exit 0
        }
    }
    $mode = Get-Content -LiteralPath (Join-Path $root 'oobe-mode.json') -Raw | ConvertFrom-Json
    $conf = Get-Content -LiteralPath (Join-Path $env:ProgramData 'WinBoat\AtlasMedia\atlas.json') -Raw | ConvertFrom-Json
    if ($conf.username -notmatch '^[a-zA-Z0-9]{2,}$') { throw 'Invalid setup configuration.' }
    $diagnostics = & (Join-Path $PSScriptRoot 'Get-AtlasDiagnostics.ps1') | ConvertFrom-Json
    $applied = Get-ItemProperty 'HKLM:\SOFTWARE\AME\Playbooks\Applied\{00000000-0000-4000-6174-6C6173203A33}' -ErrorAction SilentlyContinue
    $users = @(Get-CimInstance Win32_UserAccount -Filter ("LocalAccount=True AND Name='{0}'" -f $conf.username))
    $reason = Test-AtlasRecoveryState ([pscustomobject]@{mode=$mode.mode; release=$mode.release;
        diagnostics=$diagnostics; applied=($null -ne $applied); configuredUserExists=($users.Count -ne 0)})
    if ($reason) { @{status='blocked'; message=$reason} | ConvertTo-Json -Compress; exit 0 }
    Restore-AtlasSetupAutologon
    $ameRoot = Join-Path $env:ProgramData 'AME\OOBE'
    $backup = Join-Path $root 'pre-recovery-ame-acl.json'
    if (-not (Test-Path -LiteralPath $backup)) {
        @{sddl=(Get-Acl -LiteralPath $ameRoot).Sddl; createdAtUtc=[DateTime]::UtcNow.ToString('o')} |
            ConvertTo-Json | Set-Content -LiteralPath $backup -Encoding UTF8
    }
    # Refresh the persistent observer as well as the original install's ACL.
    Stop-ScheduledTask -TaskName 'WinBoatAtlasOOBE' -ErrorAction SilentlyContinue
    $registered = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Register' -f (Join-Path $PSScriptRoot 'Start-AtlasOOBE.ps1')) -Wait -PassThru
    if ($registered.ExitCode -ne 0) { throw 'Cannot refresh the AME observer and permissions.' }
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RunSysprep' -f $PSCommandPath)
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    # Demand-only: a failed or interrupted attempt must never retry on its own.
    Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -User SYSTEM -RunLevel Highest -Force | Out-Null
    $result = Publish-Recovery 'queued' 'AME access repaired. Windows will restart OOBE through Sysprep; no account passwords were changed.'
    Start-ScheduledTask -TaskName $taskName
    $result | ConvertTo-Json -Compress
} catch {
    Publish-Recovery 'failed' 'AME OOBE recovery could not complete. Inspect Windows Sysprep and WinBoat recovery logs; no passwords were reset.' | ConvertTo-Json -Compress
}

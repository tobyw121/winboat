# Launch only the pinned AME client into an existing defaultuser0 console session.
param([switch]$RestartStalled, [switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Test-AtlasUILaunchState($State, [bool]$RestartStalled = $false) {
    if ($State.mode -ne 'ame-oobe' -or $State.release -ne '0.5.0-hotfix' -or $State.applied) { return 'Not an incomplete supported AME ISO setup.' }
    $d = $State.diagnostics
    $criticalErrors = @($d.errors | Where-Object {$_ -notin @('WinBoat Atlas observer status unavailable','Observer script version unavailable')})
    if ($criticalErrors.Count -or -not $d.shim.originalAME -or $d.files.Count -ne 4 -or
        @($d.files | Where-Object {-not $_.exists}).Count) { return 'AME diagnostic or payload verification failed.' }
    if ($d.logon.shell -ne 'ame-oobe' -or -not $d.setupAccount.exists -or $d.setupAccount.disabled) { return 'The temporary setup-account handoff is missing.' }
    if (@($d.processes | Where-Object { ($_.ProcessName -eq 'AME.Client' -and -not $RestartStalled) -or $_.ProcessName -in @('msoobe','msoobeext','CloudExperienceHost','UserOOBEBroker') }).Count) { return 'AME UI or Windows setup is already active.' }
    if ($RestartStalled -and ($d.handoffPhase -ne 'handshake-ended-without-window' -or
        $d.logon.consoleAccount -ne 'setup-account' -or $d.service.Count -ne 1 -or
        $d.service[0].State -ne 'Stopped' -or $d.service[0].ExitCode -ne 1067 -or
        @($d.processes | Where-Object {$_.ProcessName -eq 'AME.Client'}).Count -ne 1)) {
        return 'Not a verified ended UI handshake with one leftover setup client.'
    }
    return $null
}
function Import-AtlasSessionLauncher {
    if (-not ('WinBoat.AtlasSessionLauncher' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'AtlasSessionLauncher.cs')
    }
}
function Invoke-AtlasSessionLaunch([string]$Executable, [string]$SID) {
    Import-AtlasSessionLauncher
    [WinBoat.AtlasSessionLauncher]::ValidateSession($SID)
    # Restart only the AME service so its four-minute GUI handshake starts anew.
    Restart-Service -Name ameoobe -ErrorAction Stop
    (Get-Service -Name ameoobe).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
    return [WinBoat.AtlasSessionLauncher]::Start($Executable, $SID)
}
if ($LibraryOnly) { return }
try {
    $root = Join-Path $env:ProgramData 'AME\OOBE'
    $mode = Get-Content -LiteralPath (Join-Path $env:ProgramData 'WinBoat\Atlas\oobe-mode.json') -Raw | ConvertFrom-Json
    $d = & (Join-Path $PSScriptRoot 'Get-AtlasDiagnostics.ps1') | ConvertFrom-Json
    $applied = Get-ItemProperty 'HKLM:\SOFTWARE\AME\Playbooks\Applied\{00000000-0000-4000-6174-6C6173203A33}' -ErrorAction SilentlyContinue
    $reason = Test-AtlasUILaunchState ([pscustomobject]@{mode=$mode.mode; release=$mode.release; applied=($null -ne $applied); diagnostics=$d}) $RestartStalled
    if ($reason) { @{status='blocked'; message=$reason} | ConvertTo-Json -Compress; exit 0 }
    $executable = Join-Path $root 'AME.Client.exe'
    if ((Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash -ine '7985a9d5fb1e40cf8840f35e5ecee6332f31d9279b30dfa06ef8d2435b417af6') { throw 'AME client verification failed.' }
    $restartRequested = $RestartStalled
    . (Join-Path $PSScriptRoot 'Start-AtlasOOBE.ps1') -LibraryOnly
    if (-not (Grant-AtlasSetupAccountAccess)) { throw 'Setup account is unavailable.' }
    $account = @(Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True AND Name='defaultuser0'")
    if ($account.Count -ne 1) { throw 'Setup account is unavailable.' }
    if ($restartRequested) {
        Import-AtlasSessionLauncher
        $client = @($d.processes | Where-Object {$_.ProcessName -eq 'AME.Client'})[0]
        [WinBoat.AtlasSessionLauncher]::ValidateStalled([uint32]$client.Id, $executable, [string]$account[0].SID)
        $attempt = Join-Path $env:ProgramData 'WinBoat\Atlas\ui-restart-attempt.json'
        if (Test-Path -LiteralPath $attempt) { @{status='blocked'; message='A stalled-UI restart was already attempted. Review diagnostics before another attempt.'} | ConvertTo-Json -Compress; exit 0 }
        # Atomic, persistent one-attempt guard. A failed attempt requires review.
        $marker = [IO.File]::Open($attempt, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes('{"operation":"restart-ame-ui"}')
            $marker.Write($bytes,0,$bytes.Length)
        } finally { $marker.Dispose() }
        [WinBoat.AtlasSessionLauncher]::StopStalled([uint32]$client.Id, $executable, [string]$account[0].SID)
        if (@(Get-Process -Name 'AME.Client' -ErrorAction SilentlyContinue).Count) { throw 'Another AME client appeared; refusing a duplicate.' }
    }
    $launch = Invoke-AtlasSessionLaunch $executable ([string]$account[0].SID)
    if ($null -ne $launch.EarlyExitCode) {
        @{status='failed'; message='The original AME client exited during startup.'; exitCode=$launch.EarlyExitCode} | ConvertTo-Json -Compress
    } else {
        if ($restartRequested) {
            # Install the current bounded observer instead of resurrecting its old failed copy.
            Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Register' -f (Join-Path $PSScriptRoot 'Start-AtlasOOBE.ps1')) | Out-Null
        }
        @{status='launched'; message='The original AME client was started in the existing setup-user session. Check the console; Atlas completion remains unconfirmed.';
            processId=$launch.ProcessId; sessionId=$launch.SessionId} | ConvertTo-Json -Compress
    }
} catch {
    $exception = $_.Exception
    while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
    $code = if ($exception -is [ComponentModel.Win32Exception]) { $exception.NativeErrorCode } else { $exception.HResult }
    @{status='blocked'; message='Cannot launch AME in an existing setup-user session. No logon, password reset or Windows restart was performed.'; errorCode=$code} | ConvertTo-Json -Compress
}

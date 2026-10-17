# Launch only the pinned AME client into an existing defaultuser0 console session.
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Test-AtlasUILaunchState($State) {
    if ($State.mode -ne 'ame-oobe' -or $State.release -ne '0.5.0-hotfix' -or $State.applied) { return 'Not an incomplete supported AME ISO setup.' }
    $d = $State.diagnostics
    if ($d.errors.Count -or -not $d.shim.originalAME -or $d.files.Count -ne 4 -or
        @($d.files | Where-Object {-not $_.exists}).Count) { return 'AME diagnostic or payload verification failed.' }
    if ($d.logon.shell -ne 'ame-oobe' -or -not $d.setupAccount.exists -or $d.setupAccount.disabled) { return 'The temporary setup-account handoff is missing.' }
    if (@($d.processes | Where-Object { $_.ProcessName -eq 'AME.Client' -or $_.ProcessName -in @('msoobe','msoobeext','CloudExperienceHost','UserOOBEBroker') }).Count) { return 'AME UI or Windows setup is already active.' }
    return $null
}
function Invoke-AtlasSessionLaunch([string]$Executable, [string]$SID) {
    Add-Type -Path (Join-Path $PSScriptRoot 'AtlasSessionLauncher.cs')
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
    $reason = Test-AtlasUILaunchState ([pscustomobject]@{mode=$mode.mode; release=$mode.release; applied=($null -ne $applied); diagnostics=$d})
    if ($reason) { @{status='blocked'; message=$reason} | ConvertTo-Json -Compress; exit 0 }
    $executable = Join-Path $root 'AME.Client.exe'
    if ((Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash -ine '7985a9d5fb1e40cf8840f35e5ecee6332f31d9279b30dfa06ef8d2435b417af6') { throw 'AME client verification failed.' }
    . (Join-Path $PSScriptRoot 'Start-AtlasOOBE.ps1') -LibraryOnly
    if (-not (Grant-AtlasSetupAccountAccess)) { throw 'Setup account is unavailable.' }
    $account = @(Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True AND Name='defaultuser0'")
    if ($account.Count -ne 1) { throw 'Setup account is unavailable.' }
    $launch = Invoke-AtlasSessionLaunch $executable ([string]$account[0].SID)
    if ($null -ne $launch.EarlyExitCode) {
        @{status='failed'; message='The original AME client exited during startup.'; exitCode=$launch.EarlyExitCode} | ConvertTo-Json -Compress
    } else {
        @{status='launched'; message='The original AME client was started in the existing setup-user session. Check the Windows console.';
            processId=$launch.ProcessId; sessionId=$launch.SessionId} | ConvertTo-Json -Compress
    }
} catch {
    $exception = $_.Exception
    while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
    $code = if ($exception -is [ComponentModel.Win32Exception]) { $exception.NativeErrorCode } else { $exception.HResult }
    @{status='blocked'; message='Cannot launch AME in an existing setup-user session. No logon, password reset or Windows restart was performed.'; errorCode=$code} | ConvertTo-Json -Compress
}

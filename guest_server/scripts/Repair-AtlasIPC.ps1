# Align the service with the original shim's client path; keep IPC authentication.
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ipcLibraryOnly=$LibraryOnly
. (Join-Path $PSScriptRoot 'Start-AtlasOOBEClient.ps1') -LibraryOnly
function Test-AtlasIPCRepairState($State) {
    $reason=Test-AtlasUILaunchState $State $true
    if ($reason) {return $reason}
    if ($State.diagnostics.serviceExecutable -ne 'legacy-oobe' -or
        $State.diagnostics.guiStartupPhase -ne 'ipc-initialized') {
        return 'Not the verified legacy service/client IPC path mismatch.'
    }
    return $null
}
function Set-AtlasCanonicalService($Service, [string]$Executable) {
    if ($Service.Name -ne 'ameoobe' -or $Service.State -ne 'Stopped' -or $Service.StartName -ne 'LocalSystem') {
        throw 'The original AME service is not stopped under LocalSystem.'
    }
    $changed=Invoke-CimMethod -InputObject $Service -MethodName Change -Arguments @{PathName=('"{0}" --service' -f $Executable)}
    if ($changed.ReturnValue -ne 0) {throw 'Windows refused the AME service configuration change.'}
}
if ($ipcLibraryOnly) {return}
$stage='preflight'; $pathChanged=$false; $clientStopped=$false
try {
    $root=Join-Path $env:ProgramData 'WinBoat\Atlas'
    $mode=Get-Content -LiteralPath (Join-Path $root 'oobe-mode.json') -Raw | ConvertFrom-Json
    $d=& (Join-Path $PSScriptRoot 'Get-AtlasDiagnostics.ps1') | ConvertFrom-Json
    $applied=Get-ItemProperty 'HKLM:\SOFTWARE\AME\Playbooks\Applied\{00000000-0000-4000-6174-6C6173203A33}' -ErrorAction SilentlyContinue
    $reason=Test-AtlasIPCRepairState ([pscustomobject]@{mode=$mode.mode;release=$mode.release;applied=($null -ne $applied);diagnostics=$d})
    if ($reason) {@{status='blocked';message=$reason} | ConvertTo-Json -Compress; exit 0}
    $executable=Join-Path $env:ProgramData 'AME\OOBE\AME.Client.exe'
    if ((Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash -ine '7985a9d5fb1e40cf8840f35e5ecee6332f31d9279b30dfa06ef8d2435b417af6') {throw 'Original AME client verification failed.'}
    . (Join-Path $PSScriptRoot 'Start-AtlasOOBE.ps1') -LibraryOnly
    if (-not (Grant-AtlasSetupAccountAccess)) {throw 'Setup account unavailable.'}
    . (Join-Path $PSScriptRoot 'Get-AtlasDiagnostics.ps1') -LibraryOnly
    $account=@(Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True AND Name='defaultuser0'")
    if ($account.Count -ne 1) {throw 'Setup account unavailable.'}
    $sid=[string]$account[0].SID
    $client=@($d.processes | Where-Object {$_.ProcessName -eq 'AME.Client' -and $_.SessionId -gt 0})[0]
    Import-AtlasSessionLauncher
    $stage='validate-stalled-client'
    [WinBoat.AtlasSessionLauncher]::ValidateStalled([uint32]$client.Id,$executable,$sid)
    $service=Get-CimInstance Win32_Service -Filter "Name='ameoobe'"
    if ((Get-AtlasServiceExecutable $service.PathName (Split-Path -Parent $executable)) -ne 'legacy-oobe') {throw 'Service configuration changed during verification.'}
    $marker=Join-Path $root 'ipc-path-repair.json'
    if (Test-Path -LiteralPath $marker) {@{status='blocked';message='IPC path repair was already attempted; inspect diagnostics.'} | ConvertTo-Json -Compress; exit 0}
    $file=[IO.File]::Open($marker,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes('{"operation":"repair-ame-ipc","previousServiceExecutable":"legacy-oobe"}')
        $file.Write($bytes,0,$bytes.Length)
    } finally {$file.Dispose()}
    $stage='change-service-path'
    Set-AtlasCanonicalService $service $executable
    $pathChanged=$true
    $verified=Get-CimInstance Win32_Service -Filter "Name='ameoobe'"
    if ((Get-AtlasServiceExecutable $verified.PathName (Split-Path -Parent $executable)) -ne 'shared-client') {throw 'Service path verification failed.'}
    $stage='stop-stalled-client'
    [WinBoat.AtlasSessionLauncher]::StopStalled([uint32]$client.Id,$executable,$sid)
    $clientStopped=$true
    if (@(Get-Process -Name 'AME.Client' -ErrorAction SilentlyContinue | Where-Object {$_.SessionId -gt 0}).Count) {throw 'Another AME UI appeared.'}
    # A running task retains its old parsed script after files are updated.
    Stop-ScheduledTask -TaskName 'WinBoatAtlasOOBE' -ErrorAction SilentlyContinue
    $stage='start-service-and-client'
    $launch=Invoke-AtlasSessionLaunch $executable $sid
    if ($null -ne $launch.EarlyExitCode) {throw 'Original AME client exited during startup.'}
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Register' -f (Join-Path $PSScriptRoot 'Start-AtlasOOBE.ps1')) | Out-Null
    @{status='launched';message='AME service and UI now use the same verified executable path. Check the console; Atlas completion remains unconfirmed.';processId=$launch.ProcessId;sessionId=$launch.SessionId} | ConvertTo-Json -Compress
} catch {
    $exception=$_.Exception
    while ($null -ne $exception.InnerException) {$exception=$exception.InnerException}
    $code=if ($exception -is [ComponentModel.Win32Exception]) {$exception.NativeErrorCode} else {$exception.HResult}
    @{status='failed';message='AME IPC path repair did not complete. Windows was not restarted and no passwords were changed.';stage=$stage;errorCode=$code;servicePathChanged=$pathChanged;clientStopped=$clientStopped} | ConvertTo-Json -Compress
}

# Fixed read-only diagnostics. Never return credentials, command lines or raw logs.
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Select-AtlasStartupLines([string[]]$Lines) {
    foreach ($line in $Lines) {
        # Return only AME's fixed startup messages, numeric WNF states and timestamps.
        if ($line -match '(?<phase>(?:\d{2}:\d{2}:\d{2}\.\d{4}: )?(?:Worker Start|WNF Wait(?:ed)?|Window Launched|WNF Published \d+|Monitor [123]: \d+|LogonComplete [123]: \d+))["'']?\s*$') {
            $Matches.phase
        }
    }
}
function Get-AtlasShellKind([string]$Shell, [string]$Client) {
    # The pinned shim embeds repeated separators; Windows accepts those paths.
    if (($Shell -replace '\\{2,}', '\') -eq ('"{0}" --oobe' -f ($Client -replace '\\{2,}', '\'))) { return 'ame-oobe' }
    if ($Shell -ieq 'explorer.exe') { return 'windows-explorer' }
    if ([string]::IsNullOrWhiteSpace($Shell)) { return 'missing' }
    return 'other'
}
function Select-AtlasFailureKinds([string[]]$Lines) {
    # Never return exception messages: they may include command-line credentials.
    @($Lines | ForEach-Object {
        foreach ($match in [regex]::Matches($_, '\b(?:System|Microsoft|WinRT)\.[A-Za-z0-9_.]+Exception\b|\b0x[0-9a-fA-F]{8}\b')) {
            $match.Value
        }
    } | Select-Object -Unique)
}
if ($LibraryOnly) { return }
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$result = [ordered]@{ collectedAtUtc = [DateTime]::UtcNow.ToString('o'); errors = @() }
$root = Join-Path $env:ProgramData 'AME'
try {
    $result.service = @(Get-CimInstance Win32_Service -Filter "Name='ameoobe'" |
        Select-Object Name, State, StartMode, ProcessId, ExitCode, ServiceSpecificExitCode)
} catch { $result.errors += 'AME service status unavailable' }
$result.processes = @(Get-Process -Name 'OOBE','AME.Client','msoobe','msoobeext','CloudExperienceHost','UserOOBEBroker','LogonUI' -ErrorAction SilentlyContinue |
    Select-Object ProcessName, Id, SessionId, Responding)
$result.files = @(foreach ($name in @('AME.Client.exe','OOBE.exe','oobe.conf','Playbook\playbook.conf')) {
    $file = Join-Path (Join-Path $root 'OOBE') $name
    [ordered]@{ name = $name; exists = (Test-Path -LiteralPath $file -PathType Leaf) }
})
try {
    $shim = Join-Path $env:SystemRoot 'System32\oobe\msoobe.exe'
    $result.shim = [ordered]@{
        originalAME = ((Get-FileHash -LiteralPath $shim -Algorithm SHA256).Hash -ieq 'c2b4f73bc9615e2981b9c60bb51974ed67539873dbd3d29b97258e21fa3ada7d')
        microsoftBackupExists = (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\oobe\msoobeext.exe') -PathType Leaf)
    }
} catch { $result.errors += 'AME OOBE shim state unavailable' }
try {
    $task = Get-ScheduledTask -TaskName 'WinBoatAtlasOOBE'
    $info = $task | Get-ScheduledTaskInfo
    $result.observer = [ordered]@{ state = $task.State.ToString(); lastResult = $info.LastTaskResult }
} catch { $result.errors += 'WinBoat Atlas observer status unavailable' }
try {
    $lines = @(Get-Content -LiteralPath (Join-Path $root 'Logs\Log.yml') -Tail 400)
    $result.startup = @(Select-AtlasStartupLines $lines)
    $result.failureKinds = @(Select-AtlasFailureKinds $lines)
} catch { $result.errors += 'AME startup log unavailable' }
try {
    $key = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $shell = if ($null -ne $key.PSObject.Properties['Shell']) { [string]$key.Shell } else { '' }
    $result.logon = [ordered]@{ shell = (Get-AtlasShellKind $shell (Join-Path $root 'OOBE\AME.Client.exe')) }
    $result.logon.setupCredentialPresent = ($null -ne $key.PSObject.Properties['DefaultPassword'] -and -not [string]::IsNullOrEmpty([string]$key.DefaultPassword))
    foreach ($name in @('AutoAdminLogon','AutoLogonCount','ForceAutoLogon')) {
        if ($null -ne $key.PSObject.Properties[$name] -and [string]$key.$name -match '^\d{1,5}$') {
            $result.logon[$name] = [int]$key.$name
        }
    }
    if ($null -ne $key.PSObject.Properties['DefaultUserName']) {
        $result.logon.defaultIsSetupAccount = ([string]$key.DefaultUserName -ieq 'defaultuser0')
    }
} catch { $result.errors += 'Windows shell handoff state unavailable' }
try {
    $consoleUser = [string](Get-CimInstance Win32_ComputerSystem).UserName
    $result.logon.consoleAccount = if (-not $consoleUser) { 'none' } elseif ($consoleUser -match '(?i)(^|\\)defaultuser0$') { 'setup-account' } else { 'other' }
} catch { $result.errors += 'Windows console logon state unavailable' }
try {
    $account = @(Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True AND Name='defaultuser0'")
    $result.setupAccount = [ordered]@{ exists = ($account.Count -eq 1) }
    if ($account.Count -eq 1) { $result.setupAccount.disabled = [bool]$account[0].Disabled }
    $result.amePermissions = @(foreach ($name in @('', 'AME.Client.exe', 'oobe.conf')) {
        $path = Join-Path (Join-Path $root 'OOBE') $name
        $acl = Get-Acl -LiteralPath $path
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object {
            # Return built-in access categories rather than names or machine SIDs.
            $sid = $_.IdentityReference.Value
            $principal = switch ($sid) {
                'S-1-5-18' { 'system' }
                'S-1-5-32-544' { 'administrators' }
                'S-1-5-32-545' { 'users' }
                'S-1-5-11' { 'authenticated-users' }
                'S-1-1-0' { 'everyone' }
                default { if ($account.Count -eq 1 -and $sid -eq $account[0].SID) { 'setup-account' } else { 'other' } }
            }
            [ordered]@{ principal = $principal; rights = [int]$_.FileSystemRights;
                type = $_.AccessControlType.ToString(); inherited = $_.IsInherited }
        })
        [ordered]@{ file = $(if ($name) { $name } else { 'OOBE-directory' }); protected = $acl.AreAccessRulesProtected; rules = $rules }
    })
} catch { $result.errors += 'AME setup-account permissions unavailable' }
try {
    $key = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
    $result.windowsSetup = [ordered]@{}
    foreach ($name in @('OOBEInProgress','SystemSetupInProgress','SetupType')) {
        if ($null -ne $key.PSObject.Properties[$name]) { $result.windowsSetup[$name] = [int]$key.$name }
    }
} catch { $result.errors += 'Windows setup state unavailable' }
$result | ConvertTo-Json -Depth 6 -Compress

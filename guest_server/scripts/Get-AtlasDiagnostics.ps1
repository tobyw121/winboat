# Fixed read-only diagnostics. Never return credentials, command lines or raw logs.
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Select-AtlasStartupLines([string[]]$Lines) {
    foreach ($line in $Lines) {
        # Return only AME's fixed startup messages, numeric WNF states and timestamps.
        if ($line -match '(?<phase>(?:\d{2}:\d{2}:\d{2}\.\d{4}: )?(?:Worker Start|WNF Wait(?:ed)?|Window Launched|WNF Published \d+|Monitor [123]: \d+|LogonComplete [123]: \d+))["'']?\s*$') {
            $Matches.phase
        } elseif ($line -match '(?<phase>(?:\d{2}:\d{2}:\d{2}\.\d{4}:?\s*)?(?:Window Loaded|Window Thread Started|Window InterLink Initialized|Window Registered|Window Signaled|Waiting Anim|Window Relaunching|Window Relaunched|Service event wait timed out\.|Service event could not be opened\.))["'']?\s*$') {
            # Original 0.8.4 GUI messages omit the colon/space after the time.
            # These are fixed literals; never return the surrounding YAML/log text.
            $Matches.phase
        }
    }
}
function Get-AtlasGUIStartupPhase([string[]]$Lines) {
    $phase='not-reported'
    $stages=[ordered]@{'Worker Start'='not-reported';'Window Loaded'='window-loaded';
        'Window Thread Started'='window-worker-started';'Window InterLink Initialized'='ipc-initialized';
        'Window Registered'='ipc-registered';'Window Signaled'='service-signaled';
        'Waiting Anim'='waiting-for-first-logon-animation';'Window Relaunching'='relaunching-after-drivers';
        'Window Relaunched'='relaunched-after-drivers';'Service event wait timed out.'='service-event-timeout';
        'Service event could not be opened.'='service-event-unavailable'}
    foreach ($line in (Select-AtlasStartupLines $Lines)) {
        $message=$line -replace '^\d{2}:\d{2}:\d{2}\.\d{4}:?\s*',''
        if ($stages.Contains($message)) { $phase=$stages[$message] }
    }
    return $phase
}
function Get-AtlasHandoffPhase([string[]]$Lines) {
    $phase='unknown'
    foreach ($line in $Lines) {
        if ($line -match 'Worker Start["'']?\s*$') { $phase='waiting-for-ui' }
        elseif ($line -match '(?:WNF Waited|\d{2}:\d{2}:\d{2}\.\d{4}: L)["'']?\s*$') { $phase='handshake-ended-without-window' }
        elseif ($line -match '(?:Window Launched|WNF Published 104)["'']?\s*$') { $phase='window-launched' }
    }
    return $phase
}
function Get-AtlasShellKind([string]$Shell, [string]$Client) {
    # The pinned shim embeds repeated separators; Windows accepts those paths.
    if (($Shell -replace '[\\/]+', '\') -eq ('"{0}" --oobe' -f ($Client -replace '[\\/]+', '\'))) { return 'ame-oobe' }
    if ($Shell -ieq 'explorer.exe') { return 'windows-explorer' }
    if ([string]::IsNullOrWhiteSpace($Shell)) { return 'missing' }
    return 'other'
}
function Get-AtlasServiceExecutable([string]$Command, [string]$Folder) {
    $expanded=[Environment]::ExpandEnvironmentVariables($Command)
    if ($expanded -ieq ('"{0}" --service' -f (Join-Path $Folder 'AME.Client.exe'))) { return 'shared-client' }
    if ($expanded -ieq ('"{0}" --service' -f (Join-Path $Folder 'OOBE.exe'))) { return 'legacy-oobe' }
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
function Select-AtlasCrashEvents($Events) {
    foreach ($event in $Events) {
        # Event messages may contain credentials or user paths. Return only
        # fixed provider IDs, timestamps, exception types and numeric codes.
        $message = [string]$event.Message
        if ($message -notmatch '(?i)(?:AME\.Client|OOBE)\.exe|ProgramData\\AME\\') { continue }
        $provider = [string]$event.ProviderName
        if ($provider -notin @('.NET Runtime','Application Error','Windows Error Reporting')) { continue }
        $module = $null; $exceptionCode = $null
        if ($null -ne $event.PSObject.Methods['ToXml']) {
            $xml = [xml]$event.ToXml()
            foreach ($entry in @($xml.SelectNodes('//*[local-name()="EventData"]/*[local-name()="Data"]'))) {
                if ($entry.GetAttribute('Name') -eq 'ModuleName') {
                    $name = ([string]$entry.InnerText -split '[\\/]')[-1]
                    if ($name -match '^[A-Za-z0-9_.+-]{1,120}\.dll$') { $module = $name }
                }
                if ($entry.GetAttribute('Name') -eq 'ExceptionCode' -and [string]$entry.InnerText -match '^(?:0x)?[0-9a-fA-F]{8}$') {
                    $exceptionCode = '0x' + ([string]$entry.InnerText -replace '^0x','')
                }
            }
        }
        [ordered]@{ id = [int]$event.Id; provider = $provider;
            module = $module; exceptionCode = $exceptionCode;
            timeUtc = $event.TimeCreated.ToUniversalTime().ToString('o');
            failureKinds = @(Select-AtlasFailureKinds @($message)) }
    }
}
function Get-AtlasWindowKind([string]$Title) {
    if (-not $Title) { return 'none' }
    if ($Title -eq 'An unexpected initialization error occured') { return 'initialization-error' }
    if ($Title -eq 'An unexpected error occured') { return 'application-error' }
    return 'other'
}
if ($LibraryOnly) { return }
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$result = [ordered]@{ diagnosticsVersion = 2; collectedAtUtc = [DateTime]::UtcNow.ToString('o'); errors = @() }
$result.collectorHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
$root = Join-Path $env:ProgramData 'AME'
try {
    $service = @(Get-CimInstance Win32_Service -Filter "Name='ameoobe'")
    $result.service = @($service |
        Select-Object Name, State, StartMode, ProcessId, ExitCode, ServiceSpecificExitCode)
    $result.serviceExecutable = 'unknown'
    if ($service.Count -eq 1 -and $null -ne $service[0].PSObject.Properties['PathName']) {
        $result.serviceExecutable = Get-AtlasServiceExecutable $service[0].PathName (Join-Path $root 'OOBE')
    }
} catch { $result.errors += 'AME service status unavailable' }
$result.processes = @(Get-Process -Name 'OOBE','AME.Client','msoobe','msoobeext','CloudExperienceHost','UserOOBEBroker','LogonUI' -ErrorAction SilentlyContinue |
    Select-Object ProcessName, Id, SessionId, Responding,
        @{Name='windowKind';Expression={
            if ($null -ne $_.PSObject.Properties['MainWindowTitle']) { Get-AtlasWindowKind $_.MainWindowTitle } else { 'unknown' }
        }})
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
$result.observer = [ordered]@{state='unknown';lastResult=$null}
try {
    $task = Get-ScheduledTask -TaskName 'WinBoatAtlasOOBE'
    if ($null -eq $task) {
        $result.observer.state = 'not-registered'
    } else {
        $info = $task | Get-ScheduledTaskInfo
        $result.observer = [ordered]@{ state = $task.State.ToString(); lastResult = $info.LastTaskResult }
    }
} catch {
    if ($_.FullyQualifiedErrorId -match 'NoMatchingMSFT_ScheduledTaskObjectsFound') {
        $result.observer.state = 'not-registered'
    } else {
        $result.observer.state = 'unavailable'
        $result.errors += 'WinBoat Atlas observer status unavailable'
    }
}
try {
    $lines = @(Get-Content -LiteralPath (Join-Path $root 'Logs\Log.yml') -Tail 400)
    $result.startup = @(Select-AtlasStartupLines $lines)
    $result.handoffPhase = Get-AtlasHandoffPhase $lines
    $result.guiStartupPhase = Get-AtlasGUIStartupPhase $lines
    $result.failureKinds = @(Select-AtlasFailureKinds $lines)
} catch { $result.errors += 'AME startup log unavailable' }
try {
    # Do not filter by wall-clock time: Windows Setup may have corrected its clock.
    $events = @(Get-WinEvent -FilterHashtable @{LogName='Application'; Id=@(1000,1001,1026)} -MaxEvents 100 -ErrorAction SilentlyContinue)
    $result.crashEvents = @(Select-AtlasCrashEvents $events | Select-Object -First 20)
} catch { $result.errors += 'Windows application crash events unavailable' }
try {
    $stored = Join-Path $env:ProgramData 'WinBoat\Atlas\Start-AtlasOOBE.ps1'
    $result.observer.scriptCurrent = ((Get-FileHash -LiteralPath $stored -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Start-AtlasOOBE.ps1') -Algorithm SHA256).Hash)
} catch { $result.errors += 'Observer script version unavailable' }
try {
    $key = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $shell = if ($null -ne $key.PSObject.Properties['Shell']) { [string]$key.Shell } else { '' }
    $result.logon = [ordered]@{ shell = (Get-AtlasShellKind $shell (Join-Path $root 'OOBE\AME.Client.exe')) }
    $result.logon.setupCredentialPresent = ($null -ne $key.PSObject.Properties['DefaultPassword'] -and -not [string]::IsNullOrEmpty([string]$key.DefaultPassword))
    $result.logon.setupCredentialSource = 'winlogon-registry-only'
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
    $entries=@(@{label='OOBE-directory';relative='OOBE'},@{label='AME.Client.exe';relative='OOBE\AME.Client.exe'},
        @{label='oobe.conf';relative='OOBE\oobe.conf'},@{label='Logs-directory';relative='Logs'},@{label='Log.yml';relative='Logs\Log.yml'})
    $result.amePermissions = @(foreach ($entry in $entries) {
        $path = Join-Path $root $entry.relative
        if ($entry.label -in @('Logs-directory','Log.yml') -and -not (Test-Path -LiteralPath $path)) { continue }
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
        [ordered]@{ file = $entry.label; protected = $acl.AreAccessRulesProtected; rules = $rules }
    })
} catch { $result.errors += 'AME setup-account permissions unavailable' }
try {
    $result.uiRestartAttempted = Test-Path -LiteralPath (Join-Path $env:ProgramData 'WinBoat\Atlas\ui-restart-attempt.json')
    $result.ipcPathRepairAttempted = Test-Path -LiteralPath (Join-Path $env:ProgramData 'WinBoat\Atlas\ipc-path-repair.json')
    $result.clientInspection = @()
    # Windows PowerShell 5.1 has no $IsWindows automatic variable.
    if ($env:OS -eq 'Windows_NT') {
        if (-not ('WinBoat.AtlasProcessDiagnostics' -as [type])) {
            Add-Type -Path (Join-Path $PSScriptRoot 'AtlasProcessDiagnostics.cs')
        }
        $setupSid = if ($account.Count -eq 1) { [string]$account[0].SID } else { '' }
        $result.clientInspection = @(foreach ($client in @($result.processes | Where-Object {$_.ProcessName -eq 'AME.Client' -and $_.SessionId -gt 0} | Select-Object -First 2)) {
            [WinBoat.AtlasProcessDiagnostics]::Inspect([uint32]$client.Id, (Join-Path $root 'OOBE\AME.Client.exe'), $setupSid)
        })
    }
} catch { $result.errors += 'AME native client inspection unavailable' }
try {
    $key = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
    $result.windowsSetup = [ordered]@{}
    foreach ($name in @('OOBEInProgress','SystemSetupInProgress','SetupType')) {
        if ($null -ne $key.PSObject.Properties[$name]) { $result.windowsSetup[$name] = [int]$key.$name }
    }
} catch { $result.errors += 'Windows setup state unavailable' }
try {
    $handoff=Join-Path $env:ProgramData 'WinBoat\Atlas\helios-handoff.json'
    if (Test-Path -LiteralPath $handoff) {
        $result.heliosHandoff=Get-Content -LiteralPath $handoff -Raw | ConvertFrom-Json | Select-Object status,message,updatedAtUtc
    }
} catch { $result.heliosHandoff=@{status='unavailable'} }
$result | ConvertTo-Json -Depth 6 -Compress

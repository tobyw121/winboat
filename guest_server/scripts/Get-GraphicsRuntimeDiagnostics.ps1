# On-demand observation only. Never enable logs, change displays or restart DWM.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Get-HeliosApplicationDiagnostics.ps1') -LibraryOnly
$errors=@();$processes=@();$crashes=@();$tdr=@();$bootUtc=$null;$power=@()
$since=(Get-Date).AddHours(-1)
try {
    $boot=(Get-CimInstance Win32_OperatingSystem -Property LastBootUpTime).LastBootUpTime
    $bootUtc=$boot.ToUniversalTime().ToString('o')
    if($boot -gt $since){$since=$boot}
} catch {$errors+='Windows boot time unavailable'}
foreach($process in @(Get-Process -Name dwm -ErrorAction SilentlyContinue | Select-Object -First 4)) {
    try {
        $processes += [ordered]@{processId=$process.Id;sessionId=$process.SessionId;
            startedAtUtc=$process.StartTime.ToUniversalTime().ToString('o');
            cpuMilliseconds=[long]$process.TotalProcessorTime.TotalMilliseconds;
            threads=$process.Threads.Count;handles=$process.HandleCount}
    } catch {$errors+='DWM process timing unavailable'}
}
try {
    $events=@(Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000;StartTime=$since} -MaxEvents 64)
    $crashes=@($events | ForEach-Object {Convert-HeliosCrashEvent $_} | Where-Object {$null -ne $_ -and $_.AppName -ieq 'dwm.exe'} | Select-Object -First 16)
} catch {if($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*'){$errors+='DWM crash events unavailable'}}
try {
    $tdr=@(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Display';Id=4101;StartTime=$since} -MaxEvents 16 | ForEach-Object {
        [ordered]@{timeUtc=$_.TimeCreated.ToUniversalTime().ToString('o');recordId=$_.RecordId;eventId=4101;provider='Display'}
    })
} catch {if($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*'){$errors+='Display reset events unavailable'}}
foreach($filter in @(@{LogName='System';ProviderName='Microsoft-Windows-Kernel-Power';Id=42;StartTime=$since},
                       @{LogName='System';ProviderName='Microsoft-Windows-Power-Troubleshooter';Id=1;StartTime=$since})) {
    try {$power+=@(Get-WinEvent -FilterHashtable $filter -MaxEvents 8 | ForEach-Object {
        [ordered]@{timeUtc=$_.TimeCreated.ToUniversalTime().ToString('o');recordId=$_.RecordId;kind=$(if($_.Id -eq 42){'sleep'}else{'resume'})}
    })} catch {if($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*'){$errors+='Power events unavailable'}}
}
[ordered]@{powerEvents=$power;collectedAtUtc=[DateTime]::UtcNow.ToString('o');bootAtUtc=$bootUtc;windowStartUtc=$since.ToUniversalTime().ToString('o');
    dwmProcesses=$processes;dwmCrashes=$crashes;displayResets=$tdr;errors=$errors;
    scope='Read-only process totals and existing events; absence of events is not proof of a stable compositor'} |
    ConvertTo-Json -Depth 6 -Compress

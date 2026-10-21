$ErrorActionPreference='Stop'
$script=Join-Path $PSScriptRoot '../guest_server/scripts/Get-GraphicsRuntimeDiagnostics.ps1'
function Get-CimInstance {param($ClassName,$Property);[pscustomobject]@{LastBootUpTime=[DateTime]::UtcNow.AddMinutes(-30)}}
function Get-Process {param($Name,$ErrorAction)
    if($Name -ne 'dwm'){throw 'Unexpected process query'}
    [pscustomobject]@{Id=123;SessionId=1;StartTime=[DateTime]::UtcNow.AddMinutes(-2);TotalProcessorTime=[TimeSpan]::FromSeconds(5);Threads=@(1,2);HandleCount=40}
}
function Get-WinEvent {param($FilterHashtable,$MaxEvents)
    if($FilterHashtable.LogName -eq 'System') {
        if($FilterHashtable.Id -in @(42,1)){return [pscustomobject]@{TimeCreated=[DateTime]::UtcNow;RecordId=90+$FilterHashtable.Id;Id=$FilterHashtable.Id}}
        if($FilterHashtable.Id -ne 4101 -or $FilterHashtable.ProviderName -ne 'Display'){throw 'Unexpected event query'}
        return [pscustomobject]@{TimeCreated=[DateTime]::UtcNow;RecordId=80}
    }
    $event=[pscustomobject]@{TimeCreated=[DateTime]::UtcNow;Xml='<Event><EventData><Data Name="AppName">dwm.exe</Data><Data Name="ModuleName">vulkan_virtio.dll</Data><Data Name="ExceptionCode">c0000005</Data><Data Name="FaultingOffset">123</Data><Data Name="ProcessId">123</Data><Data Name="AppPath">PRIVATE-PATH</Data></EventData></Event>'}
    $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value {$this.Xml}
    return $event
}
$output=& $script
$report=$output | ConvertFrom-Json
if($report.powerEvents.Count -ne 2 -or $report.dwmProcesses.Count -ne 1 -or $report.dwmProcesses[0].cpuMilliseconds -ne 5000 -or
    $report.dwmCrashes.Count -ne 1 -or $report.displayResets.Count -ne 1 -or $report.errors.Count -ne 0){throw $output}
if($output -like '*PRIVATE-PATH*'){throw 'Raw event application data leaked'}
if($report.dwmCrashes[0].ModuleName -ne 'vulkan_virtio.dll' -or $report.displayResets[0].eventId -ne 4101){throw 'Failure evidence lost'}
Write-Host 'Graphics runtime diagnostics: DWM timing/crashes, TDR markers and private-field exclusion passed.'

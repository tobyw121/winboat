# On-demand only. No command lines, process termination or scheduled polling.
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Compare-HeliosProcessLoad($Before,$After,[double]$Seconds,[int]$Cores) {
    if($Seconds -le 0 -or $Cores -lt 1){throw 'Invalid sampling interval'}
    $index=@{};foreach($p in $Before){$index[[string]$p.ProcessId+'|'+[string]$p.CreationDate]=$p}
    foreach($p in $After){
        $key=[string]$p.ProcessId+'|'+[string]$p.CreationDate
        if(-not $index.ContainsKey($key)){continue};$old=$index[$key]
        $cpu=([double]$p.KernelModeTime+[double]$p.UserModeTime-[double]$old.KernelModeTime-[double]$old.UserModeTime)/1e7
        $read=[double]$p.ReadTransferCount-[double]$old.ReadTransferCount;$write=[double]$p.WriteTransferCount-[double]$old.WriteTransferCount
        if($cpu -lt 0 -or $read -lt 0 -or $write -lt 0){continue}
        [ordered]@{processId=$p.ProcessId;parentProcessId=$p.ParentProcessId;name=$p.Name;
            cpuPercentOneCore=[math]::Round($cpu/$Seconds*100,2);cpuPercentVM=[math]::Round($cpu/$Seconds*100/$Cores,2);
            readBytesPerSecond=[math]::Round($read/$Seconds);writeBytesPerSecond=[math]::Round($write/$Seconds)}
    }
}
if($LibraryOnly){return}
$properties=@('ProcessId','ParentProcessId','Name','CreationDate','KernelModeTime','UserModeTime','ReadTransferCount','WriteTransferCount')
$cores=[Environment]::ProcessorCount;$timer=[Diagnostics.Stopwatch]::StartNew()
$before=@(Get-CimInstance Win32_Process -Property $properties);$first=$timer.Elapsed.TotalSeconds
Start-Sleep -Milliseconds 1000
$after=@(Get-CimInstance Win32_Process -Property $properties);$seconds=$timer.Elapsed.TotalSeconds-$first
$rows=@(Compare-HeliosProcessLoad $before $after $seconds $cores)
[ordered]@{schema=1;collectedAtUtc=[DateTime]::UtcNow.ToString('o');sampleSeconds=$seconds;logicalProcessors=$cores;
    topCpu=@($rows | Sort-Object cpuPercentOneCore -Descending | Select-Object -First 12);
    topIO=@($rows | Sort-Object @{Expression={$_.readBytesPerSecond+$_.writeBytesPerSecond};Descending=$true} | Select-Object -First 12);
    scope='Two cumulative samples; short-lived processes can be missed. I/O includes non-disk transfers. One-core CPU can exceed 100%; VM CPU divides by logical processors.'} | ConvertTo-Json -Depth 5 -Compress

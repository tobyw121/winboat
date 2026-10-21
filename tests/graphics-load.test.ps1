. "$PSScriptRoot/../guest_server/scripts/Get-GraphicsLoad.ps1" -LibraryOnly
function Row($id,$created,$cpu,$read){[pscustomobject]@{ProcessId=$id;CreationDate=$created;ParentProcessId=1;Name='test';KernelModeTime=$cpu;UserModeTime=0;ReadTransferCount=$read;WriteTransferCount=0}}
$a=@((Row 2 'old' 0 0),(Row 3 'same' 100 10))
$b=@((Row 2 'new' 10000000 999),(Row 3 'same' 20000100 2010))
$r=@(Compare-HeliosProcessLoad $a $b 2 4)
if($r.Count -ne 1 -or $r[0].processId -ne 3 -or $r[0].cpuPercentOneCore -ne 100 -or $r[0].cpuPercentVM -ne 25 -or $r[0].readBytesPerSecond -ne 1000){throw 'PID reuse or normalized CPU/I/O regression'}
if(@(Compare-HeliosProcessLoad $b $a 2 4).Count -ne 0){throw 'Counter reset must not become negative load'}
Write-Host 'Process load delta and PID reuse checks passed'

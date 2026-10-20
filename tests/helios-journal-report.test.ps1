$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('helios-journal-'+[Guid]::NewGuid().ToString('N'))
$before=$env:ProgramData
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $root 'Helios'))
    $env:ProgramData=$root
    $prefix='[pid=123 tid=8] '
    $text=$prefix+"GPU-DIAG device=1 birth=1234 elapsed_ms=100 queries=120 mismatches=0 presented=0`n"
    foreach($i in 1..120){$text+=$prefix+"GPU-DIAG event device=1 birth=1234 seq=$i kind=format a=28 b=0 c=8 d=0 e=0 f=0`n"}
    $text+=$prefix+"GPU-DIAG first-failure device=1 birth=1234 seq=12 kind=resource a=28 b=1920 c=1080 d=4 e=0 f=32`n"
    $text+=$prefix+"GPU-DIAG first-failure device=1 birth=1234 seq=13 kind=runtime-error a=2147942487 b=0 c=0 d=0 e=0 f=0`n"
    $text+="PRIVATE-LOG-CONTENT`n"
    $path=Join-Path $root 'Helios/umd-123.log'
    [IO.File]::WriteAllText($path,$text)
    $output=& (Join-Path $PSScriptRoot '../guest_server/scripts/Get-HeliosJournalReport.ps1')
    $report=$output | ConvertFrom-Json
    if($report.journals.Count -ne 1 -or $report.journals[0].journal.events.Count -ne 96 -or
        $report.journals[0].journal.events[0].seq -ne '25' -or $report.journals[0].journal.events[95].seq -ne '120'){throw 'Full bounded journal lost'}
    if($report.journals[0].journal.firstFailure.Count -ne 2 -or $report.journals[0].journal.firstFailure[0].values[1] -ne '1920') {throw 'First failure resource context lost'}
    if($output -match 'PRIVATE-LOG-CONTENT'  -or [Text.Encoding]::UTF8.GetByteCount($output) -gt 60000){throw 'Journal privacy/size boundary failed'}
    . (Join-Path $PSScriptRoot '../guest_server/scripts/Get-HeliosUmdDiagnostics.ps1')
    if((Read-HeliosUmdSummary $path).journal.events.Count -ne 16){throw 'Compact report default changed'}
    Write-Host 'Detailed journal API: 96 events, compact default, fixed fields and byte limit passed.'
} finally {$env:ProgramData=$before;Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}

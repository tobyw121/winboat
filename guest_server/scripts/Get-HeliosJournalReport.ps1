# Explicit read-only API collection. Fixed UMD filenames; structured fields only.
. (Join-Path $PSScriptRoot 'Get-HeliosUmdDiagnostics.ps1')
$ErrorActionPreference='Stop'
$errors=@()
$files=@()
try {$files=@(Get-HeliosUmdDiagnostics -EventLimit 96 -FileLimit 2)} catch {$errors+='UMD journals unavailable'}
$report=[ordered]@{journals=$files;collectedAtUtc=[DateTime]::UtcNow.ToString('o');errors=$errors;truncated=$false}
foreach($file in $files) {
    while ([Text.Encoding]::UTF8.GetByteCount(($report | ConvertTo-Json -Depth 10 -Compress)) -gt 60000 -and $null -ne $file.journal -and @($file.journal.events).Count) {
        $file.journal.events=@($file.journal.events | Select-Object -Skip 1)
        $report.truncated=$true
    }
}
$report | ConvertTo-Json -Depth 10 -Compress

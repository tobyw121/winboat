$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../guest_server/scripts/Manage-HeliosCrashCapture.ps1') -LibraryOnly
# Exercise actual Windows registry types on a disposable per-user key.
if ($env:OS -eq 'Windows_NT') {
    $path='HKCU:\Software\WinBoatCrashCaptureTest-'+[guid]::NewGuid().ToString('N')
    try {
        New-Item -Path $path | Out-Null
        $expected=Get-HeliosDumpValues 'C:\fixed\dumps'
        foreach($name in $expected.Keys) {
            $kind=if($name -eq 'DumpFolder'){'ExpandString'}else{'DWord'}
            New-ItemProperty -LiteralPath $path -Name $name -Value $expected[$name] -PropertyType $kind | Out-Null
        }
        if(-not (Test-HeliosDumpOwnership (Get-Item $path) $expected)){throw 'Real registry policy not recognized'}
        Set-ItemProperty -LiteralPath $path -Name DumpType -Value 2
        if(Test-HeliosDumpOwnership (Get-Item $path) $expected){throw 'Foreign/full dump policy claimed'}
        Set-ItemProperty -LiteralPath $path -Name DumpType -Value 1
        New-ItemProperty -LiteralPath $path -Name PrivateSetting -Value 1 -PropertyType DWord | Out-Null
        if(Test-HeliosDumpOwnership (Get-Item $path) $expected){throw 'Additional policy setting ignored'}
    } finally {Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue}
} else {
    $values=Get-HeliosDumpValues '/fixed/dumps'
    if ($values.DumpType -ne 1 -or $values.DumpCount -ne 3) {throw 'Unbounded or full dump policy'}
}
Write-Host 'Crash capture policy bounds and ownership checks passed; no real WER policy modified.'

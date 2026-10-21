# Explicit local analysis only. Dumps and debugger output may contain private data.
param([Parameter(Mandatory)][string]$DumpPath,[Parameter(Mandatory)][string]$SymbolsPath,
    [Parameter(Mandatory)][string]$DebuggerPath,[switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Assert-HeliosAnalysisPath([string]$Path,[bool]$Directory=$false) {
    if($Path -match '[;*\r\n"]'){throw 'Debugger paths cannot contain command separators.'}
    $item=Get-Item -LiteralPath $Path -Force
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.PSIsContainer -ne $Directory){throw 'Expected a local regular file or directory.'}
    return $item.FullName
}
if($LibraryOnly){return}
. (Join-Path $PSScriptRoot 'Helios-ValidationCommon.ps1')
$dump=Assert-HeliosAnalysisPath $DumpPath
$symbols=Assert-HeliosAnalysisPath $SymbolsPath $true
$debugger=Assert-HeliosAnalysisPath $DebuggerPath
if([IO.Path]::GetFileName($debugger) -ine 'cdb.exe' -or [IO.Path]::GetExtension($dump) -ine '.dmp'){throw 'Select Windows SDK cdb.exe and a .dmp file.'}
$root=Initialize-HeliosValidationRoot
$id=[guid]::NewGuid().ToString('N');$out=Join-Path $root ($id+'-analysis.txt');$err=Join-Path $root ($id+'-analysis-errors.txt')
# Force exact symbols, remove LOAD_ANYTHING, and override inherited symbol servers.
$command='.symopt-0x40; .symopt+0x400; .reload /f; !analyze -v; .ecxr; kb 40; q'
$process=Start-Process -FilePath $debugger -ArgumentList @('-sins','-z',('"'+$dump+'"'),'-y',('"'+$symbols+'"'),'-c',('"'+$command+'"')) -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
try {
    Protect-HeliosValidationPath $out $false;Protect-HeliosValidationPath $err $false
    if(-not $process.WaitForExit(120000)){$process.Kill();throw 'Debugger timed out; no analysis success recorded.'}
    $process.WaitForExit();$process.Refresh()
    if($process.ExitCode -ne 0){throw 'Debugger failed; inspect the local output.'}
    [ordered]@{status='analysis-saved';output=$out;errors=$err;scope='Local debugger output only. Inspect symbol-load warnings before attributing a crash; no rendering fix or exact-symbol match is inferred.'} | ConvertTo-Json
} finally {$process.Dispose()}

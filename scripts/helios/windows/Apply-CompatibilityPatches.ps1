param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$BuildRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Join-Path $RepoRoot 'helios/compatibility'
$manifest=Get-Content (Join-Path $root 'proton-ge.lock.json') -Raw | ConvertFrom-Json
if($manifest.schema -ne 1){throw 'Unknown compatibility patch schema.'}
$receiptFile=Join-Path $BuildRoot 'compatibility-patches.json'
$previous=if(Test-Path $receiptFile){Get-Content $receiptFile -Raw | ConvertFrom-Json}else{$null}
$diffs=@{}
function Get-DiffHash([string]$Target){
    $diff=(& git -C $Target diff --binary HEAD) -join "`n"
    if($LASTEXITCODE -ne 0){throw 'Cannot inspect dependency changes.'}
    $hash=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($diff))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
foreach($patch in $manifest.patches){
    if($patch.component -notin @('dxvk-helios','vkd3d-proton-helios') -or $patch.file -notmatch '^patches/[a-z0-9-]+\.patch$'){throw 'Invalid compatibility patch target.'}
    $file=Join-Path $root $patch.file
    $actualHash=(Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if($actualHash -ine $patch.sha256){throw "Compatibility patch checksum mismatch: $($patch.file); expected $($patch.sha256), got $actualHash. Check Git checkout attributes and local modifications."}
    $target=Join-Path $BuildRoot $patch.component
    $head=(& git -C $target rev-parse HEAD)
    if($LASTEXITCODE -ne 0 -or $head -ne $patch.baseRevision){throw 'Compatibility patch base revision differs.'}
    if($previous){
        $saved=$previous.appliedDiffs.PSObject.Properties[$patch.component]
        if(-not $saved -or $saved.Value -ne (Get-DiffHash $target)){throw 'Compatibility patch conflicts with the recorded build tree.'}
    }else{
        & git -C $target diff --quiet HEAD
        if($LASTEXITCODE -ne 0){throw 'Compatibility patches require clean dependency sources.'}
    }
    & git -C $target apply --check $file 2>$null
    if($LASTEXITCODE -eq 0){
        & git -C $target apply $file
        if($LASTEXITCODE -ne 0){throw 'Compatibility patch application failed.'}
    }else{
        & git -C $target apply --reverse --check $file 2>$null
        if($LASTEXITCODE -ne 0){throw 'Compatibility patch conflicts with the build tree.'}
    }
    $diffs[$patch.component]=Get-DiffHash $target
}
# The immutable snapshot and packaged stable installers are never modified.
$manifest | Add-Member -NotePropertyName appliedDiffs -NotePropertyValue $diffs
$manifest | ConvertTo-Json -Depth 8 | Set-Content $receiptFile -Encoding utf8

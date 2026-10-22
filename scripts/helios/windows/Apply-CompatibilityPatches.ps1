param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$BuildRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Join-Path $RepoRoot 'helios/compatibility'
$manifest=Get-Content (Join-Path $root 'proton-ge.lock.json') -Raw | ConvertFrom-Json
if($manifest.schema -ne 1){throw 'Unknown compatibility patch schema.'}
foreach($patch in $manifest.patches){
    if($patch.component -notin @('dxvk-helios','vkd3d-proton-helios') -or $patch.file -notmatch '^patches/[a-z0-9-]+\.patch$'){throw 'Invalid compatibility patch target.'}
    $file=Join-Path $root $patch.file
    if((Get-FileHash $file -Algorithm SHA256).Hash -ine $patch.sha256){throw 'Compatibility patch checksum mismatch.'}
    $target=Join-Path $BuildRoot $patch.component
    $head=(& git -C $target rev-parse HEAD)
    if($LASTEXITCODE -ne 0 -or $head -ne $patch.baseRevision){throw 'Compatibility patch base revision differs.'}
    & git -C $target apply --check $file 2>$null
    if($LASTEXITCODE -eq 0){
        & git -C $target apply $file
        if($LASTEXITCODE -ne 0){throw 'Compatibility patch application failed.'}
    }else{
        & git -C $target apply --reverse --check $file 2>$null
        if($LASTEXITCODE -ne 0){throw 'Compatibility patch conflicts with the build tree.'}
    }
}
# The immutable snapshot and packaged stable installers are never modified.
Copy-Item (Join-Path $root 'proton-ge.lock.json') (Join-Path $BuildRoot 'compatibility-patches.json')

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$temporary=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
function Reject([scriptblock]$Action,[string]$Pattern){
    try{& $Action}catch{if($_ -match $Pattern){return};throw}
    throw "Expected rejection: $Pattern"
}
try{
    $patchRoot=Join-Path $temporary 'repo/helios/compatibility'
    $target=Join-Path $temporary 'build/dxvk-helios'
    New-Item -Type Directory -Force "$patchRoot/patches",$target | Out-Null
    git -C $target init -q
    git -C $target config core.autocrlf false
    git -C $target config user.name Fixture
    git -C $target config user.email fixture@example.invalid
    [IO.File]::WriteAllText("$target/file.txt","before`n")
    git -C $target add file.txt
    git -C $target commit -qm fixture
    $base=(git -C $target rev-parse HEAD)
    [IO.File]::WriteAllText("$target/file.txt","after`n")
    $diff=(git -C $target diff --no-ext-diff) -join "`n"
    [IO.File]::WriteAllText("$patchRoot/patches/test.patch",$diff+"`n")
    git -C $target checkout -- file.txt
    $patch=@{component='dxvk-helios';baseRevision=$base;file='patches/test.patch';sha256=(Get-FileHash "$patchRoot/patches/test.patch").Hash}
    @{schema=1;patches=@($patch)} | ConvertTo-Json -Depth 5 | Set-Content "$patchRoot/proton-ge.lock.json"
    $apply={& "$root/scripts/helios/windows/Apply-CompatibilityPatches.ps1" -RepoRoot "$temporary/repo" -BuildRoot "$temporary/build"}
    & $apply
    & $apply
    if((Get-Content "$target/file.txt") -ne 'after'){throw 'Patch not applied.'}
    if(-not (Test-Path "$temporary/build/compatibility-patches.json")){throw 'Missing receipt.'}
    [IO.File]::WriteAllText("$target/file.txt","conflict`n")
    Reject $apply 'conflicts'
    Add-Content "$patchRoot/patches/test.patch" 'tampered'
    Reject $apply 'checksum'
    Write-Host 'Compatibility patch application, repeat, conflict and tamper tests passed.'
}finally{Remove-Item $temporary -Recurse -Force}

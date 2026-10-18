<#
.SYNOPSIS
Optional, reversible per-game Direct3D 9 to Vulkan profile. No system DLL changes.
.EXAMPLE
.\Set-WinBoatGameCompatibility.ps1 -GameExe 'C:\Games\Icarus\Bin64\Client.exe' -Action D3D9
.EXAMPLE
.\Set-WinBoatGameCompatibility.ps1 -GameExe 'C:\Games\Icarus\Bin64\Client.exe' -Action Restore
#>
param(
    [Parameter(Mandatory)][string]$GameExe,
    [ValidateSet('Inspect','D3D9','Restore')][string]$Action='Inspect',
    [string]$DxvkArchive
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$version='2.7.1'
$archiveHash='d85ce7c79f57ecd765aaa1b9e7007cb875e6fde9f6d331df799bce73d513ce87'
function Get-Architecture([string]$Path) {
    $stream=[IO.File]::OpenRead($Path)
    try {
        $reader=[IO.BinaryReader]::new($stream)
        if($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d){throw 'Expected a Windows PE executable.'}
        $stream.Position=0x3c; $offset=$reader.ReadUInt32()
        if($offset -gt $stream.Length-6){throw 'Invalid PE header bounds.'}
        $stream.Position=$offset
        if($reader.ReadUInt32() -ne 0x4550){throw 'Invalid PE signature.'}
        switch($reader.ReadUInt16()){0x14c{return 'x32'};0x8664{return 'x64'};default{throw 'Only x86 and x64 Windows games are supported.'}}
    } finally {$stream.Dispose()}
}
$exe=(Resolve-Path -LiteralPath $GameExe).Path
$architecture=Get-Architecture $exe
if($Action -eq 'D3D9' -and [IO.Path]::GetFileNameWithoutExtension($exe) -match '^javaw?$'){
    throw 'Minecraft Java uses OpenGL. A D3D9 profile cannot improve Java rendering.'
}
$directory=Split-Path -Parent $exe
$dll=Join-Path $directory 'd3d9.dll'
$stateFile=Join-Path $directory '.winboat-d3d9.json'
if($Action -eq 'Inspect') {
    [ordered]@{gameExe=$exe;architecture=$architecture;profile=if(Test-Path -LiteralPath $stateFile){'managed-d3d9'}else{'none'};
        localD3D9=(Test-Path -LiteralPath $dll);note='Minecraft Java uses OpenGL; do not apply the D3D9 profile to Java. Select the actual Icarus game executable, not its launcher.'} | ConvertTo-Json
    return
}
# One writer per game directory. Never replace an existing wrapper from a client/mod.
$lock=$null; $temporary=$null
try {
    # Delete-on-close also releases the file after process termination. Reopen
    # an unlocked leftover from an older tool version, while rejecting a live writer.
    $lock=[IO.FileStream]::new((Join-Path $directory '.winboat-d3d9.lock'),[IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,[IO.FileShare]::None,4096,[IO.FileOptions]::DeleteOnClose)
    $state=$null
    if(Test-Path -LiteralPath $stateFile){
        $state=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        if($state.profile -ne 'dxvk-d3d9' -or $state.dllSha256 -notmatch '^[a-f0-9]{64}$'){throw 'Invalid compatibility receipt.'}
    }
    if($Action -eq 'Restore'){
        if(-not $state){throw 'No WinBoat D3D9 profile is installed; nothing was removed.'}
        if(Test-Path -LiteralPath $dll){
            if((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant() -ne $state.dllSha256){throw 'd3d9.dll was changed by another program; nothing was removed.'}
            Remove-Item -LiteralPath $dll
        }
        Remove-Item -LiteralPath $stateFile -Force
        [ordered]@{status='restored';gameExe=$exe} | ConvertTo-Json
        return
    }
    if(Test-Path -LiteralPath $dll){
        if($state -and (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant() -eq $state.dllSha256){
            [ordered]@{status='already-enabled';architecture=$architecture;gameExe=$exe} | ConvertTo-Json;return
        }
        throw 'An existing d3d9.dll belongs to the game or another wrapper; it was not overwritten.'
    }
    if($state){throw 'A previous profile receipt exists without its DLL. Run Restore first.'}
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('winboat-dxvk-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporary | Out-Null
    if(-not $DxvkArchive){
        $DxvkArchive=Join-Path $temporary 'dxvk.tar.gz'
        Invoke-WebRequest -Uri "https://github.com/doitsujin/dxvk/releases/download/v$version/dxvk-$version.tar.gz" -OutFile $DxvkArchive
    }
    if((Get-FileHash -LiteralPath $DxvkArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $archiveHash){throw 'DXVK archive checksum mismatch.'}
    # Extract precisely the selected DLL, never arbitrary archive entries.
    & tar -xzf $DxvkArchive -C $temporary "dxvk-$version/$architecture/d3d9.dll"
    if($LASTEXITCODE -ne 0){throw 'DXVK DLL extraction failed.'}
    $source=Join-Path $temporary "dxvk-$version/$architecture/d3d9.dll"
    if((Get-Architecture $source) -ne $architecture){throw 'DXVK DLL architecture mismatch.'}
    $receipt=[ordered]@{profile='dxvk-d3d9';version=$version;gameExe=$exe;architecture=$architecture;
        archiveSha256=$archiveHash;dllSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()}
    # Persist ownership before the copy so an interrupted install remains recoverable.
    $receipt | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
    [IO.File]::Copy($source,$dll,$false)
    [ordered]@{status='enabled';version=$version;architecture=$architecture;gameExe=$exe;
        note='Restart the game. This profile requires a functioning Vulkan driver and does not guarantee client or anti-cheat compatibility.'} | ConvertTo-Json
} finally {
    if($temporary -and (Test-Path -LiteralPath $temporary)){Remove-Item -LiteralPath $temporary -Recurse -Force}
    if($lock){$lock.Dispose()}
}

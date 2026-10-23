<#
.SYNOPSIS
Optional, reversible per-game DXVK D3D9 or D7VK D3D3/5/6/7 profile. No system DLL changes.
.EXAMPLE
.\Set-WinBoatGameCompatibility.ps1 -GameExe 'C:\Games\Icarus\Bin64\Client.exe' -Action D3D9
.EXAMPLE
.\Set-WinBoatGameCompatibility.ps1 -GameExe 'C:\Games\Icarus\Bin64\Client.exe' -Action Restore
.EXAMPLE
.\Set-WinBoatGameCompatibility.ps1 -GameExe 'C:\Games\Classic\game.exe' -Action D7VK
.EXAMPLE
.\Set-WinBoatGameCompatibility.ps1 -GameExe 'C:\Games\Classic\game.exe' -Action Restore -Profile D7VK
#>
param(
    [Parameter(Mandatory)][string]$GameExe,
    [ValidateSet('Inspect','D3D9','D7VK','Restore')][string]$Action='Inspect',
    [string]$DxvkArchive,
    [string]$D7vkArchive,
    [ValidateSet('D3D9','D7VK')][string]$Profile='D3D9'
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
if($Action -eq 'D7VK'){$Profile='D7VK'}elseif($Action -eq 'D3D9'){$Profile='D3D9'}
$isD7vk=$Profile -eq 'D7VK'
$wrapper=if($isD7vk){'ddraw.dll'}else{'d3d9.dll'}
$profileName=if($isD7vk){'d7vk-ddraw'}else{'dxvk-d3d9'}
if($isD7vk){$version='2.3';$archiveHash='ed7eec7d622d81c3606e3a7e705de955da65aba9d16ea812aa88711980b1bb66'}
$exe=(Resolve-Path -LiteralPath $GameExe).Path
$architecture=Get-Architecture $exe
if($Action -in @('D3D9','D7VK') -and [IO.Path]::GetFileNameWithoutExtension($exe) -match '^javaw?$'){
    throw 'Minecraft Java uses OpenGL. A D3D9 profile cannot improve Java rendering.'
}
$directory=Split-Path -Parent $exe
if($env:SystemRoot){
    $systemRoot=[IO.Path]::GetFullPath($env:SystemRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if($directory -ieq $systemRoot -or $directory.StartsWith($systemRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Compatibility wrappers must never be installed in a Windows system directory.'}
}
$dll=Join-Path $directory $wrapper
$stateFile=Join-Path $directory $(if($isD7vk){'.winboat-d7vk.json'}else{'.winboat-d3d9.json'})
if($Action -eq 'Inspect') {
    [ordered]@{gameExe=$exe;architecture=$architecture;profile=if(Test-Path -LiteralPath $stateFile){$profileName}else{'none'};
        localD3D9=(Test-Path -LiteralPath (Join-Path $directory 'd3d9.dll'));localD7VK=(Test-Path -LiteralPath (Join-Path $directory 'ddraw.dll'));wrapper=$wrapper;note='Minecraft Java uses OpenGL; do not apply the D3D9 profile to Java. Select the actual Icarus game executable, not its launcher.'} | ConvertTo-Json
    return
}
if($isD7vk -and $Action -ne 'Restore' -and $architecture -ne 'x32'){throw 'D7VK v2.3 supports x86 games only.'}
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
        if($state.profile -ne $profileName -or $state.dllSha256 -notmatch '^[a-f0-9]{64}$'){throw 'Invalid compatibility receipt.'}
    }
    if($Action -eq 'Restore'){
        if(-not $state){throw 'No matching WinBoat compatibility profile is installed; nothing was removed.'}
        if(Test-Path -LiteralPath $dll){
            if((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant() -ne $state.dllSha256){throw "$wrapper was changed by another program; nothing was removed."}
            Remove-Item -LiteralPath $dll
        }
        Remove-Item -LiteralPath $stateFile -Force
        [ordered]@{status='restored';gameExe=$exe} | ConvertTo-Json
        return
    }
    if($state -and $state.PSObject.Properties['gameSha256'] -and $state.gameSha256 -ne (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'Game executable changed. Restore the profile before rebinding it.'}
    if(Test-Path -LiteralPath $dll){
        if($state -and (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant() -eq $state.dllSha256){
            [ordered]@{status='already-enabled';architecture=$architecture;gameExe=$exe} | ConvertTo-Json;return
        }
        throw "An existing $wrapper belongs to the game or another wrapper; it was not overwritten."
    }
    if($state){throw 'A previous profile receipt exists without its DLL. Run Restore first.'}
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('winboat-dxvk-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporary | Out-Null
    if($isD7vk){
        if(-not $D7vkArchive){
            $D7vkArchive=Join-Path $temporary 'd7vk.zip'
            Invoke-WebRequest -Uri "https://github.com/WinterSnowfall/d7vk/releases/download/v$version/d7vk-v$version.zip" -OutFile $D7vkArchive
        }
        if((Get-FileHash $D7vkArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $archiveHash){throw 'D7VK archive checksum mismatch.'}
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive=[IO.Compression.ZipFile]::OpenRead($D7vkArchive)
        try{
            $entries=@($archive.Entries | Where-Object {$_.FullName -ceq "d7vk-v$version/x32/ddraw.dll"})
            if($entries.Count -ne 1 -or $entries[0].Length -gt 33554432){throw 'Invalid D7VK package entry.'}
            $source=Join-Path $temporary 'ddraw.dll'
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0],$source,$false)
        }finally{$archive.Dispose()}
    }else{
        if(-not $DxvkArchive){
            $DxvkArchive=Join-Path $temporary 'dxvk.tar.gz'
            Invoke-WebRequest -Uri "https://github.com/doitsujin/dxvk/releases/download/v$version/dxvk-$version.tar.gz" -OutFile $DxvkArchive
        }
        if((Get-FileHash $DxvkArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $archiveHash){throw 'DXVK archive checksum mismatch.'}
        & tar -xzf $DxvkArchive -C $temporary "dxvk-$version/$architecture/d3d9.dll"
        if($LASTEXITCODE -ne 0){throw 'DXVK DLL extraction failed.'}
        $source=Join-Path $temporary "dxvk-$version/$architecture/d3d9.dll"
    }
    if((Get-Architecture $source) -ne $architecture){throw 'Compatibility DLL architecture mismatch.'}
    $receipt=[ordered]@{schema=1;profile=$profileName;version=$version;gameExe=$exe;gameSha256=(Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant();architecture=$architecture;
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

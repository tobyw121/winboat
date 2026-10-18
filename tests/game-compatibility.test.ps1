param([string]$RepoRoot=(Split-Path -Parent $PSScriptRoot),[string]$DxvkArchive)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script=Join-Path $RepoRoot 'guest_server/scripts/Set-WinBoatGameCompatibility.ps1'
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('winboat-game-tests-'+[guid]::NewGuid().ToString('N'))
function Assert-Fails([scriptblock]$Action,[string]$Pattern){
    $failed=$false
    try{& $Action | Out-Null}catch{if($_.Exception.Message -notmatch $Pattern){throw};$failed=$true}
    if(-not $failed){throw "Expected rejection: $Pattern"}
}
try {
    New-Item -ItemType Directory -Path $temporary | Out-Null
    if(-not $DxvkArchive){
        $DxvkArchive=Join-Path $temporary 'dxvk.tar.gz'
        Invoke-WebRequest -Uri 'https://github.com/doitsujin/dxvk/releases/download/v2.7.1/dxvk-2.7.1.tar.gz' -OutFile $DxvkArchive
    }
    foreach($architecture in @('x32','x64')){
        $directory=Join-Path $temporary $architecture
        New-Item -ItemType Directory -Path $directory | Out-Null
        # Header-only EXE fixture: only architecture selection is tested here.
        # The installed DLL is a real checksum-verified DXVK release binary.
        $exe=Join-Path $directory 'client.exe';[byte[]]$bytes=New-Object byte[] 128
        $bytes[0]=77;$bytes[1]=90;$bytes[0x3c]=64;$bytes[64]=80;$bytes[65]=69
        $machine=if($architecture -eq 'x32'){[uint16]0x14c}else{[uint16]0x8664}
        [BitConverter]::GetBytes($machine).CopyTo($bytes,68);[IO.File]::WriteAllBytes($exe,$bytes)
        $inspection=& $script -GameExe $exe | ConvertFrom-Json
        if($inspection.architecture -ne $architecture){throw 'Wrong executable architecture.'}
        $result=& $script -GameExe $exe -Action D3D9 -DxvkArchive $DxvkArchive | ConvertFrom-Json
        if($result.status -ne 'enabled' -or $result.architecture -ne $architecture){throw 'Profile was not installed.'}
        $dll=Join-Path $directory 'd3d9.dll'
        if((Get-Item -LiteralPath $dll).Length -lt 100000){throw 'Expected a real release DLL.'}
        $result=& $script -GameExe $exe -Action D3D9 -DxvkArchive $DxvkArchive | ConvertFrom-Json
        if($result.status -ne 'already-enabled'){throw 'Profile activation is not idempotent.'}
        [IO.File]::AppendAllText($dll,'modified by another program')
        Assert-Fails {& $script -GameExe $exe -Action Restore} 'changed by another program'
        Remove-Item -LiteralPath $dll
        & $script -GameExe $exe -Action Restore | Out-Null # recover an interrupted/missing DLL
        if(Test-Path (Join-Path $directory '.winboat-d3d9.json')){throw 'Stale profile receipt.'}
        'existing client DLL' | Set-Content -LiteralPath $dll
        Assert-Fails {& $script -GameExe $exe -Action D3D9 -DxvkArchive $DxvkArchive} 'not overwritten'
        if((Get-Content -LiteralPath $dll -Raw).Trim() -ne 'existing client DLL'){throw 'Client DLL was replaced.'}
        Remove-Item -LiteralPath $dll
        & $script -GameExe $exe -Action D3D9 -DxvkArchive $DxvkArchive | Out-Null
        & $script -GameExe $exe -Action Restore | Out-Null
        if(Test-Path -LiteralPath $dll){throw 'Owned DLL was not removed.'}
        $badArchive=Join-Path $temporary 'bad.tar.gz';'not DXVK' | Set-Content -LiteralPath $badArchive
        Assert-Fails {& $script -GameExe $exe -Action D3D9 -DxvkArchive $badArchive} 'checksum mismatch'
        if(Test-Path -LiteralPath $dll){throw 'Unverified DLL installed.'}
        $java=Join-Path $directory 'javaw.exe';Copy-Item -LiteralPath $exe -Destination $java
        Assert-Fails {& $script -GameExe $java -Action D3D9 -DxvkArchive $DxvkArchive} 'Minecraft Java uses OpenGL'
        if(Test-Path -LiteralPath $dll){throw 'D3D9 DLL was installed for Java.'}
    }
    Write-Host 'Real pinned DXVK x86/x64 selection, repeat activation, ownership protection, restoration and checksum rejection passed. No game was executed.'
} finally {if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}}

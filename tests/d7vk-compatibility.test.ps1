param([string]$D7vkArchive)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$temporary=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
$script=Join-Path $root 'guest_server/scripts/Set-WinBoatGameCompatibility.ps1'
function Reject([scriptblock]$Action,[string]$Pattern){try{& $Action|Out-Null}catch{if($_ -match $Pattern){return};throw};throw "Expected rejection: $Pattern"}
try{
 New-Item -Type Directory $temporary | Out-Null
 if(-not $D7vkArchive){$D7vkArchive=Join-Path $temporary 'd7vk.zip';Invoke-WebRequest 'https://github.com/WinterSnowfall/d7vk/releases/download/v2.3/d7vk-v2.3.zip' -OutFile $D7vkArchive}
 $exe=Join-Path $temporary 'game.exe';$dll=Join-Path $temporary 'ddraw.dll'
 [byte[]]$bytes=New-Object byte[] 128;$bytes[0]=77;$bytes[1]=90;$bytes[60]=64;$bytes[64]=80;$bytes[65]=69;$bytes[68]=76;$bytes[69]=1
 [IO.File]::WriteAllBytes($exe,$bytes)
 $result=& $script -GameExe $exe -Action D7VK -D7vkArchive $D7vkArchive | ConvertFrom-Json
 if($result.status -ne 'enabled' -or (Get-Item $dll).Length -lt 100000){throw 'Real pinned D7VK DLL not installed.'}
 $result=& $script -GameExe $exe -Action D7VK -D7vkArchive $D7vkArchive | ConvertFrom-Json
 if($result.status -ne 'already-enabled'){throw 'Repeat activation failed.'}
 [IO.File]::AppendAllText($exe,'updated game');Reject {& $script -GameExe $exe -Action D7VK -D7vkArchive $D7vkArchive} 'Game executable changed'
 [IO.File]::AppendAllText($dll,'other wrapper');Reject {& $script -GameExe $exe -Action Restore -Profile D7VK} 'changed by another program'
 Remove-Item $dll
 & $script -GameExe $exe -Action Restore -Profile D7VK | Out-Null
 'existing wrapper' | Set-Content $dll
 Reject {& $script -GameExe $exe -Action D7VK -D7vkArchive $D7vkArchive} 'not overwritten'
 Remove-Item $dll
 $bytes[68]=100;$bytes[69]=134;[IO.File]::WriteAllBytes($exe,$bytes)
 Reject {& $script -GameExe $exe -Action D7VK -D7vkArchive $D7vkArchive} 'x86 games only'
 $bytes[68]=76;$bytes[69]=1;[IO.File]::WriteAllBytes($exe,$bytes)
 $bad=Join-Path $temporary 'bad.zip';'not a release'|Set-Content $bad
 Reject {& $script -GameExe $exe -Action D7VK -D7vkArchive $bad} 'checksum mismatch'
 if(Test-Path $dll){throw 'An unverified DLL escaped validation.'}
 Write-Host 'Real D7VK x86 package, game pin, repeat activation, wrapper protection, restore and architecture/hash rejection passed. No game rendering was tested.'
}finally{Remove-Item $temporary -Recurse -Force}

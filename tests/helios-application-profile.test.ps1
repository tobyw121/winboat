Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'guest_server/scripts/Start-HeliosApplication.ps1') -LibraryOnly
$old=$env:HELIOS_DIAGNOSTIC_FEATURE_LEVEL
$oldBackend=$env:HELIOS_DIAGNOSTIC_BACKEND_CAPS
try {
    $env:HELIOS_DIAGNOSTIC_FEATURE_LEVEL='parent-value'
    $env:HELIOS_DIAGNOSTIC_BACKEND_CAPS='1'
    function Test-HeliosProcessProfileSupport {return $true}
    $info=New-HeliosApplicationStartInfo '/fixture/game.exe' 'd3d11-fl10' '--windowed'
    if ($info.EnvironmentVariables['HELIOS_DIAGNOSTIC_FEATURE_LEVEL'] -ne '0' -or $info.UseShellExecute -or $info.Arguments -ne '--windowed') {throw 'Child-only profile was not applied.'}
    if ($env:HELIOS_DIAGNOSTIC_FEATURE_LEVEL -ne 'parent-value') {throw 'Parent process modified.'}
    $info=New-HeliosApplicationStartInfo '/fixture/game.exe' 'driver-default'
    if ($info.EnvironmentVariables.ContainsKey('HELIOS_DIAGNOSTIC_BACKEND_CAPS')){throw 'Backend override escaped default profile'}
    if ($info.EnvironmentVariables.ContainsKey('HELIOS_DIAGNOSTIC_FEATURE_LEVEL')) {throw 'Inherited diagnostic override escaped default profile.'}
    $info=New-HeliosApplicationStartInfo '/fixture/game.exe' 'd3d11-backend-caps'
    if($info.EnvironmentVariables['HELIOS_DIAGNOSTIC_BACKEND_CAPS'] -ne '1' -or $info.EnvironmentVariables.ContainsKey('HELIOS_DIAGNOSTIC_FEATURE_LEVEL')){throw 'Backend diagnostic profile leaked FL override'}
    function Test-HeliosProcessProfileSupport {return $false}
    $blocked=$false
    try {New-HeliosApplicationStartInfo '/fixture/game.exe' 'd3d11-fl11' | Out-Null} catch {$blocked=$true}
    if (-not $blocked) {throw 'Unsupported installed driver accepted a profile.'}
} finally {$env:HELIOS_DIAGNOSTIC_FEATURE_LEVEL=$old;$env:HELIOS_DIAGNOSTIC_BACKEND_CAPS=$oldBackend}
Write-Host 'Application profiles stay child-local, preserve arguments and refuse unsupported UMDs.'
$exe=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')+'.exe')
try {
    $bytes=New-Object byte[] 256;$bytes[0]=0x4d;$bytes[1]=0x5a
    [BitConverter]::GetBytes([int]128).CopyTo($bytes,60)
    $bytes[128]=0x50;$bytes[129]=0x45;$bytes[132]=0x64;$bytes[133]=0x86
    [IO.File]::WriteAllBytes($exe,$bytes)
    $data=@{schema=1;executable=$exe;expectedSha256=(Get-FileHash $exe -Algorithm SHA256).Hash}
    Assert-HeliosApplication $data
    $bytes[132]=0x4c;$bytes[133]=0x01;[IO.File]::WriteAllBytes($exe,$bytes)
    $data.expectedSha256=(Get-FileHash $exe -Algorithm SHA256).Hash;$blocked=$false
    try{Assert-HeliosApplication $data}catch{$blocked=$true}
    if(-not $blocked){throw 'x86 executable was accepted as native x64.'}
} finally {Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue}

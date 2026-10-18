param([string]$RepoRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$script=Join-Path $RepoRoot 'guest_server/scripts/Test-WinBoatOpenGL.ps1'
# Windows runners normally expose Microsoft's GDI OpenGL 1.1. This test checks
# real WGL context creation/readout, not Helios or Minecraft compatibility.
if((Get-Process -Id $PID).SessionId -eq 0){
    try{& $script;throw 'Session 0 was incorrectly accepted.'}catch{
        if($_.Exception.Message -notlike '*not session 0*'){throw}
    }
    Write-Host 'Session 0 correctly refused; desktop OpenGL probe not run.'
}else{
    $result=& $script | ConvertFrom-Json
    if(-not $result.version -or -not $result.renderer -or -not $result.vendor){throw 'Missing actual WGL capability strings.'}
    if($result.renderer -like '*GDI Generic*' -and $result.openGl33Core){throw 'Software OpenGL 1.1 incorrectly passed the 3.3 core requirement.'}
    $result | ConvertTo-Json | Write-Host
}

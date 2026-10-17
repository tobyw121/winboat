param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'guest_server/scripts/Start-AtlasOOBE.ps1') -LibraryOnly
$sid='S-1-5-21-1-2-3-1000'
$public=Get-AtlasRuntimeSddl '' $true $true $false
$secret=Get-AtlasRuntimeSddl '' $false $true $true
$private=Get-AtlasRuntimeSddl $sid $true $false $false
if ($public -notmatch '0x1200a9;;;BU' -or $secret -match 'BU|AU|WD' -or
    $private -match ';;;BU|;;;AU|;;;WD' -or $private -notmatch ([regex]::Escape("0x1200a9;;;$sid"))) { throw 'Startup/password/setup SID ACL separation failed.' }
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $descriptor=[Security.AccessControl.DirectorySecurity]::new()
    $descriptor.SetSecurityDescriptorSddlForm($private)
    $rules=@($descriptor.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    $setup=@($rules | Where-Object {$_.IdentityReference.Value -eq $sid})
    if (-not $descriptor.AreAccessRulesProtected -or $rules.Count -ne 3 -or $setup.Count -ne 1 -or [int]$setup[0].FileSystemRights -ne 1179817) {throw 'Windows ACL parser rejected the exact RX descriptor.'}
}
$rejected=$false
try { Get-AtlasRuntimeSddl 'S-1-1-0' $true $false $false | Out-Null } catch {$rejected=$true}
if (-not $rejected) {throw 'Broad principal accepted.'}
$oldData=$env:ProgramData
$temp=Join-Path ([IO.Path]::GetTempPath()) ('atlas-acl-'+[Guid]::NewGuid().ToString('N'))
try {
    $env:ProgramData=$temp
    $folder=Join-Path $temp 'AME/OOBE'
    New-Item -ItemType Directory -Force $folder | Out-Null
    'fixture' | Set-Content (Join-Path $folder 'oobe.conf')
    'fixture' | Set-Content (Join-Path $folder 'OOBE.exe')
    $global:atlasAclWrites=@()
    function Get-Acl {
        param($LiteralPath)
        $acl=[pscustomobject]@{Sddl='D:(A;;FA;;;WD)'}
        $acl | Add-Member ScriptMethod SetSecurityDescriptorSddlForm {param($Sddl) $this.Sddl=$Sddl}
        $acl
    }
    function Set-Acl {param($LiteralPath,$AclObject) $global:atlasAclWrites += ,@($LiteralPath,$AclObject.Sddl)}
    Set-AtlasRuntimeAccess
    if ($global:atlasAclWrites.Count -ne 3 -or $global:atlasAclWrites[0][0] -notlike '*oobe.conf' -or $global:atlasAclWrites[0][1] -match 'BU|WD') {throw 'Password must be protected before public binary access.'}
    $global:atlasAclWrites=@()
    Set-AtlasRuntimeAccess $sid
    foreach ($entry in $global:atlasAclWrites) {
        if ($entry[1] -match ';;;BU|;;;WD' -or $entry[1] -notmatch [regex]::Escape($sid)) {throw 'Previous broad ACEs survived handoff.'}
    }
    $global:atlasAclWrites=@()
    Set-AtlasTreeAccess $folder '' $false
    foreach ($entry in $global:atlasAclWrites) {
        if ($entry[1] -match ';;;BU|;;;WD|S-1-5-21') {throw 'Private observer policy retained another principal.'}
    }
    # Linux test host can exercise the actual reparse-point refusal with a symlink.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) {
        New-Item -ItemType SymbolicLink -Path (Join-Path $folder 'escape') -Target $temp | Out-Null
        $global:atlasAclWrites=@(); $rejected=$false
        try {Set-AtlasRuntimeAccess $sid} catch {$rejected=$true}
        if (-not $rejected -or $global:atlasAclWrites.Count) {throw 'Reparse tree was modified or followed.'}
    }
    Write-Host 'Exact runtime ACL replacement, protected password, setup SID handoff and reparse guards passed with ACL fixtures.'
} finally {
    $env:ProgramData=$oldData
    Remove-Item -LiteralPath $temp -Recurse -Force
}

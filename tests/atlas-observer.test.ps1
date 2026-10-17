# Execute the observer with Windows operations replaced; verify ordering, not just predicates.
param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$oldData=$env:ProgramData
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('atlas-observer-'+[Guid]::NewGuid().ToString('N'))
try {
    $env:ProgramData=$temporary
    $root=Join-Path $temporary 'WinBoat/Atlas'
    $media=Join-Path $temporary 'WinBoat/AtlasMedia'
    New-Item -ItemType Directory -Force $root,$media,(Join-Path $temporary 'AME/OOBE') | Out-Null
    @{mode='ame-oobe';release='0.5.0-hotfix';createdAtUtc=[DateTime]::UtcNow.AddMinutes(-1).ToString('o');waitForHelios=$false} | ConvertTo-Json | Set-Content (Join-Path $root 'oobe-mode.json')
    @{username='ConfiguredUser'} | ConvertTo-Json | Set-Content (Join-Path $media 'atlas.json')
    '[]' | Set-Content (Join-Path $root 'security-backup.json')
    $global:atlasObserverFailed=$false
    $global:atlasObserverChecks=0; $global:atlasObserverWaits=0; $global:atlasObserverChanges=0
    function Get-CimInstance {
        param($ClassName,$Filter)
        if ($ClassName -eq 'Win32_Service') { return [pscustomobject]@{State='Stopped';ExitCode=1067} }
        if ($ClassName -eq 'Win32_ComputerSystem') { return [pscustomobject]@{UserName=$null} }
        if ($Filter -match "Name='defaultuser0'") { return [pscustomobject]@{SID='S-1-5-21-1-2-3-1000';Disabled=$false} }
        if ($Filter -notmatch "Name='ConfiguredUser'") { throw 'Unexpected account query.' }
        $global:atlasObserverChecks++
        if ($global:atlasObserverChecks -gt 1) { return [pscustomobject]@{Disabled=$false} }
    }
    function Get-ItemProperty {
        param($Path)
        if ($Path -notlike '*Playbooks*Applied*') { throw 'Unexpected registry read.' }
        if ($global:atlasObserverFailed) { return $null }
        [pscustomobject]@{Version='0.5.0';ErrorLevel=0;AppliedTimeUTC=[DateTime]::UtcNow.ToBinary();SelectedOptions=@('defender-enable','mitigations-default','auto-updates-default')}
    }
    function Set-ItemProperty {
        param($Path,$Name,$Value)
        if ($global:atlasObserverChecks -lt 2 -or $Name -ne 'AutoAdminLogon' -or $Value -ne '0') { throw 'Autologon was disabled before the configured user existed.' }
        $global:atlasObserverChanges++
    }
    function Start-Sleep {param($Seconds) $global:atlasObserverWaits++}
    function Start-Service {param($Name) if ($global:atlasObserverChanges -ne 1) { throw 'Service sequencing failed.' }}
    function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm)}
    function icacls.exe { $global:LASTEXITCODE=0 }
    & (Join-Path $RepoRoot 'guest_server/scripts/Start-AtlasOOBE.ps1')
    $status=Get-Content (Join-Path $root 'status.json') -Raw | ConvertFrom-Json
    if ($status.status -ne 'finished' -or $global:atlasObserverWaits -ne 1 -or $global:atlasObserverChanges -ne 1) { throw 'Observer did not wait for final account creation.' }
    $global:atlasObserverFailed=$true; $global:atlasObserverWaits=0
    try { & (Join-Path $RepoRoot 'guest_server/scripts/Start-AtlasOOBE.ps1') } catch { }
    $status=Get-Content (Join-Path $root 'status.json') -Raw | ConvertFrom-Json
    if ($status.status -ne 'failed' -or $status.message -notmatch '1067' -or $global:atlasObserverWaits -ne 11 -or $global:atlasObserverChanges -ne 1) {
        throw 'Stopped AME service did not end the wait without changing logon.'
    }
    Write-Host 'Observer reports persistent AME startup failure after its grace period.'
    Write-Host 'Observer waits for both a fresh Atlas result and configured Windows account before disabling setup logon.'
} finally {
    $env:ProgramData=$oldData
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

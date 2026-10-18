param([string]$RepoRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'guest_server/scripts/Preserve-WinBoatProvisioning.ps1')
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('winboat-update-'+[guid]::NewGuid().ToString('N'))
try {
    $app=Join-Path $temporary 'app'
    New-Item -ItemType Directory -Force (Join-Path $app 'helios'),(Join-Path $app 'atlas'),(Join-Path $app 'scripts') | Out-Null
    'selected-helios' | Set-Content (Join-Path $app 'helios-enabled')
    'selected-atlas' | Set-Content (Join-Path $app 'atlas-enabled')
    'pinned-driver-media' | Set-Content (Join-Path $app 'helios/HeliosSetup.exe')
    'pinned-playbook' | Set-Content (Join-Path $app 'atlas/AtlasPlaybook.apbx')
    'stale-script' | Set-Content (Join-Path $app 'scripts/old.ps1')
    'old-api' | Set-Content (Join-Path $app 'winboat_guest_server.exe')
    'stale-library' | Set-Content (Join-Path $app 'old.dll')
    Get-WinBoatUpdateItemsToRemove $app | Remove-Item -Recurse -Force
    foreach($name in @('helios-enabled','atlas-enabled','helios/HeliosSetup.exe','atlas/AtlasPlaybook.apbx')) {
        if(-not (Test-Path -LiteralPath (Join-Path $app $name))){throw "OEM state was deleted: $name"}
    }
    foreach($name in @('scripts','winboat_guest_server.exe','old.dll')) {
        if(Test-Path -LiteralPath (Join-Path $app $name)){throw "Obsolete application code survived cleanup: $name"}
    }
    # Model extraction of a generic guest update: it has no per-VM selections.
    New-Item -ItemType Directory -Force (Join-Path $app 'scripts') | Out-Null
    'new-api' | Set-Content (Join-Path $app 'winboat_guest_server.exe')
    'new-script' | Set-Content (Join-Path $app 'scripts/current.ps1')
    if((Get-Content (Join-Path $app 'helios-enabled')) -ne 'selected-helios' -or
       (Get-Content (Join-Path $app 'atlas/AtlasPlaybook.apbx')) -ne 'pinned-playbook'){throw 'Update lost OEM selection/media identity'}
    Write-Output 'Guest update preserves OEM choices and media while replacing stale code.'
} finally {Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue}

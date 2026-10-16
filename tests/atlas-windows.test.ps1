param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$script = Join-Path $RepoRoot 'guest_server/scripts/Start-AtlasProvisioning.ps1'
$parseErrors = $null; $tokens = $null
[Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
. $script -LibraryOnly
$now = [DateTime]::UtcNow
$ok = [pscustomobject]@{ Version = '0.5.0'; ErrorLevel = 0; AppliedTimeUTC = $now.ToBinary() }
if (-not (Test-AtlasApplied $ok $now.AddSeconds(-1))) { throw 'Valid completion rejected.' }
if (Test-AtlasApplied $ok $now.AddSeconds(1)) { throw 'Stale success accepted.' }
foreach ($bad in @($null, [pscustomobject]@{}, [pscustomobject]@{Version='0.5.0';ErrorLevel=1;AppliedTimeUTC=$now.ToBinary()}, [pscustomobject]@{Version='0.4.1';ErrorLevel=0;AppliedTimeUTC=$now.ToBinary()})) {
    if (Test-AtlasApplied $bad $now.AddSeconds(-1)) { throw 'Incomplete, failed or old playbook accepted.' }
}
Write-Host 'Atlas PowerShell parsing and fresh completion/error validation passed.'

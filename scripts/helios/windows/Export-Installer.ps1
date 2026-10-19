param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$WinBoatCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$lockFile = Join-Path $RepoRoot 'helios/source.lock.json'
$source = Get-Content -LiteralPath $lockFile -Raw | ConvertFrom-Json
$stack = Get-Content -LiteralPath (Join-Path $RepoRoot 'helios/stack.lock.json') -Raw | ConvertFrom-Json
if ($WinBoatCommit -notmatch '^[a-f0-9]{40}$') { throw 'Expected the full WinBoat build commit.' }
if ($env:GITHUB_REPOSITORY -and $env:GITHUB_REPOSITORY -ne $stack.installerBuild.repository) {
    throw 'This workflow runs in a different repository. Update installerBuild.repository for your fork first.'
}
$installers = @(Get-ChildItem -LiteralPath $PackageRoot -Filter HeliosSetup.exe -Recurse -File |
    Where-Object { $_.DirectoryName -ne $PackageRoot })
if ($installers.Count -ne 1) { throw 'Expected one fully assembled installer, not a skeleton or symbols package.' }
$installer = $installers[0].FullName
$bytes = [IO.File]::ReadAllBytes($installer)
if ($bytes.Length -lt 128 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 2) -ne 'MZ' -or
    [Text.Encoding]::ASCII.GetString($bytes, $bytes.Length - 8, 8) -ne 'HLIOSET2') {
    throw 'The assembled installer has no complete embedded payload.'
}
$footer = $bytes.Length - 64
$offset = [BitConverter]::ToUInt64($bytes, $footer)
$size = [BitConverter]::ToUInt64($bytes, $footer + 8)
$header = [BitConverter]::ToUInt64($bytes, $footer + 16)
if ($offset -lt 64 -or $size -le 0 -or $offset -gt $footer -or $size -ne ($footer - $offset) -or $header -le 0 -or $header -ge $size) {
    throw 'Invalid installer payload bounds.'
}
$hasher = [Security.Cryptography.SHA256]::Create()
try { $payloadHash = $hasher.ComputeHash($bytes, [int]$offset, [int]$size) }
finally { $hasher.Dispose() }
for ($index = 0; $index -lt 32; $index++) {
    if ($payloadHash[$index] -ne $bytes[$footer + 24 + $index]) { throw 'Installer payload checksum mismatch.' }
}
Copy-Item -LiteralPath $installer -Destination (Join-Path $PackageRoot 'HeliosSetup.exe') -Force
$identityText = & python (Join-Path $RepoRoot 'scripts/helios/installer-identity.py') $installer
if ($LASTEXITCODE -ne 0) { throw 'Embedded installer manifest inspection failed.' }
$identity = $identityText | ConvertFrom-Json
$receipt = [ordered]@{
    revision = $stack.guestRevision
    sha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    repository = $stack.installerBuild.repository
    winboatCommit = $WinBoatCommit
    sourceSnapshot = $source.revision
    sourceLockSha256 = (Get-FileHash -LiteralPath $lockFile -Algorithm SHA256).Hash.ToLowerInvariant()
    workflow = '.github/workflows/build-helios-windows.yml'
    manifestSha256 = $identity.manifestSha256
    driverVersion = $identity.driverVersion
}
$receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PackageRoot 'helios-build.json') -Encoding ascii
Write-Host "Complete WinBoat-built installer exported from $WinBoatCommit"

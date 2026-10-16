param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path,
    [string]$BuildRoot,
    [ValidateSet('none', 'driver', 'mesa', 'all')][string]$Component = 'none'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $RepoRoot 'temp/helios-windows' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$upstream = Join-Path $RepoRoot 'helios/upstream'
$source = Get-Content -LiteralPath (Join-Path $RepoRoot 'helios/source.lock.json') -Raw | ConvertFrom-Json
$stack = Get-Content -LiteralPath (Join-Path $RepoRoot 'helios/stack.lock.json') -Raw | ConvertFrom-Json
if ($source.revision -ne $stack.hostRevision) { throw 'Helios snapshot and stack revisions differ.' }

# Verify the immutable first-party snapshot before adding dependency checkouts
# or compiler outputs. All compilation takes place in a separate local tree.
$expected = @($source.files.PSObject.Properties)
$actual = @(Get-ChildItem -LiteralPath $upstream -File -Recurse -Force)
if ($actual.Count -ne $expected.Count) { throw 'Incomplete or modified embedded Helios sources.' }
foreach ($entry in $expected) {
    $file = Join-Path $upstream $entry.Name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
        (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Value) {
        throw "Embedded Helios source checksum mismatch: $($entry.Name)"
    }
}
foreach ($dep in $source.submodules) {
    $pin = $stack.sharedSources.PSObject.Properties[$dep.path]
    if ($pin -and $pin.Value -ne $dep.revision) { throw "Dependency pin differs: $($dep.path)" }
}

if ($BuildRoot -eq $RepoRoot -or $BuildRoot.StartsWith($upstream, [StringComparison]::OrdinalIgnoreCase) -or
    $RepoRoot.StartsWith($BuildRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'BuildRoot must be separate from the source snapshot and cannot contain the WinBoat repository.'
}
$marker = Join-Path $BuildRoot '.winboat-helios-build.json'
if (Test-Path -LiteralPath $BuildRoot) {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw "BuildRoot already exists without a WinBoat marker: $BuildRoot" }
    $previous = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    if ($previous.repository -ne $RepoRoot -or $previous.revision -ne $source.revision) {
        throw 'BuildRoot belongs to a different repository or snapshot. Choose a new empty BuildRoot.'
    }
}
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
Get-ChildItem -LiteralPath $upstream -Force | Copy-Item -Destination $BuildRoot -Recurse -Force
@{ repository = $RepoRoot; revision = $source.revision } | ConvertTo-Json |
    Set-Content -LiteralPath $marker -Encoding utf8

$wanted = switch ($Component) {
    'driver' { @('dxvk-helios', 'vkd3d-proton-helios') }
    'mesa' { @('icd/mesa') }
    'all' { @('dxvk-helios', 'vkd3d-proton-helios', 'icd/mesa') }
    default { @() }
}
foreach ($name in $wanted) {
    $dep = @($source.submodules | Where-Object { $_.path -eq $name })
    if ($dep.Count -ne 1 -or $dep[0].revision -notmatch '^[a-f0-9]{40}$') { throw "Missing dependency pin: $name" }
    $destination = Join-Path $BuildRoot $name
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $destination '.git'))) {
        & git -C $destination init
        if ($LASTEXITCODE -ne 0) { throw "git init failed: $name" }
    }
    & git -C $destination config core.longpaths true
    if ($LASTEXITCODE -ne 0) { throw "Could not configure long paths: $name" }
    & git -C $destination config core.autocrlf false
    if ($LASTEXITCODE -ne 0) { throw "Could not configure dependency line endings: $name" }
    & git -C $destination fetch --depth 1 $dep[0].url $dep[0].revision
    if ($LASTEXITCODE -ne 0) { throw "Dependency fetch failed: $name" }
    & git -C $destination checkout --detach FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw "Dependency checkout failed: $name" }
    $head = (& git -C $destination rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -ne $dep[0].revision) { throw "Dependency revision mismatch: $name" }
    if ($name -ne 'icd/mesa') {
        & git -C $destination submodule update --init --recursive
        if ($LASTEXITCODE -ne 0) { throw "Nested dependency initialization failed: $name" }
    }
}
$env:HELIOS_SOURCE_ROOT = $BuildRoot
$env:WINBOAT_ROOT = $RepoRoot
if ($env:GITHUB_ENV) {
    "HELIOS_SOURCE_ROOT=$BuildRoot" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    "WINBOAT_ROOT=$RepoRoot" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}
Write-Host "Verified $($expected.Count) embedded Helios files; $Component build tree: $BuildRoot"

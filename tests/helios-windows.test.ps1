param([string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$previousGithubEnv = $env:GITHUB_ENV
$previousSourceRoot = $env:HELIOS_SOURCE_ROOT
$previousWinboatRoot = $env:WINBOAT_ROOT
$env:GITHUB_ENV = $null
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('winboat-installer-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
$prepare = Join-Path $RepoRoot 'scripts/helios/windows/Initialize-Sources.ps1'
$export = Join-Path $RepoRoot 'scripts/helios/windows/Export-Installer.ps1'
function Assert-Fails([scriptblock]$Action, [string]$Pattern) {
    $failed = $false
    try { & $Action } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; $failed = $true }
    if (-not $failed) { throw "Expected rejection: $Pattern" }
}
try {
    $build = Join-Path $temporary 'source'
    & $prepare -RepoRoot $RepoRoot -BuildRoot $build -Component none
    & $prepare -RepoRoot $RepoRoot -BuildRoot $build -Component none
    if (-not (Test-Path (Join-Path $build 'installer/Cargo.toml'))) { throw 'Installer sources were not prepared.' }
    $foreign = Join-Path $temporary 'foreign'
    New-Item -ItemType Directory -Path $foreign | Out-Null
    Assert-Fails { & $prepare -RepoRoot $RepoRoot -BuildRoot $foreign -Component none } 'without a WinBoat marker'

    # Format-only fixture; this is not an executable Windows installer.
    $package = Join-Path $temporary 'package'
    $nested = Join-Path $package 'fixture'
    New-Item -ItemType Directory -Path $nested | Out-Null
    $installer = Join-Path $nested 'HeliosSetup.exe'
    [byte[]]$payload = [Text.Encoding]::ASCII.GetBytes('header-fixture-container')
    [byte[]]$bytes = New-Object byte[] (128 + $payload.Length + 64)
    $bytes[0] = 77; $bytes[1] = 90
    $payload.CopyTo($bytes, 128)
    $footer = $bytes.Length - 64
    [BitConverter]::GetBytes([uint64]128).CopyTo($bytes, $footer)
    [BitConverter]::GetBytes([uint64]$payload.Length).CopyTo($bytes, $footer + 8)
    [BitConverter]::GetBytes([uint64]6).CopyTo($bytes, $footer + 16)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $hasher.ComputeHash($payload).CopyTo($bytes, $footer + 24) } finally { $hasher.Dispose() }
    [Text.Encoding]::ASCII.GetBytes('HLIOSET2').CopyTo($bytes, $footer + 56)
    [IO.File]::WriteAllBytes($installer, $bytes)
    & $export -RepoRoot $RepoRoot -PackageRoot $package -WinBoatCommit ('a' * 40)
    $receipt = Get-Content (Join-Path $package 'helios-build.json') -Raw | ConvertFrom-Json
    $lock = Get-Content (Join-Path $RepoRoot 'helios/stack.lock.json') -Raw | ConvertFrom-Json
    if ($receipt.revision -ne $lock.guestRevision -or $receipt.winboatCommit -ne ('a' * 40) -or
        $receipt.sha256 -ne (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'Exported receipt lost source identity or installer integrity.'
    }
    $bytes[130] = $bytes[130] -bxor 1
    [IO.File]::WriteAllBytes($installer, $bytes)
    Assert-Fails { & $export -RepoRoot $RepoRoot -PackageRoot $package -WinBoatCommit ('a' * 40) } 'payload checksum mismatch'
    [IO.File]::WriteAllBytes($installer, [Text.Encoding]::ASCII.GetBytes('MZ-skeleton'))
    Assert-Fails { & $export -RepoRoot $RepoRoot -PackageRoot $package -WinBoatCommit ('a' * 40) } 'no complete embedded payload'
    Write-Host 'Windows source preparation, rebuild isolation, receipt export, checksum rejection and skeleton rejection passed.'
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
    $env:GITHUB_ENV = $previousGithubEnv
    $env:HELIOS_SOURCE_ROOT = $previousSourceRoot
    $env:WINBOAT_ROOT = $previousWinboatRoot
}

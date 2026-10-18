# Create missing registry parents without replacing an existing recovery key.
function Initialize-DisplayRecoveryKey([string]$Path='HKLM:\SOFTWARE\WinBoat\DisplayRecovery') {
    if (Test-Path -LiteralPath $Path) { return }
    $parent=Split-Path -Path $Path -Parent
    if (-not $parent -or $parent -eq $Path) { throw 'Recovery registry root is unavailable.' }
    Initialize-DisplayRecoveryKey $parent
    New-Item -Path $Path -ErrorAction Stop | Out-Null
}

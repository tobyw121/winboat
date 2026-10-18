# Generic API ZIPs contain code, not the per-VM OEM selection and media.
# Retain those protected Program Files items in place during an update.
function Get-WinBoatUpdateItemsToRemove([string]$AppPath) {
    Get-ChildItem -LiteralPath $AppPath -Force -ErrorAction Stop |
        Where-Object { $_.Name -notin @('helios-enabled', 'atlas-enabled', 'helios', 'atlas') }
}

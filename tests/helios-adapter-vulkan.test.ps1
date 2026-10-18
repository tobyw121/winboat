param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'helios/upstream/packaging/windows/Helios-PackageCommon.ps1')
$script:registry = @{}
function Get-HeliosRegistrySnapshot([string]$Path, [string]$Name) {
    $key = "$Path/$Name"
    if ($script:registry.ContainsKey($key)) { return $script:registry[$key] }
    return @{ exists = $false; kind = $null; value = $null }
}
function Test-Path { param([string]$LiteralPath) return $LiteralPath -in @('adapter-A','adapter-B') }
function Restore-HeliosRegistrySnapshot([string]$Path, [string]$Name, $Snapshot) {
    $script:registry["$Path/$Name"] = $Snapshot
}
function Install-Records($Records, [string]$Key) {
    foreach ($entry in @($Records | Where-Object { $_.classKey -eq $Key })) {
        $script:registry["$Key/$($entry.name)"] = @{ exists=$true; kind='MultiString'; value=@($entry.installed) }
    }
}
$script:registry['adapter-A/VulkanDriverName'] = @{ exists=$true; kind='String'; value='previous.json' }
$records = @(Get-HeliosAdapterVulkanRegistration 'adapter-A' 'x64.json' 'x86.json' @())
if ($records.Count -ne 2 -or $records[0].previous.value -ne 'previous.json') { throw 'Initial snapshot lost' }
Install-Records $records 'adapter-A'
$records = @(Get-HeliosAdapterVulkanRegistration 'adapter-A' 'new64.json' 'new32.json' $records)
if ($records[0].previous.value -ne 'previous.json') { throw 'Repair overwrote original snapshot' }
Install-Records $records 'adapter-A'
$records = @(Get-HeliosAdapterVulkanRegistration 'adapter-B' 'new64.json' 'new32.json' $records)
if ($records.Count -ne 4) { throw 'PCI move lost old class key' }
Install-Records $records 'adapter-B'
# JSON roundtrip is the installer/reboot/uninstaller boundary.
$records = @($records | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
$script:registry['adapter-B/VulkanDriverNameWow'] = @{ exists=$true; kind='MultiString'; value=@('manual.json') }
Restore-HeliosAdapterVulkanRegistration $records
if ($script:registry['adapter-A/VulkanDriverName'].value -ne 'previous.json') { throw 'Original value not restored' }
if ($script:registry['adapter-A/VulkanDriverNameWow'].exists) { throw 'Absent value not restored' }
if ($script:registry['adapter-B/VulkanDriverName'].exists) { throw 'Moved adapter not cleaned up' }
if ($script:registry['adapter-B/VulkanDriverNameWow'].value[0] -ne 'manual.json') { throw 'Manual override erased' }
Write-Host 'Adapter ICD snapshots, repair, PCI move, JSON persistence and guarded restoration passed.'

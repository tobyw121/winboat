Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'helios/upstream/packaging/windows/Test-HeliosDeviceProfiles.ps1') -LibraryOnly
$script:values=@{FeatureLevel11=7;UmdTrace=0;Unrelated=42}
$script:exists=$true
function Test-Path {param($LiteralPath) return $script:exists}
function Get-Item {
    param($LiteralPath)
    $item=[pscustomobject]@{ValueCount=$script:values.Count;SubKeyCount=0}
    $item | Add-Member ScriptMethod GetValueNames {return @($script:values.Keys)}
    $item | Add-Member ScriptMethod GetValueKind {param($name) return 'DWord'}
    $item | Add-Member ScriptMethod GetValue {param($name) return $script:values[$name]}
    return $item
}
function New-Item {param($Path) $script:exists=$true}
function New-ItemProperty {param($LiteralPath,$Name,$Value,$PropertyType,[switch]$Force) $script:values[$Name]=$Value}
function Remove-ItemProperty {param($LiteralPath,$Name,$ErrorAction) $script:values.Remove($Name)}
function Remove-Item {param($LiteralPath) $script:exists=$false}
$arms=@(Invoke-HeliosProfileArms {param($mode)
    if ($script:values.UmdTrace -ne 1 -or $script:values.FeatureLevel11 -ne $mode) {throw 'Probe profile not applied'}
    $mode
})
if (($arms -join ',') -ne '1,0,2,1' -or $script:values.FeatureLevel11 -ne 7 -or
    $script:values.UmdTrace -ne 0 -or $script:values.Unrelated -ne 42) {throw 'Profile comparison/restoration failed'}
$script:values=@{Unrelated=42}
$failed=$false
try {Invoke-HeliosProfileArms {throw 'fixture probe failed'}} catch {$failed=$true}
if (-not $failed -or $script:values.Count -ne 1 -or $script:values.Unrelated -ne 42) {throw 'Absent values not restored after failure'}
$script:values=@{}; $script:exists=$false
try {Invoke-HeliosProfileArms {throw 'fixture timeout'}} catch {}
if ($script:exists -or $script:values.Count) {throw 'New empty key not removed after failure'}
$script:values=@{FeatureLevel11=7;UmdTrace=0;Unrelated=42}
$arms=@(Invoke-HeliosProfileArms -ProcessLocal {param($mode)
    if ($script:values.FeatureLevel11 -ne 7 -or $script:values.UmdTrace -ne 0) {throw 'Process-local test changed global registry'}
    $mode
})
if (($arms -join ',') -ne '1,0,2,1') {throw 'Child-process profile ordering failed'}
Write-Host 'Interleaved profiles, exact registry restoration and failure cleanup passed.'

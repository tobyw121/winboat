Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
. (Join-Path $root 'guest_server/scripts/Test-HeliosAcceptance.ps1') -LibraryOnly
$plan=@(Get-HeliosAcceptancePlan)
if ($plan.Count -ne 5 -or @($plan | Where-Object {$_.exe -match '[\\/]' -or $_.exe -notmatch '^[a-z0-9-]+\.exe$'}).Count) {throw 'Unsafe or incomplete graphics test plan'}
# Exercise real timeout and exit-code handling; no display or driver is required.
$exe=(Get-Process -Id $PID).Path
$result=Invoke-HeliosValidationProcess $exe @('-NoProfile','-Command','exit 7') 10
if ($result.status -ne 'failed' -or $result.exitCode -ne 7) {throw 'Failed probe accepted'}
$result=Invoke-HeliosValidationProcess $exe @('-NoProfile','-Command','Start-Sleep 20') 1
if ($result.status -ne 'timeout' -or $null -ne $result.exitCode) {throw 'Probe timeout accepted'}
$result=Invoke-HeliosValidationProcess $exe @('-NoProfile','-Command','exit 0') 10
if ($result.status -ne 'passed' -or $result.exitCode -ne 0) {throw 'Successful child result lost'}
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Write-Output 'budget local=1 budget=8192 usage=4096 reservation=0 available=2048'; Write-Output 'PRIVATE-APPLICATION-TEXT'"))
$result=Invoke-HeliosValidationProcess $exe @('-NoProfile','-EncodedCommand',$encoded) 10
if($result.memoryBudget.Count -ne 1 -or $result.memoryBudget[0].usageBytes -ne '4096' -or ($result | ConvertTo-Json -Depth 6) -match 'PRIVATE-APPLICATION-TEXT'){throw 'Budget decoding/privacy failed'}
Write-Host 'Fixed graphics plan, real child exit codes and bounded timeout passed.'
. (Join-Path $root 'guest_server/scripts/Helios-ControlSettings.ps1')
$script:values=@{Unrelated=42;UmdCommandLists=1}
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('helios-control-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temporary | Out-Null
function Initialize-HeliosValidationRoot {return $temporary}
function Get-Item {
    param($LiteralPath,$ErrorAction)
    $item=[pscustomobject]@{}
    $item | Add-Member ScriptMethod GetValueNames {return @($script:values.Keys)}
    $item | Add-Member ScriptMethod GetValueKind {param($name) return 'DWord'}
    $item | Add-Member ScriptMethod GetValue {param($name) return $script:values[$name]}
    return $item
}
function New-Item {throw 'An existing registry key must never be recreated'}
function New-ItemProperty {param($LiteralPath,$Name,$Value,$PropertyType,[switch]$Force) $script:values[$Name]=$Value}
function Remove-ItemProperty {param($LiteralPath,$Name,$ErrorAction) $script:values.Remove($Name)}
function Test-Path {param($LiteralPath) if($LiteralPath -like 'HKLM:*'){return $true};return [IO.File]::Exists($LiteralPath)}
try {
    $options=Get-HeliosControlSettings
    $options.UmdCommandLists=0
    Set-HeliosControlSettings $options | Out-Null
    if ($script:values.UmdCommandLists -ne 0 -or $script:values.Unrelated -ne 42) {throw 'Driver options changed unrelated state'}
    $saved=Get-Content (Join-Path $temporary 'settings-before.json') -Raw | ConvertFrom-Json
    if ($saved.UmdCommandLists -ne 1 -or $null -ne $saved.UmdD3D12) {throw 'Original settings were not preserved'}
    $options.Vulkan=0;$blocked=$false
    try {Set-HeliosControlSettings $options | Out-Null} catch {$blocked=$true}
    if (-not $blocked) {throw 'Unknown global API switch accepted'}
} finally {Remove-Item $temporary -Recurse -Force}
Write-Host 'Control-panel allowlist, inherited defaults and original-settings backup passed.'

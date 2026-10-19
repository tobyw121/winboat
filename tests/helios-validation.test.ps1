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
Write-Host 'Fixed graphics plan, real child exit codes and bounded timeout passed.'

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../guest_server/scripts/Test-HeliosLifecycle.ps1" -LibraryOnly
$data=[pscustomobject]@{sampleAgeMs=50;basic=@{state='running'};helios=@{state='running';instanceId='PCI\VEN_1AF4&DEV_1050&REV_01\3&123&0&10'};desktop=@{managed=$true;sessionId=1;basic=@{state='active';primary=$true}}}
Assert-HeliosRestartObservation $data 1
foreach($change in @('age','primary','session','device')) {
    $copy=$data | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    switch($change){age {$copy.sampleAgeMs=10001};primary {$copy.desktop.basic.primary=$false};session {$copy.desktop.sessionId=2};device {$copy.helios.instanceId='VGA'}}
    $failed=$false;try {Assert-HeliosRestartObservation $copy 1} catch {$failed=$true}
    if(-not $failed){throw 'Unsafe restart observation accepted'}
}
$script:saved=@();$script:calls=0;$script:restarts=0
function Write-HeliosValidationJson($Name,$Data){if($Name -ne 'lifecycle.json'){throw 'Unexpected report'};$script:saved+=($Data | ConvertTo-Json -Depth 10)}
function Invoke-HeliosLifecycleRestart {$script:restarts++}
function Invoke-HeliosAcceptance($Label){$script:calls++;return @{runId=$Label;automatedPassed=$script:calls -lt 2}}
$result=Invoke-HeliosLifecycle 3 $true
if($result.status -ne 'failed' -or $script:calls -ne 2 -or $script:restarts -ne 2 -or $result.cycles.Count -ne 2){throw 'Lifecycle did not stop at first failing cycle'}
if(($script:saved[-1] | ConvertFrom-Json).status -ne 'failed'){throw 'Partial lifecycle failure lost'}
$script:calls=0;$script:restarts=0
$result=Invoke-HeliosLifecycle 1 $false
if($result.status -ne 'passed' -or $script:restarts){throw 'Default loop restarted an adapter'}
Write-Host 'Lifecycle gate rejects stale/unsafe restart observations, persists failures and stops at the first failed cycle.'

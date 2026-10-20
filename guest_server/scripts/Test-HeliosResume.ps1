param([ValidateSet('minimize','reconnect','standby')][string]$Scenario='minimize',
    [ValidateRange(3,30)][int]$Samples=20,[string]$ToolsPath,[string]$ToolsManifestSha256,[switch]$LibraryOnly)
$resumeLibrary=$LibraryOnly;$resumeTools=$ToolsPath;$resumePin=$ToolsManifestSha256
. (Join-Path $PSScriptRoot 'Test-HeliosAcceptance.ps1') -LibraryOnly
$ToolsPath=$resumeTools;$ToolsManifestSha256=$resumePin
function Get-HeliosResumeAssessment($Before,$After,$Observations,[bool]$ProbePassed) {
    $same=($Before | ConvertTo-Json -Compress) -eq ($After | ConvertTo-Json -Compress)
    $unavailable=@($Observations | Where-Object {$_.status -ne 'running'}).Count
    return [ordered]@{identityUnchanged=$same;unavailableSamples=$unavailable;probesPassed=$ProbePassed;
        technicalChecksPassed=($same -and $unavailable -eq 0 -and $ProbePassed);
        scenarioOccurrence='operator-observation-required';scope='API samples and post-action probes; neither a sampling gap nor elapsed time proves suspend or visible recovery.'}
}
if($resumeLibrary){return}
if([Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0){throw 'Run in the interactive Windows desktop.'}
$before=Get-HeliosValidationIdentity;$start=[DateTime]::UtcNow;$observations=@()
Write-Host ('Perform the requested host/viewer action now, then return: '+$Scenario+'. Do not change drivers or disable VGA.')
for($index=0;$index -lt $Samples;$index++) {
    $state='unavailable'
    try {$data=Invoke-RestMethod 'http://127.0.0.1:7148/graphics/adapters' -TimeoutSec 3;$state=[string]$data.helios.state} catch {}
    $observations += [ordered]@{atUtc=[DateTime]::UtcNow.ToString('o');status=$state}
    if($index+1 -lt $Samples){Start-Sleep -Seconds 2}
}
try {$after=Get-HeliosValidationIdentity} catch {$after=@{error='Post-action driver identity unavailable'}}
try {$runtime=& (Join-Path $PSScriptRoot 'Get-GraphicsRuntimeDiagnostics.ps1') | ConvertFrom-Json}
catch {$runtime=[pscustomobject]@{dwmCrashes=@();displayResets=@();errors=@('Runtime observations unavailable')}}
$crashes=@($runtime.dwmCrashes | Where-Object {[DateTimeOffset]::Parse($_.timeUtc) -ge $start})
$resets=@($runtime.displayResets | Where-Object {[DateTimeOffset]::Parse($_.timeUtc) -ge $start})
$probe=@{runId=$null;automatedPassed=$false}
try {$probe=Invoke-HeliosAcceptance ('resume-'+$Scenario)} catch {} # Persist the failure window even if no device can be created.
$passed=$probe.automatedPassed -and $crashes.Count -eq 0 -and $resets.Count -eq 0 -and @($runtime.errors).Count -eq 0
$report=[ordered]@{schema=1;scenario=$Scenario;startedAtUtc=$start.ToString('o');finishedAtUtc=[DateTime]::UtcNow.ToString('o');
    before=$before;after=$after;observations=$observations;dwmCrashes=$crashes;displayResets=$resets;
    probeRunId=$probe.runId;assessment=(Get-HeliosResumeAssessment $before $after $observations $passed)}
Write-HeliosValidationJson 'resume.json' $report
$report | ConvertTo-Json -Depth 10

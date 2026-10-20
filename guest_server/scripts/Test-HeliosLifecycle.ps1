param([ValidateRange(1,10)][int]$Cycles=3,[switch]$RestartAdapter,
    [string]$ToolsPath,[string]$ToolsManifestSha256,[switch]$LibraryOnly)
$lifecycleLibrary=$LibraryOnly;$lifecycleTools=$ToolsPath;$lifecyclePin=$ToolsManifestSha256
. (Join-Path $PSScriptRoot 'Test-HeliosAcceptance.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'Assert-HeliosStackCoherence.ps1') -LibraryOnly
$ToolsPath=$lifecycleTools;$ToolsManifestSha256=$lifecyclePin
function Assert-HeliosRestartObservation($Data,[int]$Session) {
    if($Session -eq 0 -or $Data.sampleAgeMs -lt 0 -or $Data.sampleAgeMs -gt 10000 -or
       $Data.basic.state -ne 'running' -or $Data.helios.state -ne 'running' -or
       -not $Data.desktop.managed -or $Data.desktop.sessionId -ne $Session -or
       $Data.desktop.basic.state -ne 'active' -or -not $Data.desktop.basic.primary){throw 'Adapter restart requires fresh desktop evidence and healthy primary VGA.'}
    if([string]$Data.helios.instanceId -notmatch '^PCI\\VEN_1AF4&DEV_1050[^\\]*\\[a-zA-Z0-9&]+$'){throw 'Invalid Helios device identity.'}
}
function Invoke-HeliosLifecycleRestart {
    [void](Assert-HeliosStackCoherence)
    $hold=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WinBoat\DisplayRecovery' -ErrorAction SilentlyContinue
    if($hold -and $hold.PSObject.Properties['HeliosDisabled'] -and $hold.HeliosDisabled){throw 'Persistent VGA rescue is active; no restart requested.'}
    $data=Invoke-RestMethod 'http://127.0.0.1:7148/graphics/adapters' -TimeoutSec 3
    Assert-HeliosRestartObservation $data ([Diagnostics.Process]::GetCurrentProcess().SessionId)
    # Only this exact already-verified Helios instance; never restart VGA.
    $result=Invoke-HeliosValidationProcess "$env:SystemRoot\System32\pnputil.exe" @('/restart-device',('"'+$data.helios.instanceId+'"')) 15
    if($result.status -ne 'passed'){throw 'Helios restart did not finish successfully; no reboot or additional device change was attempted.'}
    for($i=0;$i -lt 10;$i++) {
        Start-Sleep -Seconds 1
        $next=Invoke-RestMethod 'http://127.0.0.1:7148/graphics/adapters' -TimeoutSec 3
        if($next.helios.state -eq 'running' -and $next.basic.state -eq 'running'){return}
    }
    throw 'Helios did not recover within the observation window.'
}
function Invoke-HeliosLifecycle([int]$Count,[bool]$Restart) {
    if($Count -lt 1 -or $Count -gt 10){throw 'Use one to ten lifecycle cycles.'}
    $report=[ordered]@{schema=1;startedAtUtc=[DateTime]::UtcNow.ToString('o');finishedAtUtc=$null;
        requestedCycles=$Count;restartAdapter=$Restart;cycles=@();status='running';
        scope='Repeated pixel/resize/shared-resource probes and optional explicit Helios restart; no host suspend or visual certification.'}
    Write-HeliosValidationJson 'lifecycle.json' $report
    try {
        for($i=1;$i -le $Count;$i++) {
            if($Restart){Invoke-HeliosLifecycleRestart}
            $run=Invoke-HeliosAcceptance ('lifecycle-'+$i)
            $report.cycles+=@{cycle=$i;runId=$run.runId;passed=[bool]$run.automatedPassed}
            Write-HeliosValidationJson 'lifecycle.json' $report
            if(-not $run.automatedPassed){throw 'A lifecycle acceptance cycle failed.'}
        }
        $report.status='passed'
    } catch {$report.status='failed';$report.errorCode=$_.Exception.HResult}
    finally {$report.finishedAtUtc=[DateTime]::UtcNow.ToString('o');Write-HeliosValidationJson 'lifecycle.json' $report}
    return $report
}
if($lifecycleLibrary){return}
if(-not [Environment]::Is64BitProcess -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0){throw 'Run native PowerShell on the interactive desktop.'}
$mutex=New-Object Threading.Mutex($false,'Global\WinBoatHeliosProvisioning');$owned=$false
try {
    try {$owned=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$owned=$true}
    if(-not $owned){throw 'Helios provisioning is active.'}
    Invoke-HeliosLifecycle $Cycles ([bool]$RestartAdapter) | ConvertTo-Json -Depth 10
} finally {if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}

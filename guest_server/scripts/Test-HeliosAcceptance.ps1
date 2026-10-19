param([ValidatePattern('^[a-zA-Z0-9_.-]{1,48}$')][string]$Label='manual',[switch]$LibraryOnly)
. (Join-Path $PSScriptRoot 'Helios-ValidationCommon.ps1')
function Get-HeliosAcceptancePlan {
    return @(
        @{name='D3D11';exe='d3d11-smoke.exe';arguments=@();coverage='Packaged render/readback/MSAA checks; exact coverage is tied to probe hash'},
        @{name='Vulkan enumeration';exe='vulkan-smoke.exe';arguments=@();coverage='Enumeration only'},
        @{name='Vulkan features';exe='vulkan-features.exe';arguments=@();coverage='Feature queries and device creation'},
        @{name='Vulkan presentation';exe='vulkan-wsi-probe.exe';arguments=@('3');coverage='WSI; visible colors require observation'},
        @{name='OpenGL';exe='opengl-smoke.exe';arguments=@();coverage='Context and renderer identity only'}
    )
}
function Invoke-HeliosAcceptance([string]$RunLabel) {
    if ([Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {throw 'Run in the logged-in Windows desktop, not the service session.'}
    $identity=Get-HeliosValidationIdentity
    $state=Read-HeliosValidationJson (Join-Path $env:ProgramData 'Helios\install-state.json')
    $start=[DateTime]::UtcNow
    $runId=[guid]::NewGuid().ToString('N');$rows=@()
    foreach($test in @(Get-HeliosAcceptancePlan)) {
        $path=Join-Path ([string]$state.installRoot) ('runtime\smoke\'+$test.exe)
        $result=[ordered]@{name=$test.name;coverage=$test.coverage;status='missing';sha256=$null;exitCode=$null}
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $expected=@($state.runtimeFiles | Where-Object {$_.path -ieq $path -and $_.sha256 -ieq $actual})
            if ($expected.Count -ne 1) {throw 'Probe bytes do not match the installed runtime manifest.'}
            $result.sha256=$actual
            $execution=Invoke-HeliosValidationProcess $path $test.arguments
            $result.status=$execution.status;$result.exitCode=$execution.exitCode
        }
        $rows+=$result
    }
    $after=Get-HeliosValidationIdentity
    if (($identity | ConvertTo-Json -Compress) -ne ($after | ConvertTo-Json -Compress)) {throw 'Driver or boot identity changed during graphics tests.'}
    $runtime=& (Join-Path $PSScriptRoot 'Get-GraphicsRuntimeDiagnostics.ps1') | ConvertFrom-Json
    $crashes=@($runtime.dwmCrashes | Where-Object {[DateTime]::Parse($_.timeUtc).ToUniversalTime() -ge $start})
    $resets=@($runtime.displayResets | Where-Object {[DateTime]::Parse($_.timeUtc).ToUniversalTime() -ge $start})
    $passed=@($rows | Where-Object {$_.status -ne 'passed'}).Count -eq 0 -and
        $crashes.Count -eq 0 -and $resets.Count -eq 0 -and @($runtime.errors).Count -eq 0
    $report=[ordered]@{schema=1;runId=$runId;label=$RunLabel;identity=$identity;startedAtUtc=$start.ToString('o');
        finishedAtUtc=[DateTime]::UtcNow.ToString('o');automatedPassed=$passed;tests=$rows;
        dwmCrashes=$crashes;displayResets=$resets;observationErrors=@($runtime.errors);
        manualChecks=@{visibleColors=$false;windowSwitch=$false;resolutionChange=$false;deviceRecovery=$false};
        scope='Probe exit codes and existing crash events. No complete visual, MSAA or device-loss certification.'}
    Write-HeliosValidationJson 'acceptance.json' $report
    return $report
}
if ($LibraryOnly) {return}
Invoke-HeliosAcceptance $Label | ConvertTo-Json -Depth 10

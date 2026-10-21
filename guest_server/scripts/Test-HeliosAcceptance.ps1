param([ValidatePattern('^[a-zA-Z0-9_.-]{1,48}$')][string]$Label='manual',
    [ValidatePattern('^[a-zA-Z0-9_.-]{1,96}$')][string]$ComparisonKey='graphics-suite-v1',
    [string]$ToolsPath,[string]$ToolsManifestSha256,[switch]$LibraryOnly)
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
    if (-not [Environment]::Is64BitProcess -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {throw 'Run native 64-bit PowerShell in the logged-in desktop, not the service session.'}
    $identity=Get-HeliosValidationIdentity
    $state=Read-HeliosValidationJson (Join-Path $env:ProgramData 'Helios\install-state.json')
    $start=[DateTime]::UtcNow
    $runId=[guid]::NewGuid().ToString('N');$rows=@()
    $verify=Join-Path $env:ProgramData 'Helios\Verify-Helios.ps1'
    $verification=Invoke-HeliosValidationProcess "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$verify+'"'))
    $rows += [ordered]@{name='Package integrity';coverage='Installed package verifier, API registrations and runtime hashes';status=$verification.status;
        sha256=(Get-FileHash -LiteralPath $verify -Algorithm SHA256).Hash;exitCode=$verification.exitCode}
    $plan=@(Get-HeliosAcceptancePlan)
    $toolRoot=$null
    if ($ToolsPath) {
        $toolRoot=Initialize-HeliosAcceptanceTools $ToolsPath $ToolsManifestSha256
        $plan+=@(
            @{name='OpenGL pixels';exe='helios-opengl-pixels.exe';arguments=@();coverage='Exact RGB readback, two odd dimensions';external=$true},
            @{name='D3D11 1x resize';exe='helios-msaa-present.exe';arguments=@('1','unorm','12','resize');coverage='Rendered pixel oracle, presentation and window resize';external=$true},
            @{name='D3D11 4x MSAA resize';exe='helios-msaa-present.exe';arguments=@('4','srgb','12','resize');coverage='4x MSAA resolve, pixel oracle, presentation and window resize';external=$true}
        )
        if(@((Read-HeliosValidationJson (Join-Path $toolRoot 'tools.json')).files | Where-Object {$_.name -eq 'helios-capabilities.exe'}).Count -eq 1) {
            $plan+=@{name='Capabilities';exe='helios-capabilities.exe';arguments=@();coverage='Queries only; identity and exact probe hash retained in this acceptance run';external=$true}
        }
        if(@((Read-HeliosValidationJson (Join-Path $toolRoot 'tools.json')).files | Where-Object {$_.name -eq 'helios-format-contract.exe'}).Count -eq 1) {
            $plan+=@{name='D3D11 format contracts';exe='helios-format-contract.exe';arguments=@();coverage='Advertised formats/MSAA versus texture/view creation and shared readback';external=$true}
        }
        if(@((Read-HeliosValidationJson (Join-Path $toolRoot 'tools.json')).files | Where-Object {$_.name -eq 'helios-shared-process.exe'}).Count -eq 1) {
            $plan+=@{name='D3D11 shared processes';exe='helios-shared-process.exe';arguments=@();coverage='Two-device and two-process NT handles, keyed mutex and exact bidirectional readback';external=$true}
        }
    }
    foreach($test in $plan) {
        $path=Join-Path ([string]$state.installRoot) ('runtime\smoke\'+$test.exe)
        if ($test.Contains('external')) {$path=Join-Path $toolRoot $test.exe}
        $result=[ordered]@{name=$test.name;coverage=$test.coverage;status='missing';sha256=$null;exitCode=$null;signals=@();codes=@()}
        if ($verification.status -ne 'passed') {$result.status='not-run';$rows+=$result;continue}
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $expected=@($state.runtimeFiles | Where-Object {$_.path -ieq $path -and $_.sha256 -ieq $actual})
            if ($test.Contains('external')) {$expected=@($actual)} # Copied and verified against the pinned tools manifest below.
            if ($expected.Count -ne 1) {throw 'Probe bytes do not match the installed runtime manifest.'}
            $result.sha256=$actual
            $execution=Invoke-HeliosValidationProcess $path $test.arguments
            $result.status=$execution.status;$result.exitCode=$execution.exitCode
            if ($execution.Contains('signals')) {$result.signals=$execution.signals;$result.codes=$execution.codes
                if($execution.Contains('memoryBudget')){$result.memoryBudget=$execution.memoryBudget}
                if($execution.Contains('capabilities')){$result.capabilities=$execution.capabilities}}
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
    $report=[ordered]@{schema=1;runId=$runId;label=$RunLabel;comparisonKey=$ComparisonKey;identity=$identity;startedAtUtc=$start.ToString('o');
        finishedAtUtc=[DateTime]::UtcNow.ToString('o');automatedPassed=$passed;tests=$rows;
        dwmCrashes=$crashes;displayResets=$resets;observationErrors=@($runtime.errors);
        manualChecks=@{visibleColors=$false;windowSwitch=$false;resolutionChange=$false;deviceRecovery=$false};
        scope='Probe exit codes and existing crash events. No complete visual, MSAA or device-loss certification.'}
    $report.extendedToolsSha256=$ToolsManifestSha256
    try {
        . (Join-Path $PSScriptRoot 'Helios-Comparison.ps1')
        Save-HeliosComparisonRun $report
    } catch {$report.historyError='Comparison history unavailable; export this result before the next run.'}
    Write-HeliosValidationJson 'acceptance.json' $report
    return $report
}
function Initialize-HeliosAcceptanceTools([string]$Folder,[string]$Pin) {
    $path=Join-Path $Folder 'tools.json'
    if ($Pin -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $Pin) {throw 'Independently verified tools-manifest SHA-256 required.'}
    $manifest=Read-HeliosValidationJson $path
    $expected=@('helios-msaa-present.exe','helios-opengl-pixels.exe')
    if ($manifest.schema -ne 1 -or @($manifest.files).Count -lt 2 -or @($manifest.files).Count -gt 5) {throw 'Unsupported tools manifest.'}
    foreach($optional in @('helios-format-contract.exe','helios-shared-process.exe','helios-capabilities.exe')) {
        if(@($manifest.files | Where-Object {$_.name -eq $optional}).Count){$expected+=$optional}
    }
    if(@($manifest.files).Count -ne $expected.Count){throw 'Unknown or duplicate acceptance tool'}
    $target=Join-Path (Initialize-HeliosValidationRoot) ('tools-'+$Pin.ToLowerInvariant())
    if ((Test-Path -LiteralPath $target) -and ((Get-Item $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Tools directory is a reparse point.'}
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Protect-HeliosValidationPath $target
    foreach($name in $expected) {
        $entries=@($manifest.files | Where-Object {$_.name -eq $name -and $_.sha256 -match '^[a-fA-F0-9]{64}$'})
        if ($entries.Count -ne 1) {throw 'Incomplete tools manifest.'}
        $source=Join-Path $Folder $name;$dest=Join-Path $target $name
        if ((Get-Item $source -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Tool is a reparse point.'}
        if ((Test-Path -LiteralPath $dest) -and ((Get-Item $dest -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Stored tool is a reparse point.'}
        if ((Get-FileHash $source -Algorithm SHA256).Hash -ine $entries[0].sha256) {throw 'Tool checksum mismatch.'}
        Copy-Item -LiteralPath $source -Destination $dest -Force
        Protect-HeliosValidationPath $dest $false
        if ((Get-FileHash $dest -Algorithm SHA256).Hash -ine $entries[0].sha256) {throw 'Stored tool checksum mismatch.'}
    }
    $storedManifest=Join-Path $target 'tools.json'
    if((Test-Path -LiteralPath $storedManifest) -and ((Get-Item -LiteralPath $storedManifest -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Stored manifest is a reparse point.'}
    Copy-Item -LiteralPath $path -Destination $storedManifest -Force
    if((Get-FileHash -LiteralPath $storedManifest -Algorithm SHA256).Hash -ine $Pin){throw 'Stored tools manifest checksum mismatch.'}
    return $target
}
if ($LibraryOnly) {return}
Invoke-HeliosAcceptance $Label | ConvertTo-Json -Depth 10

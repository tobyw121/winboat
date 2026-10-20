param([ValidateSet('Status','MarkTested','Reset')][string]$Action='Status',[switch]$ObservedStable,[switch]$LibraryOnly)
$releaseOperation=$Action;$releaseObservation=$ObservedStable;$releaseLibrary=$LibraryOnly
. (Join-Path $PSScriptRoot 'Manage-HeliosTransaction.ps1') -LibraryOnly
function Get-HeliosReleaseStatus($Policy,$Identity,$Record) {
    $stage='experimental'
    $sameMachine=$false
    try {$sameMachine=[bool]$Record.machineId -and $Record.machineId -eq $Identity.machineId} catch {}
    if ($sameMachine -and $null -ne $Record -and $Record.stage -eq 'vm-tested' -and $Record.version -eq $Identity.version -and
        $Record.manifestSha256 -eq $Identity.manifestSha256 -and
        ($Record.profile | ConvertTo-Json -Compress) -eq ($Identity.profile | ConvertTo-Json -Compress)) {$stage='vm-tested'}
    $default=$Policy.repositoryDefaultVersion -eq $Identity.version -and $Policy.repositoryDefaultManifestSha256 -ieq $Identity.manifestSha256
    return [ordered]@{schema=1;localStage=$stage;version=$Identity.version;repositoryDefault=$default;
        repositoryDefaultVersion=$Policy.repositoryDefaultVersion;scope='Local VM evidence only. A successful build never promotes a driver; repository default changes require a reviewed bundle/policy update.'}
}
function Invoke-HeliosRelease([string]$Operation) {
    $policy=Read-HeliosValidationJson (Join-Path $PSScriptRoot 'helios-release-policy.json')
    $identity=Get-HeliosValidationIdentity
    $path=Join-Path (Get-HeliosValidationRoot) 'release.json';$record=$null
    if(Test-Path -LiteralPath $path){$record=Read-HeliosValidationJson $path}
    if($Operation -eq 'MarkTested') {
        if(-not $releaseObservation){throw 'Explicit visible-output and recovery acceptance is required.'}
        $report=Read-HeliosValidationJson (Join-Path (Get-HeliosValidationRoot) 'acceptance.json')
        Assert-HeliosAcceptance $report $identity
        $record=[ordered]@{schema=1;stage='vm-tested';version=$identity.version;machineId=$identity.machineId;manifestSha256=$identity.manifestSha256;
            profile=$identity.profile;acceptedRunId=$report.runId;observedAtUtc=[DateTime]::UtcNow.ToString('o');acceptedBoot=$identity.bootAtUtc}
        Write-HeliosValidationJson 'release.json' $record
    }
    if($Operation -eq 'Reset') {
        $record=@{schema=1;stage='experimental';version=$identity.version;manifestSha256=$identity.manifestSha256;profile=$identity.profile}
        Write-HeliosValidationJson 'release.json' $record
    }
    return Get-HeliosReleaseStatus $policy $identity $record
}
if($releaseLibrary){return}
Invoke-HeliosRelease $releaseOperation | ConvertTo-Json -Depth 8

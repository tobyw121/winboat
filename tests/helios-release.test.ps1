Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
. (Join-Path $repo 'guest_server/scripts/Manage-HeliosRelease.ps1') -LibraryOnly
$policy=Get-Content (Join-Path $repo 'guest_server/scripts/helios-release-policy.json') -Raw | ConvertFrom-Json
$receipt=Get-Content (Join-Path $repo 'resources/helios/helios-build.json') -Raw | ConvertFrom-Json
if($policy.repositoryDefaultVersion -ne $receipt.driverVersion -or $policy.repositoryDefaultManifestSha256 -ine $receipt.manifestSha256){throw 'Release policy differs from pinned bundled default.'}
$identity=[pscustomobject]@{version='22.22.999.0';machineId='vm-a';manifestSha256='candidate';profile=@{UmdD3D12=1};bootAtUtc='2026-10-20T00:00:00Z'}
$record=[pscustomobject]@{stage='vm-tested';version=$identity.version;machineId='vm-a';manifestSha256='candidate';profile=$identity.profile}
$result=Get-HeliosReleaseStatus $policy $identity $record
if($result.repositoryDefault -or $result.localStage -ne 'vm-tested'){throw 'Local evidence incorrectly changed repository default.'}
$record.machineId='vm-b'
if((Get-HeliosReleaseStatus $policy $identity $record).localStage -ne 'experimental'){throw 'Another VM inherited approval.'}
$record.machineId='vm-a'
$identity.manifestSha256='different'
if((Get-HeliosReleaseStatus $policy $identity $record).localStage -ne 'experimental'){throw 'Changed package retained VM approval.'}
if((Get-HeliosReleaseStatus $policy $identity $null).localStage -ne 'experimental'){throw 'Missing evidence promoted a candidate.'}
Write-Host 'Local testing and pinned repository default stay independent; changed packages lose approval.'
$script:assertions=0;$script:written=$null
function Get-HeliosValidationRoot {return $repo}
function Get-HeliosValidationIdentity {return $identity}
function Test-Path {param($LiteralPath) return $false}
function Read-HeliosValidationJson($Path) {if($Path -like '*helios-release-policy.json'){return $policy};return @{runId='fixture'}}
function Assert-HeliosAcceptance($Report,$Identity) {$script:assertions++}
function Write-HeliosValidationJson($Name,$Data) {$script:written=$Data}
$releaseObservation=$false;$blocked=$false
try{Invoke-HeliosRelease MarkTested | Out-Null}catch{$blocked=$true}
if(-not $blocked -or $script:written){throw 'Unobserved candidate was marked tested.'}
$releaseObservation=$true
$result=Invoke-HeliosRelease MarkTested
if($result.localStage -ne 'vm-tested' -or $result.repositoryDefault -or $script:assertions -ne 1){throw 'Promotion did not require acceptance or changed default.'}
if((Invoke-HeliosRelease Reset).localStage -ne 'experimental'){throw 'Local release reset failed.'}
& {
    . (Join-Path $repo 'guest_server/scripts/Manage-HeliosRelease.ps1') -LibraryOnly -Action MarkTested -ObservedStable
    if($releaseOperation -ne 'MarkTested' -or -not $releaseObservation){throw 'Script parameter intent was lost while importing transaction helpers.'}
}

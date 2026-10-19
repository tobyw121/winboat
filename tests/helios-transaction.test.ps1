Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
. (Join-Path $repo 'guest_server/scripts/Manage-HeliosTransaction.ps1') -LibraryOnly
$identity=[ordered]@{version='22.22.291.0';manifestSha256=('a'*64);bootAtUtc='2026-10-19T00:00:00Z'}
$report=[pscustomobject]@{schema=1;automatedPassed=$true;identity=$identity;finishedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');tests=@(
    'D3D11','Vulkan enumeration','Vulkan features','Vulkan presentation','OpenGL' | ForEach-Object {
        [pscustomobject]@{name=$_;status='passed';sha256=('b'*64)}
    })}
Assert-HeliosAcceptance $report $identity
foreach($kind in @('failed','old-boot','old-result','future','missing-probes')) {
    $copy=$report | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    switch($kind) {
        failed {$copy.automatedPassed=$false}
        old-boot {$copy.identity.bootAtUtc='2026-10-18T00:00:00Z'}
        old-result {$copy.finishedAtUtc=[DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')}
        future {$copy.finishedAtUtc=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')}
        missing-probes {$copy.tests=@()}
    }
    $blocked=$false
    try {Assert-HeliosAcceptance $copy $identity} catch {$blocked=$true}
    if (-not $blocked) {throw "Invalid acceptance allowed: $kind"}
}
# Exercise the post-boot state machine without driver or registry operations.
$script:saved=$null;$script:protected=0;$script:released=0
$script:transaction=[pscustomobject]@{status='pending-reboot';installBoot=$identity.bootAtUtc;candidate=$identity;previous=$identity}
function Read-HeliosValidationJson($Path) {if($Path -like '*acceptance.json'){return $report};return $script:transaction}
function Get-HeliosValidationIdentity {return $identity}
function Get-HeliosValidationRoot {return $repo}
function Write-HeliosValidationJson($Name,$Data) {if($Name -eq 'transaction.json'){$script:saved=$Data.status}}
function Protect-HeliosTransaction {$script:protected++;return @{status='disabled'}}
function Set-HeliosTransactionHold($Enabled) {if(-not $Enabled){$script:released++}}
function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm,$ErrorAction)}
Invoke-HeliosTransaction Check | Out-Null
if ($null -ne $script:saved) {throw 'Same-boot installation was promoted'}
$script:transaction.installBoot='2026-10-18T00:00:00Z'
Invoke-HeliosTransaction Check | Out-Null
if ($script:saved -ne 'awaiting-acceptance') {throw 'Reboot did not require acceptance'}
$ObservedStable=$false;$blocked=$false
try {Invoke-HeliosTransaction Accept | Out-Null} catch {$blocked=$true}
if (-not $blocked -or $script:released) {throw 'Unobserved desktop accepted'}
$ObservedStable=$true
Invoke-HeliosTransaction Accept | Out-Null
if ($script:saved -ne 'accepted' -or $script:released -ne 1) {throw 'Valid acceptance did not release the hold'}
$script:transaction.status='pending-reboot';$script:transaction.candidate=[pscustomobject]@{version='22.22.294.0';manifestSha256=('c'*64)}
Invoke-HeliosTransaction Check | Out-Null
if ($script:saved -ne 'rollback-required' -or $script:protected -ne 1) {throw 'Mismatching post-boot package was not isolated'}
if ((Get-FileHash (Join-Path $repo 'scripts/helios/Clear-HeliosDriverStore.ps1')).Hash -ne
    (Get-FileHash (Join-Path $repo 'guest_server/scripts/Clear-HeliosDriverStore.ps1')).Hash) {throw 'Delivered cleanup helper differs from tested rescue helper'}
Write-Host 'Current-boot acceptance, stale/future rejection, explicit observation and failure isolation passed.'

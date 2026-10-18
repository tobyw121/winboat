param([string]$RepoRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'guest_server/scripts/Start-VCRedistProvisioning.ps1') -LibraryOnly
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('winboat-vcredist-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $failure=$null
    try { & $Action | Out-Null } catch { $failure=$_.Exception.Message }
    if (-not $failure -or $failure -notmatch $Pattern) { throw "Expected $Pattern; got $failure" }
}
try {
    $packages=@(Get-VCRedistPackages)
    if ($packages.Count -ne 10 -or @($packages.id | Select-Object -Unique).Count -ne 10) { throw 'Missing/duplicate runtime packages.' }
    foreach ($family in @('2008','2010','2012','2013','2015+')) {
        if (@($packages | Where-Object {$_.family -eq $family}).Count -ne 2) { throw 'Both x86 and x64 are required.' }
    }
    function Entry($Package) { [pscustomobject]@{productCode=$Package.productCode;name='';publisher='Microsoft Corporation';version=$Package.version} }
    foreach ($package in $packages) {
        if (-not (Test-VCRedistInstalled $package @((Entry $package)))) {throw 'Installed package was not recognized.'}
        if (Test-VCRedistInstalled $package @([pscustomobject]@{productCode=$package.productCode;name='';publisher='';version='1.0'})) {throw 'An older runtime satisfied the required version.'}
    }
    $v13=$packages | Where-Object {$_.id -eq '2013-x86'}
    $entry=Entry $v13; $entry.version='12.0.40664'
    if (-not (Test-VCRedistInstalled $v13 @($entry))) {throw 'Three/four-part versions should compare equally.'}
    $v14=$packages | Where-Object {$_.id -eq '2015+-x64'}
    $newer=[pscustomobject]@{productCode='{a-different-bundle}';name='Microsoft Visual C++ v14 Redistributable (x64) - 14.99.99999';publisher='Microsoft Corporation';version='14.99.99999.0'}
    if (-not (Test-VCRedistInstalled $v14 @($newer))) {throw 'Newer unified v14 runtime would be downgraded.'}
    $newer.name='Microsoft Visual C++ 2015-2022 Redistributable (x86) - 14.99.99999'
    if (Test-VCRedistInstalled $v14 @($newer)) {throw 'x86 cannot satisfy x64.'}

    $install=Join-Path $temporary 'install'; $data=Join-Path $temporary 'data'
    New-Item -ItemType Directory -Force $install,$data | Out-Null
    if (Get-VCRedistWaitReason $install $data) {throw 'Standard Windows should not wait for unselected Atlas/Helios.'}
    '1' | Set-Content (Join-Path $install 'atlas-enabled')
    if ((Get-VCRedistWaitReason $install $data) -notmatch 'AME/Atlas') {throw 'Worker raced Atlas.'}
    $atlas=Join-Path $data 'WinBoat/Atlas';New-Item -ItemType Directory -Force $atlas | Out-Null
    '{"status":"applying"}' | Set-Content (Join-Path $atlas 'status.json')
    if ((Get-VCRedistWaitReason $install $data) -notmatch 'applying') {throw 'An active AME playbook was ignored.'}
    '{"status":"finished"}' | Set-Content (Join-Path $atlas 'status.json')
    '1' | Set-Content (Join-Path $install 'helios-enabled')
    if ((Get-VCRedistWaitReason $install $data) -notmatch 'Helios') {throw 'Worker raced selected Helios.'}
    $helios=Join-Path $data 'Helios';New-Item -ItemType Directory -Force $helios | Out-Null
    '{"status":"driver-restart-required"}' | Set-Content (Join-Path $helios 'provisioning-status.json')
    if (-not (Get-VCRedistWaitReason $install $data)) {throw 'Worker raced a pending driver reboot.'}
    '{"status":"finished"}' | Set-Content (Join-Path $helios 'provisioning-status.json')
    if (Get-VCRedistWaitReason $install $data) {throw 'Completed provisioning should release the runtime worker.'}

    # Real SHA-256, substituted network and Windows signature APIs. No EXEs run.
    $global:vcDownloads=0; $global:vcSignature='Valid'; $global:vcPayload='trusted fixture'
    function Invoke-WebRequest {param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec) $global:vcDownloads++; [IO.File]::WriteAllText($OutFile,$global:vcPayload)}
    function Get-AuthenticodeSignature {param($LiteralPath) [pscustomobject]@{Status=$global:vcSignature;SignerCertificate=[pscustomobject]@{Subject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'}}}
    $fixture=Join-Path $temporary 'fixture';[IO.File]::WriteAllText($fixture,$global:vcPayload)
    $package=$packages[0] | Select-Object *; $package.sha256=Get-WinBoatFileSha256 $fixture
    $cached=Get-VCRedistInstaller $package $temporary
    Get-VCRedistInstaller $package $temporary | Out-Null
    if ($global:vcDownloads -ne 1) {throw 'Validated cache was needlessly downloaded again.'}
    $global:vcSignature='NotTrusted'
    Assert-Throws {Get-VCRedistInstaller $package $temporary} 'signature'
    $global:vcSignature='Valid'; Remove-Item -LiteralPath $cached
    $global:vcPayload='corrupt transfer'
    Assert-Throws {Get-VCRedistInstaller $package $temporary} 'SHA-256'
    if (Test-Path -LiteralPath ($cached+'.download')) {throw 'Incomplete payload survived checksum rejection.'}

    $global:vcEntries=@(); $global:vcLaunches=0; $global:vcExit=3010; $global:vcRegisters=$true
    $global:vcCurrent=$v14
    function Get-VCRedistInstalledEntries {return $global:vcEntries}
    function Get-VCRedistInstaller {param($Package,$Cache) return (Join-Path $Cache 'fixture-never-executed.exe')}
    function Start-Process {
        param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru)
        if (-not $Wait -or -not $PassThru -or $ArgumentList -notmatch '/norestart' -or $ArgumentList -notmatch '/quiet') {throw 'Installer must be unattended and must not reboot.'}
        $global:vcLaunches++
        if ($global:vcRegisters) {$global:vcEntries=@((Entry $global:vcCurrent))}
        return [pscustomobject]@{ExitCode=$global:vcExit}
    }
    $result=Invoke-VCRedistPackages @($v14) $temporary
    if (-not $result.rebootRequired -or $result.packages[0].status -ne 'installed' -or $global:vcLaunches -ne 1) {throw '3010 was not preserved as successful without a forced reboot.'}
    Invoke-VCRedistPackages @($v14) $temporary | Out-Null
    if ($global:vcLaunches -ne 1) {throw 'Completed runtime was installed twice.'}
    $global:vcEntries=@(); $global:vcRegisters=$false; $global:vcExit=1618
    Assert-Throws {Invoke-VCRedistPackages @($v14) $temporary} '1618'
    $global:vcExit=1638
    Assert-Throws {Invoke-VCRedistPackages @($v14) $temporary} 'did not register'
    $global:vcExit=0
    Assert-Throws {Invoke-VCRedistPackages @($v14) $temporary} 'did not register'
    Write-Output 'Visual C++ runtime tests passed: versions, both architectures, provisioning gates, verified downloads, idempotency, MSI failure/reboot handling.'
} finally {Remove-Item -LiteralPath $temporary -Recurse -Force}

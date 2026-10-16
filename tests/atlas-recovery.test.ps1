param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$parseErrors = $null; $tokens = $null
$repair = Join-Path $RepoRoot 'guest_server/scripts/Repair-AtlasOOBE.ps1'
[Management.Automation.Language.Parser]::ParseFile($repair, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
. $repair -LibraryOnly
$valid = [pscustomobject]@{mode='ame-oobe'; release='0.5.0-hotfix'; applied=$false; configuredUserExists=$false;
    diagnostics=[pscustomobject]@{errors=@(); shim=@{originalAME=$true; microsoftBackupExists=$true};
        files=@(@{exists=$true}, @{exists=$true}, @{exists=$true}, @{exists=$true});
        logon=@{shell='ame-oobe'; defaultIsSetupAccount=$true}; setupAccount=@{exists=$true; disabled=$false};
        windowsSetup=@{OOBEInProgress=0; SystemSetupInProgress=0; SetupType=0};
        service=@(@{State='Stopped'}); processes=@(@{ProcessName='LogonUI'})}}
if ($null -ne (Test-AtlasRecoveryState $valid)) { throw 'Verified stopped setup was rejected.' }
foreach ($mutate in @(
    {param($s) $s.applied=$true}, {param($s) $s.configuredUserExists=$true},
    {param($s) $s.diagnostics.shim.originalAME=$false}, {param($s) $s.diagnostics.windowsSetup.OOBEInProgress=1},
    {param($s) $s.diagnostics.files[0].exists=$false},
    {param($s) $s.diagnostics.service[0].State='Running'},
    {param($s) $s.diagnostics.processes += [pscustomobject]@{ProcessName='AME.Client'}},
    {param($s) $s.diagnostics.setupAccount.disabled=$true}, {param($s) $s.diagnostics.logon.shell='windows-explorer'}
)) {
    $state = $valid | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    & $mutate $state
    if (-not (Test-AtlasRecoveryState $state)) { throw 'Recovery accepted an unsafe/nonmatching Windows state.' }
}
. (Join-Path $RepoRoot 'guest_server/scripts/Start-AtlasOOBE.ps1') -LibraryOnly
$testData = Join-Path ([IO.Path]::GetTempPath()) ('winboat-recovery-test-' + [Guid]::NewGuid().ToString('N'))
$oldData = $env:ProgramData
$oldSystem = $env:SystemRoot
try {
    $env:ProgramData = $testData
    $env:SystemRoot = $testData
    New-Item -ItemType Directory -Path (Join-Path $testData 'AME/OOBE'), (Join-Path $testData 'WinBoat/Atlas') -Force | Out-Null
    $script:account = [pscustomobject]@{SID='S-1-5-21-1-2-3-1000'; Disabled=$false}
    $script:aclCalls = @()
    function Get-CimInstance { param($ClassName, $Filter) $script:account }
    function icacls.exe { $script:aclCalls += ,$args; $global:LASTEXITCODE=0 }
    if (-not (Grant-AtlasSetupAccountAccess)) { throw 'Setup account access was not granted.' }
    if ($script:aclCalls[0][0] -ne (Join-Path $testData 'AME/OOBE')) { throw 'Access change escaped the AME runtime directory.' }
    if (($script:aclCalls[0] -join ' ') -notmatch '\*S-1-5-21-1-2-3-1000:\(OI\)\(CI\)RX$') { throw 'Setup account must receive only RX on the AME folder.' }
    $script:account.Disabled = $true
    if ((Grant-AtlasSetupAccountAccess) -or $script:aclCalls.Count -ne 1) { throw 'Disabled setup account received access.' }
    $script:account.Disabled=$false; $script:account.SID='S-1-1-0'
    $rejected=$false
    try { Grant-AtlasSetupAccountAccess | Out-Null } catch { $rejected=$true }
    if (-not $rejected -or $script:aclCalls.Count -ne 1) { throw 'A broad principal was accepted as the setup SID.' }
    # Test the actual worker dispatch with the OS operations mocked, including
    # Sysprep failure reporting. Never execute Windows recovery on the test host.
    $status = Join-Path $testData 'WinBoat/Atlas/recovery.json'
    @{status='queued'} | ConvertTo-Json | Set-Content $status
    $repeated = & $repair | ConvertFrom-Json
    if ($repeated.status -ne 'blocked' -or (Get-Content $status -Raw | ConvertFrom-Json).status -ne 'queued') { throw 'Repeated request cancelled a pending recovery.' }
    $logFolder = Join-Path $testData 'System32/Sysprep/Panther'
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    'Private package details: 0x80073cf2 secret-password' | Set-Content (Join-Path $logFolder 'setuperr.log')
    function Start-Sleep { param($Seconds) }
    function Start-Process {
        param($FilePath, $ArgumentList, [switch]$PassThru, [switch]$Wait)
        if ($ArgumentList -ne '/oobe /reboot /quiet' -or $FilePath -notlike '*Sysprep.exe') { throw 'Unexpected recovery command.' }
        [pscustomobject]@{ExitCode=42}
    }
    $result = & $repair -RunSysprep | ConvertFrom-Json
    if ($result.status -ne 'failed' -or $result.exitCode -ne 42 -or $result.failureCodes[0] -ne '0x80073cf2' -or
        ($result | ConvertTo-Json) -match 'secret-password' -or (Get-Content $status -Raw | ConvertFrom-Json).status -ne 'failed') { throw 'Sysprep failure was not safely reported.' }
} finally {
    $env:ProgramData=$oldData; $env:SystemRoot=$oldSystem
    Remove-Item -LiteralPath $testData -Recurse -Force
}
Write-Host 'Recovery preflight guards, scoped setup SID access and mocked Sysprep failure reporting passed.'

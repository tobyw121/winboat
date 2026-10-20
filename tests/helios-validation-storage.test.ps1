Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'guest_server/scripts/Test-HeliosAcceptance.ps1') -LibraryOnly
$previous=$env:ProgramData
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('helios-storage-'+[guid]::NewGuid().ToString('N'))
try {
    $env:ProgramData=$temporary
    $root=Initialize-HeliosValidationRoot
    Write-HeliosValidationJson 'acceptance.json' @{schema=1;status='fixture'}
    $saved=Read-HeliosValidationJson (Join-Path $root 'acceptance.json')
    if ($saved.status -ne 'fixture') {throw 'Atomic validation write/read failed.'}
    $rules=(Get-Acl $root).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
    foreach($rule in $rules) {
        if ($rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544')) {throw 'Validation storage permits an unexpected identity.'}
    }
    $source=Join-Path $temporary 'tools';New-Item -ItemType Directory $source | Out-Null
    $files=@('helios-msaa-present.exe','helios-opengl-pixels.exe') | ForEach-Object {
        $file=Join-Path $source $_;'not executed fixture' | Set-Content $file
        @{name=$_;sha256=(Get-FileHash $file -Algorithm SHA256).Hash}
    }
    @{schema=1;files=@($files)} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $source 'tools.json')
    $pin=(Get-FileHash (Join-Path $source 'tools.json') -Algorithm SHA256).Hash
    $target=Initialize-HeliosAcceptanceTools $source $pin
    if (-not (Test-Path (Join-Path $target 'helios-msaa-present.exe'))) {throw 'Verified tools were not staged.'}
    'changed' | Set-Content (Join-Path $source 'helios-msaa-present.exe')
    $blocked=$false
    try {Initialize-HeliosAcceptanceTools $source $pin | Out-Null} catch {$blocked=$true}
    if (-not $blocked) {throw 'Changed probe bytes were accepted.'}
    . (Join-Path (Split-Path $PSScriptRoot) 'guest_server/scripts/Helios-Comparison.ps1')
    New-HeliosComparisonSession
    foreach($label in @('A1','B1','A2','B2')) {
        $arm=$label.StartsWith('A')
        Save-HeliosComparisonRun ([pscustomobject]@{runId=[guid]::NewGuid().ToString('N');label=$label;comparisonKey='same';
            identity=[pscustomobject]@{version=$(if($arm){'291'}else{'294'})};
            tests=@([pscustomobject]@{name='MSAA';sha256=('a'*64);status=$(if($arm){'passed'}else{'failed'});exitCode=$(if($arm){0}else{2})})})
    }
    if(-not (Get-HeliosComparisonProgress).reproducedFirstDivergence){throw 'Archived comparison session lost its first failure.'}
    Write-Host 'Real Windows protected storage, atomic receipts and external-tool hash checks passed.'
} finally {
    $env:ProgramData=$previous
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

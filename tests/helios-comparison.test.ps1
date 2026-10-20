Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'guest_server/scripts/Helios-Comparison.ps1')
$reports=@(foreach($label in @('A1','B1','A2','B2')) {
    [pscustomobject]@{label=$label;comparisonKey='same';identity=[pscustomobject]@{version=$(if($label.StartsWith('A')){'291'}else{'294'})};
        tests=@([pscustomobject]@{name='MSAA';sha256='same';status=$(if($label.StartsWith('A')){'passed'}else{'failed'});exitCode=$(if($label.StartsWith('A')){0}else{2})})}
})
$result=Get-HeliosComparison $reports
if(-not $result.reproducedFirstDivergence -or $result.pairs[0].firstDivergence.test -ne 'MSAA'){throw 'First reproducible failure lost.'}
$reports[1].tests[0].sha256='different'
if((Get-HeliosComparison $reports).sameProbeBytes){throw 'Changed test bytes hidden.'}
$reports[2].identity.version='296';$blocked=$false
try{Get-HeliosComparison $reports | Out-Null}catch{$blocked=$true}
if(-not $blocked){throw 'Mixed baseline versions accepted.'}
$reports[2].identity.version='291'
foreach($report in $reports){$report.identity | Add-Member NoteProperty profile @{UmdCommandLists=1} -Force}
$reports[2].identity.profile.UmdCommandLists=0;$blocked=$false
try{Get-HeliosComparison $reports | Out-Null}catch{$blocked=$true}
if(-not $blocked){throw 'Changed settings within an arm were accepted.'}
$reports[2].identity.profile.UmdCommandLists=1
foreach($report in $reports){$report.identity | Add-Member NoteProperty machineId 'vm-a' -Force}
$reports[3].identity.machineId='vm-b';$blocked=$false
try{Get-HeliosComparison $reports | Out-Null}catch{if($_.Exception.Message -notlike '*VM identit*'){throw};$blocked=$true}
if(-not $blocked){throw 'Another VM was mixed into the comparison.'}
Write-Host 'Guided comparison reports first reproducible result difference and rejects changing arms.'

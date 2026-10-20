Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'guest_server/scripts/Test-HeliosResume.ps1') -LibraryOnly
$identity=[pscustomobject]@{version='291';boot='first'}
$good=@([pscustomobject]@{status='running'},[pscustomobject]@{status='running'})
$result=Get-HeliosResumeAssessment $identity $identity $good $true
if(-not $result.technicalChecksPassed -or $result.scenarioOccurrence -ne 'operator-observation-required'){throw 'A technical check claimed an observed resume.'}
$bad=@([pscustomobject]@{status='unavailable'})
if((Get-HeliosResumeAssessment $identity $identity $bad $true).technicalChecksPassed){throw 'Unavailable adapter was accepted.'}
if((Get-HeliosResumeAssessment $identity ([pscustomobject]@{version='294';boot='second'}) $good $true).technicalChecksPassed){throw 'Changed driver or reboot was hidden.'}
if((Get-HeliosResumeAssessment $identity $identity $good $false).technicalChecksPassed){throw 'Post-resume probe failure was accepted.'}
Write-Host 'Resume assessment distinguishes successful probes, missing observations and changed identities.'

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'guest_server/scripts/Manage-HeliosTransaction.ps1') -LibraryOnly
function Get-HeliosValidationRoot {return $PSScriptRoot}
$script:protected=0
function Protect-HeliosTransaction {$script:protected++;return @{status='disabled'}}
function Read-HeliosValidationJson($Path){return $script:state}
function Write-HeliosValidationJson($Name,$Data){$script:saved=$Data.status}
foreach($phase in @('prepared','restoring')){
 $script:state=[pscustomobject]@{status=$phase;reason=''}
 Invoke-HeliosTransaction Check | Out-Null
 if($script:saved -ne 'rollback-required' -or $script:state.reason -ne 'interrupted-installation'){throw 'Interrupted update was not isolated'}
}
if($script:protected -ne 2){throw 'Recovery did not run exactly once per interrupted update'}
Write-Host 'Interrupted install/restore require explicit recovery.'

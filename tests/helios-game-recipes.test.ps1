$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'guest_server/scripts/Start-HeliosApplication.ps1') -LibraryOnly
function Reject([scriptblock]$Action,[string]$Pattern){try{& $Action|Out-Null}catch{if($_ -match $Pattern){return};throw};throw "Expected rejection: $Pattern"}
$temporary=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
$recipe='d3d11-fl10-v1'
try{
 New-Item -Type Directory $temporary|Out-Null
 $exe=Join-Path $temporary 'game.exe';'fixture'|Set-Content $exe
 $script:driver='22.22.302.0'
 function Get-HeliosValidationIdentity {return @{version=$script:driver;manifestSha256=('a'*64);profile=[ordered]@{FeatureLevel11=1}}}
 function Test-HeliosProcessProfileSupport {return $true}
 $info=New-HeliosApplicationStartInfo $exe 'driver-default' '--windowed' $recipe
 if($info.EnvironmentVariables['HELIOS_DIAGNOSTIC_FEATURE_LEVEL'] -ne '0'){throw 'Recipe not applied to child.'}
 New-HeliosApplicationStartInfo $exe 'driver-default' '' $recipe|Out-Null
 Add-Content $exe 'updated'
 Reject {New-HeliosApplicationStartInfo $exe 'driver-default' '' $recipe} 'changed'
 New-HeliosApplicationStartInfo $exe 'driver-default' '' $recipe -RebindRecipe|Out-Null
 $script:driver='22.22.303.0'
 Reject {New-HeliosApplicationStartInfo $exe 'driver-default' '' $recipe} 'changed'
 Reject {New-HeliosApplicationStartInfo $exe 'driver-default' '' 'not-a-recipe'} 'Unknown'
 Reject {New-HeliosApplicationStartInfo $exe 'd3d11-fl10' '' $recipe} 'cannot be combined'
 $info=New-HeliosApplicationStartInfo $exe 'driver-default'
 if($info.EnvironmentVariables.ContainsKey('HELIOS_DIAGNOSTIC_FEATURE_LEVEL')){throw 'Default launch retained recipe.'}
 Write-Host 'Native recipe application, executable/driver binding, explicit rebind and process-local reset passed.'
}finally{
 # The fixture uses a random executable path; remove only its own exact receipt.
 $hasher=[Security.Cryptography.SHA256]::Create()
 try{$key=[BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($exe.ToLowerInvariant()+'|'+$recipe))).Replace('-','').ToLowerInvariant()}finally{$hasher.Dispose()}
 $receipt=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('WinBoat/RecipeBindings/'+$key+'.json')
 Remove-Item $receipt -Force -ErrorAction SilentlyContinue
 Remove-Item $temporary -Recurse -Force
}

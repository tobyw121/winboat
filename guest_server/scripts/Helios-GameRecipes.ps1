# Versioned process-local diagnostic recipes; no game is claimed fixed by these presets.
function Get-HeliosRecipeMode([string]$Recipe){
    switch($Recipe){
        'd3d11-fl10-v1' {return 'd3d11-fl10'}
        'd3d11-backend-caps-v1' {return 'd3d11-backend-caps'}
        default {throw 'Unknown Helios compatibility recipe.'}
    }
}
function Assert-HeliosRecipeBinding([string]$Executable,[string]$Recipe,[switch]$Rebind){
    [void](Get-HeliosRecipeMode $Recipe)
    $exe=(Get-Item -LiteralPath $Executable)
    if(-not [IO.Path]::IsPathRooted($Executable) -or $exe.Extension -ine '.exe' -or ($exe.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'A regular absolute game executable is required.'}
    $identity=Get-HeliosValidationIdentity
    $hasher=[Security.Cryptography.SHA256]::Create()
    try{
        $key=[BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($exe.FullName.ToLowerInvariant()+'|'+$Recipe))).Replace('-','').ToLowerInvariant()
        $options=[BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes(($identity.profile|ConvertTo-Json -Compress)))).Replace('-','').ToLowerInvariant()
    }finally{$hasher.Dispose()}
    $binding=[ordered]@{schema=1;recipe=$Recipe;executable=$exe.FullName.ToLowerInvariant();exeSha256=(Get-FileHash $exe.FullName -Algorithm SHA256).Hash.ToLowerInvariant();
        driverVersion=$identity.version;manifestSha256=$identity.manifestSha256;driverOptionsSha256=$options}
    $directory=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WinBoat/RecipeBindings'
    New-Item -Type Directory -Force $directory | Out-Null
    if((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Recipe directory must not be a reparse point.'}
    $file=Join-Path $directory ($key+'.json')
    if(Test-Path -LiteralPath $file){
        $existing=Get-Item -LiteralPath $file
        if($existing.Length -gt 16384 -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Invalid recipe binding file.'}
        if(-not $Rebind){
            $previous=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            if(($previous|ConvertTo-Json -Compress) -cne ($binding|ConvertTo-Json -Compress)){throw 'Game, driver or driver options changed. Explicitly rebind the recipe in Windows before using it.'}
            return
        }
    }
    $json=$binding|ConvertTo-Json
    if($Rebind){[IO.File]::WriteAllText($file,$json)}else{
        $stream=[IO.File]::Open($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$bytes=[Text.Encoding]::UTF8.GetBytes($json);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    }
}

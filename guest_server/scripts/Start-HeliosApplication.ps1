param([string]$ProfileFile,[switch]$LibraryOnly)
. (Join-Path $PSScriptRoot 'Helios-ValidationCommon.ps1')
. (Join-Path $PSScriptRoot 'Helios-GameRecipes.ps1')
function Test-HeliosProcessProfileSupport([string]$Marker='HELIOS_DIAGNOSTIC_FEATURE_LEVEL') {
    [void](Get-HeliosValidationIdentity)
    $state=Read-HeliosValidationJson (Join-Path $env:ProgramData 'Helios\install-state.json')
    if ($state.classKey -notmatch '^HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Class\\\{4d36e968-e325-11ce-bfc1-08002be10318\}\\\d{4}$') {throw 'Invalid Helios adapter key.'}
    $key=Get-Item -LiteralPath $state.classKey
    $paths=@($key.GetValue('UserModeDriverName',$null))
    if (-not $paths.Count -or [IO.Path]::GetFileName($paths[0]) -ine 'helios_umd.dll') {throw 'Native Helios UMD unavailable.'}
    $path=[string]$paths[0]
    $file=Get-Item -LiteralPath $path
    if ($file.Length -gt 33554432 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Invalid UMD file.'}
    $expected=@($state.driverFiles | Where-Object {$_.name -ieq 'helios_umd.dll' -and $_.sha256 -ieq (Get-FileHash $path -Algorithm SHA256).Hash})
    if ($expected.Count -ne 1) {throw 'Bound UMD does not match the recorded package.'}
    # This marker names the process-local reader in the checksum-locked UMD
    # source. Old binaries lacking the reader must never silently ignore it.
    return [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($path)).Contains($Marker)
}
function New-HeliosApplicationStartInfo([string]$Executable,[string]$Mode,[string]$ArgumentLine='',[string]$Recipe='',[switch]$RebindRecipe) {
    if($RebindRecipe -and -not $Recipe){throw 'Select a recipe before rebinding.'}
    if($Recipe){if($Mode -ne 'driver-default'){throw 'A recipe cannot be combined with another compatibility override.'};$Mode=Get-HeliosRecipeMode $Recipe}
    if ($Mode -notin @('driver-default','d3d11-fl10','d3d11-fl11','d3d11-backend-caps')) {throw 'Unknown application profile.'}
    $marker=if($Mode -eq 'd3d11-backend-caps'){'HELIOS_DIAGNOSTIC_BACKEND_CAPS'}else{'HELIOS_DIAGNOSTIC_FEATURE_LEVEL'}
    if ($Mode -ne 'driver-default' -and -not (Test-HeliosProcessProfileSupport $marker)) {throw 'Installed UMD does not support this process-local diagnostic profile.'}
    if($Recipe){Assert-HeliosRecipeBinding $Executable $Recipe -Rebind:$RebindRecipe}
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Executable;$info.Arguments=$ArgumentLine;$info.WorkingDirectory=Split-Path -Parent $Executable
    $info.UseShellExecute=$false
    $info.EnvironmentVariables.Remove('HELIOS_DIAGNOSTIC_FEATURE_LEVEL')
    $info.EnvironmentVariables.Remove('HELIOS_DIAGNOSTIC_BACKEND_CAPS')
    if($Mode -eq 'd3d11-backend-caps'){$info.EnvironmentVariables['HELIOS_DIAGNOSTIC_BACKEND_CAPS']='1'}
    if($Mode -in @('d3d11-fl10','d3d11-fl11')) {$info.EnvironmentVariables['HELIOS_DIAGNOSTIC_FEATURE_LEVEL']=if($Mode -eq 'd3d11-fl10'){'0'}else{'1'}}
    return $info
}
function Assert-HeliosApplication($Data) {
    if ($Data.schema -ne 1 -or $Data.expectedSha256 -notmatch '^[a-fA-F0-9]{64}$' -or -not [IO.Path]::IsPathRooted($Data.executable) -or
        [IO.Path]::GetExtension($Data.executable) -ine '.exe' -or (Get-FileHash -LiteralPath $Data.executable -Algorithm SHA256).Hash -ine $Data.expectedSha256) {throw 'Application identity changed; create a new shortcut after updating the application.'}
    $stream=[IO.File]::OpenRead($Data.executable);$reader=New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 128 -or $reader.ReadUInt16() -ne 0x5a4d) {throw 'Invalid Windows executable.'}
        $stream.Position=0x3c;$offset=$reader.ReadUInt32()
        if($offset -gt 1048576 -or $offset+6 -gt $stream.Length){throw 'Invalid PE header.'}
        $stream.Position=$offset
        if($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664){throw 'This launcher currently supports native x64 applications only.'}
    } finally {$reader.Dispose()}
}
function New-HeliosApplicationShortcut([string]$Executable,[string]$Mode) {
    $data=[ordered]@{schema=1;executable=$Executable;mode=$Mode;argumentLine='';expectedSha256=(Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash}
    Assert-HeliosApplication $data
    [void](New-HeliosApplicationStartInfo $Executable $Mode)
    $root=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WinBoat\HeliosProfiles'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $file=Join-Path $root ([guid]::NewGuid().ToString('N')+'.json')
    $data | ConvertTo-Json | Set-Content -LiteralPath $file -Encoding UTF8
    $link=Join-Path ([Environment]::GetFolderPath('Desktop')) ('Helios - '+[IO.Path]::GetFileNameWithoutExtension($Executable)+' - '+$Mode+'.lnk')
    $shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($link)
    $shortcut.TargetPath="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Start-HeliosApplication.ps1')+'" -ProfileFile "'+$file+'"'
    # No run-as flag: launch this shortcut from the ordinary Windows desktop.
    $shortcut.Save()
    return @{status='shortcut-created';profile=$Mode;scope='One application process; registry and DWM are unchanged. Launch from the normal desktop.'}
}
if ($LibraryOnly) {return}
if ([Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0 -or -not [Environment]::Is64BitProcess) {throw 'Use native 64-bit PowerShell in the interactive desktop.'}
$data=Read-HeliosValidationJson $ProfileFile
Assert-HeliosApplication $data
$process=[Diagnostics.Process]::Start((New-HeliosApplicationStartInfo $data.executable $data.mode $data.argumentLine))
Write-Output ('Started process '+$process.Id+' with '+$data.mode)

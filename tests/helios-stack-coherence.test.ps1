Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../guest_server/scripts/Assert-HeliosStackCoherence.ps1" -LibraryOnly
if($env:OS -ne 'Windows_NT'){Write-Host 'Windows paths require the Windows CI job.';return}
$root=Join-Path ([IO.Path]::GetTempPath()) ('helios-coherence-'+[guid]::NewGuid().ToString('N'))
try {
    $driver=Join-Path $root 'DriverStore\test';$runtime=Join-Path $root 'Helios\package'
    New-Item -ItemType Directory -Path $driver -Force | Out-Null
    $files=@('helios_kmd_render.sys','helios_umd.dll','helios_umd12.dll','helios_umd32.dll','helios_umd12_32.dll')
    $state=[pscustomobject]@{version='22.22.299.0';installRoot=$runtime;driverFiles=@();runtimeFiles=@()}
    foreach($name in $files) {
        $path=Join-Path $driver $name;[IO.File]::WriteAllText($path,$name)
        $state.driverFiles+=@{name=$name;sha256=(Get-FileHash $path).Hash}
    }
    $reg=[pscustomobject]@{DriverVersion=$state.version;UserModeDriverName=@();UserModeDriverNameWoW=@()}
    foreach($i in 0..3) {
        $reg.UserModeDriverName+=Join-Path $driver $(if($i -eq 3){'helios_umd12.dll'}else{'helios_umd.dll'})
        $reg.UserModeDriverNameWoW+=Join-Path $driver $(if($i -eq 3){'helios_umd12_32.dll'}else{'helios_umd32.dll'})
    }
    $apis=@{VulkanDriverName='runtime\mesa\helios_vulkan.json';VulkanDriverNameWow='runtime\mesa\x86\helios_vulkan.json';OpenGLDriverName='runtime\mesa\libgallium_wgl.dll';OpenGLDriverNameWow='runtime\mesa\x86\libgallium_wgl.dll'}
    foreach($name in $apis.Keys){$reg | Add-Member NoteProperty $name (Join-Path $runtime $apis[$name])}
    foreach($relative in (@($apis.Values)+@('runtime\mesa\vulkan_virtio.dll','runtime\mesa\x86\vulkan_virtio.dll'))) {
        $path=Join-Path $runtime $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path,$relative)
        $state.runtimeFiles+=@{path=$path;sha256=(Get-FileHash $path).Hash}
    }
    function Check {Assert-HeliosStackRecords $state $reg (Join-Path $root 'DriverStore') (Join-Path $root 'Helios')}
    function Reject { $caught=$false;try {Check | Out-Null} catch {$caught=$true};if(-not $caught){throw 'Incoherent package passed'} }
    if((Check).status -ne 'coherent'){throw 'Complete real hashed package refused'}
    $reg.DriverVersion='22.22.294.0';Reject;$reg.DriverVersion=$state.version
    $old=$reg.VulkanDriverName;$reg.VulkanDriverName='C:\other\helios_vulkan.json';Reject;$reg.VulkanDriverName=$old
    $old=$reg.UserModeDriverNameWoW[3];$reg.UserModeDriverNameWoW[3]=$reg.UserModeDriverNameWoW[0];Reject;$reg.UserModeDriverNameWoW[3]=$old
    $state.runtimeFiles+=@{path=$reg.VulkanDriverName;sha256=(Get-FileHash $reg.VulkanDriverName).Hash};Reject
    $state.runtimeFiles=@($state.runtimeFiles)[0..5]
    [IO.File]::AppendAllText((Join-Path $driver 'helios_umd.dll'),'changed');Reject
    Write-Host 'Activation gate checks actual hashes, mixed versions, API paths, WoW64 entries and duplicate receipts.'
} finally {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}

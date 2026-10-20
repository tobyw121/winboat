# Read-only, explicit activation gate. No PnP changes or executable package scripts.
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Assert-HeliosRecordedFile([string]$Path,[string]$Hash,[string]$Root) {
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $Hash -notmatch '^[a-fA-F0-9]{64}$') {throw 'Package file lies outside its trusted root.'}
    $cursor=$full
    while($cursor -and $cursor.Length -ge $Root.Length) {
        if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Package path contains a reparse point.'}
        $cursor=Split-Path -Parent $cursor
    }
    if((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ine $Hash){throw 'Package file checksum mismatch.'}
}
function Assert-HeliosStackRecords($State,$Registry,[string]$DriverRoot,[string]$RuntimeRoot) {
    if([string]$State.version -notmatch '^22\.22\.[0-9]{1,5}\.0$' -or [string]$Registry.DriverVersion -ine [string]$State.version){throw 'Bound driver and runtime package versions differ.'}
    $names=@('helios_kmd_render.sys','helios_umd.dll','helios_umd12.dll','helios_umd32.dll','helios_umd12_32.dll')
    if(@($State.driverFiles).Count -ne 5 -or @($State.runtimeFiles).Count -lt 4 -or @($State.runtimeFiles).Count -gt 512){throw 'Incomplete package receipt.'}
    $native=@($Registry.UserModeDriverName);$wow=@($Registry.UserModeDriverNameWoW)
    if($native.Count -ne 4 -or $wow.Count -ne 4){throw 'Direct3D registration is incomplete.'}
    $base=Split-Path -Parent ([string]$native[0])
    foreach($name in $names) {
        $entry=@($State.driverFiles | Where-Object {$_.name -ieq $name})
        if($entry.Count -ne 1){throw 'Duplicate or missing driver receipt.'}
        Assert-HeliosRecordedFile (Join-Path $base $name) ([string]$entry[0].sha256) $DriverRoot
    }
    foreach($index in 0..3) {
        $n=if($index -eq 3){'helios_umd12.dll'}else{'helios_umd.dll'}
        $w=if($index -eq 3){'helios_umd12_32.dll'}else{'helios_umd32.dll'}
        if([string]$native[$index] -ine (Join-Path $base $n) -or [string]$wow[$index] -ine (Join-Path $base $w)){throw 'Direct3D registrations point at mixed packages.'}
    }
    foreach($entry in @($State.runtimeFiles)) {Assert-HeliosRecordedFile ([string]$entry.path) ([string]$entry.sha256) $RuntimeRoot}
    $registrations=@{
        VulkanDriverName='runtime\mesa\helios_vulkan.json';VulkanDriverNameWow='runtime\mesa\x86\helios_vulkan.json'
        OpenGLDriverName='runtime\mesa\libgallium_wgl.dll';OpenGLDriverNameWow='runtime\mesa\x86\libgallium_wgl.dll'
    }
    foreach($name in $registrations.Keys) {
        $expected=Join-Path ([string]$State.installRoot) $registrations[$name]
        $values=@($Registry.$name)
        if($values.Count -ne 1 -or [string]$values[0] -ine $expected){throw 'API registration points at another runtime.'}
        if(@($State.runtimeFiles | Where-Object {$_.path -ieq $expected}).Count -ne 1){throw 'Registered API file has no unique package receipt.'}
    }
    foreach($relative in @('runtime\mesa\vulkan_virtio.dll','runtime\mesa\x86\vulkan_virtio.dll')) {
        $path=Join-Path ([string]$State.installRoot) $relative
        if(@($State.runtimeFiles | Where-Object {$_.path -ieq $path}).Count -ne 1){throw 'Vulkan ICD has no unique package receipt.'}
    }
    return @{status='coherent';version=[string]$State.version;scope='Recorded hashes, bound package and API paths; no rendering proof.'}
}
function Assert-HeliosStackCoherence {
    $path=Join-Path $env:ProgramData 'Helios\install-state.json'
    $file=Get-Item -LiteralPath $path -Force
    if($file.Length -gt 262144 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Invalid installed package receipt.'}
    $state=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $devices=@(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" | Where-Object {$_.Present -and $_.PNPDeviceID -like 'PCI\VEN_1AF4&DEV_1050*' -and $_.Service -eq 'helios_kmd_render'})
    if($devices.Count -ne 1){throw 'Unique bound Helios device unavailable.'}
    $driver=(Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\'+$devices[0].PNPDeviceID)).Driver
    if($driver -notmatch '^\{4d36e968-e325-11ce-bfc1-08002be10318\}\\[0-9]{4}$'){throw 'Invalid display class key.'}
    $key='HKLM:\SYSTEM\CurrentControlSet\Control\Class\'+$driver
    if([string]$state.classKey -ine $key){throw 'Package receipt is for another device binding.'}
    $registry=Get-ItemProperty -LiteralPath $key
    return Assert-HeliosStackRecords $state $registry (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository') (Join-Path $env:ProgramFiles 'Helios')
}
if($LibraryOnly){return}
Assert-HeliosStackCoherence | ConvertTo-Json -Compress

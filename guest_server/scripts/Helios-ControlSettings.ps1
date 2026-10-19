. (Join-Path $PSScriptRoot 'Helios-ValidationCommon.ps1')
$script:heliosOptions=@('UmdD3D12','UmdCommandLists','UmdFreeThreaded','UmdAsyncPresentStream','UmdPresentBatchFold')
function Get-HeliosControlSettings {
    $key=Get-Item -LiteralPath 'HKLM:\SOFTWARE\Helios' -ErrorAction SilentlyContinue
    $result=[ordered]@{}
    foreach($name in $script:heliosOptions) {
        $value=$null
        if ($null -ne $key -and $key.GetValueNames() -contains $name) {
            if ($key.GetValueKind($name) -ne 'DWord') {throw "Unsupported registry type: $name"}
            $value=[int]$key.GetValue($name)
            if ($value -notin @(0,1)) {throw "Nonstandard option value must be reviewed before editing: $name"}
        }
        $result[$name]=$value
    }
    return $result
}
function Set-HeliosControlSettings($Values) {
    # Validate all fields before writing the first option. Unknown settings,
    # especially machine-wide Vulkan ICD removal, are never accepted here.
    if (@($Values.Keys).Count -ne $script:heliosOptions.Count) {throw 'Incomplete driver option set.'}
    foreach($name in $Values.Keys) {
        if ($name -notin $script:heliosOptions -or ($null -ne $Values[$name] -and $Values[$name] -notin @(0,1))) {throw 'Unsupported driver option.'}
    }
    $previous=Get-HeliosControlSettings
    $root=Initialize-HeliosValidationRoot
    $snapshot=Join-Path $root 'settings-before.json'
    if (-not (Test-Path -LiteralPath $snapshot)) {
        # CreateNew avoids following a pre-existing user-controlled target.
        $stream=[IO.File]::Open($snapshot,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $bytes=[Text.Encoding]::UTF8.GetBytes(($previous | ConvertTo-Json))
            $stream.Write($bytes,0,$bytes.Length)
        } finally {$stream.Dispose()}
    }
    if (-not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Helios')) {New-Item -Path 'HKLM:\SOFTWARE\Helios' | Out-Null}
    try {
        foreach($name in $script:heliosOptions) {
            if ($null -eq $Values[$name]) {Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Helios' -Name $name -ErrorAction SilentlyContinue}
            else {New-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Helios' -Name $name -Value ([int]$Values[$name]) -PropertyType DWord -Force | Out-Null}
        }
    } catch {
        foreach($name in $script:heliosOptions) {
            if ($null -eq $previous[$name]) {Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Helios' -Name $name -ErrorAction SilentlyContinue}
            else {New-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Helios' -Name $name -Value $previous[$name] -PropertyType DWord -Force | Out-Null}
        }
        throw
    }
    return @{status='restart-required';message='Options are read per driver process. Restart Windows explicitly before testing.'}
}

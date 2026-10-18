param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'guest_server/scripts/Get-HeliosApplicationDiagnostics.ps1') -LibraryOnly
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('helios-feature-' + [guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllText($temporary, ('x' * 16000) + "`npid=12 VkPhysicalDeviceVulkan12Features.timelineSemaphore not supported`npid=13 PASSWORD=secret not supported`n")
    $failures = @(Read-HeliosFeatureFailures $temporary)
    if ($failures.Count -ne 1 -or $failures[0].processId -ne 12 -or $failures[0].feature -ne 'VkPhysicalDeviceVulkan12Features.timelineSemaphore') { throw 'Bounded feature parsing failed' }
    $entry = [pscustomobject]@{ TimeCreated=[DateTime]::UtcNow }
    $entry | Add-Member ScriptMethod ToXml { '<Event><EventData><Data Name="AppName">furmark.exe</Data><Data Name="ModuleName">plugin_gxc_vulkan2_x64.dll</Data><Data Name="ExceptionCode">c0000005</Data><Data Name="FaultingOffset">11444</Data><Data Name="AppPath">secret-command-line</Data></EventData></Event>' }
    $crash = Convert-HeliosCrashEvent $entry
    if ($crash.AppName -ne 'furmark.exe' -or $crash.ExceptionCode -ne 'c0000005' -or ($crash | ConvertTo-Json) -match 'secret') { throw 'Crash field filtering failed' }
    $entry | Add-Member ScriptMethod ToXml { '<Event><EventData><Data Name="AppName">unrelated.exe</Data><Data Name="ModuleName">unrelated.dll</Data></EventData></Event>' } -Force
    if ($null -ne (Convert-HeliosCrashEvent $entry)) { throw 'Unrelated app captured' }
    # Failed/missing Windows facilities must not erase the other diagnostics.
    function Get-CimInstance { throw 'fixture unavailable' }
    function Get-WinEvent { throw 'fixture unavailable' }
    $before=$env:ProgramData; $env:ProgramData=Split-Path $temporary
    try { $report=Get-HeliosApplicationDiagnostics } finally { $env:ProgramData=$before }
    if ($report.errors.Count -ne 3 -or $report.crashes.Count -or $report.rejectedFeatures.Count) { throw 'Unavailable sections were not reported independently' }
    $root = $temporary + '-profile'
    New-Item -ItemType Directory -Path (Join-Path $root 'Helios'),(Join-Path $root 'AppData/Local') -Force | Out-Null
    try {
        $adapterKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0001'
        @{classKey=$adapterKey} | ConvertTo-Json | Set-Content (Join-Path $root 'Helios/install-state.json')
        Copy-Item $temporary (Join-Path $root 'AppData/Local/helios-vulkan-features.log')
        $registry = [pscustomobject]@{}
        $registry | Add-Member ScriptMethod GetValue { param($Name,$Default) return @('C:\Helios\driver.dll') }
        function Get-Item { param($LiteralPath)
            if ($LiteralPath -eq $adapterKey) { return $registry }
            return Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath
        }
        function Get-CimInstance { param($ClassName) return [pscustomobject]@{Loaded=$true;Special=$false;LocalPath=$root} }
        function Get-WinEvent { return @() }
        function Get-Process { return [pscustomobject]@{Id=12;ProcessName='furmark';Modules=@(
            [pscustomobject]@{ModuleName='helios_umd.dll';FileName='C:\Helios\helios_umd.dll';FileVersionInfo=[pscustomobject]@{FileVersion='22.22.292.0'}},
            [pscustomobject]@{ModuleName='unrelated.dll';FileName='private';FileVersionInfo=[pscustomobject]@{FileVersion='private'}})} }
        $before=$env:ProgramData; $env:ProgramData=$root
        try { $report=Get-HeliosApplicationDiagnostics } finally { $env:ProgramData=$before }
        if ($report.errors.Count -or $report.apiRegistration.Count -ne 6 -or $report.rejectedFeatures.Count -ne 1 -or $report.loadedApplications[0].modules.Count -ne 1) { throw 'Combined registry/profile/module collection failed' }
        if (($report | ConvertTo-Json -Depth 8) -match 'private|unrelated') { throw 'Non-graphics module data leaked' }
        $registry | Add-Member ScriptMethod GetValue { param($Name,$Default) return (@(([char]0x754c).ToString() * 2000) * 4) } -Force
        $before=$env:ProgramData; $env:ProgramData=$root
        try { $limited=Get-HeliosApplicationDiagnostics } finally { $env:ProgramData=$before }
        if ([Text.Encoding]::UTF8.GetByteCount(($limited | ConvertTo-Json -Depth 8 -Compress)) -gt 24576 -or
            -not ($limited.errors -match 'size limit reached')) { throw 'Combined diagnostic size budget was not enforced' }

    } finally { Remove-Item $root -Recurse -Force }
    Write-Host 'Bounded feature logs, crash allowlist, secret exclusion, partial failures and combined API/module collection passed.'
} finally { Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue }

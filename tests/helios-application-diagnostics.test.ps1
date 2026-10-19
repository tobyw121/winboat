param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'guest_server/scripts/Get-HeliosApplicationDiagnostics.ps1') -LibraryOnly
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('helios-feature-' + [guid]::NewGuid().ToString('N'))
try {
    $prefix='[pid=1484 tid=12] '
    [IO.File]::WriteAllText($temporary, $prefix+"UMD module: secret-old-path`n"+$prefix+"  CreateDevice: DXVK device creation FAILED -> E_FAIL`n"+
        $prefix+"UMD module: secret-new-path`n"+$prefix+"open_adapter_common interface=0x12345678`n"+
        $prefix+"  CreateDevice -> S_OK (DXVK device + D3D11 funcs table installed)`n"+
        "[dxvk-bridge] producer: stream initialization FAILED (VK_ERROR_DEVICE_LOST secret-user-path)`n"+
        "private-command HRESULT=0x80004005`n")
    $summary=Read-HeliosUmdSummary $temporary
    if (-not $summary.moduleBoundaryFound -or $summary.signals.Count -ne 3 -or
        $summary.signals.kind -contains 'device-create-failed' -or $summary.codes -notcontains 'VK_ERROR_DEVICE_LOST' -or
        $summary.codes -notcontains 'HRESULT=0x80004005' -or ($summary | ConvertTo-Json -Depth 6) -match 'secret|private') {throw 'UMD generation/allowlist filtering failed'}
    [IO.File]::WriteAllText($temporary, $prefix+"UMD module: old`n"+('x'*66000)+"`n"+$prefix+"  CreateDevice: DXVK device creation FAILED -> E_FAIL`n")
    $summary=Read-HeliosUmdSummary $temporary
    if (-not $summary.tailTruncated -or $summary.moduleBoundaryFound -or $summary.tailBytes -gt 65536 -or
        $summary.signals[0].kind -ne 'device-create-failed') {throw 'UMD tail bound/unknown generation failed'}
    $journal=$prefix+"GPU-DIAG device=3 birth=123456 elapsed_ms=8 queries=300 mismatches=1`n"+
        $prefix+"GPU-DIAG mismatch device=3 birth=123456 fmt=28 samples=4 flags=0 levels=0 hr=0x00000000`n"
    foreach ($i in 1..30) {$journal+=$prefix+"GPU-DIAG event device=3 birth=123456 seq=$i kind=msaa a=28 b=4 c=0 d=0 e=0 f=1`n"}
    $journal+=$prefix+"GPU-DIAG event device=99 birth=987 seq=1 kind=shader a=0 b=0 c=0 d=0 e=0 f=0`n"
    $journal+=$prefix+"GPU-DIAG event device=3 birth=123456 seq=31 kind=secret a=0 b=0 c=0 d=0 e=0 f=0`n"
    $parsed=Read-HeliosGpuJournal $journal
    if ($parsed.events.Count -ne 16 -or $parsed.events[0].seq -ne '15' -or
        $parsed.firstMismatch.format -ne '28' -or ($parsed | ConvertTo-Json -Depth 8) -match 'secret|987') {throw 'Journal generation/field bounds failed'}
    [IO.File]::WriteAllText($temporary, ('x' * 16000) + "`npid=12 VkPhysicalDeviceVulkan12Features.timelineSemaphore not supported`npid=13 PASSWORD=secret not supported`n")
    $failures = @(Read-HeliosFeatureFailures $temporary)
    if ($failures.Count -ne 1 -or $failures[0].processId -ne 12 -or $failures[0].feature -ne 'VkPhysicalDeviceVulkan12Features.timelineSemaphore') { throw 'Bounded feature parsing failed' }
    $entry = [pscustomobject]@{ TimeCreated=[DateTime]::UtcNow }
    $entry | Add-Member ScriptMethod ToXml { '<Event><EventData><Data Name="AppName">furmark.exe</Data><Data Name="ModuleName">plugin_gxc_vulkan2_x64.dll</Data><Data Name="ExceptionCode">c0000005</Data><Data Name="FaultingOffset">11444</Data><Data Name="AppPath">secret-command-line</Data><Data Name="PackageFullName" /></EventData></Event>' }
    $crash = Convert-HeliosCrashEvent $entry
    if ($crash.AppName -ne 'furmark.exe' -or $crash.ExceptionCode -ne 'c0000005' -or ($crash | ConvertTo-Json) -match 'secret') { throw 'Crash field filtering failed' }
    $entry | Add-Member ScriptMethod ToXml { '<Event><EventData><Data Name="AppName">dwm.exe</Data><Data Name="ModuleName">d3d11.dll</Data><Data Name="ExceptionCode">c0000005</Data><Data Name="AppPath">secret-desktop-path</Data></EventData></Event>' } -Force
    $desktopCrash = Convert-HeliosCrashEvent $entry
    if ($desktopCrash.AppName -ne 'dwm.exe' -or $desktopCrash.ModuleName -ne 'd3d11.dll' -or ($desktopCrash | ConvertTo-Json) -match 'secret') { throw 'Desktop crash filtering failed' }
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
        [IO.File]::WriteAllText((Join-Path $root 'Helios/umd-1484.log'),$prefix+"  CreateDevice: DXVK device creation FAILED -> E_FAIL`n")
        [IO.File]::WriteAllText((Join-Path $root 'Helios/umd-private.log'),'secret')
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
        if ($report.errors.Count -or $report.apiRegistration.Count -ne 6 -or $report.rejectedFeatures.Count -ne 1 -or $report.loadedApplications[0].modules.Count -ne 1 -or
            $report.umdLogs.Count -ne 1 -or $report.umdLogs[0].signals[0].kind -ne 'device-create-failed') { throw 'Combined registry/profile/module/UMD collection failed' }
        if (($report | ConvertTo-Json -Depth 8) -match 'private|unrelated') { throw 'Non-graphics module data leaked' }
        $probeFile=Join-Path $root 'Helios/device-probe-result.json'
        @{schema=1;profileScope='child-process';probeVersion='22.22.296.0';probeSha256=('a'*64);registryRestored=$true;
          startedAtUtc=[DateTime]::UtcNow.ToString('o');finishedAtUtc=[DateTime]::UtcNow.ToString('o');private='secret';
          arms=@(@{mode=1;processId=1234;timedOut=$false;exitCode=1;results=@(@{schema=1;warp=$false;requested=45056;achieved=0;flags=0;hr=2289696772;private='secret'})})} |
            ConvertTo-Json -Depth 8 | Set-Content $probeFile
        $before=$env:ProgramData; $env:ProgramData=$root
        try {$probe=Get-HeliosDeviceProbeDiagnostics} finally {$env:ProgramData=$before}
        if ($probe.arms[0].results[0].hr -ne 2289696772 -or ($probe | ConvertTo-Json -Depth 8) -match 'secret|private') {throw 'Outer HRESULT/probe allowlist failed'}
        [IO.File]::WriteAllText($probeFile, 'x'*33000)
        $before=$env:ProgramData; $env:ProgramData=$root
        try {$probe=Get-HeliosDeviceProbeDiagnostics} finally {$env:ProgramData=$before}
        if ($probe.error -notmatch 'invalid') {throw 'Oversized probe result accepted'}
        Remove-Item $probeFile
        $registry | Add-Member ScriptMethod GetValue { param($Name,$Default) return (@(([char]0x754c).ToString() * 2000) * 4) } -Force
        $before=$env:ProgramData; $env:ProgramData=$root
        try { $limited=Get-HeliosApplicationDiagnostics } finally { $env:ProgramData=$before }
        if ([Text.Encoding]::UTF8.GetByteCount(($limited | ConvertTo-Json -Depth 8 -Compress)) -gt 24576 -or
            -not ($limited.errors -match 'size limit reached')) { throw 'Combined diagnostic size budget was not enforced' }

    } finally { Remove-Item $root -Recurse -Force }
    Write-Host 'Bounded feature logs, crash allowlist, secret exclusion, partial failures and combined API/module collection passed.'
} finally { Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue }

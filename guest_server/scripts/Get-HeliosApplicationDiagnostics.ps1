# Read-only, on demand: fixed registry fields and bounded application failures.
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Get-HeliosUmdDiagnostics.ps1')
function Read-HeliosFeatureFailures([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $start = [Math]::Max(0, $stream.Length - 8192)
        [void]$stream.Seek($start, 'Begin')
        $bytes = New-Object byte[] 8192
        $count = $stream.Read($bytes, 0, $bytes.Length)
        $text = [Text.Encoding]::UTF8.GetString($bytes, 0, $count)
        $featureMatches = [regex]::Matches($text, '(?m)^pid=(\d{1,10}) (VkPhysicalDevice[A-Za-z0-9_.]{1,160}) not supported\r?$')
        return @($featureMatches | Select-Object -Last 12 | ForEach-Object {
            [ordered]@{ processId=[long]$_.Groups[1].Value; feature=$_.Groups[2].Value }
        })
    } finally { $stream.Dispose() }
}
function Convert-HeliosCrashEvent($Event) {
    $xml = [xml]$Event.ToXml()
    $data = @{}
    foreach ($entry in @($xml.Event.EventData.Data)) { $data[$entry.GetAttribute('Name')] = [string]$entry.InnerText }
    $app = [string]$data['AppName']; $module = [string]$data['ModuleName']
    if ($app -notmatch '(?i)(furmark|icarus|^(client|dwm)\.exe$)' -and
        $module -notmatch '(?i)^(helios_umd.*|vulkan_virtio|plugin_gxc_vulkan.*)\.dll$') { return $null }
    $result = [ordered]@{ timeUtc=$Event.TimeCreated.ToUniversalTime().ToString('o') }
    foreach ($name in @('AppName','ModuleName','ExceptionCode','FaultingOffset','ProcessId')) {
        $value = [string]$data[$name]
        $result[$name] = $value.Substring(0, [Math]::Min(256, $value.Length))
    }
    return $result
}
function Get-HeliosApplicationDiagnostics {
    $errors = @(); $registration = @(); $features = @(); $crashes = @(); $loaded = @()
    try {
        $path = Join-Path $env:ProgramData 'Helios/install-state.json'
        if ((Get-Item -LiteralPath $path).Length -gt 1048576) { throw 'Oversized state' }
        $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $key = [string]$state.classKey
        if ($key -notmatch '^HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Class\\\{4d36e968-e325-11ce-bfc1-08002be10318\}\\\d{4}$') { throw 'Invalid adapter key' }
        $item = Get-Item -LiteralPath $key
        foreach ($name in @('UserModeDriverName','UserModeDriverNameWoW','VulkanDriverName','VulkanDriverNameWow','OpenGLDriverName','OpenGLDriverNameWow')) {
            $values = @($item.GetValue($name, $null) | Select-Object -First 4 | ForEach-Object {
                $text=[string]$_; $text.Substring(0, [Math]::Min(512, $text.Length))
            })
            $registration += [ordered]@{ name=$name; values=$values }
        }
    } catch { $errors += 'Adapter API registration unavailable' }
    try {
        # The service runs as SYSTEM; application feature logs belong to the
        # logged-in user profiles. Never read arbitrary application log files.
        $profiles = @(Get-CimInstance Win32_UserProfile | Where-Object { $_.Loaded -and -not $_.Special } | Select-Object -First 4)
        foreach ($userProfile in $profiles) {
            $path = Join-Path ([string]$userProfile.LocalPath) 'AppData/Local/helios-vulkan-features.log'
            $features += @(Read-HeliosFeatureFailures $path)
        }
    } catch { $errors += 'Application feature log unavailable' }
    try {
        $events = @(Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000;StartTime=(Get-Date).AddDays(-1)} -MaxEvents 64)
        $crashes = @($events | ForEach-Object { Convert-HeliosCrashEvent $_ } | Where-Object { $null -ne $_ } | Select-Object -First 8)
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { $errors += 'Application crash events unavailable' }
    }
    try {
        foreach ($appProcess in @(Get-Process -Name 'furmark','icarus*','client','dwm' -ErrorAction SilentlyContinue | Select-Object -First 4)) {
            $modules = @($appProcess.Modules | Where-Object { $_.ModuleName -match '^(helios_umd.*|vulkan_virtio|vulkan-1|libgallium_wgl|d3d9|d3d11|d3d12|dxgi)\.dll$' } | Select-Object -First 6 | ForEach-Object {
                $path = [string]$_.FileName; $version = [string]$_.FileVersionInfo.FileVersion
                [ordered]@{ name=[string]$_.ModuleName; path=$path.Substring(0,[Math]::Min(384,$path.Length)); version=$version.Substring(0,[Math]::Min(64,$version.Length)) }
            })
            $loaded += [ordered]@{ processId=$appProcess.Id; name=$appProcess.ProcessName; modules=$modules }
        }
    } catch { $errors += 'Loaded application modules unavailable' }
    $umd=@()
    try {$umd=@(Get-HeliosUmdDiagnostics)} catch {$errors+='Helios UMD log summaries unavailable'}
    $report = [ordered]@{ apiRegistration=$registration; rejectedFeatures=$features; crashes=$crashes; loadedApplications=$loaded; umdLogs=$umd;
        umdCorrelation='Recent PID files; may precede the current process. Signals and codes only; no signal is not proof of success.';
        featureCorrelation='PID only; entries may precede the current process'; errors=$errors }
    # Keep this extension below the existing guest API's overall 64 KiB limit.
    # Prefer recent feature/crash details over older registry/module records.
    $limited = $false
    foreach ($section in @('loadedApplications','apiRegistration','crashes','rejectedFeatures','umdLogs')) {
        while ([Text.Encoding]::UTF8.GetByteCount(($report | ConvertTo-Json -Depth 8 -Compress)) -gt 24000 -and @($report[$section]).Count) {
            $limited = $true
            $report[$section] = @($report[$section] | Select-Object -SkipLast 1)
        }
    }
    if ($limited) { $report.errors += 'Application diagnostic size limit reached; some records omitted' }
    return $report
}
if (-not $LibraryOnly) { Get-HeliosApplicationDiagnostics | ConvertTo-Json -Depth 8 -Compress }

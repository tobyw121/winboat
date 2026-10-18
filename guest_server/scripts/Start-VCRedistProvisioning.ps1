# Install Microsoft's side-by-side runtimes after Windows/AME/Helios setup.
param([switch]$Register, [switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Get-WinBoatFileSha256.ps1')

function Get-VCRedistPackages {
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'vcredist-packages.json') -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.revision -ne 'vcredist-v1' -or $manifest.packages.Count -ne 10) {
        throw 'Unsupported Visual C++ runtime manifest.'
    }
    foreach ($package in $manifest.packages) {
        $uri = [Uri]$package.url
        if ($uri.Scheme -ne 'https' -or $uri.Host -notin @('download.microsoft.com', 'download.visualstudio.microsoft.com') -or
            $package.sha256 -notmatch '^[a-f0-9]{64}$' -or $package.id -notmatch '^(2008|2010|2012|2013|2015\+)-x(86|64)$') {
            throw 'Invalid Visual C++ runtime source.'
        }
    }
    return $manifest.packages
}

function Get-VCRedistInstalledEntries {
    # Never query Win32_Product: it can trigger MSI repairs of unrelated apps.
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        try {
            $uninstall = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if ($null -eq $uninstall) { continue }
            try {
                foreach ($name in $uninstall.GetSubKeyNames()) {
                    $key = $uninstall.OpenSubKey($name)
                    if ($null -eq $key) { continue }
                    try {
                        [pscustomobject]@{ productCode=$name; name=[string]$key.GetValue('DisplayName');
                            publisher=[string]$key.GetValue('Publisher'); version=[string]$key.GetValue('DisplayVersion') }
                    } finally { $key.Dispose() }
                }
            } finally { $uninstall.Dispose() }
        } finally { $base.Dispose() }
    }
}

function Test-VCRedistInstalled($Package, $Entries) {
    $required = ConvertTo-VCRedistVersion $Package.version
    foreach ($entry in $Entries) {
        try { $version = ConvertTo-VCRedistVersion $entry.version } catch { continue }
        if ($version -lt $required) { continue }
        if ($entry.productCode -eq $Package.productCode) { return $true }
        # Burn bundle product codes change between updates. A newer compatible
        # v14 bundle must be kept, including the current 2015-2026 naming.
        $family = [regex]::Escape($Package.family)
        if ($Package.family -eq '2015+') { $family = '(?:2015(?:\s*-\s*20\d\d)?|v14)' }
        $arch = [regex]::Escape($Package.architecture)
        if ($entry.publisher -eq 'Microsoft Corporation' -and
            $entry.name -match ('^Microsoft Visual C\+\+ '+$family+' Redistributable.*\b'+$arch+'\b')) { return $true }
    }
    return $false
}

function ConvertTo-VCRedistVersion([string]$Value) {
    $parsed = [Version]$Value.TrimStart('v', 'V')
    return [Version]::new($parsed.Major, $parsed.Minor, [Math]::Max(0, $parsed.Build), [Math]::Max(0, $parsed.Revision))
}

function Get-VCRedistWaitReason([string]$Install, [string]$Data) {
    # All modes use the same worker; never race AME's playbook or driver setup.
    $atlas = Join-Path $Data 'WinBoat\Atlas'
    $checks = @()
    if ((Test-Path -LiteralPath (Join-Path $Install 'atlas-enabled')) -or
        (Test-Path -LiteralPath (Join-Path $atlas 'oobe-mode.json'))) {
        $checks += [pscustomobject]@{path=(Join-Path $atlas 'status.json'); name='AME/Atlas'}
    }
    if ((Test-Path -LiteralPath (Join-Path $Install 'helios-enabled')) -or
        (Test-Path -LiteralPath (Join-Path $Data 'WinBoat\Helios\helios-build.json'))) {
        $checks += [pscustomobject]@{path=(Join-Path $Data 'Helios\provisioning-status.json'); name='Helios'}
    }
    foreach ($check in $checks) {
        if (-not (Test-Path -LiteralPath $check.path)) { return ('Waiting for '+$check.name+' provisioning.') }
        $state = Get-Content -LiteralPath $check.path -Raw | ConvertFrom-Json
        if ($state.status -ne 'finished') { return ('Waiting for '+$check.name+' provisioning: '+$state.status) }
    }
    return ''
}

function Get-VCRedistInstaller($Package, [string]$Cache) {
    $target = Join-Path $Cache ($Package.id+'.exe')
    if ((Test-Path -LiteralPath $target) -and (Get-WinBoatFileSha256 $target) -ne $Package.sha256) {
        Remove-Item -LiteralPath $target -Force
    }
    if (-not (Test-Path -LiteralPath $target)) {
        $partial = $target+'.download'
        try {
            # Windows PowerShell 5.1 on older images does not default to TLS 1.2.
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $Package.url -OutFile $partial -UseBasicParsing -TimeoutSec 180 | Out-Null
            if ((Get-WinBoatFileSha256 $partial) -ne $Package.sha256) { throw ('SHA-256 mismatch: '+$Package.id) }
            Move-Item -LiteralPath $partial -Destination $target -Force
        } finally { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $target
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw ('Invalid Microsoft installer signature: '+$Package.id)
    }
    return $target
}

function Invoke-VCRedistPackages($Packages, [string]$Cache) {
    $result = @(); $reboot = $false
    foreach ($package in $Packages) {
        if (Test-VCRedistInstalled $package @(Get-VCRedistInstalledEntries)) {
            $result += @{id=$package.id; status='already-installed'}
            continue
        }
        $installer = Get-VCRedistInstaller $package $Cache
        $process = Start-Process -FilePath $installer -ArgumentList $package.arguments -Wait -PassThru
        if ($process.ExitCode -notin @(0, 3010, 1638, -2147023258)) {
            throw ('Installer '+$package.id+' failed with exit code '+$process.ExitCode+'. It will be retried.')
        }
        # 1638 / HRESULT 0x80070666 alone never proves a suitable runtime exists.
        if (-not (Test-VCRedistInstalled $package @(Get-VCRedistInstalledEntries))) {
            throw ('Installer '+$package.id+' did not register the required runtime.')
        }
        if ($process.ExitCode -eq 3010) { $reboot = $true }
        $result += @{id=$package.id; status='installed'; exitCode=$process.ExitCode}
    }
    return @{packages=@($result); rebootRequired=$reboot}
}

if ($LibraryOnly) { return }
$root = Join-Path $env:ProgramData 'WinBoat\VCRedist'
$install = Split-Path -Parent $PSScriptRoot
$taskName = 'WinBoatVCRedistProvisioning'
function Publish-VCRedist([string]$Status, [string]$Message, $Result) {
    $state = @{revision='vcredist-v1'; status=$Status; message=$Message; updatedAtUtc=[DateTime]::UtcNow.ToString('o')}
    if ($null -ne $Result) { $state.packages=$Result.packages; $state.rebootRequired=$Result.rebootRequired }
    $path = Join-Path $root 'status.json'
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath ($path+'.tmp') -Encoding UTF8
    Move-Item -LiteralPath ($path+'.tmp') -Destination $path -Force
}
try {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Visual C++ provisioning requires an elevated Windows session.'
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    # The task runs as SYSTEM. Ordinary users may read status, never replace EXEs.
    & icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot protect Visual C++ installer storage.' }
    $packages = @(Get-VCRedistPackages)
    if ($Register) {
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($null -ne $existing -and $existing.State.ToString() -eq 'Running') { return }
        $missing = @($packages | Where-Object { -not (Test-VCRedistInstalled $_ @(Get-VCRedistInstalledEntries)) })
        if ($missing.Count -eq 0) {
            # Preserve the receipt of the completed run (including its 3010).
            $previous = $null
            if (Test-Path -LiteralPath (Join-Path $root 'status.json')) {
                try { $previous = Get-Content -LiteralPath (Join-Path $root 'status.json') -Raw | ConvertFrom-Json } catch { $previous = $null }
            }
            if ($null -eq $previous -or $previous.status -ne 'finished') {
                Publish-VCRedist 'finished' 'All Visual C++ runtimes are already installed.' @{packages=@();rebootRequired=$false}
            }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            return
        }
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
        $periodic = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(15) -RepetitionInterval (New-TimeSpan -Minutes 15)
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1) -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Trigger @((New-ScheduledTaskTrigger -AtStartup),$periodic) -User SYSTEM -RunLevel Highest -Force | Out-Null
        Publish-VCRedist 'queued' 'Visual C++ runtimes will be installed after Windows/AME/Helios setup.' $null
        Start-ScheduledTask -TaskName $taskName
        return
    }
    $wait = Get-VCRedistWaitReason $install $env:ProgramData
    if ($wait) { Publish-VCRedist 'waiting' $wait $null; return }
    Publish-VCRedist 'installing' 'Installing missing Microsoft Visual C++ runtimes.' $null
    $result = Invoke-VCRedistPackages $packages $root
    Publish-VCRedist 'finished' 'Microsoft Visual C++ runtimes are installed. No automatic reboot was requested.' $result
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $root -Filter '*.exe' | Remove-Item -Force
} catch {
    if (Test-Path -LiteralPath $root) { Publish-VCRedist 'failed' $_.Exception.Message $null }
    Write-Error $_
    exit 1
}

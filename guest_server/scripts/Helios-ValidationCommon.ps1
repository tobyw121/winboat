Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Get-HeliosValidationRoot {
    return Join-Path $env:ProgramData 'WinBoat\GraphicsValidation'
}
function Initialize-HeliosValidationRoot {
    $root=Get-HeliosValidationRoot
    foreach($path in @((Join-Path $env:ProgramData 'WinBoat'),$root)) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Validation path is a reparse point.'}
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    $acl=Get-Acl -LiteralPath $root
    $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    Set-Acl -LiteralPath $root -AclObject $acl
    return $root
}
function Read-HeliosValidationJson([string]$Path) {
    $item=Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 1048576) {throw 'Invalid validation JSON file.'}
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Write-HeliosValidationJson([string]$Name,$Data) {
    if ($Name -notmatch '^(acceptance|transaction|last-good)\.json$') {throw 'Unknown validation state.'}
    $root=Initialize-HeliosValidationRoot
    $path=Join-Path $root $Name
    foreach($target in @($path,"$path.tmp")) {
        if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Validation file is a reparse point.'}
    }
    $Data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$path.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
}
function Get-HeliosValidationIdentity {
    $state=Read-HeliosValidationJson (Join-Path $env:ProgramData 'Helios\install-state.json')
    $manifest=Join-Path $env:ProgramData 'Helios\manifest.json'
    $devices=@(Get-CimInstance Win32_VideoController | Where-Object {$_.PNPDeviceID -like 'PCI\VEN_1AF4&DEV_1050*'})
    if ($devices.Count -ne 1 -or $devices[0].ConfigManagerErrorCode -ne 0 -or $devices[0].DriverVersion -ne $state.version) {throw 'One healthy Helios adapter matching the installation state is required.'}
    return [ordered]@{version=[string]$state.version;manifestSha256=(Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash;
        bootAtUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')}
}
function Invoke-HeliosValidationProcess([string]$Exe,[string[]]$Arguments=@(),[int]$Timeout=45) {
    $out=[IO.Path]::GetTempFileName();$err=[IO.Path]::GetTempFileName();$process=$null
    try {
        $options=@{FilePath=$Exe;PassThru=$true;RedirectStandardOutput=$out;RedirectStandardError=$err}
        if ($Arguments.Count) {$options.ArgumentList=$Arguments}
        $process=Start-Process @options
        if (-not $process.WaitForExit($Timeout*1000)) {
            $process.Kill();[void]$process.WaitForExit(5000)
            return [ordered]@{status='timeout';exitCode=$null}
        }
        $process.Refresh()
        return [ordered]@{status=$(if($process.ExitCode -eq 0){'passed'}else{'failed'});exitCode=$process.ExitCode}
    } finally {
        if ($null -ne $process) {$process.Dispose()}
        Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Get-HeliosValidationRoot {
    return Join-Path $env:ProgramData 'WinBoat\GraphicsValidation'
}
function Protect-HeliosValidationPath([string]$Path,[bool]$Directory=$true) {
    $acl=Get-Acl -LiteralPath $Path
    $sddl=if($Directory){'O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'}else{'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)'}
    $acl.SetSecurityDescriptorSddlForm($sddl)
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Initialize-HeliosValidationRoot {
    $root=Get-HeliosValidationRoot
    foreach($path in @((Join-Path $env:ProgramData 'WinBoat'),$root)) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Validation path is a reparse point.'}
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    Protect-HeliosValidationPath $root
    return $root
}
function Read-HeliosValidationJson([string]$Path) {
    $item=Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 1048576) {throw 'Invalid validation JSON file.'}
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Write-HeliosValidationJson([string]$Name,$Data) {
    if ($Name -notmatch '^(acceptance|transaction|last-good|comparison|comparison-session|resume|release)\.json$') {throw 'Unknown validation state.'}
    $root=Initialize-HeliosValidationRoot
    $path=Join-Path $root $Name
    $temporary=Join-Path $root ([guid]::NewGuid().ToString('N')+'.tmp')
    foreach($target in @($path,$temporary)) {
        if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Validation file is a reparse point.'}
    }
    try {
        $Data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $path -Force
    } finally {Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
}
function Get-HeliosMachineIdentity {
    $product=Get-CimInstance Win32_ComputerSystemProduct -Property UUID
    $machineKey=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Cryptography')
    try {$machineGuid=[string]$machineKey.GetValue('MachineGuid',$null)} finally {if($machineKey){$machineKey.Dispose()}}
    $first=[Guid]::Empty;$second=[Guid]::Empty
    if (-not [Guid]::TryParse($machineGuid,[ref]$first) -or -not [Guid]::TryParse([string]$product.UUID,[ref]$second) -or
        $first -eq [Guid]::Empty -or $second -eq [Guid]::Empty) {throw 'VM identity unavailable; local acceptance cannot be bound.'}
    $hash=[Security.Cryptography.SHA256]::Create()
    try {return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($first.ToString('D')+'|'+$second.ToString('D'))))).Replace('-','').ToLowerInvariant()}
    finally {$hash.Dispose()}
}
function Get-HeliosValidationIdentity {
    $state=Read-HeliosValidationJson (Join-Path $env:ProgramData 'Helios\install-state.json')
    $manifest=Join-Path $env:ProgramData 'Helios\manifest.json'
    $devices=@(Get-CimInstance Win32_VideoController | Where-Object {$_.PNPDeviceID -like 'PCI\VEN_1AF4&DEV_1050*'})
    if ($devices.Count -ne 1 -or $devices[0].ConfigManagerErrorCode -ne 0 -or $devices[0].DriverVersion -ne $state.version) {throw 'One healthy Helios adapter matching the installation state is required.'}
    $machineId=Get-HeliosMachineIdentity
    $profile=[ordered]@{};$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Helios')
    try {
        foreach($name in @('UmdD3D12','UmdCommandLists','UmdFreeThreaded','UmdAsyncPresentStream','UmdPresentBatchFold','FeatureLevel11')) {
            $value=$null
            if ($null -ne $key -and $key.GetValueNames() -contains $name) {
                if ($key.GetValueKind($name) -ne 'DWord') {throw 'Driver profile contains a non-DWORD option.'}
                $value=[int]$key.GetValue($name)
            }
            $profile[$name]=$value
        }
    } finally {if($null -ne $key){$key.Dispose()}}
    return [ordered]@{version=[string]$state.version;machineId=$machineId;profile=$profile;manifestSha256=(Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash;
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
        $text=''
        foreach($file in @($out,$err)) {
            $stream=[IO.File]::Open($file,'Open','Read','ReadWrite')
            try {
                [void]$stream.Seek([Math]::Max(0,$stream.Length-32768),'Begin')
                $bytes=New-Object byte[] 32768;$count=$stream.Read($bytes,0,$bytes.Length)
                $text += [Text.Encoding]::UTF8.GetString($bytes,0,$count)
            } finally {$stream.Dispose()}
        }
        $signals=@()
        if ($text -match 'Direct3D 11 clear/copy/readback: all 527 pixels match') {$signals+='d3d11-readback-527'}
        if ($text -match 'MSAA format=\d+ samples=\d+ quality=\d+') {$signals+='msaa-query-observed'}
        $codes=@([regex]::Matches($text,'\b(?:VK_ERROR_[A-Z0-9_]{1,64}|0x[0-9a-fA-F]{8})\b') | ForEach-Object {$_.Value} | Sort-Object -Unique | Select-Object -First 16)
        return [ordered]@{status=$(if($process.ExitCode -eq 0){'passed'}else{'failed'});exitCode=$process.ExitCode;signals=$signals;codes=$codes}
    } finally {
        if ($null -ne $process) {$process.Dispose()}
        Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue
    }
}

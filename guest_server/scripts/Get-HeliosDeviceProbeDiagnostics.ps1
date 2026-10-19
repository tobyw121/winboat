function Get-HeliosDeviceProbeDiagnostics {
    $path=Join-Path $env:ProgramData 'Helios/device-probe-result.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {return $null}
    try {
        $file=Get-Item -LiteralPath $path
        if ($file.Length -gt 32768 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Invalid report file'}
        $data=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($data.schema -ne 1 -or $data.profileScope -ne 'child-process' -or $data.registryRestored -isnot [bool] -or
            $data.probeVersion -notmatch '^\d{1,4}\.\d{1,4}\.\d{1,4}\.\d{1,4}$' -or
            $data.probeSha256 -notmatch '^[0-9a-fA-F]{64}$') {throw 'Invalid report schema'}
        $start=[DateTimeOffset]::Parse([string]$data.startedAtUtc).ToUniversalTime().ToString('o')
        $finish=[DateTimeOffset]::Parse([string]$data.finishedAtUtc).ToUniversalTime().ToString('o')
        $arms=@(foreach ($arm in @($data.arms | Select-Object -First 4)) {
            if ($arm.mode -notin @(0,1,2) -or $arm.timedOut -isnot [bool]) {throw 'Invalid arm'}
            $rows=@(foreach ($row in @($arm.results | Select-Object -First 6)) {
                if ($row.schema -ne 1 -or $row.warp -ne $false -or $row.warp -isnot [bool]) {throw 'Invalid probe backend'}
                [ordered]@{requested=[uint32]$row.requested;achieved=[uint32]$row.achieved;flags=[uint32]$row.flags;hr=[uint32]$row.hr}
            })
            [ordered]@{mode=[int]$arm.mode;processId=[uint32]$arm.processId;timedOut=$arm.timedOut;exitCode=[int]$arm.exitCode;results=$rows}
        })
        return [ordered]@{schema=1;profileScope='child-process';probeVersion=[string]$data.probeVersion;probeSha256=[string]$data.probeSha256;
            startedAtUtc=$start;finishedAtUtc=$finish;registryRestored=$data.registryRestored;arms=$arms}
    } catch {return [ordered]@{error='Device profile result unavailable or invalid'}}
}

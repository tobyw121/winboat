# Read-only, bounded summaries. Never return arbitrary log lines or module paths.
function Read-HeliosGpuJournal([string]$Text,[ValidateRange(1,96)][int]$EventLimit=16) {
    $prefix='(?m)^\[pid=\d+ tid=\d+\] GPU-DIAG '
    $heads=[regex]::Matches($Text,$prefix+'device=(\d{1,20}) birth=(\d{1,24}) elapsed_ms=(\d{1,16}) queries=(\d{1,16}) mismatches=(\d{1,16})(?: presented=([01]))?\r?$')
    if (-not $heads.Count) {return $null}
    $head=$heads[$heads.Count-1]
    $id=$head.Groups[1].Value; $birth=$head.Groups[2].Value
    $tail=$Text.Substring($head.Index)
    $events=@([regex]::Matches($tail,$prefix+"event device=$id birth=$birth seq=(\d{1,16}) kind=(created|format|msaa|msaa-refused|msaa-policy|runtime-error|resource|view|shader|present|returned) a=(\d{1,20}) b=(\d{1,20}) c=(\d{1,20}) d=(\d{1,20}) e=(\d{1,20}) f=(\d{1,20})\r?$") |
        Select-Object -Last $EventLimit | ForEach-Object {
            [ordered]@{seq=$_.Groups[1].Value;kind=$_.Groups[2].Value;values=@($_.Groups[3..8] | ForEach-Object {$_.Value})}
        })
    $failure=@([regex]::Matches($tail,$prefix+"first-failure device=$id birth=$birth seq=(\d{1,16}) kind=(created|format|msaa|msaa-refused|msaa-policy|runtime-error|resource|view|shader|present|returned) a=(\d{1,20}) b=(\d{1,20}) c=(\d{1,20}) d=(\d{1,20}) e=(\d{1,20}) f=(\d{1,20})\r?$") |
        Select-Object -First 16 | ForEach-Object {
            [ordered]@{seq=$_.Groups[1].Value;kind=$_.Groups[2].Value;values=@($_.Groups[3..8] | ForEach-Object {$_.Value})}
        })
    $first=[regex]::Match($tail,$prefix+"mismatch device=$id birth=$birth fmt=(\d{1,10}) samples=(\d{1,3}) flags=(\d{1,10}) levels=(\d{1,10}) hr=(0x[0-9a-fA-F]{8})\r?$")
    $mismatch=$null
    if ($first.Success) {$mismatch=[ordered]@{format=$first.Groups[1].Value;samples=$first.Groups[2].Value;flags=$first.Groups[3].Value;levels=$first.Groups[4].Value;hr=$first.Groups[5].Value}}
    return [ordered]@{device=$id;birth=$birth;elapsedMs=$head.Groups[3].Value;queries=$head.Groups[4].Value;
        mismatches=$head.Groups[5].Value;presented=$(if ($head.Groups[6].Success) {$head.Groups[6].Value -eq '1'} else {$null});firstMismatch=$mismatch;firstFailure=$failure;events=$events}
}
function Read-HeliosUmdSummary([string]$Path,[ValidateRange(1,96)][int]$EventLimit=16) {
    $stream=[IO.File]::Open($Path,'Open','Read','ReadWrite')
    try {
        $start=[Math]::Max(0,$stream.Length-65536)
        [void]$stream.Seek($start,'Begin')
        $bytes=New-Object byte[] 65536
        $count=$stream.Read($bytes,0,$bytes.Length)
        $text=[Text.Encoding]::UTF8.GetString($bytes,0,$count)
        if ($start -gt 0) {
            $newline=$text.IndexOf("`n")
            $text=if($newline -ge 0){$text.Substring($newline+1)}else{''}
        }
        # PID files append across module reloads and boots. Discard older
        # generations if the latest module boundary is inside this tail.
        $boundaries=[regex]::Matches($text,'(?m)^\[pid=\d+ tid=\d+\] UMD module:')
        $boundary=$boundaries.Count -gt 0
        # Preserve the latest completed device even if a later adapter-only
        # enumeration appended another module marker without creating a device.
        $journal=Read-HeliosGpuJournal $text $EventLimit
        if ($boundary) {$text=$text.Substring($boundaries[$boundaries.Count-1].Index)}
        if ($null -ne $journal) {
            $journal.latestModuleBoundaryMatches=$null
            if ($boundary) {
                $journal.latestModuleBoundaryMatches=($text -match ('GPU-DIAG device='+$journal.device+' birth='+$journal.birth+' '))
            }
        }
        $patterns=[ordered]@{
            'adapter-open'='(?m)^\[pid=\d+ tid=\d+\] open_adapter_common interface='
            'device-ready'='(?m)^\[pid=\d+ tid=\d+\]   CreateDevice -> S_OK \(DXVK device \+ D3D11 funcs table installed\)\r?$'
            'device-create-failed'='(?m)^\[pid=\d+ tid=\d+\]   CreateDevice: DXVK device creation FAILED -> E_FAIL\r?$'
            'device-destroyed'='(?m)^\[pid=\d+ tid=\d+\] DDI: DestroyDevice\r?$'
            'no-present-observed'='(?m)^\[pid=\d+ tid=\d+\] DDI PresentBoundary: entry present=0 present1_single=0 present1_multi=0 mpo=0 render attempt/success/failure/missing=0/0/0/0 present attempt/success/failure/missing=0/0/0/0 mpo attempt/success/failure/missing=0/0/0/0 early_refusal=0\r?$'
            'producer-init-failed'='(?m)^\[dxvk-bridge\] producer: stream initialization FAILED \('
            'producer-submit-failed'='(?m)^\[dxvk-bridge\] present_frame_gate: command stream/submission failed\r?$'
        }
        $signals=@(foreach($name in $patterns.Keys) {
            $hits=[regex]::Matches($text,$patterns[$name]).Count
            if($hits){[ordered]@{kind=$name;count=$hits}}
        })
        # Codes are useful even when the surrounding exception contains paths
        # or application data. Return only fixed API symbols and numeric codes.
        $codes=@([regex]::Matches($text,'\b(?:VK_ERROR_[A-Z0-9_]{1,64}|(?:hr|HRESULT)=0x[0-9a-fA-F]{8})\b') |
            ForEach-Object {$_.Value} | Sort-Object -Unique | Select-Object -First 16)
        return [ordered]@{tailBytes=$count;tailTruncated=($start -gt 0);moduleBoundaryFound=$boundary;signals=$signals;codes=$codes;
            deviceReadyMeaning='UMD callback only; outer runtime acceptance unknown';journal=$journal}
    } finally {$stream.Dispose()}
}
function Get-HeliosUmdDiagnostics([uint32[]]$PreferredProcessIds=@(),[ValidateRange(1,96)][int]$EventLimit=16,[ValidateRange(1,8)][int]$FileLimit=8) {
    $root=Join-Path $env:ProgramData 'Helios'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {return @()}
    # File names are fixed by the Helios UMD, not supplied by an API caller.
    $files=@(Get-ChildItem -LiteralPath $root -Filter 'umd*.log' -File |
        Where-Object {$_.Name -match '^umd(?:12)?-\d{1,10}\.log$' -and
            [uint64]($_.BaseName -replace '^umd(?:12)?-','') -le [uint32]::MaxValue -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)} |
        Sort-Object @{Expression={if ($PreferredProcessIds -contains [uint32]($_.BaseName -replace '^umd(?:12)?-','')) {0} else {1}}},
            @{Expression='LastWriteTimeUtc';Descending=$true} | Select-Object -First $FileLimit)
    return @(foreach($file in $files) {
        $summary=Read-HeliosUmdSummary $file.FullName $EventLimit
        $summary.file=$file.Name
        $summary.updatedAtUtc=$file.LastWriteTimeUtc.ToString('o')
        $summary
    })
}

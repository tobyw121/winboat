# Read-only, bounded summaries. Never return arbitrary log lines or module paths.
function Read-HeliosUmdSummary([string]$Path) {
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
        if ($boundary) {$text=$text.Substring($boundaries[$boundaries.Count-1].Index)}
        $patterns=[ordered]@{
            'adapter-open'='(?m)^\[pid=\d+ tid=\d+\] open_adapter_common interface='
            'device-ready'='(?m)^\[pid=\d+ tid=\d+\]   CreateDevice -> S_OK \(DXVK device \+ D3D11 funcs table installed\)\r?$'
            'device-create-failed'='(?m)^\[pid=\d+ tid=\d+\]   CreateDevice: DXVK device creation FAILED -> E_FAIL\r?$'
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
        return [ordered]@{tailBytes=$count;tailTruncated=($start -gt 0);moduleBoundaryFound=$boundary;signals=$signals;codes=$codes}
    } finally {$stream.Dispose()}
}
function Get-HeliosUmdDiagnostics {
    $root=Join-Path $env:ProgramData 'Helios'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {return @()}
    # File names are fixed by the Helios UMD, not supplied by an API caller.
    $files=@(Get-ChildItem -LiteralPath $root -Filter 'umd*.log' -File |
        Where-Object {$_.Name -match '^umd(?:12)?-\d{1,10}\.log$' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)} |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 8)
    return @(foreach($file in $files) {
        $summary=Read-HeliosUmdSummary $file.FullName
        $summary.file=$file.Name
        $summary.updatedAtUtc=$file.LastWriteTimeUtc.ToString('o')
        $summary
    })
}

# One persistent runspace; native status every five seconds, expensive reports
# at most once a minute, only while the control panel is visible.
$script:liveWorker=$null;$script:liveHandle=$null;$script:liveLastSlow=[DateTime]::MinValue
$script:liveCache=[ordered]@{}
function Update-HeliosDashboard {
    if ($null -ne $script:liveWorker) {
        if (-not $script:liveHandle.IsCompleted) {return}
        try {
            $data=@($script:liveWorker.EndInvoke($script:liveHandle))[-1]
            foreach($key in $data.Keys) {$script:liveCache[$key]=$data[$key]}
            $dashboard.Text=$script:liveCache | ConvertTo-Json -Depth 12
        } catch {$dashboard.Text='Dashboard unavailable: '+$_.Exception.Message}
        finally {$script:liveWorker.Dispose();$script:liveWorker=$null;$script:liveHandle=$null}
    }
    if ($form.WindowState -eq 'Minimized') {return}
    $slow=([DateTime]::UtcNow-$script:liveLastSlow).TotalSeconds -ge 60
    if ($slow) {$script:liveLastSlow=[DateTime]::UtcNow}
    $script:liveWorker=[PowerShell]::Create()
    [void]$script:liveWorker.AddCommand((Join-Path $PSScriptRoot 'Get-HeliosLiveStatus.ps1')).AddParameter('IncludeSlow',$slow)
    $script:liveHandle=$script:liveWorker.BeginInvoke()
}

# One persistent runspace; native status every five seconds, expensive reports
# at most once a minute, only while the control panel is visible.
$script:liveWorker=$null;$script:liveHandle=$null;$script:liveLastSlow=[DateTime]::MinValue
$script:liveCache=[ordered]@{}
$script:liveDwmIds='';$script:liveDwmChanges=0
function Update-HeliosDashboard {
    if ($null -ne $script:liveWorker) {
        if (-not $script:liveHandle.IsCompleted) {
            $dashboardSummary.Text='Aktualisierung laeuft; vorherige Daten sind nicht aktuell.'
            $dashboardSummary.ForeColor=[Drawing.Color]::DarkOrange
            return
        }
        try {
            $data=@($script:liveWorker.EndInvoke($script:liveHandle))[-1]
            foreach($key in $data.Keys) {$script:liveCache[$key]=$data[$key]}
            if($data.Contains('graphics/diagnostics/runtime')) {
                try {
                    $ids=(@($data['graphics/diagnostics/runtime'].driver.dwmProcesses.processId | Sort-Object) -join ',')
                    if($ids -and $script:liveDwmIds -and $ids -ne $script:liveDwmIds){$script:liveDwmChanges++}
                    if($ids){$script:liveDwmIds=$ids}
                } catch {}
            }
            $warnings=@();$version='unknown';$state='unavailable'
            if($script:liveCache.Contains('warnings')){$warnings=@($script:liveCache.warnings)}
            if($data.Contains('graphics/adapters')) {try {$state=[string]$data['graphics/adapters'].helios.state} catch {}}
            if($script:liveCache.Contains('boundDriverVersion')){$version=[string]$script:liveCache.boundDriverVersion}
            $errors=@($data.errors).Count
            $dashboardSummary.Text='Helios: '+$state+' | Treiber: '+$version+' | DWM-PID-Wechsel beobachtet: '+$script:liveDwmChanges+' | API-Fehler: '+$errors+' | '+($warnings -join '; ')
            $dashboardSummary.ForeColor=if($warnings.Count -or $errors -or $state -ne 'running'){[Drawing.Color]::DarkOrange}else{[Drawing.Color]::DimGray}
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

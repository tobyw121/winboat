# Native Windows UI. Run elevated in the logged-in desktop; never from the API.
param([switch]$CheckUI)
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $PSScriptRoot 'Helios-ControlSettings.ps1')
. (Join-Path $PSScriptRoot 'Helios-Comparison.ps1')
. (Join-Path $PSScriptRoot 'Start-HeliosApplication.ps1') -LibraryOnly
if (-not $CheckUI -and [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {throw 'The control panel requires the interactive desktop.'}
if (-not $CheckUI -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Start Helios Control as Administrator.'}
$form=New-Object Windows.Forms.Form
$form.Text='Helios Control';$form.Width=900;$form.Height=760
$layout=New-Object Windows.Forms.FlowLayoutPanel
$layout.Dock='Fill';$layout.FlowDirection='TopDown';$layout.WrapContents=$false;$layout.AutoScroll=$true
$form.Controls.Add($layout)
$dashboardSummary=New-Object Windows.Forms.Label;$dashboardSummary.Width=840;$dashboardSummary.Height=40
$dashboardSummary.Text='Live-Status wird geladen; fehlende Daten bleiben unbekannt.';$layout.Controls.Add($dashboardSummary)
$dashboard=New-Object Windows.Forms.TextBox
$dashboard.Multiline=$true;$dashboard.ReadOnly=$true;$dashboard.ScrollBars='Both';$dashboard.Width=840;$dashboard.Height=150
$dashboard.Text='Live status: native adapter state every 5 seconds; slow reports at most once a minute.'
$layout.Controls.Add($dashboard)
. (Join-Path $PSScriptRoot 'Helios-LiveDashboard.ps1')
$liveTimer=New-Object Windows.Forms.Timer;$liveTimer.Interval=5000
$liveTimer.Add_Tick({Update-HeliosDashboard})
$form.Add_Shown({$liveTimer.Start();Update-HeliosDashboard})
$form.Add_FormClosed({$liveTimer.Stop();$liveTimer.Dispose();if($null -ne $script:liveWorker){$script:liveWorker.Stop();$script:liveWorker.Dispose()}})
function Add-HeliosLabel([string]$Text) {
    $label=New-Object Windows.Forms.Label;$label.Text=$Text;$label.Width=840;$label.Height=38;$layout.Controls.Add($label)
}
function Add-HeliosButton([string]$Text,[scriptblock]$Handler) {
    $button=New-Object Windows.Forms.Button;$button.Text=$Text;$button.Width=330;$button.Height=28
    $button.Add_Click($Handler);$layout.Controls.Add($button)
}
$details=New-Object Windows.Forms.TextBox
$details.Multiline=$true;$details.ReadOnly=$true;$details.ScrollBars='Both';$details.Width=840;$details.Height=160
$layout.Controls.Add($details)
function Invoke-HeliosPanel([scriptblock]$Work) {
    $form.UseWaitCursor=$true
    try {$details.Text=(& $Work | ConvertTo-Json -Depth 10)}
    catch {$details.Text=$_.Exception.Message}
    finally {$form.UseWaitCursor=$false}
}
Add-HeliosLabel 'Optional: DWM-Minidumps fuer 30 Minuten (maximal 3 Dateien). Sie koennen private Speicherinhalte enthalten und bleiben lokal. Keine vollstaendigen Speicherabbilder; WER garantiert nicht fuer jeden Grafikfehler einen Dump.'
Add-HeliosButton 'DWM-Minidumps 30 Minuten aktivieren' {
    Invoke-HeliosPanel {& (Join-Path $PSScriptRoot 'Manage-HeliosCrashCapture.ps1') -Action Enable | ConvertFrom-Json}
}
Add-HeliosButton 'DWM-Minidumps deaktivieren / Status' {
    Invoke-HeliosPanel {& (Join-Path $PSScriptRoot 'Manage-HeliosCrashCapture.ps1') -Action Disable | ConvertFrom-Json}
}
Add-HeliosButton 'Status und geladene Grafikmodule' {
    Invoke-HeliosPanel {& (Join-Path $PSScriptRoot 'Get-HeliosDiagnostics.ps1') | ConvertFrom-Json}
}
Add-HeliosButton 'Installations- und Teststatus' {
    Invoke-HeliosPanel {& (Join-Path $PSScriptRoot 'Manage-HeliosTransaction.ps1') -Action Status | ConvertFrom-Json}
}
Add-HeliosButton 'Freigabestufe dieser VM anzeigen' {
    Invoke-HeliosPanel {& (Join-Path $PSScriptRoot 'Manage-HeliosRelease.ps1') -Action Status | ConvertFrom-Json}
}
Add-HeliosLabel 'Treiberoptionen: Unbestimmt = Treibervorgabe. Änderungen benötigen einen Windows-Neustart. Bei einem Fehler ursprüngliche Werte wiederherstellen.'
$boxes=@{}
$current=Get-HeliosControlSettings
foreach($name in $script:heliosOptions) {
    $box=New-Object Windows.Forms.CheckBox;$box.Text=$name;$box.ThreeState=$true;$box.Width=500
    $box.CheckState=if($null -eq $current[$name]){'Indeterminate'}elseif($current[$name]){'Checked'}else{'Unchecked'}
    $boxes[$name]=$box;$layout.Controls.Add($box)
}
Add-HeliosButton 'Treiberoptionen speichern' {
    Invoke-HeliosPanel {
        $values=[ordered]@{}
        foreach($name in $boxes.Keys) {$values[$name]=if($boxes[$name].CheckState -eq 'Indeterminate'){$null}elseif($boxes[$name].Checked){1}else{0}}
        Set-HeliosControlSettings $values
    }
}
Add-HeliosButton 'Ursprüngliche Optionen wiederherstellen' {
    Invoke-HeliosPanel {
        $saved=Read-HeliosValidationJson (Join-Path (Get-HeliosValidationRoot) 'settings-before.json')
        $values=[ordered]@{};foreach($name in $script:heliosOptions){$values[$name]=$saved.$name}
        Set-HeliosControlSettings $values
    }
}
Add-HeliosLabel 'Vulkan/Mesa Venus wird auch von D3D11/12 und OpenGL genutzt. Globales Abschalten ist daher kein unabhängiger API-Schalter und wird hier nicht angeboten.'
Add-HeliosLabel 'Anwendungsprofil: nur fuer eine x64-EXE, ohne globale Registry-Aenderung. Diagnoseprofile koennen die Grafikfunktionen einschraenken; alte Treiber ohne Unterstuetzung werden abgewiesen.'
$applicationMode=New-Object Windows.Forms.ComboBox;$applicationMode.DropDownStyle='DropDownList';$applicationMode.Width=330
[void]$applicationMode.Items.AddRange(@('driver-default','d3d11-fl10','d3d11-fl11'));$applicationMode.SelectedIndex=0;$layout.Controls.Add($applicationMode)
Add-HeliosButton 'Anwendungs-Verknuepfung erstellen' {
    Invoke-HeliosPanel {
        $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='Windows x64 application|*.exe'
        if($dialog.ShowDialog() -eq 'OK'){return New-HeliosApplicationShortcut $dialog.FileName ([string]$applicationMode.SelectedItem)}
    }
}
$label=New-Object Windows.Forms.TextBox;$label.Text='A1';$label.Width=330;$layout.Controls.Add($label)
Add-HeliosButton 'A/B/A/B-Vergleich beginnen' {
    Invoke-HeliosPanel {New-HeliosComparisonSession;$label.Text='A1';return @{next='A1';message='Baseline explicitly selected; run tests before changing the driver.'}}
}
Add-HeliosButton 'Naechster Vergleichsschritt / Ergebnis' {
    Invoke-HeliosPanel {$progress=Get-HeliosComparisonProgress;if($progress.Contains('label')){$label.Text=$progress.label};return $progress}
}
Add-HeliosLabel 'Optional: Verzeichnis der zusätzlichen Grafikprüfprogramme und unabhängig geprüfte tools.json-SHA-256 (für A/B/A/B dieselben Programme verwenden):'
$tools=New-Object Windows.Forms.TextBox;$tools.Width=840;$layout.Controls.Add($tools)
$toolsPin=New-Object Windows.Forms.TextBox;$toolsPin.Width=840;$layout.Controls.Add($toolsPin)
Add-HeliosButton 'Grafiktests starten (kurze Testfenster)' {
    Invoke-HeliosPanel {
        if ($label.Text -notmatch '^[a-zA-Z0-9_.-]{1,48}$') {throw 'Use a short label such as A1 or B1.'}
        $arguments='-NoProfile -NoExit -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Test-HeliosAcceptance.ps1')+'" -Label '+$label.Text
        if ($tools.Text) {
            if ($tools.Text -match '["\r\n]' -or $toolsPin.Text -notmatch '^[a-fA-F0-9]{64}$') {throw 'Invalid tools path or manifest pin.'}
            $arguments+=' -ToolsPath "'+$tools.Text.TrimEnd('\')+'" -ToolsManifestSha256 '+$toolsPin.Text
        }
        $child=Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -PassThru
        return @{status='running';processId=$child.Id;message='Tests run in a separate interactive window. Export the result after completion.'}
    }
}
$resumeScenario=New-Object Windows.Forms.ComboBox;$resumeScenario.DropDownStyle='DropDownList';$resumeScenario.Width=330
[void]$resumeScenario.Items.AddRange(@('minimize','reconnect','standby'));$resumeScenario.SelectedIndex=0;$layout.Controls.Add($resumeScenario)
Add-HeliosButton 'Wiederaufnahme beobachten und testen' {
    Invoke-HeliosPanel {
        $observed.Checked=$false
        $arguments='-NoProfile -NoExit -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Test-HeliosResume.ps1')+'" -Scenario '+[string]$resumeScenario.SelectedItem
        if($tools.Text) {
            if($tools.Text -match '["\r\n]' -or $toolsPin.Text -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid tools path or manifest pin.'}
            $arguments+=' -ToolsPath "'+$tools.Text.TrimEnd('\')+'" -ToolsManifestSha256 '+$toolsPin.Text
        }
        $child=Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -PassThru
        return @{status='running';processId=$child.Id;message='Perform the selected action on the host/viewer, then inspect visible recovery and the saved resume report.'}
    }
}
$observed=New-Object Windows.Forms.CheckBox
$observed.Text='Farben, Fensterwechsel, Auflösungswechsel und Wiederherstellung geprüft; kein Flackern'
$observed.Width=840;$layout.Controls.Add($observed)
Add-HeliosButton 'Nur auf dieser VM als getestet markieren' {
    Invoke-HeliosPanel {& (Join-Path $PSScriptRoot 'Manage-HeliosRelease.ps1') -Action MarkTested -ObservedStable:$observed.Checked | ConvertFrom-Json}
}
Add-HeliosButton 'Lokale Freigabe zuruecknehmen' {
    Invoke-HeliosPanel {& (Join-Path $PSScriptRoot 'Manage-HeliosRelease.ps1') -Action Reset | ConvertFrom-Json}
}
Add-HeliosButton 'Update nach Neustart bestätigen' {
    Invoke-HeliosPanel {& (Join-Path $PSScriptRoot 'Manage-HeliosTransaction.ps1') -Action Accept -ObservedStable:$observed.Checked | ConvertFrom-Json}
}
Add-HeliosButton 'Testergebnis exportieren' {
    Invoke-HeliosPanel {
        $dialog=New-Object Windows.Forms.SaveFileDialog;$dialog.Filter='JSON|*.json';$dialog.FileName='helios-'+$label.Text+'.json'
        if ($dialog.ShowDialog() -eq 'OK') {
            $data=Read-HeliosValidationJson (Join-Path (Get-HeliosValidationRoot) 'acceptance.json')
            $data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $dialog.FileName -Encoding UTF8
            return @{status='exported'}
        }
    }
}
Add-HeliosButton 'Automatische Helios-Isolation aktivieren' {
    Invoke-HeliosPanel {
        $key='HKLM:\SOFTWARE\WinBoat\DisplayRecovery'
        . (Join-Path $PSScriptRoot 'Initialize-DisplayRecoveryKey.ps1')
        Initialize-DisplayRecoveryKey $key
        New-ItemProperty -LiteralPath $key -Name AutoIsolateHelios -Value 1 -PropertyType DWord -Force | Out-Null
        return @{status='enabled';scope='Three confirmed PnP failures with healthy primary VGA; no automatic re-enable.'}
    }
}
Add-HeliosButton 'Automatische Helios-Isolation deaktivieren' {
    Invoke-HeliosPanel {
        Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WinBoat\DisplayRecovery' -Name AutoIsolateHelios -ErrorAction SilentlyContinue
        return @{status='disabled'}
    }
}
Add-HeliosButton 'Helios isolieren, VGA behalten' {
    Invoke-HeliosPanel {& (Join-Path $PSScriptRoot 'Set-HeliosRescue.ps1') -Action helios-disable | ConvertFrom-Json}
}
Add-HeliosLabel 'Geprüftes Installer-Verzeichnis (HeliosSetup.exe + helios-build.json) und unabhängig geprüfte EXE-SHA-256:'
$bundle=New-Object Windows.Forms.TextBox;$bundle.Width=840;$layout.Controls.Add($bundle)
$pin=New-Object Windows.Forms.TextBox;$pin.Width=840;$layout.Controls.Add($pin)
Add-HeliosButton 'Aktuelle Version als stabil hinterlegen' {
    Invoke-HeliosPanel {& (Join-Path $PSScriptRoot 'Manage-HeliosTransaction.ps1') -Action RememberStable -BundlePath $bundle.Text -ExpectedSha256 $pin.Text -ObservedStable:$observed.Checked | ConvertFrom-Json}
}
Add-HeliosButton 'Geprüftes Treiberupdate installieren' {
    Invoke-HeliosPanel {& (Join-Path $PSScriptRoot 'Manage-HeliosTransaction.ps1') -Action Install -BundlePath $bundle.Text -ExpectedSha256 $pin.Text | ConvertFrom-Json}
}
Add-HeliosButton 'Rollback vorbereiten (VGA-Rettungsstart)' {
    Invoke-HeliosPanel {& (Join-Path $PSScriptRoot 'Manage-HeliosTransaction.ps1') -Action Rollback | ConvertFrom-Json}
}
if ($CheckUI) {
    if ($layout.Controls.Count -lt 20 -or $boxes.Count -ne 5) {throw 'Incomplete control panel.'}
    $form.Dispose()
    Write-Output 'Native WinForms control construction passed; no driver operations executed.'
} else {[void]$form.ShowDialog()}

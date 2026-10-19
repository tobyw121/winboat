# Native Windows UI. Run elevated in the logged-in desktop; never from the API.
param([switch]$CheckUI)
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $PSScriptRoot 'Helios-ControlSettings.ps1')
if (-not $CheckUI -and [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {throw 'The control panel requires the interactive desktop.'}
if (-not $CheckUI -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Start Helios Control as Administrator.'}
$form=New-Object Windows.Forms.Form
$form.Text='Helios Control';$form.Width=900;$form.Height=760
$layout=New-Object Windows.Forms.FlowLayoutPanel
$layout.Dock='Fill';$layout.FlowDirection='TopDown';$layout.WrapContents=$false;$layout.AutoScroll=$true
$form.Controls.Add($layout)
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
Add-HeliosButton 'Status und geladene Grafikmodule' {
    Invoke-HeliosPanel {& (Join-Path $PSScriptRoot 'Get-HeliosDiagnostics.ps1') | ConvertFrom-Json}
}
Add-HeliosButton 'Installations- und Teststatus' {
    Invoke-HeliosPanel {& (Join-Path $PSScriptRoot 'Manage-HeliosTransaction.ps1') -Action Status | ConvertFrom-Json}
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
$label=New-Object Windows.Forms.TextBox;$label.Text='A1';$label.Width=330;$layout.Controls.Add($label)
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
$observed=New-Object Windows.Forms.CheckBox
$observed.Text='Farben, Fensterwechsel, Auflösungswechsel und Wiederherstellung geprüft; kein Flackern'
$observed.Width=840;$layout.Controls.Add($observed)
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

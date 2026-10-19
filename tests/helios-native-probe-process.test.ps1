param([Parameter(Mandatory)][string]$Probe,[Parameter(Mandatory)][string]$TimeoutProbe)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$source=Get-Content (Join-Path (Split-Path $PSScriptRoot) 'helios/upstream/packaging/windows/Test-HeliosDeviceProfiles.ps1') -Raw
$start=$source.IndexOf('        $info=New-Object Diagnostics.ProcessStartInfo')
$end=$source.IndexOf('    })',$start)
if ($start -lt 0 -or $end -le $start) {throw 'Production process runner was not found'}
$body=$source.Substring($start,$end-$start)
# Execute the production runner, changing only backend to WARP for the control.
$probe=(Resolve-Path -LiteralPath $Probe).Path; $mode=1
$control=[scriptblock]::Create($body.Replace("'--single'","'--warp --single'"))
$result=& $control
if ($result.timedOut -or -not $result.exited -or $result.exitCode -ne 0 -or
    $result.results.Count -ne 1 -or $result.results[0].hr -ne 0 -or -not $result.results[0].warp) {throw 'Real WARP result/pipe drain failed'}
# The second native executable sleeps. Change only the timeout to exercise kill.
$probe=(Resolve-Path -LiteralPath $TimeoutProbe).Path
$timeout=[scriptblock]::Create($body.Replace('WaitForExit(30000)','WaitForExit(25)'))
$result=& $timeout
if (-not $result.timedOut -or -not $result.exited -or $result.exitCode -eq 0 -or $result.results.Count) {throw 'Real native timeout/teardown failed'}
Write-Host 'Production native probe runner: WARP HRESULT/pipe drain and bounded child termination passed.'

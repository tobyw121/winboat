# Read-only version coherence. Multiple unused DriverStore packages are not a conflict.
Set-StrictMode -Version Latest
function Compare-HeliosStack($Controllers,$Application) {
    $parts=@();$unknown=@()
    foreach($c in @($Controllers)) {
        if($c.PNPDeviceID -notlike 'PCI\VEN_1AF4&DEV_1050*'){continue}
        if([string]$c.DriverVersion -match '^22\.22\.\d+\.0$'){
            $parts+=@{source='bound-miniport';version=[string]$c.DriverVersion}
        } else {$unknown+='bound-miniport'}
    }
    $paths=@()
    foreach($row in @($Application.apiRegistration)) {foreach($value in @($row.values)) {$paths+=@{source=('registered-'+$row.name);path=[string]$value}}}
    foreach($process in @($Application.loadedApplications)) {foreach($module in @($process.modules)) {$paths+=@{source=('loaded-'+$module.name);path=[string]$module.path}}}
    foreach($row in $paths) {
        if($row.path -match '(?i)helios-windows-x64-(22\.22\.\d+\.0)-') {$parts+=@{source=$row.source;version=$Matches[1]};continue}
        if($row.path -match '(?i)\\helios_umd(?:12)?(?:_?32)?\.dll$') {
            try {
                $v=[Diagnostics.FileVersionInfo]::GetVersionInfo($row.path).FileVersion
                if($v -match '^22\.22\.\d+\.0$') {$parts+=@{source=$row.source;version=$v}} else {$unknown+=$row.source}
            } catch {$unknown+=$row.source}
        }
    }
    $versions=@($parts | ForEach-Object {$_.version} | Sort-Object -Unique)
    $state=if($versions.Count -gt 1){'mismatch'}elseif($versions.Count -eq 1 -and $unknown.Count -eq 0 -and @($Application.apiRegistration).Count -gt 0){'coherent-observed'}else{'unknown'}
    return [ordered]@{state=$state;versions=$versions;components=$parts;unknown=$unknown;
        scope='Bound and registered/loaded file versions only. Unused installed packages do not establish a conflict. Coherence does not prove rendering.'}
}

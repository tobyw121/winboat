. (Join-Path $PSScriptRoot 'Helios-ValidationCommon.ps1')
function Get-HeliosComparison($Reports) {
    $labels=@('A1','B1','A2','B2')
    if (@($Reports).Count -ne 4 -or (@($Reports.label) -join ',') -ne ($labels -join ',')) {throw 'Four reports in A1/B1/A2/B2 order are required.'}
    if (@($Reports.comparisonKey | Sort-Object -Unique).Count -ne 1) {throw 'Comparison workload differs.'}
    if ($Reports[0].identity.version -ne $Reports[2].identity.version -or $Reports[1].identity.version -ne $Reports[3].identity.version) {throw 'Driver version changed within an arm.'}
    $pairs=@();$allSame=$true
    foreach($index in @(0,2)) {
        $a=$Reports[$index];$b=$Reports[$index+1];$first=$null
        $map=@{}
        foreach($row in @($b.tests)) {if($map.ContainsKey($row.name)){throw 'Duplicate probe name.'};$map[$row.name]=$row}
        $seen=@{}
        foreach($row in @($a.tests)) {
            if($seen.ContainsKey($row.name)){throw 'Duplicate baseline probe name.'};$seen[$row.name]=$true
            $other=$map[$row.name]
            $same=$null -ne $other -and $row.sha256 -and $row.sha256 -eq $other.sha256
            if(-not $same){$allSame=$false}
            if($null -eq $first -and ($null -eq $other -or $row.status -ne $other.status -or $row.exitCode -ne $other.exitCode)) {
                $first=[ordered]@{test=$row.name;baselineStatus=$row.status;baselineCode=$row.exitCode;
                    candidateStatus=$(if($null -ne $other){$other.status}else{'missing'});
                    candidateCode=$(if($null -ne $other){$other.exitCode}else{$null});sameProbeBytes=[bool]$same}
            }
        }
        if($map.Count -ne $seen.Count){$allSame=$false}
        $pairs+= [ordered]@{baseline=$a.label;candidate=$b.label;firstDivergence=$first}
    }
    $reproduced=$null -ne $pairs[0].firstDivergence -and
        ($pairs[0].firstDivergence | ConvertTo-Json -Compress) -eq ($pairs[1].firstDivergence | ConvertTo-Json -Compress)
    return [ordered]@{schema=1;sameProbeBytes=$allSame;reproducedFirstDivergence=$reproduced;pairs=$pairs;
        scope='First result/exit-code difference, not proof of cause. Different probe bytes limit attribution; manual checks remain separate.'}
}
function New-HeliosComparisonSession {
    Write-HeliosValidationJson 'comparison-session.json' @{schema=1;id=[guid]::NewGuid().ToString('N');runs=@();startedAtUtc=[DateTime]::UtcNow.ToString('o')}
}
function Save-HeliosComparisonRun($Report) {
    $root=Initialize-HeliosValidationRoot
    if ($Report.runId -notmatch '^[a-f0-9]{32}$') {throw 'Invalid test run identifier.'}
    if (@(Get-ChildItem -LiteralPath $root -Filter 'run-*.json' -File).Count -ge 64) {throw 'History full; export and archive old runs first.'}
    $name='run-'+$Report.runId+'.json'
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Report | ConvertTo-Json -Depth 12))
    $stream=[IO.File]::Open((Join-Path $root $name),'CreateNew','Write','None')
    try {$stream.Write($bytes,0,$bytes.Length)} finally {$stream.Dispose()}
    $sessionPath=Join-Path $root 'comparison-session.json'
    if (-not (Test-Path -LiteralPath $sessionPath)) {return}
    $session=Read-HeliosValidationJson $sessionPath
    $labels=@('A1','B1','A2','B2');$runs=@($session.runs)
    if ($runs.Count -ge 4 -or $Report.label -ne $labels[$runs.Count]) {return}
    $session.runs=@($runs)+@([ordered]@{label=$Report.label;file=$name})
    Write-HeliosValidationJson 'comparison-session.json' $session
}
function Get-HeliosComparisonProgress {
    $root=Get-HeliosValidationRoot
    $session=Read-HeliosValidationJson (Join-Path $root 'comparison-session.json')
    $runs=@($session.runs)
    if($runs.Count -gt 4){throw 'Invalid comparison session.'}
    if($runs.Count -lt 4){return @{status='next-run';label=@('A1','B1','A2','B2')[$runs.Count];message='Use the matching baseline/candidate explicitly, restart as needed, then run the same tests.'}}
    $reports=@(foreach($run in $runs){
        if($run.file -notmatch '^run-[a-f0-9]{32}\.json$'){throw 'Invalid comparison report path.'}
        Read-HeliosValidationJson (Join-Path $root $run.file)
    })
    $result=Get-HeliosComparison $reports
    Write-HeliosValidationJson 'comparison.json' $result
    return $result
}

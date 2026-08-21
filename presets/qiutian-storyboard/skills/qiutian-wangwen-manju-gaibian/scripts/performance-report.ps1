[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Start', 'Mark', 'Finish', 'Report', 'StartUnit', 'UnitMark', 'FinishUnit', 'AmendUnitResult')]
    [string]$Mode,

    [string]$RunId = '',
    [string]$Task = '',
    [string]$Range = '',
    [string]$Stage = '',
    [int]$Units = 0,
    [int]$FirstPass = 0,
    [int]$CheckerRounds = 0,
    [int]$TargetedRepairs = 0,
    [int]$FullReviews = 0,
    [int]$Unresolved = 0,
    [string]$UnitTarget = '',
    [ValidateSet('active', 'wait', 'checker', 'checker_wait', 'checker_queue', 'checker_execution', 'visual', 'ledger', 'source_read', 'skeleton', 'draft_generation', 'candidate_ingest', 'seam_audit', 'batch_checker', 'repair', 'batch_visual', 'batch_ledger', 'batch_commit')]
    [string]$Category = 'active',
    [string]$UnitResult = '',
    [string]$Note = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComicAdapt.Common.psm1') -Force
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$perfRoot = Join-Path $root '.comic-adapt-cache\performance'
$runsRoot = Join-Path $perfRoot 'runs'
$unitsRoot = Join-Path $perfRoot 'units'
$historyPath = Join-Path $perfRoot 'history.json'

function Get-RunPath([string]$Id) { return Join-Path $runsRoot ($Id + '.json') }
function Get-UnitPath([string]$Id, [string]$Target) {
    $safe = $Target -replace '[^A-Za-z0-9._-]', '_'
    return Join-Path $unitsRoot ($Id + '__' + $safe + '.json')
}

function Get-UnitRecords([string]$Id) {
    if (-not (Test-Path -LiteralPath $unitsRoot -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $unitsRoot -File -Filter ($Id + '__*.json') | Sort-Object Name | ForEach-Object { Read-Json $_.FullName })
}

function Get-CategorySeconds([object[]]$Marks, [datetime]$EndAt) {
    $totals = [ordered]@{ active = 0.0; wait = 0.0; checker = 0.0; checker_wait = 0.0; checker_queue = 0.0; checker_execution = 0.0; visual = 0.0; ledger = 0.0; source_read = 0.0; skeleton = 0.0; draft_generation = 0.0; candidate_ingest = 0.0; seam_audit = 0.0; batch_checker = 0.0; repair = 0.0; batch_visual = 0.0; batch_ledger = 0.0; batch_commit = 0.0 }
    for ($i = 0; $i -lt $Marks.Count; $i++) {
        $from = [datetime]$Marks[$i].at
        $to = if ($i -lt ($Marks.Count - 1)) { [datetime]$Marks[$i + 1].at } else { $EndAt }
        $label = [string]$Marks[$i].category
        if (-not $totals.Contains($label)) { $label = 'active' }
        $totals[$label] = [Math]::Round([double]$totals[$label] + ($to - $from).TotalSeconds, 3)
    }
    return $totals
}

function Get-Percentile([double[]]$Values, [double]$Percent) {
    if (-not $Values -or $Values.Count -eq 0) { return 0.0 }
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Ceiling(($Percent / 100.0) * $sorted.Count) - 1
    return [double]$sorted[[Math]::Max(0, [Math]::Min($sorted.Count - 1, $index))]
}

function Get-PacketMetrics([object]$Run) {
    $totals = [ordered]@{
        write_bytes = 0L; write_chars = 0L; write_estimated_tokens = 0L
        review_bytes = 0L; review_chars = 0L; review_estimated_tokens = 0L
        writer_brief_bytes = 0L; writer_brief_chars = 0L; writer_brief_estimated_tokens = 0L
        checker_brief_bytes = 0L; checker_brief_chars = 0L; checker_brief_estimated_tokens = 0L
        batch_contract_bytes = 0L; batch_contract_chars = 0L; batch_contract_estimated_tokens = 0L
        batch_checker_brief_bytes = 0L; batch_checker_brief_chars = 0L; batch_checker_brief_estimated_tokens = 0L
    }
    foreach ($target in @(Get-RunTargets $Run)) {
        if ($target -notmatch '^EP-(\d+)$') { continue }
        $base = Join-Path $root ('.comic-adapt-cache\packets\' + $target)
        foreach ($kind in @('write', 'review')) {
            $path = if ($kind -eq 'write') { $base + '.json' } else { $base + '.review.json' }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
            $totals[$kind + '_bytes'] += (Get-Item -LiteralPath $path).Length
            $totals[$kind + '_chars'] += $raw.Length
            $totals[$kind + '_estimated_tokens'] += [Math]::Ceiling($raw.Length / 2.0)
        }
        foreach ($kind in @('writer_brief', 'checker_brief')) {
            $suffix = if ($kind -eq 'writer_brief') { '.writer.md' } else { '.checker.md' }
            $path = Join-Path $root ('.comic-adapt-cache\briefs\' + $target + $suffix)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
            $totals[$kind + '_bytes'] += (Get-Item -LiteralPath $path).Length
            $totals[$kind + '_chars'] += $raw.Length
            $totals[$kind + '_estimated_tokens'] += [Math]::Ceiling($raw.Length / 2.0)
        }
    }
    $batchState = Read-Json (Join-Path $root '.comic-adapt\batch-run.json')
    if ($batchState -and [string]$Run.range -match '^\s*(\d+)\s*[-–—]\s*(\d+)\s*$') {
        $runStart = [int]$Matches[1]; $runEnd = [int]$Matches[2]
        foreach ($batch in @($batchState.batches | Where-Object { [int]$_.end -ge $runStart -and [int]$_.start -le $runEnd })) {
            foreach ($kind in @('batch_contract', 'batch_checker_brief')) {
                $relative = if ($kind -eq 'batch_contract') { [string]$batch.contract_path } else { [string]$batch.checker_brief_path }
                if (-not $relative) { continue }
                $path = Join-Path $root $relative
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
                $totals[$kind + '_bytes'] += (Get-Item -LiteralPath $path).Length
                $totals[$kind + '_chars'] += $raw.Length
                $totals[$kind + '_estimated_tokens'] += [Math]::Ceiling($raw.Length / 2.0)
            }
        }
    }
    return $totals
}

function Get-RunTargets([object]$Run) {
    if ([string]$Run.task -ne 'write' -or [string]$Run.range -notmatch '^\s*(\d+)\s*[-–—]\s*(\d+)\s*$') { return @() }
    $start = [int]$Matches[1]; $end = [int]$Matches[2]
    if ($end -lt $start) { return @() }
    return @($start..$end | ForEach-Object { 'EP-' + $_.ToString('D2') })
}

function Get-AutoQualityMetrics([object]$Run, [datetime]$EndAt) {
    $qualityRoot = Join-Path $root '.comic-adapt\quality'
    $startedAt = [datetime]$Run.started_at
    $semanticEvents = [Collections.Generic.List[object]]::new()
    $firstPass = 0
    $unresolvedCount = 0
    foreach ($target in @(Get-RunTargets $Run)) {
        $receipt = Read-Json (Join-Path $qualityRoot ($target + '.json'))
        if (-not $receipt) { continue }
        $targetEvents = @($receipt.events | Where-Object {
            $_.event_type -in @('semantic_review', 'historical_closure') -and $_.result -ne 'FAIL_INPUT' -and
            [datetime]$_.at -ge $startedAt -and [datetime]$_.at -le $EndAt
        } | Sort-Object { [datetime]$_.at })
        foreach ($event in $targetEvents) { $semanticEvents.Add($event) }
        if ($targetEvents.Count -gt 0 -and $targetEvents[0].result -eq 'PASS') { $firstPass++ }
        if ($receipt.status -eq 'UNRESOLVED' -and $targetEvents.Count -gt 0) { $unresolvedCount++ }
    }
    return [ordered]@{
        first_pass = $firstPass
        checker_rounds = $semanticEvents.Count
        targeted_repairs = @($semanticEvents | Where-Object { $_.mode -eq 'Targeted' }).Count
        full_reviews = @($semanticEvents | Where-Object { $_.mode -eq 'Full' }).Count
        unresolved = $unresolvedCount
    }
}

function Get-FirstFailureSources([object]$Run, [datetime]$EndAt) {
    $totals = [ordered]@{}
    $qualityRoot = Join-Path $root '.comic-adapt\quality'
    $startedAt = [datetime]$Run.started_at
    foreach ($target in @(Get-RunTargets $Run)) {
        $receipt = Read-Json (Join-Path $qualityRoot ($target + '.json'))
        if (-not $receipt) { continue }
        $failure = @($receipt.events | Where-Object {
            $_.event_type -in @('semantic_review', 'historical_closure') -and $_.result -in @('FAIL', 'FAIL_INPUT') -and
            [datetime]$_.at -ge $startedAt -and [datetime]$_.at -le $EndAt
        } | Sort-Object { [datetime]$_.at } | Select-Object -First 1)
        if ($failure.Count -eq 0) { continue }
        $labels = if ([string]$failure[0].result -eq 'FAIL_INPUT' -or [bool]$failure[0].hash_mismatch) {
            @('input_stale')
        } elseif ([bool]$failure[0].structural_change) {
            @('structural_change')
        } elseif (@($failure[0].failed_dimensions).Count -gt 0) {
            @($failure[0].failed_dimensions | ForEach-Object { 'dimension_' + [string]$_ })
        } else {
            @('semantic_other')
        }
        foreach ($label in $labels) {
            if ($totals.Contains($label)) { $totals[$label] = [int]$totals[$label] + 1 } else { $totals[$label] = 1 }
        }
    }
    return $totals
}

function Get-PipelineStepSeconds([object]$Run, [datetime]$EndAt) {
    $path = Join-Path $perfRoot 'pipeline-events.jsonl'
    $totals = [ordered]@{}
    $startedAt = [datetime]$Run.started_at
    $targets = @(Get-RunTargets $Run)
    foreach ($line in $(if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Content -LiteralPath $path -Encoding UTF8 } else { @() })) {
        if (-not $line.Trim()) { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        $at = [datetime]$event.at
        if ($at -lt $startedAt -or $at -gt $EndAt) { continue }
        if ($targets.Count -gt 0 -and [string]$event.episode -notin $targets) { continue }
        $name = [string]$event.step
        if (-not $name) { continue }
        $seconds = [double]$event.duration_seconds
        if ($totals.Contains($name)) { $totals[$name] = [Math]::Round([double]$totals[$name] + $seconds, 3) }
        else { $totals[$name] = [Math]::Round($seconds, 3) }
    }
    return $totals
}

function Get-BatchSharedSeconds([object]$Run, [datetime]$EndAt) {
    $totals = [ordered]@{}
    $startedAt = [datetime]$Run.started_at
    $batchPath = Join-Path $perfRoot 'batch-events.jsonl'
    if (Test-Path -LiteralPath $batchPath -PathType Leaf) {
        $runStartNumber = 0; $runEndNumber = 0
        if ([string]$Run.range -match '^\s*(\d+)\s*[-–—]\s*(\d+)\s*$') { $runStartNumber = [int]$Matches[1]; $runEndNumber = [int]$Matches[2] }
        foreach ($line in (Get-Content -LiteralPath $batchPath -Encoding UTF8)) {
            if (-not $line.Trim()) { continue }
            try { $event = $line | ConvertFrom-Json } catch { continue }
            $at = [datetime]$event.at
            if ($at -lt $startedAt -or $at -gt $EndAt) { continue }
            if ($runStartNumber -gt 0 -and [string]$event.range -match '^\s*(\d+)\s*[-–—]\s*(\d+)\s*$') {
                if ([int]$Matches[2] -lt $runStartNumber -or [int]$Matches[1] -gt $runEndNumber) { continue }
            }
            $name = [string]$event.step
            if (-not $name) { continue }
            $seconds = [double]$event.duration_seconds
            if ($totals.Contains($name)) { $totals[$name] = [Math]::Round([double]$totals[$name] + $seconds, 3) }
            else { $totals[$name] = [Math]::Round($seconds, 3) }
        }
    }
    return $totals
}

if ($Mode -eq 'Start') {
    if (-not $Task) { throw 'Start requires -Task.' }
    if (-not $RunId) { $RunId = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    $run = [ordered]@{
        schema_version = 'comic-adapt-performance/1.0'
        run_id = $RunId
        task = $Task
        range = $Range
        started_at = (Get-Date).ToString('o')
        finished_at = $null
        status = 'RUNNING'
        marks = @([ordered]@{ stage = 'active'; at = (Get-Date).ToString('o'); note = $Note })
        metrics = $null
    }
    Write-JsonAtomic (Get-RunPath $RunId) $run
    Write-Output ("PERF-RUN-START: {0} | task={1} | range={2}" -f $RunId, $Task, $Range)
    exit 0
}

if ($Mode -in @('StartUnit', 'UnitMark', 'FinishUnit', 'AmendUnitResult')) {
    if (-not $RunId) { throw "$Mode requires -RunId." }
    if (-not $UnitTarget) { throw "$Mode requires -UnitTarget." }
    $run = Read-Json (Get-RunPath $RunId)
    if (-not $run) { throw "Run not found: $RunId" }
    $unitPath = Get-UnitPath $RunId $UnitTarget
    if ($Mode -eq 'StartUnit') {
        if (Test-Path -LiteralPath $unitPath -PathType Leaf) { throw "Unit already exists: $UnitTarget" }
        $now = Get-Date
        $unit = [ordered]@{
            schema_version = 'comic-adapt-performance-unit/1.0'
            run_id = $RunId
            target = $UnitTarget
            started_at = $now.ToString('o')
            finished_at = $null
            status = 'RUNNING'
            result = ''
            marks = @([ordered]@{ category = $Category; at = $now.ToString('o'); note = $Note })
            category_seconds = $null
            wall_seconds = $null
        }
        Write-JsonAtomic $unitPath $unit
        Write-Output ("PERF-UNIT-START: {0} | target={1} | category={2}" -f $RunId, $UnitTarget, $Category)
        exit 0
    }
    $unit = Read-Json $unitPath
    if (-not $unit) { throw "Unit not found: $UnitTarget" }
    if ($Mode -eq 'AmendUnitResult') {
        if ($unit.status -ne 'COMPLETED') { throw "Only a completed unit can be amended: $UnitTarget" }
        if (-not $UnitResult) { throw 'AmendUnitResult requires -UnitResult.' }
        $oldResult = [string]$unit.result
        $unit.result = $UnitResult
        $amendments = [Collections.Generic.List[object]]::new()
        foreach ($entry in @($unit.amendments)) { $amendments.Add($entry) }
        $amendments.Add([ordered]@{ at = (Get-Date).ToString('o'); old_result = $oldResult; new_result = $UnitResult; note = $Note })
        if ($unit.PSObject.Properties['amendments']) { $unit.amendments = $amendments.ToArray() }
        else { $unit | Add-Member -NotePropertyName amendments -NotePropertyValue $amendments.ToArray() }
        Write-JsonAtomic $unitPath $unit
        Write-Output ("PERF-UNIT-AMEND: {0} | target={1} | {2}->{3}" -f $RunId, $UnitTarget, $oldResult, $UnitResult)
        exit 0
    }
    if ($unit.status -ne 'RUNNING') { throw "Unit is not active: $UnitTarget" }
    $unitMarks = New-Object Collections.Generic.List[object]
    foreach ($mark in @($unit.marks)) { $unitMarks.Add($mark) }
    $now = Get-Date
    if ($Mode -eq 'UnitMark') {
        $unitMarks.Add([ordered]@{ category = $Category; at = $now.ToString('o'); note = $Note })
        $unit.marks = $unitMarks.ToArray()
        Write-JsonAtomic $unitPath $unit
        Write-Output ("PERF-UNIT-MARK: {0} | target={1} | category={2}" -f $RunId, $UnitTarget, $Category)
        exit 0
    }
    $unit.finished_at = $now.ToString('o')
    $unit.status = 'COMPLETED'
    $unit.result = $UnitResult
    $unit.marks = $unitMarks.ToArray()
    $unit.category_seconds = Get-CategorySeconds $unitMarks.ToArray() $now
    $unit.wall_seconds = [Math]::Round(($now - [datetime]$unit.started_at).TotalSeconds, 3)
    Write-JsonAtomic $unitPath $unit
    Write-Output ("PERF-UNIT-FINISH: {0} | target={1} | wall={2}s | result={3}" -f $RunId, $UnitTarget, $unit.wall_seconds, $UnitResult)
    exit 0
}

if ($Mode -eq 'Report') {
    if ($RunId) {
        $liveRun = Read-Json (Get-RunPath $RunId)
        $runs = if ($liveRun) { @($liveRun) } else { @() }
    } else {
        $history = Read-Json $historyPath
        $runs = if ($history) { @($history) } else { @() }
    }
    if ($runs.Count -eq 0) { Write-Output 'PERF-REPORT: no matching runs'; exit 0 }
    foreach ($run in $runs) {
        $unitRecords = @(Get-UnitRecords ([string]$run.run_id))
        $completedUnits = @($unitRecords | Where-Object { $_.status -eq 'COMPLETED' -and $null -ne $_.wall_seconds })
        if ($run.status -eq 'RUNNING') {
            $wall = [Math]::Round(((Get-Date) - [datetime]$run.started_at).TotalSeconds, 3)
            Write-Output ("PERF-REPORT: {0} | {1} {2} | status=RUNNING | wall={3}s | units-completed={4}" -f $run.run_id, $run.task, $run.range, $wall, @($unitRecords | Where-Object { $_.status -eq 'COMPLETED' }).Count)
        } else {
            $rate = if ([int]$run.metrics.units -gt 0) { [Math]::Round(100.0 * [int]$run.metrics.first_pass / [int]$run.metrics.units, 1) } else { 0 }
            Write-Output ("PERF-REPORT: {0} | {1} {2} | status={3} | wall={4}s | units={5} | first-pass={6}% | checker-rounds={7} | targeted={8} | full={9} | unresolved={10}" -f $run.run_id, $run.task, $run.range, $run.status, $run.metrics.wall_seconds, $run.metrics.units, $rate, $run.metrics.checker_rounds, $run.metrics.targeted_repairs, $run.metrics.full_reviews, $run.metrics.unresolved)
        }
        if ($run.stage_seconds) {
            $pairs = @($run.stage_seconds.PSObject.Properties | ForEach-Object { $_.Name + '=' + $_.Value + 's' })
            Write-Output ('PERF-STAGES: ' + ($pairs -join '; '))
        }
        if ($run.pipeline_step_seconds) {
            $pipelinePairs = @($run.pipeline_step_seconds.PSObject.Properties | ForEach-Object { $_.Name + '=' + $_.Value + 's' })
            if ($pipelinePairs.Count -gt 0) { Write-Output ('PERF-PIPELINE-STEPS: ' + ($pipelinePairs -join '; ')) }
        }
        if ($run.batch_shared_seconds) {
            $batchPairs = @($run.batch_shared_seconds.PSObject.Properties | ForEach-Object { $_.Name + '=' + $_.Value + 's' })
            if ($batchPairs.Count -gt 0) { Write-Output ('PERF-BATCH-SHARED: ' + ($batchPairs -join '; ')) }
        }
        if ($run.first_failure_sources) {
            $failurePairs = @($run.first_failure_sources.PSObject.Properties | ForEach-Object { $_.Name + '=' + $_.Value })
            if ($failurePairs.Count -gt 0) { Write-Output ('PERF-FIRST-FAILURES: ' + ($failurePairs -join '; ')) }
        }
        if ($completedUnits.Count -gt 0) {
            $walls = [double[]]@($completedUnits | ForEach-Object { [double]$_.wall_seconds })
            $average = [Math]::Round((($walls | Measure-Object -Average).Average), 3)
            $median = [Math]::Round((Get-Percentile $walls 50), 3)
            $p90 = [Math]::Round((Get-Percentile $walls 90), 3)
            Write-Output ("PERF-UNIT-STATS: average={0}s | median={1}s | p90={2}s | count={3}" -f $average,$median,$p90,$walls.Count)
            $anomalies = @($completedUnits | Where-Object { [double]$_.wall_seconds -ge $p90 -or [string]$_.result -match 'UNRESOLVED|FAIL' } | ForEach-Object { $_.target + '=' + $_.wall_seconds + 's/' + $_.result })
            if ($anomalies.Count -gt 0) { Write-Output ('PERF-ANOMALIES: ' + ($anomalies -join '; ')) }
        }
        $packetMetrics = if ($run.packet_metrics) { $run.packet_metrics } else { Get-PacketMetrics $run }
        if ($packetMetrics) {
            Write-Output ("PERF-PACKETS: write={0}B/{1}chars/~{2}tok | review={3}B/{4}chars/~{5}tok | writer-brief={6}B/{7}chars/~{8}tok | checker-brief={9}B/{10}chars/~{11}tok" -f $packetMetrics.write_bytes,$packetMetrics.write_chars,$packetMetrics.write_estimated_tokens,$packetMetrics.review_bytes,$packetMetrics.review_chars,$packetMetrics.review_estimated_tokens,$packetMetrics.writer_brief_bytes,$packetMetrics.writer_brief_chars,$packetMetrics.writer_brief_estimated_tokens,$packetMetrics.checker_brief_bytes,$packetMetrics.checker_brief_chars,$packetMetrics.checker_brief_estimated_tokens)
            if ([long]$packetMetrics.batch_contract_bytes -gt 0 -or [long]$packetMetrics.batch_checker_brief_bytes -gt 0) {
                Write-Output ("PERF-BATCH-CONTEXT: contract={0}B/{1}chars/~{2}tok | checker-brief={3}B/{4}chars/~{5}tok" -f $packetMetrics.batch_contract_bytes,$packetMetrics.batch_contract_chars,$packetMetrics.batch_contract_estimated_tokens,$packetMetrics.batch_checker_brief_bytes,$packetMetrics.batch_checker_brief_chars,$packetMetrics.batch_checker_brief_estimated_tokens)
            }
        }
        foreach ($unit in $unitRecords) {
            $unitWall = if ($unit.status -eq 'RUNNING') { [Math]::Round(((Get-Date) - [datetime]$unit.started_at).TotalSeconds, 3) } else { $unit.wall_seconds }
            Write-Output ("PERF-UNIT: {0} | status={1} | wall={2}s | result={3}" -f $unit.target, $unit.status, $unitWall, $unit.result)
            if ($unit.category_seconds) {
                $unitPairs = @($unit.category_seconds.PSObject.Properties | ForEach-Object { $_.Name + '=' + $_.Value + 's' })
                Write-Output ('PERF-UNIT-STAGES: ' + ($unitPairs -join '; '))
            }
        }
    }
    exit 0
}

if (-not $RunId) { throw "$Mode requires -RunId." }
$runPath = Get-RunPath $RunId
$run = Read-Json $runPath
if (-not $run) { throw "Run not found: $RunId" }
if ($run.status -ne 'RUNNING' -and $Mode -ne 'Report') { throw "Run is not active: $RunId" }
$marks = New-Object Collections.Generic.List[object]
foreach ($mark in $run.marks) { $marks.Add($mark) }

if ($Mode -eq 'Mark') {
    if (-not $Stage) { throw 'Mark requires -Stage.' }
    $marks.Add([ordered]@{ stage = $Stage; at = (Get-Date).ToString('o'); note = $Note })
    $run.marks = $marks.ToArray()
    Write-JsonAtomic $runPath $run
    Write-Output ("PERF-MARK: {0} | stage={1}" -f $RunId, $Stage)
    exit 0
}

$finishedAt = Get-Date
$marks.Add([ordered]@{ stage = 'finish'; at = $finishedAt.ToString('o'); note = $Note })
$stageSeconds = [ordered]@{}
for ($i = 0; $i -lt ($marks.Count - 1); $i++) {
    $from = [datetime]$marks[$i].at
    $to = [datetime]$marks[$i + 1].at
    $label = [string]$marks[$i].stage
    $seconds = [Math]::Round(($to - $from).TotalSeconds, 3)
    if ($stageSeconds.Contains($label)) { $stageSeconds[$label] = [Math]::Round([double]$stageSeconds[$label] + $seconds, 3) }
    else { $stageSeconds[$label] = $seconds }
}
$startedAt = [datetime]$run.started_at
$unitRecords = @(Get-UnitRecords $RunId)
$runningUnits = @($unitRecords | Where-Object { $_.status -eq 'RUNNING' })
if ($runningUnits.Count -gt 0) { throw ('Cannot finish run with active units: ' + (($runningUnits | ForEach-Object { $_.target }) -join ', ')) }
$workflowPolicy = Read-Json (Join-Path $root '.comic-adapt\policy.json')
if ($workflowPolicy -and [bool]$workflowPolicy.require_closed_scopes_before_finish -and [string]$run.task -eq 'write') {
    $closureIssues = [Collections.Generic.List[string]]::new()
    foreach ($target in @(Get-RunTargets $run)) {
        $receipt = Read-Json (Join-Path $root ('.comic-adapt\quality\' + $target + '.json'))
        if (-not $receipt -or [string]$receipt.status -notin @('PASS', 'UNRESOLVED')) { $closureIssues.Add("$target has no final semantic receipt"); continue }
        $plan = Read-Json (Join-Path $root ('.comic-adapt-cache\quality-plans\' + $target + '.json'))
        if ($plan -and [string]$plan.action -in @('RUN_FULL','RUN_DIFFERENTIAL','RUN_TARGETED','TARGETED_REPAIR','RUN_SCOPE_CHECKS')) { $closureIssues.Add("$target pending $($plan.action)") }
    }
    if ($closureIssues.Count -gt 0) { throw ('Cannot finish run before batch-end quality closure: ' + ($closureIssues -join '; ')) }
}
if ($Units -le 0 -and $unitRecords.Count -gt 0) { $Units = @($unitRecords | Where-Object { $_.status -eq 'COMPLETED' }).Count }
$autoMetrics = Get-AutoQualityMetrics $run $finishedAt
if (-not $PSBoundParameters.ContainsKey('FirstPass')) { $FirstPass = [int]$autoMetrics.first_pass }
if (-not $PSBoundParameters.ContainsKey('CheckerRounds')) { $CheckerRounds = [int]$autoMetrics.checker_rounds }
if (-not $PSBoundParameters.ContainsKey('TargetedRepairs')) { $TargetedRepairs = [int]$autoMetrics.targeted_repairs }
if (-not $PSBoundParameters.ContainsKey('FullReviews')) { $FullReviews = [int]$autoMetrics.full_reviews }
if (-not $PSBoundParameters.ContainsKey('Unresolved')) { $Unresolved = [int]$autoMetrics.unresolved }
$run.finished_at = $finishedAt.ToString('o')
$run.status = 'COMPLETED'
$run.marks = $marks.ToArray()
if ($run.PSObject.Properties['stage_seconds']) { $run.stage_seconds = $stageSeconds }
else { $run | Add-Member -NotePropertyName stage_seconds -NotePropertyValue $stageSeconds }
$run.metrics = [ordered]@{
    wall_seconds = [Math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
    units = $Units
    first_pass = $FirstPass
    checker_rounds = $CheckerRounds
    targeted_repairs = $TargetedRepairs
    full_reviews = $FullReviews
    unresolved = $Unresolved
}
$pipelineStepSeconds = Get-PipelineStepSeconds $run $finishedAt
if ($run.PSObject.Properties['pipeline_step_seconds']) { $run.pipeline_step_seconds = $pipelineStepSeconds }
else { $run | Add-Member -NotePropertyName pipeline_step_seconds -NotePropertyValue $pipelineStepSeconds }
$batchSharedSeconds = Get-BatchSharedSeconds $run $finishedAt
if ($run.PSObject.Properties['batch_shared_seconds']) { $run.batch_shared_seconds = $batchSharedSeconds }
else { $run | Add-Member -NotePropertyName batch_shared_seconds -NotePropertyValue $batchSharedSeconds }
$firstFailureSources = Get-FirstFailureSources $run $finishedAt
if ($run.PSObject.Properties['first_failure_sources']) { $run.first_failure_sources = $firstFailureSources }
else { $run | Add-Member -NotePropertyName first_failure_sources -NotePropertyValue $firstFailureSources }
$packetMetrics = Get-PacketMetrics $run
if ($run.PSObject.Properties['packet_metrics']) { $run.packet_metrics = $packetMetrics }
else { $run | Add-Member -NotePropertyName packet_metrics -NotePropertyValue $packetMetrics }
Write-JsonAtomic $runPath $run
$history = Read-Json $historyPath
$items = New-Object Collections.Generic.List[object]
if ($history) {
    foreach ($historyRun in @($history)) {
        if ($historyRun.run_id -ne $RunId) { $items.Add($historyRun) }
    }
}
$items.Add($run)
Write-JsonAtomic $historyPath $items.ToArray()
Write-Output ("PERF-RUN-FINISH: {0} | wall={1}s | units={2} | first-pass={3}/{2} | unresolved={4}" -f $RunId, $run.metrics.wall_seconds, $Units, $FirstPass, $Unresolved)
Write-Output ("PERF-REPORT-COMMAND: powershell -NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -ProjectRoot `"$root`" -Mode Report -RunId $RunId")
exit 0

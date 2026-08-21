[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [ValidateSet('Init', 'Next', 'Advance', 'Status', 'Report')]
    [string]$Mode,
    [ValidateSet('write', 'map')]
    [string]$Task = 'write',
    [string]$Range = '',
    [string]$UnitTarget = '',
    [ValidateSet('PENDING', 'PREFETCHED', 'DRAFTED', 'MACHINE_PASS', 'REVIEWED', 'SEMANTIC_PASS', 'UNRESOLVED', 'COMMITTED', 'COMPLETE')]
    [string]$State = 'PENDING',
    [string]$Note = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComicAdapt.Common.psm1') -Force
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$statePath = Join-Path $root '.comic-adapt\goal-run.json'
$policyScript = Join-Path $PSScriptRoot 'workflow-policy.ps1'
$performanceScript = Join-Path $PSScriptRoot 'performance-report.ps1'
$sourceIndexScript = Join-Path $PSScriptRoot 'source-index.ps1'
$batchRunnerScript = Join-Path $PSScriptRoot 'batch-runner.ps1'
$policyPath = Join-Path $root '.comic-adapt\policy.json'
$prefetchWindow = 3
$executionProfile = 'auto'
$longRunMinEpisodes = 6
if (Test-Path -LiteralPath $policyPath -PathType Leaf) {
    try {
        $policyData = Get-Content -Raw -Encoding UTF8 -LiteralPath $policyPath | ConvertFrom-Json
        if ([int]$policyData.prefetch_window -ge 1 -and [int]$policyData.prefetch_window -le 9) { $prefetchWindow = [int]$policyData.prefetch_window }
        if ([string]$policyData.execution_profile -in @('auto','classic','long_run_batch')) { $executionProfile = [string]$policyData.execution_profile }
        if ([int]$policyData.long_run_min_episodes -ge 2) { $longRunMinEpisodes = [int]$policyData.long_run_min_episodes }
    } catch { throw "Unreadable workflow policy: $policyPath" }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    return Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json
}

function Resolve-Units([string]$Value, [string]$TaskName) {
    if ($Value -notmatch '^\s*(\d+)\s*[-–—]\s*(\d+)\s*$') { throw 'Init requires -Range N-M.' }
    $start = [int]$Matches[1]; $end = [int]$Matches[2]
    if ($end -lt $start) { throw "Invalid range: $Value" }
    return @($start..$end | ForEach-Object {
        $target = if ($TaskName -eq 'write') { 'EP-' + $_.ToString('D2') } else { 'MAP-BATCH-' + $_ }
        [ordered]@{ target = $target; number = $_; state = 'PENDING'; updated_at = (Get-Date).ToString('o'); note = '' }
    })
}

function Get-PerformanceRunPath([string]$RunId) {
    return Join-Path $root ('.comic-adapt-cache\performance\runs\' + $RunId + '.json')
}

function Get-PerformanceUnitPath([string]$RunId, [string]$Target) {
    $safe = $Target -replace '[^A-Za-z0-9._-]', '_'
    return Join-Path $root ('.comic-adapt-cache\performance\units\' + $RunId + '__' + $safe + '.json')
}

function Invoke-PerformanceChecked([hashtable]$Arguments) {
    $output = & $performanceScript @Arguments 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($output)) { Write-Output $line }
    if ($code -ne 0) { throw "Performance command failed: mode=$($Arguments.Mode) exit=$code" }
}

function Ensure-PerformanceUnitStarted([object]$Goal, [object]$Unit) {
    $runId = [string]$Goal.run_id
    $target = [string]$Unit.target
    if (-not $runId -or -not $target) { return }
    $unitPath = Get-PerformanceUnitPath $runId $target
    if (Test-Path -LiteralPath $unitPath -PathType Leaf) { return }
    Invoke-PerformanceChecked @{ ProjectRoot = $root; Mode = 'StartUnit'; RunId = $runId; UnitTarget = $target; Category = 'active'; Note = 'goal-unit-auto-start' }
}

function Mark-PerformanceUnit([object]$Goal, [object]$Unit, [string]$Category, [string]$MarkNote) {
    Ensure-PerformanceUnitStarted $Goal $Unit
    $unitPath = Get-PerformanceUnitPath ([string]$Goal.run_id) ([string]$Unit.target)
    if (-not (Test-Path -LiteralPath $unitPath -PathType Leaf)) { return }
    $data = Get-Content -Raw -Encoding UTF8 -LiteralPath $unitPath | ConvertFrom-Json
    if ([string]$data.status -ne 'RUNNING') { return }
    $last = @($data.marks | Select-Object -Last 1)
    if ($last.Count -gt 0 -and [string]$last[0].category -eq $Category) { return }
    Invoke-PerformanceChecked @{ ProjectRoot = $root; Mode = 'UnitMark'; RunId = [string]$Goal.run_id; UnitTarget = [string]$Unit.target; Category = $Category; Note = $MarkNote }
}

function Finish-PerformanceUnit([object]$Goal, [object]$Unit, [string]$Result) {
    Ensure-PerformanceUnitStarted $Goal $Unit
    $unitPath = Get-PerformanceUnitPath ([string]$Goal.run_id) ([string]$Unit.target)
    if (-not (Test-Path -LiteralPath $unitPath -PathType Leaf)) { return }
    $data = Get-Content -Raw -Encoding UTF8 -LiteralPath $unitPath | ConvertFrom-Json
    if ([string]$data.status -eq 'RUNNING') {
        Invoke-PerformanceChecked @{ ProjectRoot = $root; Mode = 'FinishUnit'; RunId = [string]$Goal.run_id; UnitTarget = [string]$Unit.target; UnitResult = $Result; Note = 'goal-unit-auto-finish' }
    } elseif ([string]$data.result -ne $Result) {
        Invoke-PerformanceChecked @{ ProjectRoot = $root; Mode = 'AmendUnitResult'; RunId = [string]$Goal.run_id; UnitTarget = [string]$Unit.target; UnitResult = $Result; Note = 'goal-terminal-state-correction' }
    }
}

function Try-FinishPerformanceRun([object]$Goal) {
    $runId = [string]$Goal.run_id
    if (-not $runId) { return }
    $runPath = Get-PerformanceRunPath $runId
    if (-not (Test-Path -LiteralPath $runPath -PathType Leaf)) { return }
    $run = Get-Content -Raw -Encoding UTF8 -LiteralPath $runPath | ConvertFrom-Json
    if ([string]$run.status -ne 'RUNNING') { return }
    if (@($Goal.units | Where-Object { $_.state -notin @('COMPLETE', 'UNRESOLVED') }).Count -gt 0) { return }
    try {
        Invoke-PerformanceChecked @{ ProjectRoot = $root; Mode = 'Finish'; RunId = $runId; Note = 'goal-target-reached-auto-finish' }
    } catch {
        # Scope closure may legitimately lag the terminal goal transition. Report stays usable and retries Finish.
        Write-Output ("PERF-RUN-FINISH-DEFERRED: {0} | {1}" -f $runId, $_.Exception.Message)
    }
}

function Get-NextAction([object]$Unit, [string]$TaskName) {
    if ($TaskName -eq 'map') {
        switch ([string]$Unit.state) {
            'PENDING' { return 'READ_SOURCE_AND_BUILD_MAP_SPEC' }
            'PREFETCHED' { return 'COMPILE_MAP_AND_RUN_PREFLIGHT' }
            'MACHINE_PASS' { return 'RUN_QUALITY_PLAN_AND_CHECKER' }
            'REVIEWED' { return 'RECORD_CHECKER_RESULT' }
            'SEMANTIC_PASS' { return 'COMMIT_MAP_LEDGER' }
            'COMMITTED' { return 'MARK_COMPLETE' }
        }
    } else {
        switch ([string]$Unit.state) {
            'PENDING' { return 'RUN_EPISODE_PREFETCH' }
            'PREFETCHED' { return 'BUILD_WRITE_PACKET_AND_DRAFT' }
            'DRAFTED' { return 'RUN_ADAPTIVE_PRE_REVIEW' }
            'MACHINE_PASS' { return 'RUN_QUALITY_PLAN_AND_CHECKER' }
            'REVIEWED' { return 'RECORD_CHECKER_RESULT' }
            'SEMANTIC_PASS' { return 'RUN_SERIAL_COMMIT' }
            'COMMITTED' { return 'MARK_COMPLETE' }
        }
    }
    return 'NO_ACTION'
}

function Get-NextCommand([object]$Unit, [string]$TaskName) {
    $number = [int]$Unit.number
    $target = [string]$Unit.target
    $ps = 'powershell -NoProfile -ExecutionPolicy Bypass -File'
    if ($TaskName -eq 'map') {
        switch ([string]$Unit.state) {
            'PENDING' { return "READ_SOURCE_AND_BUILD_MAP_SPEC target=$target" }
            'PREFETCHED' { return "$ps `"$(Join-Path $PSScriptRoot 'map-preflight.ps1')`" -ProjectRoot `"$root`" -Target $target -MapSpec <map-spec-path>" }
            'MACHINE_PASS' { return "$ps `"$(Join-Path $PSScriptRoot 'quality-receipt.ps1')`" -ProjectRoot `"$root`" -Mode Plan -Target $target -Kind Map -Operation map" }
            'REVIEWED' { return "$ps `"$(Join-Path $PSScriptRoot 'quality-receipt.ps1')`" -ProjectRoot `"$root`" -Mode Record -Target $target -Kind Map -Result <PASS|FAIL> -CheckedHash <sha256>" }
            'SEMANTIC_PASS' { return "COMMIT_MAP_LEDGER target=$target" }
            'COMMITTED' { return "$ps `"$PSCommandPath`" -ProjectRoot `"$root`" -Mode Advance -UnitTarget $target -State COMPLETE" }
        }
    } else {
        switch ([string]$Unit.state) {
            'PENDING' { return "$ps `"$(Join-Path $PSScriptRoot 'episode-prefetch.ps1')`" -ProjectRoot `"$root`" -Episode $number -Window $prefetchWindow" }
            'PREFETCHED' { return "$ps `"$(Join-Path $PSScriptRoot 'build-context-packet.ps1')`" -ProjectRoot `"$root`" -Episode $number -Stage Write" }
            'DRAFTED' { return "$ps `"$(Join-Path $PSScriptRoot 'episode-pipeline.ps1')`" -ProjectRoot `"$root`" -Episode $number -Mode PreReviewAuto" }
            'MACHINE_PASS' { return "$ps `"$(Join-Path $PSScriptRoot 'quality-receipt.ps1')`" -ProjectRoot `"$root`" -Mode Plan -Target $target -Kind Script -Operation write" }
            'REVIEWED' { return "$ps `"$(Join-Path $PSScriptRoot 'quality-receipt.ps1')`" -ProjectRoot `"$root`" -Mode Record -Target $target -Kind Script -Result <PASS|FAIL> -CheckedHash <sha256> -CheckedPacketHash <sha256>" }
            'SEMANTIC_PASS' { return "$ps `"$(Join-Path $PSScriptRoot 'episode-pipeline.ps1')`" -ProjectRoot `"$root`" -Episode $number -Mode Commit" }
            'COMMITTED' { return "$ps `"$PSCommandPath`" -ProjectRoot `"$root`" -Mode Advance -UnitTarget $target -State COMPLETE" }
        }
    }
    return 'NO_COMMAND'
}

function Get-NextResources([object]$Unit, [string]$TaskName) {
    $target = [string]$Unit.target
    $skillRoot = Split-Path -Parent $PSScriptRoot
    if ($TaskName -eq 'map') {
        switch ([string]$Unit.state) {
            'PENDING' { return @('novel/', (Join-Path $skillRoot 'references\map-card.md')) }
            'PREFETCHED' { return @('.comic-adapt-cache/map-specs/', 'plot-map.md') }
            'MACHINE_PASS' { return @('.comic-adapt-cache/quality-plans/' + $target + '.json', '.comic-adapt-cache/briefs/' + $target + '.checker.md') }
            'REVIEWED' { return @('.comic-adapt/quality/' + $target + '.json') }
            default { return @('plot-map.md', 'progress.md') }
        }
    }
    switch ([string]$Unit.state) {
        'PENDING' { return @('.comic-adapt-cache/source-index.json', 'plot-map.md') }
        'PREFETCHED' { return @('.comic-adapt-cache/prefetch/' + $target + '.json', (Join-Path $skillRoot 'references\write-card.md')) }
        'DRAFTED' { return @('scripts/' + $target + '.md', '.comic-adapt-cache/briefs/' + $target + '.writer.md') }
        'MACHINE_PASS' { return @('.comic-adapt-cache/briefs/' + $target + '.checker.md', '.comic-adapt-cache/packets/' + $target + '.review.json') }
        'REVIEWED' { return @('.comic-adapt/quality/' + $target + '.json') }
        default { return @('scripts/' + $target + '.md', 'progress.md', 'visual-assets/episodes/' + $target + '.md') }
    }
}

if ($Mode -eq 'Init') {
    if (-not $Range) { throw 'Init requires -Range.' }
    if ((Test-Path -LiteralPath $statePath -PathType Leaf) -and -not $Force) { throw "Active goal state already exists: $statePath" }
    & $policyScript -ProjectRoot $root -Mode Init | Out-Null
    if ($Task -eq 'write' -and (Test-Path -LiteralPath (Join-Path $root 'plot-map.md') -PathType Leaf)) {
        & $sourceIndexScript -ProjectRoot $root -Mode Validate 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { & $sourceIndexScript -ProjectRoot $root -Mode Build | Out-Null }
    }
    $resolvedUnits = @(Resolve-Units $Range $Task)
    $effectiveProfile = if ($Task -eq 'write' -and ($executionProfile -eq 'long_run_batch' -or ($executionProfile -eq 'auto' -and $resolvedUnits.Count -ge $longRunMinEpisodes))) { 'long_run_batch' } else { 'classic' }
    $runId = 'goal-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    & $performanceScript -ProjectRoot $root -Mode Start -RunId $runId -Task $Task -Range $Range -Note 'goal-run final-only' | Out-Null
    $goal = [ordered]@{
        schema_version = 'comic-adapt-goal-run/1.0'
        task = $Task
        range = $Range
        report_policy = 'final_only'
        execution_profile = $effectiveProfile
        run_id = $runId
        status = 'RUNNING'
        started_at = (Get-Date).ToString('o')
        updated_at = (Get-Date).ToString('o')
        units = $resolvedUnits
    }
    Write-JsonAtomic $statePath $goal
    if ($effectiveProfile -eq 'long_run_batch') {
        $batchArgs = @{ ProjectRoot = $root; Mode = 'Init'; Range = $Range }
        if ($Force) { $batchArgs['Force'] = $true }
        & $batchRunnerScript @batchArgs | Write-Output
        if ($LASTEXITCODE -ne 0) { throw "Failed to initialize long_run_batch: exit=$LASTEXITCODE" }
    }
    Write-Output ("GOAL-RUN-INIT: task={0}; range={1}; units={2}; profile={3}; report=final_only; run={4}" -f $Task, $Range, @($goal.units).Count, $effectiveProfile, $runId)
    exit 0
}

$goal = Read-State
if (-not $goal) { Write-Output "GOAL-RUN-MISSING: $statePath"; exit 2 }

if ($Mode -eq 'Next') {
    if ([string]$goal.execution_profile -eq 'long_run_batch' -and (Test-Path -LiteralPath (Join-Path $root '.comic-adapt\batch-run.json') -PathType Leaf)) {
        & $batchRunnerScript -ProjectRoot $root -Mode Next | Write-Output
        exit $LASTEXITCODE
    }
    $unit = @($goal.units | Where-Object { $_.state -notin @('COMPLETE', 'UNRESOLVED') } | Select-Object -First 1)
    if ($unit.Count -eq 0) { Try-FinishPerformanceRun $goal; Write-Output 'GOAL-RUN-TARGET-REACHED'; exit 0 }
    Ensure-PerformanceUnitStarted $goal $unit[0]
    $action = Get-NextAction $unit[0] ([string]$goal.task)
    $command = Get-NextCommand $unit[0] ([string]$goal.task)
    $nextActionPath = Join-Path $root '.comic-adapt-cache\next-action.json'
    $nextAction = [ordered]@{
        schema_version = 'comic-adapt-next-action/1.0'
        generated_at = (Get-Date).ToString('o')
        task = [string]$goal.task
        target = [string]$unit[0].target
        state = [string]$unit[0].state
        action = $action
        command = $command
        resources = @(Get-NextResources $unit[0] ([string]$goal.task))
        prefetch_window = if ([string]$goal.task -eq 'write') { $prefetchWindow } else { 0 }
        rule = 'Execute this exact command; load only the listed role resources and generated brief.'
    }
    Write-JsonAtomic $nextActionPath $nextAction
    Write-Output ("GOAL-RUN-NEXT: target={0}; state={1}; action={2}" -f $unit[0].target, $unit[0].state, $action)
    Write-Output ("GOAL-RUN-COMMAND: {0}" -f $command)
    Write-Output ("GOAL-RUN-BRIEF: {0}" -f $nextActionPath)
    exit 0
}

if ($Mode -eq 'Advance') {
    if (-not $UnitTarget) { throw 'Advance requires -UnitTarget.' }
    $unit = @($goal.units | Where-Object { $_.target -eq $UnitTarget }) | Select-Object -First 1
    if (-not $unit) { throw "Unknown unit: $UnitTarget" }
    Ensure-PerformanceUnitStarted $goal $unit
    $allowed = [ordered]@{
        PENDING = @('PREFETCHED'); PREFETCHED = @('DRAFTED', 'MACHINE_PASS'); DRAFTED = @('MACHINE_PASS')
        MACHINE_PASS = @('REVIEWED'); REVIEWED = @('SEMANTIC_PASS', 'UNRESOLVED'); SEMANTIC_PASS = @('COMMITTED')
        COMMITTED = @('COMPLETE'); UNRESOLVED = @(); COMPLETE = @()
    }
    if ($State -notin @($allowed[[string]$unit.state])) { throw "Invalid transition: $($unit.state) -> $State" }
    $unit.state = $State
    $unit.updated_at = (Get-Date).ToString('o')
    $unit.note = $Note
    $goal.updated_at = (Get-Date).ToString('o')
    $remaining = @($goal.units | Where-Object { $_.state -notin @('COMPLETE', 'UNRESOLVED') })
    if ($remaining.Count -eq 0) { $goal.status = 'TARGET_REACHED' }
    Write-JsonAtomic $statePath $goal
    switch ($State) {
        'MACHINE_PASS' { Mark-PerformanceUnit $goal $unit 'checker_wait' 'machine-pass; waiting for independent checker result' }
        'REVIEWED' { Mark-PerformanceUnit $goal $unit 'active' 'checker returned; record/repair phase' }
        'SEMANTIC_PASS' { Mark-PerformanceUnit $goal $unit 'active' 'semantic pass; commit phase' }
        'UNRESOLVED' { Finish-PerformanceUnit $goal $unit 'UNRESOLVED' }
        'COMPLETE' { Finish-PerformanceUnit $goal $unit 'PASS' }
    }
    if ($remaining.Count -eq 0) { Try-FinishPerformanceRun $goal }
    Write-Output ("GOAL-RUN-ADVANCE: target={0}; state={1}; remaining={2}" -f $UnitTarget, $State, $remaining.Count)
    exit 0
}

if ($Mode -eq 'Status') {
    $groups = @($goal.units | Group-Object state | Sort-Object Name | ForEach-Object { $_.Name + '=' + $_.Count })
    Write-Output ("GOAL-RUN-STATUS: task={0}; range={1}; status={2}; {3}" -f $goal.task, $goal.range, $goal.status, ($groups -join '; '))
    if ([string]$goal.execution_profile -eq 'long_run_batch') { & $batchRunnerScript -ProjectRoot $root -Mode Status | Write-Output }
    exit 0
}

$complete = @($goal.units | Where-Object { $_.state -eq 'COMPLETE' }).Count
$unresolved = @($goal.units | Where-Object { $_.state -eq 'UNRESOLVED' }).Count
$other = @($goal.units).Count - $complete - $unresolved
if ($other -eq 0) { Try-FinishPerformanceRun $goal }
Write-Output ("GOAL-RUN-REPORT: task={0}; range={1}; complete={2}; unresolved={3}; incomplete={4}; run={5}" -f $goal.task, $goal.range, $complete, $unresolved, $other, $goal.run_id)
if ([string]$goal.execution_profile -eq 'long_run_batch') { & $batchRunnerScript -ProjectRoot $root -Mode Status | Write-Output }
& $performanceScript -ProjectRoot $root -Mode Report -RunId ([string]$goal.run_id)
if ($other -gt 0) { exit 2 }
exit 0

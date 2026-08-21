[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 9999)]
    [int]$Episode,
    [Parameter(Mandatory = $true)]
    [ValidateSet('PreReview', 'PreReviewParallel', 'PreReviewAuto', 'Commit')]
    [string]$Mode,
    [ValidateSet('write', 'rewrite', 'polish')]
    [string]$Operation = 'write'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComicAdapt.Common.psm1') -Force
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$token = 'EP-' + $Episode.ToString('D2')
$telemetryPath = Join-Path $root '.comic-adapt-cache\performance\pipeline-events.jsonl'
$script:activeJournalPath = ''

function Write-PipelineEvent([string]$Step, [double]$Seconds, [string]$Result, [hashtable]$Extra = @{}) {
    $event = [ordered]@{
        schema_version = 'comic-adapt-pipeline-event/1.0'
        at = (Get-Date).ToString('o')
        episode = $token
        operation = $Operation
        step = $Step
        duration_seconds = [Math]::Round($Seconds, 3)
        result = $Result
    }
    foreach ($entry in $Extra.GetEnumerator()) { $event[$entry.Key] = $entry.Value }
    $dir = Split-Path -Parent $telemetryPath
    if ($dir) { [void](New-Item -ItemType Directory -Force -Path $dir) }
    [IO.File]::AppendAllText($telemetryPath, (($event | ConvertTo-Json -Depth 10 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Add-JournalStep([string]$Name, [string]$Result, [double]$Seconds) {
    if (-not $script:activeJournalPath -or -not (Test-Path -LiteralPath $script:activeJournalPath -PathType Leaf)) { return }
    $data = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:activeJournalPath | ConvertFrom-Json
    $steps = [Collections.Generic.List[object]]::new()
    foreach ($item in @($data.steps)) { $steps.Add($item) }
    $steps.Add([ordered]@{ step = $Name; result = $Result; duration_seconds = [Math]::Round($Seconds, 3); at = (Get-Date).ToString('o') })
    $data.steps = $steps.ToArray()
    Write-JsonAtomic $script:activeJournalPath $data
}

function Invoke-Step([string]$Name, [string]$Script, [hashtable]$Arguments) {
    Write-Output "PIPELINE-STEP: $Name"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $output = & $Script @Arguments 2>&1
        $code = $LASTEXITCODE
        foreach ($line in @($output)) { Write-Output $line }
        if ($code -ne 0) { throw "Pipeline step failed: $Name (exit=$code)" }
        $watch.Stop()
        Write-PipelineEvent $Name $watch.Elapsed.TotalSeconds 'PASS'
        Add-JournalStep $Name 'PASS' $watch.Elapsed.TotalSeconds
    } catch {
        $watch.Stop()
        Write-PipelineEvent $Name $watch.Elapsed.TotalSeconds 'FAIL'
        Add-JournalStep $Name 'FAIL' $watch.Elapsed.TotalSeconds
        throw
    }
}

function Find-EpisodePath([string]$Root, [int]$Number) {
    $pattern = '^EP-0*' + $Number + '\.md$'
    $item = Get-ChildItem -LiteralPath (Join-Path $Root 'scripts') -File -Filter 'EP-*.md' |
        Where-Object { $_.Name -match $pattern } | Select-Object -First 1
    if (-not $item) { throw "Missing script: $token" }
    return $item.FullName
}

function Test-PrewriteContract {
    $packetPath = Join-Path $root ('.comic-adapt-cache\packets\' + $token + '.json')
    if (-not (Test-Path -LiteralPath $packetPath -PathType Leaf)) {
        throw "Missing V6 Write packet for $token; rebuild the Write packet before running the pipeline"
    }
    $packetData = Get-Content -Raw -Encoding UTF8 -LiteralPath $packetPath | ConvertFrom-Json
    if (@($packetData.missing).Count -gt 0) { throw ('Write packet has missing inputs: ' + (@($packetData.missing) -join '; ')) }
    if ($packetData.prewrite_contracts -and $packetData.prewrite_contracts.gate_status -eq 'BLOCKED') {
        throw ('Prewrite four-contract gate blocked: ' + (@($packetData.prewrite_contracts.issues) -join '; '))
    }
    Write-Output "PIPELINE-CONTRACT-GATE-PASS: $token"
}

function Invoke-ParallelSnapshot([string]$ScriptPath) {
    $lockDir = Join-Path $root '.comic-adapt-cache\locks'
    [void](New-Item -ItemType Directory -Force -Path $lockDir)
    $lockPath = Join-Path $lockDir ($token + '.pre-review.lock')
    $lockStream = $null
    $jobs = @()
    $parallelWatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $snapshotHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ScriptPath).Hash.ToLowerInvariant()
        $worker = {
            param($Spec)
            $watch = [Diagnostics.Stopwatch]::StartNew()
            try {
                $workerArgs = $Spec.arguments
                $output = & $Spec.script @workerArgs 2>&1
                $code = $LASTEXITCODE
                $watch.Stop()
                [pscustomobject]@{ name = $Spec.name; exit = $code; output = ($output | Out-String).TrimEnd(); seconds = $watch.Elapsed.TotalSeconds }
            } catch {
                $watch.Stop()
                [pscustomobject]@{ name = $Spec.name; exit = 1; output = $_.Exception.Message; seconds = $watch.Elapsed.TotalSeconds }
            }
        }
        $specs = @(
            @{ script = $visual; arguments = @{ ProjectRoot = $root; Mode = 'Sync'; PassEp = [string]$Episode }; name = 'visual-sync' },
            @{ script = $ledger; arguments = @{ ProjectRoot = $root; PassEp = [string]$Episode; Mode = 'Plan' }; name = 'ledger-plan' }
        )
        $threadCommand = Get-Command Start-ThreadJob -ErrorAction SilentlyContinue
        $scheduler = if ($threadCommand) { 'thread-job' } else { 'process-job' }
        foreach ($spec in $specs) {
            $jobs += if ($threadCommand) { Start-ThreadJob -ScriptBlock $worker -ArgumentList (,$spec) } else { Start-Job -ScriptBlock $worker -ArgumentList (,$spec) }
        }
        [void](Wait-Job -Job $jobs)
        $failed = $false
        $serializedSeconds = 0.0
        foreach ($job in $jobs) {
            $result = Receive-Job -Job $job
            Write-Output "PIPELINE-PARALLEL-STEP: $($result.name)"
            if ($result.output) { Write-Output $result.output }
            $serializedSeconds += [double]$result.seconds
            Write-PipelineEvent ([string]$result.name) ([double]$result.seconds) $(if ([int]$result.exit -eq 0) { 'PASS' } else { 'FAIL' }) @{ scheduler = $scheduler }
            if ([int]$result.exit -ne 0) { $failed = $true; Write-Output "PIPELINE-PARALLEL-FAIL: $($result.name) exit=$($result.exit)" }
        }
        if ($failed) { throw 'Parallel pre-review worker failed.' }
        $observedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ScriptPath).Hash.ToLowerInvariant()
        if ($observedHash -ne $snapshotHash) { throw "Script changed during parallel pre-review: before=$snapshotHash after=$observedHash" }
        Write-Output "PIPELINE-SNAPSHOT-PASS: $token sha256=$snapshotHash scheduler=$scheduler"
        $parallelWatch.Stop()
        Write-PipelineEvent 'pre-review-parallel-summary' $parallelWatch.Elapsed.TotalSeconds 'PASS' @{ scheduler = $scheduler; serialized_seconds = [Math]::Round($serializedSeconds, 3) }
    } catch {
        $parallelWatch.Stop()
        Write-PipelineEvent 'pre-review-parallel-summary' $parallelWatch.Elapsed.TotalSeconds 'FAIL'
        throw
    } finally {
        foreach ($job in $jobs) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        if ($lockStream) { $lockStream.Dispose() }
        if (Test-Path -LiteralPath $lockPath -PathType Leaf) { Remove-Item -LiteralPath $lockPath -Force }
    }
}

function Get-AdaptivePreReviewMode {
    $policyPath = Join-Path $root '.comic-adapt\policy.json'
    $policyData = if (Test-Path -LiteralPath $policyPath -PathType Leaf) { Get-Content -Raw -Encoding UTF8 -LiteralPath $policyPath | ConvertFrom-Json } else { $null }
    if ($policyData -and $policyData.parallel_mode -eq 'serial') { return 'serial' }
    if (($Episode % 10) -eq 0) { return 'parallel' }
    if (-not (Test-Path -LiteralPath $telemetryPath -PathType Leaf)) { return 'parallel' }
    $last = $null
    foreach ($line in (Get-Content -LiteralPath $telemetryPath -Encoding UTF8 | Select-Object -Last 100)) {
        try {
            $candidate = $line | ConvertFrom-Json
            if ($candidate.step -eq 'pre-review-parallel-summary' -and $candidate.result -eq 'PASS') { $last = $candidate }
        } catch { continue }
    }
    if ($last -and [double]$last.serialized_seconds -gt 0 -and [double]$last.duration_seconds -ge (0.85 * [double]$last.serialized_seconds)) { return 'serial' }
    return 'parallel'
}

function Test-LedgerPlanFresh([string]$ScriptPath) {
    $planPath = Join-Path $root ('.comic-adapt-cache\receipts\ledger-' + $token + '.json')
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) { return $false }
    try {
        $planData = Get-Content -Raw -Encoding UTF8 -LiteralPath $planPath | ConvertFrom-Json
        $source = @($planData.source_files | Where-Object { [int]$_.episode -eq $Episode } | Select-Object -First 1)
        if ($source.Count -eq 0) { return $false }
        return ([string]$source[0].sha256 -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $ScriptPath).Hash.ToLowerInvariant())
    } catch { return $false }
}

function Update-MutableWritePacket([string]$ScriptPath) {
    $basePath = Join-Path $root ('.comic-adapt-cache\packets\' + $token + '.json')
    if (Test-Path -LiteralPath $basePath -PathType Leaf) {
        $base = Get-Content -Raw -Encoding UTF8 -LiteralPath $basePath | ConvertFrom-Json
        $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [void]$allowed.Add((Get-RelativePathCompat $root $ScriptPath))
        [void]$allowed.Add(('visual-assets/episodes/' + $token + '.md'))
        $rebasedVisuals = [Collections.Generic.List[string]]::new()
        foreach ($authority in @($base.authority_files)) {
            $relative = ([string]$authority.path).Replace('\', '/')
            if (-not $relative -or $allowed.Contains($relative)) { continue }
            $authorityPath = Join-Path $root $relative
            if (-not (Test-Path -LiteralPath $authorityPath -PathType Leaf)) { throw "Immutable authority disappeared after Write packet: $relative" }
            $observed = (Get-FileHash -Algorithm SHA256 -LiteralPath $authorityPath).Hash.ToLowerInvariant()
            if ($observed -eq [string]$authority.sha256) { continue }
            $isEarlierReadyVisual = $false
            if ($relative -match '^visual-assets/episodes/EP-0*(?<episode>\d+)\.md$' -and [int]$Matches['episode'] -lt $Episode) {
                $visualText = Get-Content -Raw -Encoding UTF8 -LiteralPath $authorityPath
                $status = [regex]::Match($visualText, '(?m)^交接状态[：:]\s*(?<v>\S+)').Groups['v'].Value
                $declaredScript = [regex]::Match($visualText, '(?m)^剧本路径[：:]\s*(?<v>[^\r\n]+)').Groups['v'].Value.Trim()
                $declaredHash = [regex]::Match($visualText, '(?m)^剧本SHA256[：:]\s*(?<v>[0-9a-fA-F]{64})').Groups['v'].Value.ToLowerInvariant()
                $declaredPath = if ([IO.Path]::IsPathRooted($declaredScript)) { $declaredScript } else { Join-Path $root $declaredScript }
                $isEarlierReadyVisual = ($status -eq 'READY' -and (Test-Path -LiteralPath $declaredPath -PathType Leaf) -and $declaredHash -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $declaredPath).Hash.ToLowerInvariant())
            }
            if ($isEarlierReadyVisual) { $rebasedVisuals.Add($relative); continue }
            throw "Immutable authority changed after Write packet: $relative"
        }
        if ($rebasedVisuals.Count -gt 0) { Write-Output ('PIPELINE-VISUAL-AUTHORITY-REBASE: ' + ($rebasedVisuals -join '; ')) }
    }
    Invoke-Step 'refresh-write-packet' $packet @{ ProjectRoot = $root; Episode = $Episode; Stage = 'Write' }
    Write-Output "PIPELINE-MUTABLE-CONTRACT-REFRESHED: $token"
}

function Get-VisualState([string]$ScriptPath) {
    $path = Join-Path $root ('visual-assets\episodes\' + $token + '.md')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [ordered]@{ ready = $false; path = $path } }
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
    $statusMatch = [regex]::Match($text, '(?m)^交接状态[：:]\s*(?<v>\S+)')
    $hashMatch = [regex]::Match($text, '(?m)^剧本SHA256[：:]\s*(?<v>[0-9a-fA-F]{64})')
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $ScriptPath).Hash.ToLowerInvariant()
    return [ordered]@{ ready = ($statusMatch.Groups['v'].Value -eq 'READY' -and $hashMatch.Groups['v'].Value.ToLowerInvariant() -eq $actual); path = $path }
}

function Advance-GoalIfExpected([string]$Expected, [string[]]$States) {
    $goalPath = Join-Path $root '.comic-adapt\goal-run.json'
    if (-not (Test-Path -LiteralPath $goalPath -PathType Leaf)) { return }
    $goal = Read-Json $goalPath
    $unit = @($goal.units | Where-Object { $_.target -eq $token } | Select-Object -First 1)
    if ($unit.Count -eq 0 -or [string]$unit[0].state -ne $Expected) { return }
    $runner = Join-Path $PSScriptRoot 'goal-runner.ps1'
    foreach ($state in $States) {
        & $runner -ProjectRoot $root -Mode Advance -UnitTarget $token -State $state | Write-Output
        if ($LASTEXITCODE -ne 0) { throw "Failed to auto-advance $token to $state" }
    }
    Write-Output ("PIPELINE-GOAL-AUTO-ADVANCE: {0} -> {1}" -f $token, ($States -join ' -> '))
}

$lint = Join-Path $PSScriptRoot 'script-lint.ps1'
$visual = Join-Path $PSScriptRoot 'visual-handoff.ps1'
$ledger = Join-Path $PSScriptRoot 'ledger-receipt.ps1'
$packet = Join-Path $PSScriptRoot 'build-context-packet.ps1'
$quality = Join-Path $PSScriptRoot 'quality-receipt.ps1'
$scriptPath = Find-EpisodePath $root $Episode

if ($Mode -in @('PreReview', 'PreReviewParallel', 'PreReviewAuto')) {
    Test-PrewriteContract
    # Fail cheap formatting/ledger-block syntax before starting visual and ledger workers.
    Invoke-Step 'draft-gate' $lint @{ Path = $scriptPath; Draft = $true }
    $selected = if ($Mode -eq 'PreReview') { 'serial' } elseif ($Mode -eq 'PreReviewParallel') { 'parallel' } else { Get-AdaptivePreReviewMode }
    Write-Output "PIPELINE-SCHEDULER: $selected"
    if ($selected -eq 'parallel') {
        Invoke-ParallelSnapshot $scriptPath
    } else {
        Invoke-Step 'visual-sync' $visual @{ ProjectRoot = $root; Mode = 'Sync'; PassEp = [string]$Episode }
        Invoke-Step 'ledger-plan' $ledger @{ ProjectRoot = $root; PassEp = [string]$Episode; Mode = 'Plan' }
    }
    Update-MutableWritePacket $scriptPath
    Invoke-Step 'visual-preflight' $visual @{ ProjectRoot = $root; Mode = 'Preflight'; PassEp = [string]$Episode }
    Invoke-Step 'review-packet' $packet @{ ProjectRoot = $root; Episode = $Episode; Stage = 'Review' }
    Invoke-Step 'quality-plan' $quality @{ ProjectRoot = $root; Mode = 'Plan'; Target = $token; Kind = 'Script'; Operation = $Operation }
    Advance-GoalIfExpected 'DRAFTED' @('MACHINE_PASS')
    Write-Output "EPISODE-PIPELINE-READY-FOR-REVIEW: $token"
    exit 0
}

$receiptPath = Join-Path $root ('.comic-adapt\quality\' + $token + '.json')
if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw "Missing quality receipt: $token" }
$receipt = Get-Content -Raw -Encoding UTF8 -LiteralPath $receiptPath | ConvertFrom-Json
if ($receipt.status -ne 'PASS') { throw "Commit requires semantic PASS receipt: $token status=$($receipt.status)" }

$journalPath = Join-Path $root ('.comic-adapt-cache\transactions\' + $token + '.commit.json')
$journal = [ordered]@{
    schema_version = 'comic-adapt-commit/1.0'
    episode = $token
    operation = $Operation
    started_at = (Get-Date).ToString('o')
    finished_at = $null
    failed_at = $null
    error = ''
    status = 'RUNNING'
    checked_hash = [string]$receipt.checked_raw_sha256
    steps = @()
}
Write-JsonAtomic $journalPath $journal
$script:activeJournalPath = $journalPath
try {
    $ledgerVerified = $false
    $visualVerified = $false
    $commitScriptText = Get-Content -Raw -Encoding UTF8 -LiteralPath $scriptPath
    if ($commitScriptText -match '(?ms)^【台账登记块】\s*\r?\n.*?^【台账登记块·完】\s*$') {
        if (Test-LedgerPlanFresh $scriptPath) {
            Write-Output 'PIPELINE-SKIP: ledger-plan receipt is fresh'
            Write-PipelineEvent 'ledger-plan-reuse' 0 'PASS'
        } else {
            Invoke-Step 'ledger-plan' $ledger @{ ProjectRoot = $root; PassEp = [string]$Episode; Mode = 'Plan' }
        }
        Invoke-Step 'fix-progress' $lint @{ Path = $root; FixProgress = $true; PassEp = [string]$Episode }
    }
    Invoke-Step 'ledger-verify' $ledger @{ ProjectRoot = $root; PassEp = [string]$Episode; Mode = 'Verify' }
    $ledgerVerified = $true

    $visualState = Get-VisualState $scriptPath
    if ($visualState.ready) {
        Write-Output 'PIPELINE-SKIP: visual READY already matches current script hash'
        Write-PipelineEvent 'visual-finalize-reuse' 0 'PASS'
    } else {
        Invoke-Step 'visual-sync-final' $visual @{ ProjectRoot = $root; Mode = 'Sync'; PassEp = [string]$Episode }
        Invoke-Step 'visual-preflight-final' $visual @{ ProjectRoot = $root; Mode = 'Preflight'; PassEp = [string]$Episode }
        Invoke-Step 'visual-ready' $visual @{ ProjectRoot = $root; Mode = 'Ready'; PassEp = [string]$Episode }
    }
    Invoke-Step 'visual-validate' $visual @{ ProjectRoot = $root; Mode = 'Validate'; PassEp = [string]$Episode }
    Invoke-Step 'visual-index' $visual @{ ProjectRoot = $root; Mode = 'Index'; PassEp = [string]$Episode }
    Invoke-Step 'visual-status' $visual @{ ProjectRoot = $root; Mode = 'Status'; PassEp = [string]$Episode }
    $visualVerified = $true
    Invoke-Step 'final-packet' $packet @{ ProjectRoot = $root; Episode = $Episode; Stage = 'Final' }
    Invoke-Step 'post-commit-scope-plan' $quality @{ ProjectRoot = $root; Mode = 'Plan'; Target = $token; Kind = 'Script'; Operation = 'format' }
    $postPlanPath = Join-Path $root ('.comic-adapt-cache\quality-plans\' + $token + '.json')
    if (Test-Path -LiteralPath $postPlanPath -PathType Leaf) {
        $postPlan = Get-Content -Raw -Encoding UTF8 -LiteralPath $postPlanPath | ConvertFrom-Json
        $changedScopes = @($postPlan.changed_scopes)
        $machineClosableScopes = @('ledger', 'visual', 'raw_file')
        $scopeSetIsSafe = (@($changedScopes | Where-Object { $_ -notin $machineClosableScopes }).Count -eq 0)
        $unsignedVisualSemanticChange = ($postPlan.action -eq 'RUN_SCOPE_CHECKS' -and $changedScopes -contains 'visual')
        $coreStable = $true
        foreach ($scopeName in @('core_semantic', 'continuity', 'timeline')) {
            if (-not $receipt.scopes -or [string]$receipt.scopes.$scopeName -ne [string]$postPlan.current_scopes.$scopeName) { $coreStable = $false; break }
        }
        $canMachineClose = ($postPlan.action -in @('RUN_MACHINE_ONLY', 'RUN_SCOPE_CHECKS') -and $scopeSetIsSafe -and -not $unsignedVisualSemanticChange -and $coreStable -and $ledgerVerified -and $visualVerified)
        if ($canMachineClose) {
            $currentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $scriptPath).Hash.ToLowerInvariant()
            Invoke-Step 'post-commit-machine-closure' $quality @{
                ProjectRoot = $root; Mode = 'Record'; Target = $token; Kind = 'Script'; Operation = 'format'
                Result = 'PASS'; CheckerMode = 'Machine'; EventType = 'machine_closure'
                TouchedScopes = ($changedScopes -join ','); CheckedHash = $currentHash
            }
            Invoke-Step 'post-commit-reuse-plan' $quality @{ ProjectRoot = $root; Mode = 'Plan'; Target = $token; Kind = 'Script'; Operation = 'format' }
            $postPlan = Get-Content -Raw -Encoding UTF8 -LiteralPath $postPlanPath | ConvertFrom-Json
        }
        if ($postPlan.action -in @('RUN_FULL', 'RUN_DIFFERENTIAL', 'RUN_TARGETED', 'TARGETED_REPAIR', 'RUN_SCOPE_CHECKS', 'RUN_MACHINE_ONLY')) {
            throw "Commit left pending quality action: $($postPlan.action) scopes=$(@($postPlan.changed_scopes) -join ',')"
        }
    }
    $journal = Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
    $journal.status = 'COMPLETED'
    $journal.finished_at = (Get-Date).ToString('o')
    Write-JsonAtomic $journalPath $journal
    Advance-GoalIfExpected 'SEMANTIC_PASS' @('COMMITTED', 'COMPLETE')
    Write-Output "EPISODE-PIPELINE-COMPLETE: $token transaction=$journalPath"
    exit 0
} catch {
    $journal = Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
    $journal.status = 'RECOVERABLE_FAIL'
    $journal.failed_at = (Get-Date).ToString('o')
    $journal.error = $_.Exception.Message
    Write-JsonAtomic $journalPath $journal
    throw
}

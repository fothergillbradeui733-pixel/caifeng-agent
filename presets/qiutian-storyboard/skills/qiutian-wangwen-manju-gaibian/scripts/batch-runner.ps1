[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [ValidateSet('Init', 'Plan', 'Freeze', 'Candidates', 'Repair', 'PreReview', 'PlanReview', 'RecordReview', 'Commit', 'Next', 'Status')]
    [string]$Mode,
    [string]$Range = '',
    [string]$BatchId = '',
    [string]$SkeletonPath = '',
    [string]$CandidateRoot = '',
    [string]$ResultsPath = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComicAdapt.Common.psm1') -Force
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$statePath = Join-Path $root '.comic-adapt\batch-run.json'
$cacheRoot = Join-Path $root '.comic-adapt-cache\batches'
$eventsPath = Join-Path $root '.comic-adapt-cache\performance\batch-events.jsonl'
$policyPath = Join-Path $root '.comic-adapt\policy.json'
$goalPath = Join-Path $root '.comic-adapt\goal-run.json'
$prefetchScript = Join-Path $PSScriptRoot 'episode-prefetch.ps1'
$packetScript = Join-Path $PSScriptRoot 'build-context-packet.ps1'
$lintScript = Join-Path $PSScriptRoot 'script-lint.ps1'
$visualScript = Join-Path $PSScriptRoot 'visual-handoff.ps1'
$ledgerScript = Join-Path $PSScriptRoot 'ledger-receipt.ps1'
$qualityScript = Join-Path $PSScriptRoot 'quality-receipt.ps1'
$goalScript = Join-Path $PSScriptRoot 'goal-runner.ps1'
$sourceIndexScript = Join-Path $PSScriptRoot 'source-index.ps1'
$ledgerPreflightScript = Join-Path $PSScriptRoot 'ledger-commit-preflight.ps1'

function Set-Property([object]$Object, [string]$Name, [object]$Value) {
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Read-State {
    $state = Read-Json $statePath
    if (-not $state) { throw "Batch run is not initialized: $statePath" }
    return $state
}

function Save-State([object]$State) {
    Set-Property $State 'updated_at' (Get-Date).ToString('o')
    Write-JsonAtomic $statePath $State
}

function Get-Batch([object]$State, [string]$Identity) {
    if (-not $Identity) {
        $candidate = @($State.batches | Where-Object { [string]$_.state -ne 'BATCH_COMMITTED' } | Select-Object -First 1)
    } else {
        $candidate = @($State.batches | Where-Object { [string]$_.batch_id -eq $Identity } | Select-Object -First 1)
    }
    if ($candidate.Count -eq 0) { throw "Unknown or completed batch: $Identity" }
    return $candidate[0]
}

function Get-BatchRange([object]$Batch) { return ([int]$Batch.start).ToString() + '-' + ([int]$Batch.end).ToString() }

function Resolve-PathFromRoot([string]$Value) {
    if (-not $Value) { return '' }
    if ([IO.Path]::IsPathRooted($Value)) { return $Value }
    return Join-Path $root $Value
}

function Find-Script([int]$Episode) {
    $scriptsDir = Join-Path $root 'scripts'
    $pattern = '^EP-0*' + $Episode + '\.md$'
    return Get-ChildItem -LiteralPath $scriptsDir -File -Filter 'EP-*.md' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern } | Select-Object -First 1
}

function Write-BatchEvent([string]$Identity, [string]$EventRange, [string]$Step, [double]$Seconds, [string]$Result) {
    $event = [ordered]@{
        schema_version = 'comic-adapt-batch-event/1.0'; at = (Get-Date).ToString('o')
        batch_id = $Identity; range = $EventRange; step = $Step
        duration_seconds = [Math]::Round($Seconds, 3); result = $Result
    }
    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $eventsPath))
    [IO.File]::AppendAllText($eventsPath, (($event | ConvertTo-Json -Depth 8 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Format-StepCommand([string]$Script, [hashtable]$Arguments) {
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add(('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $Script))
    foreach ($key in @($Arguments.Keys | Sort-Object)) {
        $value = $Arguments[$key]
        if ($value -is [Management.Automation.SwitchParameter] -or $value -is [bool]) {
            if ([bool]$value) { $parts.Add('-' + $key) }
            continue
        }
        if ($null -eq $value) { continue }
        $rendered = if ($value -is [array]) { @($value | ForEach-Object { [string]$_ }) -join ',' } else { [string]$value }
        $parts.Add(('-{0} "{1}"' -f $key, ($rendered -replace '"', '""')))
    }
    return $parts -join ' '
}

function Invoke-Step([object]$Batch, [string]$Name, [string]$Script, [hashtable]$Arguments, [switch]$AllowFailure) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $eventWritten = $false
    $output = @()
    $command = Format-StepCommand $Script $Arguments
    try {
        Write-Output "BATCH-STEP: $Name"
        $output = & $Script @Arguments 2>&1
        $code = $LASTEXITCODE
        foreach ($line in @($output)) { Write-Output $line }
        $watch.Stop()
        Write-BatchEvent ([string]$Batch.batch_id) (Get-BatchRange $Batch) $Name $watch.Elapsed.TotalSeconds $(if ($code -eq 0) { 'PASS' } else { 'FAIL' })
        $eventWritten = $true
        if ($code -ne 0 -and -not $AllowFailure) {
            $tail = @($output | Select-Object -Last 8 | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join ' | '
            if (-not $tail) { $tail = '<no output>' }
            throw "Batch step failed: $Name exit=$code; command=$command; output-tail=$tail"
        }
        return $code
    } catch {
        if ($watch.IsRunning) { $watch.Stop() }
        if (-not $eventWritten) { Write-BatchEvent ([string]$Batch.batch_id) (Get-BatchRange $Batch) $Name $watch.Elapsed.TotalSeconds 'FAIL' }
        if ($_.Exception.Message -notmatch '^Batch step failed:') {
            $tail = @($output | Select-Object -Last 8 | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join ' | '
            if (-not $tail) { $tail = '<no output>' }
            throw "Batch step failed: $Name; command=$command; output-tail=$tail; error=$($_.Exception.Message)"
        }
        throw
    }
}

function Assert-ExactStringList([object[]]$Expected, [object[]]$Actual, [string]$Token, [string]$Field) {
    $expectedItems = @($Expected | ForEach-Object { ([string]$_).Trim() })
    $actualItems = @($Actual | ForEach-Object { ([string]$_).Trim() })
    foreach ($side in @(@('contract', $expectedItems), @('manifest', $actualItems))) {
        if (@($side[1] | Where-Object { -not $_ }).Count -gt 0) { throw "$Token $($side[0]) $Field contains a blank item" }
        $duplicates = @($side[1] | Group-Object -CaseSensitive | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        if ($duplicates.Count -gt 0) { throw "$Token $($side[0]) $Field contains duplicates: $($duplicates -join ',')" }
    }
    $missing = @($expectedItems | Where-Object { $_ -cnotin $actualItems })
    $extra = @($actualItems | Where-Object { $_ -cnotin $expectedItems })
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        throw "$Token manifest mismatch: $Field; missing=[$($missing -join ',')]; extra=[$($extra -join ',')]"
    }
}

function Get-CommitInputCoreHashes([int]$StartEpisode, [int]$EndEpisode) {
    $hashes = [ordered]@{}
    foreach ($episode in $StartEpisode..$EndEpisode) {
        $token = Get-ComicEpisodeToken $episode
        $scriptItem = Find-Script $episode
        if (-not $scriptItem) { throw "Commit input is missing script: $token" }
        $hashes[$token] = [string](Get-ComicScriptHashes $scriptItem.FullName).core_sha256
    }
    return $hashes
}

function Get-CommitInputSignature([object]$Hashes) {
    $pairs = @($Hashes.PSObject.Properties | Sort-Object Name | ForEach-Object { $_.Name + '=' + [string]$_.Value })
    if ($Hashes -is [Collections.IDictionary]) { $pairs = @($Hashes.Keys | Sort-Object | ForEach-Object { [string]$_ + '=' + [string]$Hashes[$_] }) }
    return Get-TextSha256 ($pairs -join "`n")
}

function Get-CommitStateHash([int]$StartEpisode, [int]$EndEpisode) {
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('progress.md', '.comic-adapt\unresolved.json')) {
        $candidate = Join-Path $root $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { [void]$paths.Add($candidate) }
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $root -File -Filter 'ledger-*.md' -ErrorAction SilentlyContinue)) { [void]$paths.Add($item.FullName) }
    $visualRoot = Join-Path $root 'visual-assets'
    if (Test-Path -LiteralPath $visualRoot -PathType Container) {
        foreach ($item in @(Get-ChildItem -LiteralPath $visualRoot -File -Recurse -ErrorAction SilentlyContinue)) { [void]$paths.Add($item.FullName) }
    }
    foreach ($episode in $StartEpisode..$EndEpisode) {
        $token = Get-ComicEpisodeToken $episode
        foreach ($relative in @(
            ".comic-adapt\quality\$token.json",
            ".comic-adapt-cache\quality-plans\$token.json",
            ".comic-adapt-cache\packets\$token.json",
            ".comic-adapt-cache\packets\$token.review.json",
            ".comic-adapt-cache\packets\$token.final.json"
        )) {
            $candidate = Join-Path $root $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { [void]$paths.Add($candidate) }
        }
    }
    $pairs = @($paths | Sort-Object | ForEach-Object {
        (Get-RelativePathCompat $root $_) + '=' + (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant()
    })
    return Get-TextSha256 ($pairs -join "`n")
}

function Assert-CommitInputs([object]$Journal, [int]$StartEpisode, [int]$EndEpisode) {
    $actual = Get-CommitInputCoreHashes $StartEpisode $EndEpisode
    if ((Get-CommitInputSignature $Journal.input_core_hashes) -ne (Get-CommitInputSignature $actual)) {
        throw 'Commit input core hashes changed after transaction start; semantic re-review is required before recovery.'
    }
}

function Invoke-CommitStep([object]$Journal, [string]$JournalPath, [object]$Batch, [int]$StartEpisode, [int]$EndEpisode, [string]$Name, [string]$Script, [hashtable]$Arguments) {
    Assert-CommitInputs $Journal $StartEpisode $EndEpisode
    if (@($Journal.completed_steps | Where-Object { [string]$_.name -eq $Name }).Count -gt 0) {
        Write-Output "BATCH-COMMIT-RESUME-SKIP: $Name"
        return
    }
    Invoke-Step $Batch $Name $Script $Arguments | Out-Null
    $steps = [Collections.Generic.List[object]]::new()
    foreach ($step in @($Journal.completed_steps)) { $steps.Add($step) }
    $steps.Add([ordered]@{ name = $Name; completed_at = (Get-Date).ToString('o'); post_state_sha256 = Get-CommitStateHash $StartEpisode $EndEpisode })
    Set-Property $Journal 'completed_steps' $steps.ToArray()
    Set-Property $Journal 'error' ''
    Write-JsonAtomic $JournalPath $Journal
}

function Advance-Goal([int]$Episode, [string]$Expected, [string[]]$States) {
    $goal = Read-Json $goalPath
    if (-not $goal) { return }
    $target = Get-ComicEpisodeToken $Episode
    $unit = @($goal.units | Where-Object { [string]$_.target -eq $target } | Select-Object -First 1)
    if ($unit.Count -eq 0 -or [string]$unit[0].state -ne $Expected) { return }
    foreach ($stateName in $States) {
        & $goalScript -ProjectRoot $root -Mode Advance -UnitTarget $target -State $stateName | Write-Output
        if ($LASTEXITCODE -ne 0) { throw "Failed to advance $target to $stateName" }
    }
}

function Get-EpisodeRisk([object]$Index, [int]$Episode) {
    $token = Get-ComicEpisodeToken $Episode
    $points = @($Index.plot_points | Where-Object { @($_.episode_tokens) -contains $token })
    $text = ($points | ForEach-Object { [string]$_.text }) -join "`n"
    if ($text -match '大战|战斗|斗法|揭晓|真相|身份|伏笔|死亡|重伤|易主|损毁|闪回|境界突破|信息差|保真锚点') { return 'high' }
    if ($points.Count -le 1 -and $text.Length -lt 1800) { return 'low' }
    return 'medium'
}

function New-Batches([int[]]$Episodes, [object]$Index) {
    $items = [Collections.Generic.List[object]]::new()
    $cursor = $Episodes[0]; $last = $Episodes[-1]
    while ($cursor -le $last) {
        $remaining = $last - $cursor + 1
        $probe = @($cursor..([Math]::Min($last, $cursor + 8)) | ForEach-Object { Get-EpisodeRisk $Index $_ })
        if ($probe[0] -eq 'high' -or @($probe | Select-Object -First 3 | Where-Object { $_ -eq 'high' }).Count -gt 0) { $size = 3; $risk = 'high' }
        elseif ($remaining -ge 9 -and @($probe | Where-Object { $_ -ne 'low' }).Count -eq 0) { $size = 9; $risk = 'low' }
        else { $size = 6; $risk = 'medium' }
        $end = [Math]::Min($last, $cursor + $size - 1)
        $identity = 'BATCH-' + $cursor + '-' + $end
        $items.Add([pscustomobject][ordered]@{
            batch_id = $identity; start = $cursor; end = $end; risk = $risk; state = 'PENDING'
            contract_path = Get-RelativePathCompat $root (Join-Path $cacheRoot ($identity + '.contract.json'))
            review_plan_path = ''; checker_brief_path = ''; results_path = ''
            repair_scope = @(); active_review_range = ($cursor.ToString() + '-' + $end.ToString())
            committed_through = $cursor - 1; updated_at = (Get-Date).ToString('o')
        })
        $cursor = $end + 1
    }
    return $items.ToArray()
}

function Get-Contract([object]$Batch) {
    $path = Join-Path $root ([string]$Batch.contract_path)
    $contract = Read-Json $path
    if (-not $contract) { throw "Missing batch contract: $path" }
    return $contract
}

function Write-WorkerBriefs([object]$Batch, [object]$Contract, [string]$ContractPath) {
    $workers = [Math]::Min(3, @($Contract.episode_contracts).Count)
    $assignments = [Collections.Generic.List[object]]::new()
    for ($worker = 0; $worker -lt $workers; $worker++) {
        $targets = [Collections.Generic.List[string]]::new()
        for ($index = $worker; $index -lt @($Contract.episode_contracts).Count; $index += $workers) {
            $targets.Add([string]$Contract.episode_contracts[$index].episode)
        }
        $assignments.Add([ordered]@{ worker = $worker + 1; episodes = $targets.ToArray() })
    }
    # Rebalance into continuous chunks to minimize cross-worker seams.
    $all = @($Contract.episode_contracts)
    $chunk = [Math]::Ceiling($all.Count / [double]$workers)
    $assignments = [Collections.Generic.List[object]]::new()
    for ($worker = 0; $worker -lt $workers; $worker++) {
        $slice = @($all | Select-Object -Skip ($worker * $chunk) -First $chunk)
        if ($slice.Count -gt 0) { $assignments.Add([ordered]@{ worker = $worker + 1; episodes = @($slice | ForEach-Object { [string]$_.episode }) }) }
    }
    $stagingRoot = Join-Path $root ('.comic-adapt-cache\staging\' + [string]$Batch.batch_id)
    foreach ($assignment in $assignments) {
        $workerDir = Join-Path $stagingRoot ('worker-' + $assignment.worker)
        [void](New-Item -ItemType Directory -Force -Path $workerDir)
        $briefPath = Join-Path $workerDir 'assignment.json'
        $payload = [ordered]@{
            schema_version = 'comic-adapt-worker-assignment/1.0'; batch_id = [string]$Batch.batch_id
            worker = $assignment.worker; episodes = @($assignment.episodes)
            batch_contract = Get-RelativePathCompat $root $ContractPath
            batch_contract_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $ContractPath).Hash.ToLowerInvariant()
            output_root = Get-RelativePathCompat $root $workerDir
            rule = 'Return candidate EP markdown plus EP-XX.manifest.json. Do not write project authority files.'
        }
        Write-JsonAtomic $briefPath $payload
    }
    return $assignments.ToArray()
}

function Get-ReviewEpisodes([object]$Batch) {
    return @(Resolve-ComicEpisodeRange ([string]$Batch.active_review_range))
}

function Test-Candidate([object]$Batch, [object]$Contract, [int]$Episode, [string]$CandidateBase) {
    $token = Get-ComicEpisodeToken $Episode
    $scriptMatches = @(Get-ChildItem -LiteralPath $CandidateBase -Recurse -File -Filter ($token + '.md'))
    $manifestMatches = @(Get-ChildItem -LiteralPath $CandidateBase -Recurse -File -Filter ($token + '.manifest.json'))
    if ($scriptMatches.Count -ne 1 -or $manifestMatches.Count -ne 1) { throw "$token requires exactly one candidate script and one manifest." }
    $manifest = Read-Json $manifestMatches[0].FullName
    if (-not $manifest -or [string]$manifest.schema_version -ne 'comic-adapt-candidate-manifest/1.0') { throw "Invalid manifest schema: $token" }
    $episodeContract = @($Contract.episode_contracts | Where-Object { [string]$_.episode -eq $token } | Select-Object -First 1)
    if ($episodeContract.Count -eq 0) { throw "Frozen contract is missing $token" }
    $episodeContract = $episodeContract[0]
    $hashes = Get-ComicScriptHashes $scriptMatches[0].FullName
    $contractPath = Join-Path $root ([string]$Batch.contract_path)
    $contractHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $contractPath).Hash.ToLowerInvariant()
    foreach ($pair in @(
        @('episode', $token, [string]$manifest.episode),
        @('script_sha256', $hashes.raw_sha256, [string]$manifest.script_sha256),
        @('core_sha256', $hashes.core_sha256, [string]$manifest.core_sha256),
        @('batch_contract_sha256', $contractHash, [string]$manifest.batch_contract_sha256),
        @('entry_state', [string]$episodeContract.entry_state, [string]$manifest.entry_state),
        @('exit_state', [string]$episodeContract.exit_state, [string]$manifest.exit_state),
        @('knowledge_delta', [string]$episodeContract.knowledge_delta, [string]$manifest.knowledge_delta),
        @('source_time', [string]$episodeContract.source_time, [string]$manifest.source_time)
    )) { if ($pair[1] -ne $pair[2]) { throw "$token manifest mismatch: $($pair[0])" } }
    foreach ($field in @('entity_refs', 'asset_transitions', 'ledger_delta')) {
        if (-not $manifest.PSObject.Properties[$field]) { throw "$token manifest missing $field" }
        Assert-ExactStringList @($episodeContract.$field) @($manifest.$field) $token $field
    }
    foreach ($id in @($manifest.entity_refs)) { if ([string]$id -notmatch '^(?:CHR|SCN|PRP|GRP|BIO|VOC|Q)-\d+$') { throw "$token invalid entity ID: $id" } }
    return [ordered]@{ token = $token; script = $scriptMatches[0].FullName; manifest = $manifestMatches[0].FullName; hashes = $hashes }
}

if ($Mode -eq 'Init') {
    if (-not $Range) { throw 'Init requires -Range N-M.' }
    if ((Test-Path -LiteralPath $statePath -PathType Leaf) -and -not $Force) { throw "Batch run already exists: $statePath" }
    $episodes = @(Resolve-ComicEpisodeRange $Range)
    if ($episodes.Count -lt 2) { throw 'Batch mode requires at least two episodes.' }
    & $sourceIndexScript -ProjectRoot $root -Mode Validate 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { & $sourceIndexScript -ProjectRoot $root -Mode Build | Out-Null }
    $index = Read-Json (Join-Path $root '.comic-adapt-cache\source-index.json')
    if (-not $index) { throw 'Source index is required for batch planning.' }
    $state = [ordered]@{
        schema_version = 'comic-adapt-batch-run/1.0'; range = $episodes[0].ToString() + '-' + $episodes[-1].ToString()
        status = 'RUNNING'; started_at = (Get-Date).ToString('o'); updated_at = (Get-Date).ToString('o')
        batches = @(New-Batches $episodes $index)
    }
    Write-JsonAtomic $statePath $state
    Write-Output ("BATCH-RUN-INIT: range={0}; batches={1}; sizes={2}; path={3}" -f $state.range, @($state.batches).Count, (@($state.batches | ForEach-Object { ([int]$_.end - [int]$_.start + 1) }) -join ','), $statePath)
    exit 0
}

$state = Read-State
if ($Mode -eq 'Status') {
    $groups = @($state.batches | Group-Object state | Sort-Object Name | ForEach-Object { $_.Name + '=' + $_.Count })
    Write-Output ("BATCH-STATUS: range={0}; status={1}; {2}" -f $state.range, $state.status, ($groups -join '; '))
    foreach ($item in $state.batches) { Write-Output ("BATCH-ITEM: {0}; range={1}-{2}; risk={3}; state={4}; committed-through={5}" -f $item.batch_id, $item.start, $item.end, $item.risk, $item.state, $item.committed_through) }
    exit 0
}
if ($Mode -eq 'Next' -and @($state.batches | Where-Object { [string]$_.state -ne 'BATCH_COMMITTED' }).Count -eq 0) {
    Write-Output 'BATCH-TARGET-REACHED'
    exit 0
}
$batch = Get-Batch $state $BatchId
$BatchId = [string]$batch.batch_id
$batchRange = Get-BatchRange $batch

if ($Mode -eq 'Plan') {
    if ([string]$batch.state -ne 'PENDING' -and -not $Force) { throw "$BatchId cannot Plan from state $($batch.state)" }
    $contracts = [Collections.Generic.List[object]]::new()
    foreach ($episode in ([int]$batch.start)..([int]$batch.end)) {
        Invoke-Step $batch ('source_read:' + (Get-ComicEpisodeToken $episode)) $prefetchScript @{ ProjectRoot = $root; Episode = $episode; Window = 1 } | Out-Null
        $prefetch = Read-Json (Join-Path $root ('.comic-adapt-cache\prefetch\' + (Get-ComicEpisodeToken $episode) + '.json'))
        if (-not $prefetch) { throw "Missing prefetch packet: episode=$episode" }
        if (@($prefetch.source_files).Count -eq 0) { throw "Batch planning requires at least one source chapter: episode=$episode" }
        $contracts.Add([pscustomobject][ordered]@{
            episode = Get-ComicEpisodeToken $episode
            risk_flags = @($(Get-EpisodeRisk (Read-Json (Join-Path $root '.comic-adapt-cache\source-index.json')) $episode))
            source_files = @($prefetch.source_files)
            plot_point_ids = @($prefetch.plot_points | ForEach-Object { [int]$_.id })
            must_keep = @($prefetch.must_keep_coverage | ForEach-Object { [string]$_.item })
            entry_state = '待主编冻结'; exit_state = '待主编冻结'; knowledge_delta = '待主编冻结'; source_time = '待主编冻结'
            entity_refs = @($prefetch.relevant_entities | ForEach-Object { [string]$_.id } | Where-Object { $_ } | Sort-Object -Unique)
            asset_transitions = @(); ledger_delta = @()
            incoming_seam_sha256 = ''; outgoing_seam_sha256 = ''; contract_sha256 = ''
        })
        Advance-Goal $episode 'PENDING' @('PREFETCHED')
    }
    $contractPath = Join-Path $root ([string]$batch.contract_path)
    $contract = [ordered]@{
        schema_version = 'comic-adapt-batch-contract/1.0'; batch_id = $BatchId; range = $batchRange
        contract_status = 'DRAFT'; generated_at = (Get-Date).ToString('o'); frozen_at = $null
        rule = 'Main editor freezes entry/exit/knowledge/source-time before parallel drafting. Source chapters remain authoritative.'
        episode_contracts = $contracts.ToArray(); seams = @(); semantic_sha256 = ''
    }
    Write-JsonAtomic $contractPath $contract
    $batch.state = 'BATCH_PLANNED'; $batch.updated_at = (Get-Date).ToString('o')
    Save-State $state
    Write-Output "BATCH-PLANNED: $BatchId contract=$contractPath"
    Write-Output 'BATCH-NEXT: Fill entry_state, exit_state, knowledge_delta, source_time, asset_transitions and ledger_delta, then run Freeze.'
    exit 0
}

if ($Mode -eq 'Freeze') {
    if ([string]$batch.state -ne 'BATCH_PLANNED' -and -not $Force) { throw "$BatchId cannot Freeze from state $($batch.state)" }
    $contractPath = Join-Path $root ([string]$batch.contract_path)
    $inputPath = if ($SkeletonPath) { Resolve-PathFromRoot $SkeletonPath } else { $contractPath }
    $contract = Read-Json $inputPath
    if (-not $contract -or [string]$contract.schema_version -ne 'comic-adapt-batch-contract/1.0') { throw 'Freeze requires a comic-adapt-batch-contract/1.0 skeleton.' }
    $expected = @(([int]$batch.start)..([int]$batch.end) | ForEach-Object { Get-ComicEpisodeToken $_ })
    $actual = @($contract.episode_contracts | ForEach-Object { [string]$_.episode })
    if (@($expected | Where-Object { $_ -notin $actual }).Count -gt 0 -or @($actual | Where-Object { $_ -notin $expected }).Count -gt 0) { throw 'Skeleton episode range differs from batch.' }
    foreach ($episodeContract in @($contract.episode_contracts)) {
        foreach ($field in @('entry_state', 'exit_state', 'knowledge_delta', 'source_time')) {
            $value = [string]$episodeContract.$field
            if (-not $value -or $value -match '待主编冻结|待补|TODO') { throw "$($episodeContract.episode) field is not frozen: $field" }
        }
        foreach ($field in @('entity_refs', 'asset_transitions', 'ledger_delta')) {
            if (-not $episodeContract.PSObject.Properties[$field]) { throw "$($episodeContract.episode) frozen contract missing $field" }
            Assert-ExactStringList @($episodeContract.$field) @($episodeContract.$field) ([string]$episodeContract.episode) $field
        }
        foreach ($id in @($episodeContract.entity_refs)) {
            if ([string]$id -notmatch '^(?:CHR|SCN|PRP|GRP|BIO|VOC|Q)-\d+$') { throw "$($episodeContract.episode) frozen contract has invalid entity ID: $id" }
        }
        $semantic = [ordered]@{
            episode = [string]$episodeContract.episode; must_keep = @($episodeContract.must_keep)
            entry_state = [string]$episodeContract.entry_state; exit_state = [string]$episodeContract.exit_state
            knowledge_delta = [string]$episodeContract.knowledge_delta; source_time = [string]$episodeContract.source_time
            entity_refs = @($episodeContract.entity_refs); asset_transitions = @($episodeContract.asset_transitions); ledger_delta = @($episodeContract.ledger_delta)
        }
        $episodeContract.contract_sha256 = Get-TextSha256 ($semantic | ConvertTo-Json -Depth 12 -Compress)
        $episodeContract.incoming_seam_sha256 = ''; $episodeContract.outgoing_seam_sha256 = ''
    }
    $seams = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt (@($contract.episode_contracts).Count - 1); $index++) {
        $left = $contract.episode_contracts[$index]; $right = $contract.episode_contracts[$index + 1]
        $seamPayload = [ordered]@{ left = [string]$left.episode; left_exit = [string]$left.exit_state; right = [string]$right.episode; right_entry = [string]$right.entry_state }
        $seamHash = Get-TextSha256 ($seamPayload | ConvertTo-Json -Depth 6 -Compress)
        $left.outgoing_seam_sha256 = $seamHash; $right.incoming_seam_sha256 = $seamHash
        $seams.Add([ordered]@{ left = [string]$left.episode; right = [string]$right.episode; sha256 = $seamHash })
    }
    $contract.seams = $seams.ToArray(); $contract.contract_status = 'FROZEN'; $contract.frozen_at = (Get-Date).ToString('o')
    $contract.semantic_sha256 = Get-TextSha256 ((@($contract.episode_contracts) | ConvertTo-Json -Depth 20 -Compress))
    Write-JsonAtomic $contractPath $contract
    $assignments = @(Write-WorkerBriefs $batch $contract $contractPath)
    $batch.state = 'SEAMS_FROZEN'; $batch.updated_at = (Get-Date).ToString('o')
    Set-Property $batch 'worker_assignments' $assignments
    Save-State $state
    $contractFileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $contractPath).Hash.ToLowerInvariant()
    Write-Output ("BATCH-SEAMS-FROZEN: {0}; seams={1}; workers={2}; contract={3}; sha256={4}" -f $BatchId, $seams.Count, $assignments.Count, $contractPath, $contractFileHash)
    exit 0
}

if ($Mode -in @('Candidates', 'Repair')) {
    if (-not $CandidateRoot) { throw "$Mode requires -CandidateRoot." }
    $allowedState = if ($Mode -eq 'Repair') { 'REPAIRING' } else { 'SEAMS_FROZEN' }
    if ([string]$batch.state -ne $allowedState -and -not $Force) { throw "$BatchId cannot $Mode from state $($batch.state)" }
    $candidateBase = Resolve-PathFromRoot $CandidateRoot
    if (-not (Test-Path -LiteralPath $candidateBase -PathType Container)) { throw "Missing candidate root: $candidateBase" }
    $contract = Get-Contract $batch
    $episodes = if ($Mode -eq 'Repair') {
        @($batch.repair_scope | ForEach-Object { if ([string]$_ -match '^EP-0*(\d+)$') { [int]$Matches[1] } })
    } else { @(([int]$batch.start)..([int]$batch.end)) }
    if ($episodes.Count -eq 0) { throw 'No candidate episodes were selected.' }
    foreach ($episode in $episodes) {
        $candidate = Test-Candidate $batch $contract $episode $candidateBase
        $destination = Join-Path $root ('scripts\' + $candidate.token + '.md')
        $existingReceipt = Read-Json (Join-Path $root ('.comic-adapt\quality\' + $candidate.token + '.json'))
        if ((Test-Path -LiteralPath $destination -PathType Leaf) -and $existingReceipt -and [string]$existingReceipt.status -eq 'PASS' -and -not $Force -and $Mode -ne 'Repair') {
            throw "Refusing to overwrite an existing PASS script: $($candidate.token)"
        }
        Write-TextAtomic $destination (Get-Content -Raw -Encoding UTF8 -LiteralPath $candidate.script)
        $manifestCopy = Join-Path $root ('.comic-adapt-cache\manifests\' + $candidate.token + '.json')
        Write-TextAtomic $manifestCopy (Get-Content -Raw -Encoding UTF8 -LiteralPath $candidate.manifest)
        Advance-Goal $episode 'PREFETCHED' @('DRAFTED')
        Write-Output "BATCH-CANDIDATE-INGESTED: $($candidate.token) core=$($candidate.hashes.core_sha256)"
    }
    $batch.active_review_range = ($episodes | Measure-Object -Minimum).Minimum.ToString() + '-' + ($episodes | Measure-Object -Maximum).Maximum.ToString()
    $batch.state = 'CANDIDATES_READY'; $batch.updated_at = (Get-Date).ToString('o')
    Save-State $state
    Write-Output ("BATCH-CANDIDATES-READY: {0}; active={1}" -f $BatchId, $batch.active_review_range)
    exit 0
}

if ($Mode -eq 'PreReview') {
    if ([string]$batch.state -ne 'CANDIDATES_READY' -and -not $Force) { throw "$BatchId cannot PreReview from state $($batch.state)" }
    $episodes = @(Get-ReviewEpisodes $batch); $activeRange = $episodes[0].ToString() + '-' + $episodes[-1].ToString()
    $contractPath = Join-Path $root ([string]$batch.contract_path)
    foreach ($episode in $episodes) {
        $scriptItem = Find-Script $episode
        if (-not $scriptItem) { throw "Missing ingested script: episode=$episode" }
        Invoke-Step $batch ('draft_gate:' + (Get-ComicEpisodeToken $episode)) $lintScript @{ Path = $scriptItem.FullName; Draft = $true } | Out-Null
    }
    Invoke-Step $batch 'batch_visual_sync' $visualScript @{ ProjectRoot = $root; Mode = 'Sync'; PassEp = $activeRange } | Out-Null
    Invoke-Step $batch 'batch_ledger_plan' $ledgerScript @{ ProjectRoot = $root; Mode = 'Plan'; PassEp = $activeRange } | Out-Null
    foreach ($episode in $episodes) {
        Invoke-Step $batch ('episode_contract:' + (Get-ComicEpisodeToken $episode)) $packetScript @{ ProjectRoot = $root; Episode = $episode; Stage = 'Write'; BatchContractPath = $contractPath } | Out-Null
    }
    Invoke-Step $batch 'batch_visual_preflight' $visualScript @{ ProjectRoot = $root; Mode = 'Preflight'; PassEp = $activeRange; BatchContractPath = $contractPath } | Out-Null
    foreach ($episode in $episodes) {
        Invoke-Step $batch ('review_packet:' + (Get-ComicEpisodeToken $episode)) $packetScript @{ ProjectRoot = $root; Episode = $episode; Stage = 'Review' } | Out-Null
        Advance-Goal $episode 'DRAFTED' @('MACHINE_PASS')
    }
    $batch.state = 'DRAFTS_LINT_PASS'; $batch.updated_at = (Get-Date).ToString('o')
    Save-State $state
    Write-Output ("BATCH-DRAFTS-LINT-PASS: {0}; active={1}" -f $BatchId, $activeRange)
    exit 0
}

if ($Mode -eq 'PlanReview') {
    if ([string]$batch.state -ne 'DRAFTS_LINT_PASS' -and -not $Force) { throw "$BatchId cannot PlanReview from state $($batch.state)" }
    $activeRange = [string]$batch.active_review_range
    Invoke-Step $batch 'batch_checker_plan' $qualityScript @{ ProjectRoot = $root; Mode = 'PlanBatch'; Range = $activeRange; BatchId = $BatchId; Operation = 'write' } | Out-Null
    $planPath = Join-Path $root ('.comic-adapt-cache\quality-plans\' + $BatchId + '.json')
    $plan = Read-Json $planPath
    $batch.review_plan_path = Get-RelativePathCompat $root $planPath
    $batch.checker_brief_path = [string]$plan.checker_brief.path
    $batch.updated_at = (Get-Date).ToString('o')
    Save-State $state
    Write-Output ("BATCH-READY-FOR-CHECKER: {0}; brief={1}" -f $BatchId, (Join-Path $root $batch.checker_brief_path))
    exit 0
}

if ($Mode -eq 'RecordReview') {
    if ([string]$batch.state -ne 'DRAFTS_LINT_PASS' -and -not $Force) { throw "$BatchId cannot RecordReview from state $($batch.state)" }
    if (-not $ResultsPath) { throw 'RecordReview requires -ResultsPath.' }
    $activeRange = [string]$batch.active_review_range
    $recordOutput = @(Invoke-Step $batch 'batch_checker_record' $qualityScript @{ ProjectRoot = $root; Mode = 'RecordBatch'; Range = $activeRange; BatchId = $BatchId; ResultsPath = $ResultsPath; Operation = 'write' } -AllowFailure)
    $exitCode = [int]$recordOutput[-1]
    foreach ($line in @($recordOutput | Select-Object -SkipLast 1)) { Write-Output $line }
    $receiptPath = Join-Path $root ('.comic-adapt-cache\quality-batches\' + $BatchId + '.json')
    $receipt = Read-Json $receiptPath
    if (-not $receipt) { throw "Missing batch receipt: $receiptPath" }
    $batch.results_path = Get-RelativePathCompat $root (Resolve-PathFromRoot $ResultsPath)
    $batch.repair_scope = @($receipt.repair_scope)
    $batch.state = if ([string]$receipt.status -eq 'PASS') { 'BATCH_REVIEWED' } else { 'REPAIRING' }
    $batch.updated_at = (Get-Date).ToString('o')
    Save-State $state
    Write-Output ("BATCH-REVIEW-RECORDED: {0}; state={1}; repair={2}" -f $BatchId, $batch.state, (@($batch.repair_scope) -join ','))
    if ($exitCode -ne 0) { exit $exitCode }
    exit 0
}

if ($Mode -eq 'Commit') {
    if ([string]$batch.state -notin @('BATCH_REVIEWED', 'REPAIRING') -and -not $Force) { throw "$BatchId cannot Commit from state $($batch.state)" }
    $start = [Math]::Max([int]$batch.start, [int]$batch.committed_through + 1)
    $prefixEnd = $start - 1
    for ($episode = $start; $episode -le [int]$batch.end; $episode++) {
        $token = Get-ComicEpisodeToken $episode
        $receipt = Read-Json (Join-Path $root ('.comic-adapt\quality\' + $token + '.json'))
        $scriptItem = Find-Script $episode
        if (-not $receipt -or [string]$receipt.status -ne 'PASS' -or -not $scriptItem) { break }
        $hashes = Get-ComicScriptHashes $scriptItem.FullName
        if ([string]$receipt.checked_core_sha256 -and [string]$receipt.checked_core_sha256 -ne [string]$hashes.core_sha256) { break }
        $prefixEnd = $episode
    }
    if ($prefixEnd -lt $start) { throw 'No continuous semantic-PASS prefix is available for Commit.' }
    $commitRange = $start.ToString() + '-' + $prefixEnd.ToString()
    $journalPath = Join-Path $root ('.comic-adapt-cache\transactions\' + $BatchId + '.commit.json')
    $inputCoreHashes = Get-CommitInputCoreHashes $start $prefixEnd
    $currentStateHash = Get-CommitStateHash $start $prefixEnd
    $existingJournal = Read-Json $journalPath
    if ($existingJournal -and [string]$existingJournal.schema_version -eq 'comic-adapt-batch-commit/1.1' -and [string]$existingJournal.range -eq $commitRange -and [string]$existingJournal.status -ne 'COMPLETED') {
        if ((Get-CommitInputSignature $existingJournal.input_core_hashes) -ne (Get-CommitInputSignature $inputCoreHashes)) {
            throw 'Commit input core hashes differ from the recoverable journal; semantic re-review is required.'
        }
        $journal = $existingJournal
        $completed = @($journal.completed_steps)
        $expectedStateHash = if ($completed.Count -gt 0) { [string]$completed[-1].post_state_sha256 } else { [string]$journal.pre_state_sha256 }
        if ($expectedStateHash -ne $currentStateHash) {
            Set-Property $journal 'completed_steps' @()
            Set-Property $journal 'pre_state_sha256' $currentStateHash
            Set-Property $journal 'restarted_due_to_state_drift_at' (Get-Date).ToString('o')
            Write-Output 'BATCH-COMMIT-RECOVERY-RESTART: transaction outputs drifted after the last completed step; all gates will rerun.'
        } else {
            Write-Output ("BATCH-COMMIT-RECOVERY-RESUME: completed={0}" -f $completed.Count)
        }
        $journal.status = 'RUNNING'; $journal.finished_at = $null; $journal.error = ''
    } else {
        $journal = [ordered]@{
            schema_version = 'comic-adapt-batch-commit/1.1'; batch_id = $BatchId; range = $commitRange
            status = 'RUNNING'; started_at = (Get-Date).ToString('o'); finished_at = $null; error = ''
            input_core_hashes = $inputCoreHashes; pre_state_sha256 = $currentStateHash; completed_steps = @()
        }
    }
    Write-JsonAtomic $journalPath $journal
    try {
        Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd 'batch_ledger_preflight' $ledgerPreflightScript @{ ProjectRoot = $root; PassEp = $commitRange; ScriptLintPath = $lintScript }
        Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd 'batch_ledger_apply' $lintScript @{ Path = $root; FixProgress = $true; PassEp = $commitRange }
        Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd 'batch_ledger_verify' $ledgerScript @{ ProjectRoot = $root; Mode = 'Verify'; PassEp = $commitRange }
        Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd 'batch_visual_sync_final' $visualScript @{ ProjectRoot = $root; Mode = 'Sync'; PassEp = $commitRange }
        $commitContractPath = Join-Path $root ([string]$batch.contract_path)
        Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd 'batch_visual_preflight_final' $visualScript @{ ProjectRoot = $root; Mode = 'Preflight'; PassEp = $commitRange; BatchContractPath = $commitContractPath }
        Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd 'batch_visual_ready' $visualScript @{ ProjectRoot = $root; Mode = 'Ready'; PassEp = $commitRange; BatchContractPath = $commitContractPath }
        Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd 'batch_visual_validate' $visualScript @{ ProjectRoot = $root; Mode = 'Validate'; PassEp = $commitRange; BatchContractPath = $commitContractPath }
        Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd 'batch_visual_index' $visualScript @{ ProjectRoot = $root; Mode = 'Index'; PassEp = $commitRange }
        Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd 'batch_visual_status' $visualScript @{ ProjectRoot = $root; Mode = 'Status'; PassEp = $commitRange }
        foreach ($episode in $start..$prefixEnd) {
            $token = Get-ComicEpisodeToken $episode
            Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd ('final_packet:' + $token) $packetScript @{ ProjectRoot = $root; Episode = $episode; Stage = 'Final' }
            Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd ('quality_close_plan:' + $token) $qualityScript @{ ProjectRoot = $root; Mode = 'Plan'; Target = $token; Kind = 'Script'; Operation = 'format' }
            $plan = Read-Json (Join-Path $root ('.comic-adapt-cache\quality-plans\' + $token + '.json'))
            $forbidden = @($plan.changed_scopes | Where-Object { $_ -in @('core_file', 'core_semantic', 'continuity', 'timeline', 'visual') })
            if ($forbidden.Count -gt 0) { throw "$token Commit changed semantic scopes: $($forbidden -join ',')" }
            if ([string]$plan.action -ne 'REUSE_PASS') {
                $scriptItem = Find-Script $episode; $rawHash = (Get-ComicScriptHashes $scriptItem.FullName).raw_sha256
                Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd ('quality_machine_close:' + $token) $qualityScript @{
                    ProjectRoot = $root; Mode = 'Record'; Target = $token; Kind = 'Script'; Operation = 'format'
                    Result = 'PASS'; CheckerMode = 'Machine'; EventType = 'machine_closure'
                    TouchedScopes = (@($plan.changed_scopes) -join ','); CheckedHash = $rawHash
                }
                Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd ('quality_reuse_plan:' + $token) $qualityScript @{ ProjectRoot = $root; Mode = 'Plan'; Target = $token; Kind = 'Script'; Operation = 'format' }
                $plan = Read-Json (Join-Path $root ('.comic-adapt-cache\quality-plans\' + $token + '.json'))
                if ([string]$plan.action -notin @('REUSE_PASS', 'REUSE_LEGACY_PASS')) { throw "$token quality closure remains pending: $($plan.action)" }
            }
            Advance-Goal $episode 'SEMANTIC_PASS' @('COMMITTED', 'COMPLETE')
        }
        if (($prefixEnd % 10) -eq 0) {
            Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd 'visual_index_full_checkpoint' $visualScript @{ ProjectRoot = $root; Mode = 'Index' }
            Invoke-CommitStep $journal $journalPath $batch $start $prefixEnd 'visual_status_full_checkpoint' $visualScript @{ ProjectRoot = $root; Mode = 'Status' }
        }
        $batch.committed_through = $prefixEnd
        $batch.state = if ($prefixEnd -eq [int]$batch.end) { 'BATCH_COMMITTED' } else { 'REPAIRING' }
        $batch.updated_at = (Get-Date).ToString('o')
        if (@($state.batches | Where-Object { [string]$_.state -ne 'BATCH_COMMITTED' }).Count -eq 0) { $state.status = 'TARGET_REACHED' }
        Save-State $state
        $journal.status = 'COMPLETED'; $journal.finished_at = (Get-Date).ToString('o'); Write-JsonAtomic $journalPath $journal
        Write-Output ("BATCH-COMMIT: {0}; range={1}; state={2}; journal={3}" -f $BatchId, $commitRange, $batch.state, $journalPath)
        exit 0
    } catch {
        $journal.status = 'RECOVERABLE_FAIL'; $journal.error = $_.Exception.Message; $journal.finished_at = (Get-Date).ToString('o'); Write-JsonAtomic $journalPath $journal
        throw
    }
}

if ($Mode -eq 'Next') {
    $ps = 'powershell -NoProfile -ExecutionPolicy Bypass -File'
    $self = $PSCommandPath
    switch ([string]$batch.state) {
        'PENDING' { $action = 'PLAN_BATCH'; $command = "$ps `"$self`" -ProjectRoot `"$root`" -Mode Plan -BatchId $BatchId" }
        'BATCH_PLANNED' { $action = 'FREEZE_SEAMS'; $command = "$ps `"$self`" -ProjectRoot `"$root`" -Mode Freeze -BatchId $BatchId -SkeletonPath `"$(Join-Path $root $batch.contract_path)`"" }
        'SEAMS_FROZEN' {
            $action = 'GENERATE_PARALLEL_CANDIDATES'
            $candidatePath = Join-Path $root ('.comic-adapt-cache\staging\' + $BatchId)
            $command = "$ps `"$self`" -ProjectRoot `"$root`" -Mode Candidates -BatchId $BatchId -CandidateRoot `"$candidatePath`""
        }
        'CANDIDATES_READY' { $action = 'RUN_BATCH_PRE_REVIEW'; $command = "$ps `"$self`" -ProjectRoot `"$root`" -Mode PreReview -BatchId $BatchId" }
        'DRAFTS_LINT_PASS' {
            if ($batch.checker_brief_path) { $action = 'RUN_BATCH_CHECKER_AND_RECORD'; $command = "Checker reads $($batch.checker_brief_path); then run RecordReview -ResultsPath <json>." }
            else { $action = 'PLAN_BATCH_REVIEW'; $command = "$ps `"$self`" -ProjectRoot `"$root`" -Mode PlanReview -BatchId $BatchId" }
        }
        'BATCH_REVIEWED' { $action = 'COMMIT_PASS_PREFIX'; $command = "$ps `"$self`" -ProjectRoot `"$root`" -Mode Commit -BatchId $BatchId" }
        'REPAIRING' { $action = 'REPAIR_ISOLATED_SCOPE'; $command = "Repair $(@($batch.repair_scope) -join ',') and adjacent seams only; then run Repair -CandidateRoot <path>." }
        default { $action = 'NO_ACTION'; $command = 'NO_COMMAND' }
    }
    $nextPath = Join-Path $root '.comic-adapt-cache\next-action.json'
    Write-JsonAtomic $nextPath ([ordered]@{ schema_version = 'comic-adapt-batch-next-action/1.0'; batch_id = $BatchId; range = $batchRange; state = [string]$batch.state; action = $action; command = $command; resources = @($batch.contract_path, $batch.checker_brief_path | Where-Object { $_ }) })
    Write-Output ("BATCH-NEXT: {0}; state={1}; action={2}" -f $BatchId, $batch.state, $action)
    Write-Output "BATCH-COMMAND: $command"
    exit 0
}

throw "Unsupported batch mode: $Mode"

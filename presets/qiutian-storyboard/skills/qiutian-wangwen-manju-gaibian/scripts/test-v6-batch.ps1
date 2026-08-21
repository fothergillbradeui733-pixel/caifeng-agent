[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComicAdapt.Common.psm1') -Force
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('comic-adapt-v6-batch-' + [guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$resolvedTest = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTest.StartsWith($resolvedTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedTest) -notmatch '^comic-adapt-v6-batch-[0-9a-f]{32}$') { throw 'Unsafe test root.' }

function Assert-True([bool]$Value, [string]$Name) {
    if (-not $Value) { throw "ASSERT FAILED: $Name" }
    Write-Output "TEST-PASS: $Name"
}

function Invoke-Checked([string]$Script, [hashtable]$Arguments) {
    $output = & $Script @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Command failed: $Script exit=$code`n$($output | Out-String)" }
    return @($output)
}

function Invoke-Captured([string]$Script, [hashtable]$Arguments) {
    try {
        $output = & $Script @Arguments 2>&1
        return [ordered]@{ exit = $LASTEXITCODE; output = ($output | Out-String) }
    } catch {
        return [ordered]@{ exit = 1; output = (($_ | Out-String) + ($output | Out-String)) }
    }
}

try {
    [void](New-Item -ItemType Directory -Force -Path $testRoot)
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $testRoot 'novel'))
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $testRoot 'scripts'))
    Invoke-Checked (Join-Path $PSScriptRoot 'workflow-policy.ps1') @{ ProjectRoot = $testRoot; Mode = 'Init'; ExecutionProfile = 'long_run_batch' } | Out-Null
    $plot = [Collections.Generic.List[string]]::new()
    $plot.Add('# 剧情地图')
    for ($episode = 1; $episode -le 6; $episode++) {
        $plot.Add("### 【剧情$($episode.ToString('D2'))】测试$episode")
        $plot.Add("- **归属集数**：EP-$($episode.ToString('D2'))")
        $plot.Add("- **原著章节**：第${episode}章")
        $plot.Add("- **原著锚点**：测试锚$episode")
        $plot.Add("- **原著内容**：角色完成事件$episode")
        $plot.Add('- **行动主体/承受主体**：甲/乙')
        $plot.Add('- **信息流**：甲当场得知')
        $plot.Add("- **必保清单**：事件$episode")
        $plot.Add('- **改编处理**：忠实呈现')
        $plot.Add('- **可拍性**：动作落地')
        Write-TextAtomic (Join-Path $testRoot ("novel\第{0}章.txt" -f $episode)) (('原著测试内容。' * 120) + "`n")
    }
    Write-TextAtomic (Join-Path $testRoot 'plot-map.md') (($plot -join "`n") + "`n")
    Write-TextAtomic (Join-Path $testRoot 'progress.md') "# 改编进度`n"
    $batchRunner = Join-Path $PSScriptRoot 'batch-runner.ps1'
    Invoke-Checked (Join-Path $PSScriptRoot 'goal-runner.ps1') @{ ProjectRoot = $testRoot; Mode = 'Init'; Task = 'write'; Range = '1-6' } | Out-Null
    $goal = Read-Json (Join-Path $testRoot '.comic-adapt\goal-run.json')
    Assert-True ([string]$goal.execution_profile -eq 'long_run_batch') 'goal runner routes a six-episode target into long_run_batch'
    $state = Read-Json (Join-Path $testRoot '.comic-adapt\batch-run.json')
    Assert-True (@($state.batches).Count -eq 1 -and [string]$state.batches[0].batch_id -eq 'BATCH-1-6') 'low/medium six-episode goal forms one dynamic batch'
    Invoke-Checked $batchRunner @{ ProjectRoot = $testRoot; Mode = 'Plan'; BatchId = 'BATCH-1-6' } | Out-Null
    $state = Read-Json (Join-Path $testRoot '.comic-adapt\batch-run.json')
    $contractPath = Join-Path $testRoot ([string]$state.batches[0].contract_path)
    $contract = Read-Json $contractPath
    foreach ($item in @($contract.episode_contracts)) {
        $item.entry_state = '承接上一集完成态'; $item.exit_state = '本集事件完成'; $item.knowledge_delta = '甲得知本集事实'; $item.source_time = '原著未明示'
    }
    Write-JsonAtomic $contractPath $contract
    $freezeOutput = @(Invoke-Checked $batchRunner @{ ProjectRoot = $testRoot; Mode = 'Freeze'; BatchId = 'BATCH-1-6'; SkeletonPath = $contractPath })
    $contract = Read-Json $contractPath
    Assert-True ([string]$contract.contract_status -eq 'FROZEN' -and @($contract.seams).Count -eq 5) 'Freeze signs every adjacent seam'
    Assert-True ((($freezeOutput | Out-String) -match 'sha256=[0-9a-f]{64}')) 'Freeze reports the immutable contract file hash'
    $nextOutput = @(Invoke-Checked $batchRunner @{ ProjectRoot = $testRoot; Mode = 'Next'; BatchId = 'BATCH-1-6' })
    Assert-True ((($nextOutput | Out-String) -match '-Mode Candidates.+-CandidateRoot.+BATCH-1-6')) 'Next emits a directly executable Candidates command with CandidateRoot'
    $candidateRoot = Join-Path $testRoot 'candidate-output'
    [void](New-Item -ItemType Directory -Force -Path $candidateRoot)
    $contractHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $contractPath).Hash.ToLowerInvariant()
    foreach ($item in @($contract.episode_contracts)) {
        $number = [int]([regex]::Match([string]$item.episode, '\d+').Value)
        $scriptPath = Join-Path $candidateRoot ([string]$item.episode + '.md')
        $scriptText = "剧名：《测试》`n集数：$($item.episode)  测试`n对应剧情点：【剧情$($number.ToString('D2'))】`n原著章节：第$number 章`n场次 $($number.ToString('D2'))-1：内  测试屋  日`n出场人物：甲`n△ （中景）甲完成本集事件。`n甲`n完成了。`n【卡黑】`n"
        Write-TextAtomic $scriptPath $scriptText
        $hashes = Get-ComicScriptHashes $scriptPath
        $manifest = [ordered]@{
            schema_version = 'comic-adapt-candidate-manifest/1.0'; episode = [string]$item.episode
            script_sha256 = $hashes.raw_sha256; core_sha256 = $hashes.core_sha256; batch_contract_sha256 = $contractHash
            entry_state = [string]$item.entry_state; exit_state = [string]$item.exit_state
            knowledge_delta = [string]$item.knowledge_delta; source_time = [string]$item.source_time
            entity_refs = @(); asset_transitions = @(); ledger_delta = @()
        }
        Write-JsonAtomic (Join-Path $candidateRoot ([string]$item.episode + '.manifest.json')) $manifest
    }
    $mismatchPath = Join-Path $candidateRoot 'EP-01.manifest.json'
    $mismatchManifest = Read-Json $mismatchPath
    $mismatchManifest.entity_refs = @('CHR-999')
    Write-JsonAtomic $mismatchPath $mismatchManifest
    $mismatchResult = Invoke-Captured $batchRunner @{ ProjectRoot = $testRoot; Mode = 'Candidates'; BatchId = 'BATCH-1-6'; CandidateRoot = $candidateRoot }
    Assert-True ($mismatchResult.exit -ne 0 -and $mismatchResult.output -match 'manifest mismatch: entity_refs') 'candidate entity refs must exactly match the frozen contract'
    $mismatchManifest.entity_refs = @()
    $mismatchManifest.asset_transitions = @('PRP-999:虚构转场')
    Write-JsonAtomic $mismatchPath $mismatchManifest
    $transitionResult = Invoke-Captured $batchRunner @{ ProjectRoot = $testRoot; Mode = 'Candidates'; BatchId = 'BATCH-1-6'; CandidateRoot = $candidateRoot }
    Assert-True ($transitionResult.exit -ne 0 -and $transitionResult.output -match 'manifest mismatch: asset_transitions') 'candidate asset transitions must exactly match the frozen contract'
    $mismatchManifest.asset_transitions = @()
    Write-JsonAtomic $mismatchPath $mismatchManifest
    Invoke-Checked $batchRunner @{ ProjectRoot = $testRoot; Mode = 'Candidates'; BatchId = 'BATCH-1-6'; CandidateRoot = $candidateRoot } | Out-Null
    $state = Read-Json (Join-Path $testRoot '.comic-adapt\batch-run.json')
    Assert-True ([string]$state.batches[0].state -eq 'CANDIDATES_READY' -and (Test-Path -LiteralPath (Join-Path $testRoot 'scripts\EP-06.md'))) 'candidate manifests gate serial authority ingest'
    $progressBeforePreflight = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $testRoot 'progress.md')).Hash.ToLowerInvariant()
    $ledgerPreflight = Invoke-Captured (Join-Path $PSScriptRoot 'ledger-commit-preflight.ps1') @{ ProjectRoot = $testRoot; PassEp = '1-6' }
    Assert-True ($ledgerPreflight.exit -ne 0 -and (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $testRoot 'progress.md')).Hash.ToLowerInvariant() -eq $progressBeforePreflight) 'failed ledger Commit preflight leaves project authority byte-identical'
    Invoke-Checked (Join-Path $PSScriptRoot 'build-context-packet.ps1') @{ ProjectRoot = $testRoot; Episode = 1; Stage = 'Write'; BatchContractPath = $contractPath } | Out-Null
    $batchPacket = Read-Json (Join-Path $testRoot '.comic-adapt-cache\packets\EP-01.json')
    Write-Output ("TEST-METRIC: writer={0}; packet={1}; status={2}" -f $batchPacket.context_budget.writer_brief_estimated_tokens, $batchPacket.context_budget.write_packet_estimated_tokens, $batchPacket.context_budget.status)
    Assert-True ([string]$batchPacket.context_budget.status -eq 'PASS' -and [int]$batchPacket.context_budget.writer_brief_estimated_tokens -le 2200 -and [int]$batchPacket.context_budget.write_packet_estimated_tokens -le 5000) 'batch episode packet stays inside 2200/5000 token budgets'
    Invoke-Checked (Join-Path $PSScriptRoot 'build-context-packet.ps1') @{ ProjectRoot = $testRoot; Episode = 2; Stage = 'Write'; BatchContractPath = $contractPath } | Out-Null
    $quality = Join-Path $PSScriptRoot 'quality-receipt.ps1'
    Invoke-Checked $quality @{ ProjectRoot = $testRoot; Mode = 'PlanBatch'; Range = '1-2'; BatchId = 'BATCH-SOURCE' } | Out-Null
    $sourcePlan = Read-Json (Join-Path $testRoot '.comic-adapt-cache\quality-plans\BATCH-SOURCE.json')
    Assert-True (@($sourcePlan.shared_sources).Count -eq 2) 'batch checker brief deduplicates shared source chapter records'

    $qualityRoot = Join-Path $testRoot 'quality-only'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $qualityRoot 'scripts'))
    foreach ($episode in 1..2) {
        Write-TextAtomic (Join-Path $qualityRoot ("scripts\EP-{0}.md" -f $episode.ToString('D2'))) "剧名：《质检》`n集数：EP-$($episode.ToString('D2'))  测试`n场次 $($episode.ToString('D2'))-1：内  屋  日`n出场人物：甲`n△ （中景）甲点头。`n【卡黑】`n"
    }
    Invoke-Checked $quality @{ ProjectRoot = $qualityRoot; Mode = 'PlanBatch'; Range = '1-2'; BatchId = 'BATCH-1-2' } | Out-Null
    $results = [ordered]@{ schema_version = 'comic-adapt-batch-checker-result/1.0'; episodes = @(); seams = @([ordered]@{ left = 'EP-01'; right = 'EP-02'; status = 'PASS'; note = '' }) }
    foreach ($episode in 1..2) {
        $token = Get-ComicEpisodeToken $episode; $path = Join-Path $qualityRoot ('scripts\' + $token + '.md')
        $results.episodes += [ordered]@{ target = $token; status = 'PASS'; checked_hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant(); checked_packet_hash = ''; mode = 'Differential'; checked_dimensions = @('1','2','7','8'); failed_dimensions = @(); touched_scopes = @('core_semantic','continuity'); exit_state_changed = $false; note = '' }
    }
    $resultsPath = Join-Path $qualityRoot 'batch-results.json'; Write-JsonAtomic $resultsPath $results
    Invoke-Checked $quality @{ ProjectRoot = $qualityRoot; Mode = 'RecordBatch'; Range = '1-2'; BatchId = 'BATCH-1-2'; ResultsPath = $resultsPath } | Out-Null
    $batchReceipt = Read-Json (Join-Path $qualityRoot '.comic-adapt-cache\quality-batches\BATCH-1-2.json')
    Assert-True ([string]$batchReceipt.status -eq 'PASS' -and @($batchReceipt.episodes).Count -eq 2) 'batch checker records independent episode PASS receipts'
    $results.episodes[1].status = 'FAIL'; $results.episodes[1].failed_dimensions = @('2'); $results.episodes[1].exit_state_changed = $true; $results.episodes[1].note = '接缝失败'
    Write-JsonAtomic $resultsPath $results
    $failedBatch = Invoke-Captured $quality @{ ProjectRoot = $qualityRoot; Mode = 'RecordBatch'; Range = '1-2'; BatchId = 'BATCH-1-2'; ResultsPath = $resultsPath }
    $batchReceipt = Read-Json (Join-Path $qualityRoot '.comic-adapt-cache\quality-batches\BATCH-1-2.json')
    Assert-True ($failedBatch.exit -eq 1 -and @($batchReceipt.repair_scope) -contains 'EP-01' -and @($batchReceipt.repair_scope) -contains 'EP-02') 'failed exit state isolates failed episode and adjacent seam only'
    Write-Output 'TEST-SUMMARY: PASS=13; FAIL=0'
    exit 0
} finally {
    if (Test-Path -LiteralPath $resolvedTest -PathType Container) {
        $confirmed = [IO.Path]::GetFullPath($resolvedTest)
        if ($confirmed.StartsWith($resolvedTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($confirmed) -match '^comic-adapt-v6-batch-[0-9a-f]{32}$') { Remove-Item -LiteralPath $confirmed -Recurse -Force }
    }
}

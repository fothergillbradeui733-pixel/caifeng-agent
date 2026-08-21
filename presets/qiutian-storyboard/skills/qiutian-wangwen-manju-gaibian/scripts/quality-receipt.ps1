[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Plan', 'Record', 'Revalidate', 'PlanBatch', 'RecordBatch', 'MigrateLegacy', 'Report')]
    [string]$Mode,

    [string]$Target,
    [string]$Range,
    [string]$BatchId,
    [string]$ResultsPath,
    [string]$Path,
    [ValidateSet('Script', 'Map')]
    [string]$Kind = 'Script',
    [ValidateSet('write', 'rewrite', 'polish', 'map', 'format', 'visual')]
    [string]$Operation = 'write',
    [string]$Result,
    [int]$Round = 1,
    [string]$CheckerMode = 'Differential',
    [string]$CheckedDimensions = '',
    [string]$FailedDimensions = '',
    [string]$TouchedScopes = '',
    [string]$DependsOn = '',
    [string]$Note = '',
    [string]$CheckedHash = '',
    [string]$CheckedPacketHash = '',
    [ValidateSet('semantic_review', 'scope_review', 'machine_closure', 'historical_closure')]
    [string]$EventType = 'semantic_review',
    [switch]$StructuralChange,
    [switch]$FreshCheckerRequired
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComicAdapt.Common.psm1') -Force
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$qualityRoot = Join-Path $root '.comic-adapt\quality'
$planRoot = Join-Path $root '.comic-adapt-cache\quality-plans'
$unresolvedPath = Join-Path $root '.comic-adapt\unresolved.json'
$policyPath = Join-Path $root '.comic-adapt\policy.json'
$previewEnabled = $true
if (Test-Path -LiteralPath $policyPath -PathType Leaf) {
    try { $previewEnabled = [bool]((Get-Content -Raw -Encoding UTF8 -LiteralPath $policyPath | ConvertFrom-Json).preview_enabled) }
    catch { throw "Unreadable workflow policy: $policyPath" }
}

function Get-Sha256Text([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-Sha256File([string]$FilePath) {
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return '' }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $FilePath).Hash.ToLowerInvariant()
}

function Normalize-Text([string]$Text) {
    if ($null -eq $Text) { return '' }
    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = @($normalized -split "`n" | ForEach-Object { $_.TrimEnd() })
    return (($lines -join "`n").Trim())
}

function Normalize-SemanticLines([string[]]$Lines) {
    return Normalize-Text (($Lines | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line -match '^[═─—-]{3,}$') { return }
        return ($line -replace '\s+', ' ')
    }) -join "`n")
}

function Get-LedgerSemanticText([string]$LedgerBlock, [string]$Root, [string]$EpisodeName) {
    $items = [Collections.Generic.List[string]]::new()
    if ($LedgerBlock) {
        foreach ($line in ($LedgerBlock -split '\r?\n')) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^(?<field>原著时间|日历|角色状态|伏笔埋|伏笔收|道具|期限|场景名|口径|行动线)[：:](?<raw>.+)$') {
                if ($Matches['raw'].Trim() -and $Matches['raw'].Trim() -ne '无') { $items.Add($Matches['field'] + '|' + $Matches['raw'].Trim()) }
            } elseif ($trimmed -match '^快照来源[：:](?<source>EP-\d+)') { $items.Add('快照来源|' + $Matches['source']) }
        }
    } elseif ($EpisodeName -match '^EP-0*(\d+)$') {
        $planPath = Join-Path $Root ('.comic-adapt-cache\receipts\ledger-' + $EpisodeName + '.json')
        $plan = Read-Json $planPath
        if ($plan) {
            foreach ($item in @($plan.items)) { $items.Add(([string]$item.field) + '|' + ([string]$item.raw)) }
            foreach ($snapshot in @($plan.snapshots)) { $items.Add('快照来源|' + [string]$snapshot.source) }
        }
    }
    return Normalize-SemanticLines @($items | Sort-Object -Unique)
}

function Get-VisualSemanticText([string]$VisualPath) {
    if (-not (Test-Path -LiteralPath $VisualPath -PathType Leaf)) { return '' }
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $VisualPath
    $semantic = [regex]::Replace($text, '(?m)^(?:剧本路径|剧本SHA256|交接状态)[：:].*\r?\n?', '')
    return Normalize-Text $semantic
}

function Get-FullAuditCoreHash([object]$Scopes) {
    return Get-Sha256Text ((@([string]$Scopes.core_semantic, [string]$Scopes.continuity, [string]$Scopes.timeline) -join '|'))
}

function Split-List([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split '[,，;；]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
}

function Get-ScriptScopes([string]$FilePath, [string]$Root, [bool]$IncludePreview) {
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "Missing target file: $FilePath" }
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $FilePath
    $normalized = Normalize-Text $text
    $ledgerMatch = [regex]::Match($normalized, '(?ms)^【台账登记块】\s*\n.*\z')
    $ledger = if ($ledgerMatch.Success) { $ledgerMatch.Value } else { '' }
    $withoutLedger = if ($ledgerMatch.Success) { $normalized.Substring(0, $ledgerMatch.Index).TrimEnd() } else { $normalized }
    $previewMatch = [regex]::Match($withoutLedger, '(?m)^下集预告(?:〔[^〕\r\n]+〕)?[：:].*$')
    $preview = if ($previewMatch.Success) { $previewMatch.Value.Trim() } else { '' }
    $withoutPreview = if ($previewMatch.Success) { $withoutLedger.Remove($previewMatch.Index, $previewMatch.Length) } else { $withoutLedger }
    $lines = @($withoutPreview -split "`n")
    $timelineLines = @($lines | Where-Object { $_ -match '^场次\s+\d+-\d+[：:]' -or $_ -match '^【字幕[：:]' })
    $continuityLines = @($lines | Where-Object { $_ -match '^场次\s+\d+-\d+[：:]' -or $_ -match '^出场人物[：:]' } | ForEach-Object {
        if ($_ -match '^(场次\s+\d+-\d+[：:]\s*(?:内|外|内→外|外→内)\s+.+?)\s+(?:晨|日|黄昏|夜)(?:→(?:晨|日|黄昏|夜))?(?:·\S+)?\s*$') { return $Matches[1] }
        return $_
    })
    $coreLines = @($lines | Where-Object {
        $_ -notmatch '^场次\s+\d+-\d+[：:]' -and
        $_ -notmatch '^出场人物[：:]' -and
        $_ -notmatch '^【字幕[：:]'
    })
    $episodeName = [IO.Path]::GetFileNameWithoutExtension($FilePath)
    $visualPath = Join-Path $Root ("visual-assets\episodes\{0}.md" -f $episodeName)
    $visualSemantic = Get-VisualSemanticText $visualPath
    return [ordered]@{
        raw_file = Get-Sha256File $FilePath
        core_file = Get-TextSha256 (Get-ComicScriptCoreText $text)
        core_semantic = Get-Sha256Text (Normalize-SemanticLines $coreLines)
        continuity = Get-Sha256Text (Normalize-SemanticLines $continuityLines)
        timeline = Get-Sha256Text (Normalize-SemanticLines $timelineLines)
        preview = if ($IncludePreview) { Get-Sha256Text (Normalize-Text $preview) } else { '' }
        ledger = Get-Sha256Text (Get-LedgerSemanticText $ledger $Root $episodeName)
        ledger_raw = Get-Sha256Text (Normalize-Text $ledger)
        visual = Get-Sha256Text $visualSemantic
        visual_status = Get-Sha256File $visualPath
    }
}

function Get-MapScopes([string]$FilePath) {
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "Missing target file: $FilePath" }
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $FilePath
    return [ordered]@{
        raw_file = Get-Sha256File $FilePath
        core_file = Get-Sha256Text (Normalize-Text $text)
        core_semantic = Get-Sha256Text (Normalize-Text $text)
        continuity = ''
        timeline = ''
        preview = ''
        ledger = ''
        ledger_raw = ''
        visual = ''
        visual_status = ''
    }
}

function Get-Scopes([string]$FilePath, [string]$TargetKind, [string]$Root) {
    if ($TargetKind -eq 'Map') { return Get-MapScopes $FilePath }
    return Get-ScriptScopes $FilePath $Root $previewEnabled
}

function Get-MarkdownSection([string]$Text, [string]$HeadingPattern, [int]$Level) {
    $prefix = '#' * $Level
    $pattern = '(?ms)^' + [regex]::Escape($prefix) + '\s+' + $HeadingPattern + '[^\r\n]*\r?\n.*?(?=^#{1,' + $Level + '}\s+|\z)'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) { return $match.Value.Trim() }
    return ''
}

function New-CheckerBrief([object]$Plan, [string]$TargetFile, [string]$TargetKind, [string]$TargetName) {
    if (([string]$Plan.checker_mode) -in @('None', 'Machine', 'Reuse')) { return $null }
    $referenceName = if ($TargetKind -eq 'Map') { 'source-checker.md' } else { 'script-checker.md' }
    $referencePath = Join-Path (Split-Path -Parent $PSScriptRoot) ('references\' + $referenceName)
    if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) { throw "Missing checker authority: $referencePath" }
    $referenceText = Get-Content -Raw -Encoding UTF8 -LiteralPath $referencePath
    $safe = $TargetName -replace '[^A-Za-z0-9._-]', '_'
    $briefPath = Join-Path $root ('.comic-adapt-cache\briefs\' + $safe + '.checker.md')
    $targetRelative = $TargetFile.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
    $reviewPath = Join-Path $root ('.comic-adapt-cache\packets\' + $safe + '.review.json')
    $writerPath = Join-Path $root ('.comic-adapt-cache\briefs\' + $safe + '.writer.md')
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# ' + $TargetName + ' Checker Brief')
    $lines.Add('')
    $lines.Add('schema_version: comic-adapt-checker-brief/1.0')
    $lines.Add('kind: ' + $TargetKind)
    $lines.Add('mode: ' + [string]$Plan.checker_mode)
    $lines.Add('action: ' + [string]$Plan.action)
    $lines.Add('dimensions: ' + (@($Plan.dimensions) -join ','))
    $lines.Add('checked_file: ' + $targetRelative)
    $lines.Add('checked_raw_sha256: ' + [string]$Plan.current_scopes.raw_file)
    $lines.Add('checked_core_sha256: ' + [string]$Plan.current_scopes.core_file)
    if (Test-Path -LiteralPath $reviewPath -PathType Leaf) {
        $lines.Add('review_packet: ' + $reviewPath.Substring($root.Length).TrimStart('\', '/').Replace('\', '/'))
        $lines.Add('review_packet_sha256: ' + (Get-Sha256File $reviewPath))
    }
    if (Test-Path -LiteralPath $writerPath -PathType Leaf) {
        $lines.Add('writer_brief: ' + $writerPath.Substring($root.Length).TrimStart('\', '/').Replace('\', '/'))
        $lines.Add('writer_brief_sha256: ' + (Get-Sha256File $writerPath))
    }
    $lines.Add('')
    $lines.Add('## 角色与输入纪律')
    $lines.Add('你是独立只读checker，不修改任何项目文件。先核验上述hash；材料缺失或检中变化返回FAIL_INPUT。机器格式不重复检查，但必须确认权威lint为FAIL=0。')
    if ($TargetKind -eq 'Map') {
        $lines.Add('读取正式剧情点、map-preflight列明的map-spec、目标原章及本brief维度；自行对照原著。')
    } else {
        $lines.Add('读取剧本、writer brief列明的目标原章与接缝事实、Review增量；不要打开完整Write包，除非brief明确缺失或存在歧义。')
    }
    $lines.Add('')
    $lines.Add('## 本轮检查维度')
    foreach ($dimension in @($Plan.dimensions)) {
        if ([string]$dimension -notmatch '^(?:[1-8]|F)$') {
            $lines.Add('- 专项作用域：' + [string]$dimension)
            continue
        }
        $section = Get-MarkdownSection $referenceText ([regex]::Escape([string]$dimension) + '\.') 3
        if ($section) { $lines.Add(''); $lines.Add($section) }
    }
    $outputSection = Get-MarkdownSection $referenceText '输出' 2
    $passSection = Get-MarkdownSection $referenceText '通过条件' 2
    if ($outputSection) { $lines.Add(''); $lines.Add($outputSection) }
    if ($passSection) { $lines.Add(''); $lines.Add($passSection) }
    Write-TextAtomic $briefPath (($lines -join "`n").TrimEnd() + "`n")
    return [ordered]@{
        path = $briefPath.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        sha256 = Get-Sha256File $briefPath
        bytes = (Get-Item -LiteralPath $briefPath).Length
    }
}

function Complete-GoalSemanticState([string]$TargetName, [string]$SemanticStatus) {
    if ($SemanticStatus -notin @('PASS', 'UNRESOLVED')) { return }
    $goalPath = Join-Path $root '.comic-adapt\goal-run.json'
    $goal = Read-Json $goalPath
    if (-not $goal) { return }
    $unit = @($goal.units | Where-Object { $_.target -eq $TargetName } | Select-Object -First 1)
    if ($unit.Count -eq 0) { return }
    $runner = Join-Path $PSScriptRoot 'goal-runner.ps1'
    if ([string]$unit[0].state -eq 'MACHINE_PASS') {
        & $runner -ProjectRoot $root -Mode Advance -UnitTarget $TargetName -State REVIEWED | Write-Output
        if ($LASTEXITCODE -ne 0) { throw "Failed to advance $TargetName to REVIEWED" }
        $unit[0].state = 'REVIEWED'
    }
    if ([string]$unit[0].state -eq 'REVIEWED') {
        $next = if ($SemanticStatus -eq 'PASS') { 'SEMANTIC_PASS' } else { 'UNRESOLVED' }
        & $runner -ProjectRoot $root -Mode Advance -UnitTarget $TargetName -State $next | Write-Output
        if ($LASTEXITCODE -ne 0) { throw "Failed to advance $TargetName to $next" }
        Write-Output "QUALITY-GOAL-AUTO-ADVANCE: $TargetName -> $next"
    }
}

function Resolve-TargetPath([string]$Root, [string]$TargetName, [string]$ProvidedPath, [string]$TargetKind) {
    if ($ProvidedPath) {
        if ([IO.Path]::IsPathRooted($ProvidedPath)) { return $ProvidedPath }
        return Join-Path $Root $ProvidedPath
    }
    if ($TargetKind -eq 'Map') { return Join-Path $Root 'plot-map.md' }
    if ($TargetName -match '^EP-0*(\d+)$') {
        $episode = [int]$Matches[1]
        $candidate = Get-ChildItem -LiteralPath (Join-Path $Root 'scripts') -File -Filter 'EP-*.md' |
            Where-Object { $_.Name -match ('^EP-0*' + $episode + '\.md$') } | Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    throw 'Path is required when Target cannot be resolved automatically.'
}

function Get-ChangedScopes([object]$OldScopes, [object]$NewScopes, [bool]$IncludePreview = $true) {
    $changed = New-Object Collections.Generic.List[string]
    $scopeNames = @('core_semantic', 'continuity', 'timeline', 'ledger', 'visual', 'raw_file')
    if ($IncludePreview) { $scopeNames = @('core_semantic', 'continuity', 'timeline', 'preview', 'ledger', 'visual', 'raw_file') }
    foreach ($scope in $scopeNames) {
        $oldProperty = $OldScopes.PSObject.Properties[$scope]
        $newValue = [string]$NewScopes[$scope]
        if (-not $oldProperty -or [string]$oldProperty.Value -ne $newValue) { $changed.Add($scope) }
    }
    return $changed.ToArray()
}

function Get-RiskFlags([string]$Root, [string]$TargetName) {
    if ($TargetName -notmatch '^EP-0*(\d+)$') { return @() }
    $episode = [int]$Matches[1]
    $packetCandidates = @(
        (Join-Path $Root ('.comic-adapt-cache\packets\EP-{0}.review.json' -f $episode.ToString('D2'))),
        (Join-Path $Root ('.comic-adapt-cache\packets\EP-{0}.json' -f $episode.ToString('D2')))
    )
    foreach ($candidate in $packetCandidates) {
        $packet = Read-Json $candidate
        if ($packet -and $packet.risk_flags) { return @($packet.risk_flags) }
    }
    return @()
}

function Get-DefaultDimensions([string]$TargetKind, [string[]]$Risks) {
    if ($TargetKind -eq 'Map') { return @('1', '3', '4', '6') }
    $dimensions = New-Object Collections.Generic.HashSet[string]
    foreach ($item in @('1', '2', '7', '8')) { [void]$dimensions.Add($item) }
    foreach ($risk in $Risks) {
        switch -Regex ($risk) {
            '^fidelity$' { [void]$dimensions.Add('F') }
            'strength-9-plus' { [void]$dimensions.Add('3') }
            'reveal-or-knowledge|foreshadow' { [void]$dimensions.Add('1'); [void]$dimensions.Add('2') }
            'combat-or-vfx|many-named-characters' { [void]$dimensions.Add('7') }
            'calendar-or-deadline|source-time-or-deadline|prop-state|flashback' { [void]$dimensions.Add('2') }
            'name-state' { [void]$dimensions.Add('5'); [void]$dimensions.Add('7') }
        }
    }
    return @($dimensions | Sort-Object)
}

function Test-ScheduledFull([string]$TargetName, [string]$TargetKind) {
    if ($TargetKind -eq 'Script' -and $TargetName -match '^EP-0*(\d+)$') {
        $episode = [int]$Matches[1]
        return ($episode -eq 1 -or ($episode % 10) -eq 0)
    }
    if ($TargetKind -eq 'Map') {
        if ($TargetName -match '(?:BATCH|MAP)-0*(\d+)$') {
            $batch = [int]$Matches[1]
            return ($batch -eq 1 -or ($batch % 10) -eq 0)
        }
        if ($TargetName -match '1[-–—]6') { return $true }
    }
    return $false
}

function Get-ReceiptPath([string]$TargetName) {
    $safe = $TargetName -replace '[^A-Za-z0-9._-]', '_'
    return Join-Path $qualityRoot ($safe + '.json')
}

function Get-BatchIdentity([int[]]$Episodes, [string]$Provided) {
    if ($Provided) { return ($Provided -replace '[^A-Za-z0-9._-]', '_') }
    return 'BATCH-' + $Episodes[0] + '-' + $Episodes[-1]
}

function Get-BatchPlanPath([string]$Identity) {
    return Join-Path $planRoot ($Identity + '.json')
}

function Get-BatchReceiptPath([string]$Identity) {
    return Join-Path $root ('.comic-adapt-cache\quality-batches\' + $Identity + '.json')
}

if ($Mode -eq 'PlanBatch') {
    if (-not $Range) { throw 'PlanBatch requires -Range N-M.' }
    $episodes = @(Resolve-ComicEpisodeRange $Range)
    if ($episodes.Count -gt 10) { throw 'PlanBatch supports at most 10 consecutive episodes.' }
    $identity = Get-BatchIdentity $episodes $BatchId
    $memberPlans = [Collections.Generic.List[object]]::new()
    $sourceMap = [ordered]@{}
    foreach ($episode in $episodes) {
        $targetName = Get-ComicEpisodeToken $episode
        $memberOutput = & $PSCommandPath -ProjectRoot $root -Mode Plan -Target $targetName -Kind Script -Operation $Operation 2>&1
        foreach ($line in @($memberOutput)) { Write-Output $line }
        if ($LASTEXITCODE -ne 0) { throw "Batch member plan failed: $targetName exit=$LASTEXITCODE" }
        $memberPath = Join-Path $planRoot ($targetName + '.json')
        $member = Read-Json $memberPath
        if (-not $member) { throw "Missing member quality plan: $memberPath" }
        $memberPlans.Add($member)
        $packetPath = Join-Path $root ('.comic-adapt-cache\packets\' + $targetName + '.json')
        $packetData = Read-Json $packetPath
        $packetSources = if ($packetData.episode_contract -and @($packetData.episode_contract.source_files).Count -gt 0) { @($packetData.episode_contract.source_files) } else { @($packetData.source_files) }
        foreach ($source in $packetSources) {
            if (-not $source.path) { continue }
            $sourceMap[[string]$source.path] = [ordered]@{ path = [string]$source.path; sha256 = [string]$source.sha256; chapter = $source.chapter }
        }
    }
    $batchPlan = [ordered]@{
        schema_version = 'comic-adapt-quality-batch-plan/1.0'
        batch_id = $identity
        range = $episodes[0].ToString() + '-' + $episodes[-1].ToString()
        generated_at = (Get-Date).ToString('o')
        checker_contract = 'one shared read; independent episode verdicts; explicit seam verdicts'
        members = @($memberPlans | ForEach-Object {
            [ordered]@{
                target = [string]$_.target
                action = [string]$_.action
                checker_mode = [string]$_.checker_mode
                dimensions = @($_.dimensions)
                risk_flags = @($_.risk_flags)
                raw_sha256 = [string]$_.current_scopes.raw_file
                core_sha256 = [string]$_.current_scopes.core_file
                checker_brief = $_.checker_brief
            }
        })
        shared_sources = @($sourceMap.Values)
    }
    $briefPath = Join-Path $root ('.comic-adapt-cache\briefs\' + $identity + '.checker.md')
    $brief = [Collections.Generic.List[string]]::new()
    $brief.Add('# ' + $identity + ' Batch Checker Brief')
    $brief.Add('')
    $brief.Add('schema_version: comic-adapt-batch-checker-brief/1.0')
    $brief.Add('range: ' + $batchPlan.range)
    $brief.Add('rule: 共享原章与批次契约只读一次，但每集必须独立判定；另审相邻集接缝。')
    $brief.Add('')
    $brief.Add('## 共享原章')
    foreach ($source in @($sourceMap.Values)) { $brief.Add(('- {0}｜sha256={1}' -f $source.path, $source.sha256)) }
    if ($sourceMap.Count -eq 0) { $brief.Add('- 无') }
    $brief.Add('')
    $brief.Add('## 分集检查表')
    $brief.Add('| 集数 | 模式 | 维度 | raw_sha256 | core_sha256 |')
    $brief.Add('|:--|:--|:--|:--|:--|')
    foreach ($member in $batchPlan.members) {
        $brief.Add(('| {0} | {1} | {2} | {3} | {4} |' -f $member.target, $member.checker_mode, (@($member.dimensions) -join ','), $member.raw_sha256, $member.core_sha256))
    }
    $brief.Add('')
    $brief.Add('## 输出契约')
    $brief.Add('只输出一个 JSON 文件：schema_version=comic-adapt-batch-checker-result/1.0；episodes 数组逐集含 target、status(PASS/FAIL/FAIL_INPUT)、checked_hash、checked_packet_hash、mode、checked_dimensions、failed_dimensions、touched_scopes、exit_state_changed、note；seams 数组含 left、right、status(PASS/FAIL)、note。失败问题仍使用四元组写入 note。')
    $brief.Add('任何一集不得借用另一集PASS；维度1、2、7、8和平台合规仍逐集成立。hash不符只记FAIL_INPUT。')
    Write-TextAtomic $briefPath (($brief -join "`n").TrimEnd() + "`n")
    $batchPlan['checker_brief'] = [ordered]@{ path = Get-RelativePathCompat $root $briefPath; sha256 = Get-Sha256File $briefPath }
    $batchPlanPath = Get-BatchPlanPath $identity
    Write-JsonAtomic $batchPlanPath $batchPlan
    Write-Output ("QUALITY-BATCH-PLAN: {0} | range={1} | episodes={2} | shared-sources={3}" -f $identity, $batchPlan.range, $episodes.Count, $sourceMap.Count)
    Write-Output ("QUALITY-BATCH-CHECKER-BRIEF: {0}" -f $briefPath)
    exit 0
}

if ($Mode -eq 'RecordBatch') {
    if (-not $Range -or -not $ResultsPath) { throw 'RecordBatch requires -Range N-M and -ResultsPath.' }
    $episodes = @(Resolve-ComicEpisodeRange $Range)
    if ($episodes.Count -gt 10) { throw 'RecordBatch supports at most 10 consecutive episodes.' }
    $identity = Get-BatchIdentity $episodes $BatchId
    $resolvedResults = if ([IO.Path]::IsPathRooted($ResultsPath)) { $ResultsPath } else { Join-Path $root $ResultsPath }
    $results = Read-Json $resolvedResults
    if (-not $results -or [string]$results.schema_version -ne 'comic-adapt-batch-checker-result/1.0') { throw 'Invalid batch checker result schema.' }
    $expected = @($episodes | ForEach-Object { Get-ComicEpisodeToken $_ })
    $actual = @($results.episodes | ForEach-Object { [string]$_.target })
    if (@($actual | Sort-Object -Unique).Count -ne $actual.Count -or @($expected | Where-Object { $_ -notin $actual }).Count -gt 0 -or @($actual | Where-Object { $_ -notin $expected }).Count -gt 0) {
        throw 'Batch checker result must contain every target exactly once.'
    }
    $repair = [Collections.Generic.HashSet[int]]::new()
    $recorded = [Collections.Generic.List[object]]::new()
    $hasFail = $false; $hasInputFail = $false
    foreach ($targetName in $expected) {
        $item = @($results.episodes | Where-Object { [string]$_.target -eq $targetName } | Select-Object -First 1)[0]
        $number = [int]([regex]::Match($targetName, '\d+').Value)
        $statusValue = [string]$item.status
        if ($statusValue -notin @('PASS', 'FAIL', 'FAIL_INPUT')) { throw "Invalid batch member result: $targetName status=$statusValue" }
        $args = @{
            ProjectRoot = $root; Mode = 'Record'; Target = $targetName; Kind = 'Script'; Operation = $Operation
            Result = $statusValue; Round = $(if ($item.round) { [int]$item.round } else { 1 }); CheckerMode = $(if ($item.mode) { [string]$item.mode } else { 'Differential' })
            CheckedDimensions = (@($item.checked_dimensions) -join ','); FailedDimensions = (@($item.failed_dimensions) -join ',')
            TouchedScopes = (@($item.touched_scopes) -join ','); CheckedHash = [string]$item.checked_hash
            CheckedPacketHash = [string]$item.checked_packet_hash; Note = [string]$item.note
        }
        if ([bool]$item.fresh_checker_required) { $args['FreshCheckerRequired'] = $true }
        if ([bool]$item.structural_change) { $args['StructuralChange'] = $true }
        $memberOutput = & $PSCommandPath @args 2>&1
        foreach ($line in @($memberOutput)) { Write-Output $line }
        $memberExit = $LASTEXITCODE
        $receiptData = Read-Json (Get-ReceiptPath $targetName)
        $recorded.Add([ordered]@{ target = $targetName; input_status = $statusValue; receipt_status = [string]$receiptData.status; exit = $memberExit })
        if ($statusValue -eq 'FAIL_INPUT') { $hasInputFail = $true; [void]$repair.Add($number) }
        elseif ($statusValue -eq 'FAIL') { $hasFail = $true; [void]$repair.Add($number) }
        if ($statusValue -ne 'PASS' -and [bool]$item.exit_state_changed) {
            if ($number -gt $episodes[0]) { [void]$repair.Add($number - 1) }
            if ($number -lt $episodes[-1]) { [void]$repair.Add($number + 1) }
        }
    }
    foreach ($seam in @($results.seams)) {
        if ([string]$seam.status -ne 'FAIL') { continue }
        foreach ($tokenName in @([string]$seam.left, [string]$seam.right)) {
            if ($tokenName -match '^EP-0*(\d+)$') {
                $number = [int]$Matches[1]
                if ($number -ge $episodes[0] -and $number -le $episodes[-1]) { [void]$repair.Add($number) }
            }
        }
        $hasFail = $true
    }
    $batchStatus = if ($hasInputFail) { 'FAIL_INPUT' } elseif ($hasFail) { 'FAIL' } else { 'PASS' }
    $batchReceipt = [ordered]@{
        schema_version = 'comic-adapt-quality-batch/1.0'
        batch_id = $identity
        range = $episodes[0].ToString() + '-' + $episodes[-1].ToString()
        status = $batchStatus
        recorded_at = (Get-Date).ToString('o')
        result_file = [ordered]@{ path = Get-RelativePathCompat $root $resolvedResults; sha256 = Get-Sha256File $resolvedResults }
        episodes = $recorded.ToArray()
        seams = @($results.seams)
        repair_scope = @($repair | Sort-Object | ForEach-Object { Get-ComicEpisodeToken $_ })
    }
    $batchReceiptPath = Get-BatchReceiptPath $identity
    Write-JsonAtomic $batchReceiptPath $batchReceipt
    Write-Output ("QUALITY-BATCH-RECEIPT: {0} | status={1} | repair={2} | path={3}" -f $identity, $batchStatus, (@($batchReceipt.repair_scope) -join ','), $batchReceiptPath)
    if ($batchStatus -eq 'FAIL_INPUT') { exit 2 }
    if ($batchStatus -eq 'FAIL') { exit 1 }
    exit 0
}

if ($Mode -eq 'MigrateLegacy') {
    $progressPath = Join-Path $root 'progress.md'
    if (-not (Test-Path -LiteralPath $progressPath -PathType Leaf)) { throw "Missing progress.md: $progressPath" }
    $progress = Get-Content -Raw -Encoding UTF8 -LiteralPath $progressPath
    $matches = [regex]::Matches($progress, 'EP-0*(?<episode>\d+)\s*=\s*[^；;\r\n]*?PASS(?:\([^\)]*\))?')
    $imported = 0
    foreach ($match in $matches) {
        $episode = [int]$match.Groups['episode'].Value
        $targetName = 'EP-' + $episode.ToString('D2')
        $receiptPath = Get-ReceiptPath $targetName
        if (Test-Path -LiteralPath $receiptPath -PathType Leaf) { continue }
        $targetPath = Resolve-TargetPath $root $targetName '' 'Script'
        $scopes = Get-Scopes $targetPath 'Script' $root
        $receipt = [ordered]@{
            schema_version = 'comic-adapt-quality/1.0'
            target = $targetName
            kind = 'Script'
            path = $targetPath.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
            status = 'PASS'
            legacy_imported = $true
            imported_at = (Get-Date).ToString('o')
            raw_hash_at_import = $scopes.raw_file
            scopes = $scopes
            checker_mode = 'Legacy'
            checked_dimensions = @()
            failure_count = 0
            events = @([ordered]@{ at = (Get-Date).ToString('o'); result = 'PASS'; mode = 'Legacy'; round = 0; note = 'Imported from progress.md PASS summary; first semantic edit requires FULL.' })
        }
        Write-JsonAtomic $receiptPath $receipt
        $imported++
    }
    Write-Output ("QUALITY-MIGRATE: imported={0}; path={1}" -f $imported, $qualityRoot)
    exit 0
}

if ($Mode -eq 'Report') {
    $receipts = if (Test-Path -LiteralPath $qualityRoot -PathType Container) { @(Get-ChildItem -LiteralPath $qualityRoot -File -Filter '*.json' | ForEach-Object { Read-Json $_.FullName }) } else { @() }
    $pass = @($receipts | Where-Object { $_.status -eq 'PASS' }).Count
    $unresolved = @($receipts | Where-Object { $_.status -eq 'UNRESOLVED' }).Count
    $failed = @($receipts | Where-Object { $_.status -eq 'FAIL' }).Count
    Write-Output ("QUALITY-REPORT: total={0}; pass={1}; fail={2}; unresolved={3}" -f $receipts.Count, $pass, $failed, $unresolved)
    foreach ($receipt in ($receipts | Where-Object { $_.status -ne 'PASS' } | Sort-Object target)) {
        Write-Output ("QUALITY-ISSUE: {0} | status={1} | failures={2} | next={3}" -f $receipt.target, $receipt.status, $receipt.failure_count, $receipt.next_action)
    }
    if ($unresolved -gt 0 -or $failed -gt 0) { exit 2 }
    exit 0
}

if (-not $Target) { throw 'Target is required for Plan or Record.' }
$targetPath = Resolve-TargetPath $root $Target $Path $Kind
$receiptPath = Get-ReceiptPath $Target
$receipt = Read-Json $receiptPath
$scopes = Get-Scopes $targetPath $Kind $root

if ($Mode -eq 'Revalidate') {
    if (-not $receipt -or [string]$receipt.status -ne 'UNRESOLVED') { throw "Revalidate requires an existing UNRESOLVED receipt: $Target" }
    $fullDimensions = if ($Kind -eq 'Script') { @('1','2','3','4','5','6','7','8','F') } else { @('1','2','3','4','5','6','F') }
    if (-not $Result) {
        $risks = @(Get-RiskFlags $root $Target)
        $plan = [ordered]@{
            schema_version = 'comic-adapt-quality-plan/1.0'
            generated_at = (Get-Date).ToString('o')
            target = $Target
            kind = $Kind
            operation = $Operation
            checker_mode = 'Full'
            action = 'RUN_FULL_REVALIDATION'
            reason = 'formal revalidation of historical UNRESOLVED after an explicit repair'
            dimensions = $fullDimensions
            risk_flags = $risks
            changed_scopes = @(Get-ChangedScopes $receipt.last_observed_scopes $scopes $previewEnabled)
            failure_count = [int]$receipt.failure_count
            preview_enabled = $previewEnabled
            structural_change = $true
            fresh_checker_required = $true
            current_scopes = $scopes
            current_full_audit_core_hash = Get-FullAuditCoreHash $scopes
            receipt_path = $receiptPath
            revalidates_status = 'UNRESOLVED'
        }
        $safe = $Target -replace '[^A-Za-z0-9._-]', '_'
        $planPath = Join-Path $planRoot ($safe + '.json')
        $checkerBrief = New-CheckerBrief $plan $targetPath $Kind $Target
        if (-not $checkerBrief) { throw "Revalidate failed to generate a Full checker brief: $Target" }
        $plan['checker_brief'] = $checkerBrief
        Write-JsonAtomic $planPath $plan
        Write-Output ("QUALITY-REVALIDATE-PLAN: {0} | action=RUN_FULL_REVALIDATION | checker=Full | dimensions={1}" -f $Target, ($fullDimensions -join ','))
        Write-Output ("QUALITY-CHECKER-BRIEF: {0}" -f (Join-Path $root $checkerBrief.path))
        exit 0
    }
    if ($Result -notin @('PASS', 'FAIL', 'FAIL_INPUT')) { throw 'Revalidate record requires -Result PASS, FAIL, or FAIL_INPUT.' }
    if ($CheckerMode -ne 'Full' -and $PSBoundParameters.ContainsKey('CheckerMode')) { throw 'Revalidate only accepts CheckerMode=Full.' }
    $CheckerMode = 'Full'
    $EventType = 'historical_closure'
    if (-not $CheckedDimensions) { $CheckedDimensions = $fullDimensions -join ',' }
    $requiredMissing = @($fullDimensions | Where-Object { $_ -notin @(Split-List $CheckedDimensions) })
    if ($requiredMissing.Count -gt 0) { throw "Revalidate must check every Full dimension; missing=$($requiredMissing -join ',')" }
}

if ($Mode -eq 'Plan') {
    $risks = @(Get-RiskFlags $root $Target)
    $dimensions = @(Get-DefaultDimensions $Kind $risks)
    $changed = @()
    $checker = 'Differential'
    $action = 'RUN_DIFFERENTIAL'
    $reason = 'rolling default'
    $failureCount = if ($receipt -and $receipt.failure_count) { [int]$receipt.failure_count } else { 0 }
    $forceFreshFull = [bool]($receipt -and ($receipt.structural_change -eq $true -or $receipt.fresh_checker_required -eq $true))

    if ($failureCount -ge 3 -or ($receipt -and $receipt.status -eq 'UNRESOLVED')) {
        $checker = 'None'; $action = 'CONTINUE_WITH_UNRESOLVED'; $reason = 'third failure recorded'
    } elseif ($forceFreshFull) {
        $checker = 'Full'; $action = 'RUN_FULL'; $reason = 'persisted structural change or fresh-checker requirement'
        $dimensions = if ($Kind -eq 'Script') { @('1','2','3','4','5','6','7','8','F') } else { @('1','2','3','4','5','6','F') }
    } elseif ($failureCount -eq 2) {
        $checker = 'Full'; $action = 'RUN_FULL'; $reason = 'second failure requires a fresh full review'
        $dimensions = if ($Kind -eq 'Script') { @('1','2','3','4','5','6','7','8','F') } else { @('1','2','3','4','5','6','F') }
    } elseif ($failureCount -eq 1) {
        $checker = 'Targeted'; $action = 'TARGETED_REPAIR'; $reason = 'first failure: repair and recheck failed dimensions only'
        if ($receipt.last_failed_dimensions) { $dimensions = @($receipt.last_failed_dimensions) }
    } elseif ($Operation -in @('rewrite', 'polish')) {
        $checker = 'Full'; $action = 'RUN_FULL'; $reason = "$Operation always invalidates core semantic approval"
        $dimensions = if ($Kind -eq 'Script') { @('1','2','3','4','5','6','7','8','F') } else { @('1','2','3','4','5','6','F') }
    } elseif ($receipt -and $receipt.legacy_imported) {
        if ([string]$receipt.raw_hash_at_import -eq [string]$scopes.raw_file) {
            $checker = 'Reuse'; $action = 'REUSE_LEGACY_PASS'; $reason = 'unchanged legacy PASS'
            $dimensions = @()
        } else {
            $checker = 'Full'; $action = 'RUN_FULL'; $reason = 'first edit of a legacy PASS requires full review'
            $dimensions = if ($Kind -eq 'Script') { @('1','2','3','4','5','6','7','8','F') } else { @('1','2','3','4','5','6','F') }
        }
    } elseif ($receipt -and $receipt.status -eq 'PASS' -and $receipt.scopes) {
        $changed = @(Get-ChangedScopes $receipt.scopes $scopes $previewEnabled)
        $currentFullAuditCoreHash = Get-FullAuditCoreHash $scopes
        $legacyCoreUnchanged = ([string]$receipt.scopes.core_semantic -eq [string]$scopes.core_semantic -and [string]$receipt.scopes.continuity -eq [string]$scopes.continuity -and [string]$receipt.scopes.timeline -eq [string]$scopes.timeline)
        $legacyFullCoverage = [bool]($legacyCoreUnchanged -and @($receipt.events | Where-Object { $_.event_type -eq 'semantic_review' -and $_.result -eq 'PASS' -and $_.mode -eq 'Full' }).Count -gt 0)
        $scheduledAuditDue = (Test-ScheduledFull $Target $Kind) -and ([string]$receipt.full_audit_core_hash -ne $currentFullAuditCoreHash) -and -not $legacyFullCoverage
        $scopeHashMigration = [bool]($legacyCoreUnchanged -and -not $receipt.scopes.PSObject.Properties['ledger_raw'] -and @($changed | Where-Object { $_ -notin @('ledger','visual','raw_file') }).Count -eq 0)
        if ($scheduledAuditDue) {
            $checker = 'Full'; $action = 'RUN_FULL'; $reason = 'scheduled audit has not signed the current semantic core'
            $dimensions = if ($Kind -eq 'Script') { @('1','2','3','4','5','6','7','8','F') } else { @('1','2','3','4','5','6','F') }
        } elseif ($changed.Count -eq 0) {
            $checker = 'Reuse'; $action = 'REUSE_PASS'; $reason = 'all signed scopes unchanged'; $dimensions = @()
        } elseif ($scopeHashMigration) {
            $checker = 'Machine'; $action = 'RUN_MACHINE_ONLY'; $reason = 'one-time migration to semantic ledger/visual hashes; semantic core unchanged'; $dimensions = @($changed)
        } elseif ($changed -contains 'core_semantic' -or $changed -contains 'continuity') {
            $checker = 'Full'; $action = 'RUN_FULL'; $reason = 'core semantic or continuity scope changed'
            $dimensions = if ($Kind -eq 'Script') { @('1','2','3','4','5','6','7','8','F') } else { @('1','2','3','4','5','6','F') }
        } elseif ($changed -contains 'timeline') {
            $checker = 'Targeted'; $action = 'RUN_TARGETED'; $reason = 'timeline-only semantic change'; $dimensions = @('2')
        } elseif (@($changed | Where-Object { $_ -notin @('preview','ledger','visual','raw_file') }).Count -eq 0) {
            $checker = 'Targeted'; $action = 'RUN_SCOPE_CHECKS'; $reason = if ($previewEnabled) { 'only preview, ledger, visual, or formatting scopes changed' } else { 'only ledger, visual, or formatting scopes changed' }
            $dimensions = @($changed | Where-Object { $_ -ne 'raw_file' })
            if ($dimensions.Count -eq 0) { $checker = 'Machine'; $action = 'RUN_MACHINE_ONLY'; $reason = 'line endings or formatting only' }
        }
    } elseif (Test-ScheduledFull $Target $Kind) {
        $checker = 'Full'; $action = 'RUN_FULL'; $reason = 'first item or scheduled 1-in-10 full audit'
        $dimensions = if ($Kind -eq 'Script') { @('1','2','3','4','5','6','7','8','F') } else { @('1','2','3','4','5','6','F') }
    }

    $plan = [ordered]@{
        schema_version = 'comic-adapt-quality-plan/1.0'
        generated_at = (Get-Date).ToString('o')
        target = $Target
        kind = $Kind
        operation = $Operation
        checker_mode = $checker
        action = $action
        reason = $reason
        dimensions = $dimensions
        risk_flags = $risks
        changed_scopes = $changed
        failure_count = $failureCount
        preview_enabled = $previewEnabled
        structural_change = [bool]($receipt -and $receipt.structural_change -eq $true)
        fresh_checker_required = [bool]($receipt -and $receipt.fresh_checker_required -eq $true)
        current_scopes = $scopes
        current_full_audit_core_hash = Get-FullAuditCoreHash $scopes
        receipt_path = $receiptPath
    }
    $safe = $Target -replace '[^A-Za-z0-9._-]', '_'
    $planPath = Join-Path $planRoot ($safe + '.json')
    $checkerBrief = New-CheckerBrief $plan $targetPath $Kind $Target
    if ($checkerBrief) { $plan['checker_brief'] = $checkerBrief }
    Write-JsonAtomic $planPath $plan
    Write-Output ("QUALITY-PLAN: {0} | action={1} | checker={2} | dimensions={3} | changed={4} | reason={5}" -f $Target, $action, $checker, ($dimensions -join ','), ($changed -join ','), $reason)
    Write-Output ("QUALITY-PLAN-FILE: {0}" -f $planPath)
    if ($checkerBrief) { Write-Output ("QUALITY-CHECKER-BRIEF: {0}" -f (Join-Path $root $checkerBrief.path)) }
    if ($action -eq 'CONTINUE_WITH_UNRESOLVED') { exit 2 }
    exit 0
}

if ($Result -notin @('PASS', 'FAIL', 'FAIL_INPUT')) { throw 'Record requires -Result PASS, FAIL, or FAIL_INPUT.' }
if ($Round -lt 1 -or $Round -gt 99) { throw 'Round must be between 1 and 99.' }
$observedHash = [string]$scopes.raw_file
if ($CheckedHash) {
    $CheckedHash = $CheckedHash.Trim().ToLowerInvariant()
    if ($CheckedHash -notmatch '^[0-9a-f]{64}$') { throw 'CheckedHash must be a 64-character SHA-256 value.' }
} else {
    $CheckedHash = $observedHash
}
if ($CheckedPacketHash) {
    $CheckedPacketHash = $CheckedPacketHash.Trim().ToLowerInvariant()
    if ($CheckedPacketHash -notmatch '^[0-9a-f]{64}$') { throw 'CheckedPacketHash must be a 64-character SHA-256 value.' }
}
$hashMismatch = ($CheckedHash -ne $observedHash)
if ($Result -eq 'PASS' -and $hashMismatch) {
    throw "Refusing PASS because checked hash differs from current file: checked=$CheckedHash observed=$observedHash"
}
if ($Result -eq 'FAIL' -and $hashMismatch) {
    $Result = 'FAIL_INPUT'
    if (-not $Note) { $Note = "Auto-routed stale checker input: checked=$CheckedHash observed=$observedHash" }
}
$events = New-Object Collections.Generic.List[object]
if ($receipt -and $receipt.events) { foreach ($event in $receipt.events) { $events.Add($event) } }
$failedDimensions = @(Split-List $FailedDimensions)
$checkedDimensions = @(Split-List $CheckedDimensions)
$touched = @(Split-List $TouchedScopes)
$dependencies = @(Split-List $DependsOn)
$failureCount = if ($receipt -and $receipt.failure_count) { [int]$receipt.failure_count } else { 0 }
$isSemanticEvent = ($EventType -in @('semantic_review', 'historical_closure'))
if ($Result -eq 'FAIL_INPUT') {
    $status = if ($receipt -and $receipt.status -and $receipt.status -ne 'FAIL_INPUT') { [string]$receipt.status } else { 'FAIL_INPUT' }
    $nextAction = 'REBUILD_REVIEW_INPUT'
} elseif ($isSemanticEvent) {
    if ($Result -eq 'FAIL') { $failureCount++ } else { $failureCount = 0 }
    $status = if ($Result -eq 'FAIL' -and $failureCount -ge 3) { 'UNRESOLVED' } else { $Result }
    $nextAction = if ($status -eq 'PASS') { 'CONTINUE' } elseif ($failureCount -eq 1) { 'TARGETED_REPAIR' } elseif ($failureCount -eq 2) { 'FRESH_FULL_REVIEW' } else { 'CONTINUE_AND_REPORT_AT_BATCH_END' }
} else {
    $status = if ($receipt -and $receipt.status) { [string]$receipt.status } elseif ($Result -eq 'PASS') { 'MACHINE_PASS' } else { 'MACHINE_FAIL' }
    $nextAction = if ($Result -eq 'PASS') {
        if ($receipt -and $receipt.status -eq 'PASS') { 'CONTINUE' }
        elseif ($receipt -and $receipt.next_action -and [string]$receipt.next_action -ne 'FIX_MACHINE_CLOSURE') { [string]$receipt.next_action }
        else { 'AWAIT_SEMANTIC_REVIEW' }
    } else { 'FIX_MACHINE_CLOSURE' }
}
$persistStructural = [bool]($StructuralChange -or ($receipt -and $receipt.structural_change -eq $true))
$persistFresh = [bool]($FreshCheckerRequired -or ($receipt -and $receipt.fresh_checker_required -eq $true))
if ($isSemanticEvent -and $Result -eq 'PASS' -and $CheckerMode -eq 'Full' -and -not $StructuralChange -and -not $FreshCheckerRequired) {
    $persistStructural = $false
    $persistFresh = $false
}
$events.Add([ordered]@{
    at = (Get-Date).ToString('o')
    event_type = $EventType
    result = $Result
    status = $status
    round = $Round
    mode = $CheckerMode
    checked_dimensions = $checkedDimensions
    failed_dimensions = $failedDimensions
    touched_scopes = $touched
    checked_raw_sha256 = $CheckedHash
    checked_core_sha256 = [string]$scopes.core_file
    observed_raw_sha256 = $observedHash
    checked_packet_sha256 = $CheckedPacketHash
    hash_mismatch = $hashMismatch
    structural_change = [bool]$StructuralChange
    fresh_checker_required = [bool]$FreshCheckerRequired
    note = $Note
})
$receiptDependencies = if ($receipt) { @($receipt.depends_on) } else { @() }
$allDependencies = @(@($dependencies) + @($receiptDependencies) | Where-Object { $_ } | Select-Object -Unique)

# A successful scoped or machine closure advances only the baselines it actually
# checked.  Keeping every old baseline made Plan request the same visual/ledger
# check forever after Commit, while replacing all baselines would incorrectly
# bless unchecked semantic changes.
$persistedScopes = $null
if ($isSemanticEvent -and $Result -eq 'PASS') {
    $persistedScopes = $scopes
} elseif ($receipt -and $receipt.scopes) {
    $persistedScopes = [ordered]@{}
    foreach ($scopeName in @('raw_file', 'core_file', 'core_semantic', 'continuity', 'timeline', 'preview', 'ledger', 'ledger_raw', 'visual', 'visual_status')) {
        $oldScopeProperty = $receipt.scopes.PSObject.Properties[$scopeName]
        $persistedScopes[$scopeName] = if ($oldScopeProperty) { [string]$oldScopeProperty.Value } else { '' }
    }
    if ($Result -eq 'PASS') {
        foreach ($scopeName in $touched) {
            if ($persistedScopes.Contains($scopeName) -and $scopes.Contains($scopeName)) {
                $persistedScopes[$scopeName] = [string]$scopes[$scopeName]
            }
        }
    }
}

$canMigrateLegacyFullAudit = [bool]($receipt -and $receipt.scopes -and [string]$receipt.scopes.core_semantic -eq [string]$scopes.core_semantic -and [string]$receipt.scopes.continuity -eq [string]$scopes.continuity -and [string]$receipt.scopes.timeline -eq [string]$scopes.timeline -and @($receipt.events | Where-Object { $_.event_type -eq 'semantic_review' -and $_.result -eq 'PASS' -and $_.mode -eq 'Full' }).Count -gt 0)
$newReceipt = [ordered]@{
    schema_version = 'comic-adapt-quality/1.0'
    target = $Target
    kind = $Kind
    path = $targetPath.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
    status = $status
    updated_at = (Get-Date).ToString('o')
    legacy_imported = $false
    checker_mode = $CheckerMode
    checked_dimensions = if ($isSemanticEvent) { $checkedDimensions } elseif ($receipt) { @($receipt.checked_dimensions) } else { @() }
    failed_dimensions = if ($isSemanticEvent) { $failedDimensions } elseif ($receipt) { @($receipt.failed_dimensions) } else { @() }
    last_failed_dimensions = if ($isSemanticEvent -and $Result -eq 'FAIL') { $failedDimensions } elseif ($receipt) { @($receipt.last_failed_dimensions) } else { @() }
    touched_scopes = $touched
    depends_on = $allDependencies
    failure_count = $failureCount
    next_action = $nextAction
    checked_raw_sha256 = if ($isSemanticEvent) { $CheckedHash } elseif ($receipt -and $receipt.checked_raw_sha256) { [string]$receipt.checked_raw_sha256 } else { '' }
    checked_core_sha256 = if ($isSemanticEvent -and $Result -eq 'PASS') { [string]$scopes.core_file } elseif ($receipt -and $receipt.checked_core_sha256) { [string]$receipt.checked_core_sha256 } else { '' }
    observed_raw_sha256 = $observedHash
    checked_packet_sha256 = if ($CheckedPacketHash) { $CheckedPacketHash } elseif ($receipt -and $receipt.checked_packet_sha256) { [string]$receipt.checked_packet_sha256 } else { '' }
    structural_change = $persistStructural
    fresh_checker_required = $persistFresh
    full_audit_core_hash = if ($isSemanticEvent -and $Result -eq 'PASS' -and $CheckerMode -eq 'Full') { Get-FullAuditCoreHash $scopes } elseif ($receipt -and $receipt.full_audit_core_hash) { [string]$receipt.full_audit_core_hash } elseif ($Result -eq 'PASS' -and $canMigrateLegacyFullAudit) { Get-FullAuditCoreHash $scopes } else { '' }
    scopes = $persistedScopes
    last_observed_scopes = $scopes
    events = $events.ToArray()
}
Write-JsonAtomic $receiptPath $newReceipt

if ($status -eq 'UNRESOLVED') {
    $items = @()
    $existing = Read-Json $unresolvedPath
    if ($existing) { $items = @($existing) }
    $items = @($items | Where-Object { $_.target -ne $Target })
    $items += [ordered]@{
        target = $Target
        recorded_at = (Get-Date).ToString('o')
        failed_dimensions = $failedDimensions
        depends_on = $allDependencies
        note = $Note
        receipt = $receiptPath.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
    }
    Write-JsonAtomic $unresolvedPath $items
} elseif ($status -eq 'PASS' -and $EventType -eq 'historical_closure') {
    $existing = Read-Json $unresolvedPath
    $items = if ($existing) { @($existing | Where-Object { [string]$_.target -ne $Target }) } else { @() }
    Write-JsonAtomic $unresolvedPath $items
}

if ($isSemanticEvent) { Complete-GoalSemanticState $Target $status }

Write-Output ("QUALITY-RECEIPT: {0} | status={1} | failures={2} | next={3} | path={4}" -f $Target, $status, $failureCount, $nextAction, $receiptPath)
if ($status -eq 'UNRESOLVED') { exit 2 }
if ($Result -eq 'FAIL_INPUT') { exit 2 }
if ($isSemanticEvent -and $status -eq 'FAIL') { exit 1 }
if (-not $isSemanticEvent -and $Result -eq 'FAIL') { exit 1 }
exit 0

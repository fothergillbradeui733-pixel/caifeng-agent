[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 9999)]
    [int]$Episode,

    [ValidateSet('Write', 'Review', 'Final')]
    [string]$Stage = 'Write',

    [string]$OutFile,

    [string]$BatchContractPath = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComicAdapt.Common.psm1') -Force

function Get-FileRecord([string]$Root, [string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = Get-RelativePathCompat $Root $item.FullName
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
        bytes = $item.Length
    }
}

function Get-TextSha256([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-JsonSafe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json }
    catch { return $null }
}

function Get-Section([string]$Text, [string]$TitlePattern) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $pattern = "(?ms)^##\s+[^\r\n]*$TitlePattern[^\r\n]*\r?\n.*?(?=^##\s+|\z)"
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) { return $match.Value.Trim() }
    return ''
}

function Get-MetadataValue([string]$Text, [string]$Key) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Key) + '[：:]\s*(?<value>[^\r\n]+)\s*$')
    if ($match.Success) { return $match.Groups['value'].Value.Trim() }
    return ''
}

function ConvertFrom-MarkdownTable([string]$Text, [string]$Heading) {
    $sectionText = Get-Section $Text ([regex]::Escape($Heading))
    if (-not $sectionText) { return @() }
    $lines = @($sectionText -split '\r?\n' | Where-Object { $_ -match '^\s*\|' })
    if ($lines.Count -lt 2) { return @() }
    $headers = @($lines[0].Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        if ($line -match '^\s*\|(?:\s*:?-+:?\s*\|)+\s*$') { continue }
        $cells = @($line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells.Count -ne $headers.Count) { continue }
        $map = [ordered]@{}
        for ($i = 0; $i -lt $headers.Count; $i++) { $map[$headers[$i]] = $cells[$i] }
        $rows.Add([pscustomobject]$map)
    }
    return $rows.ToArray()
}

function Get-VisualEpisodeRecord([string]$Root, [string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
    return [ordered]@{
        file = Get-FileRecord $Root $Path
        schema_version = Get-MetadataValue $text 'schema_version'
        status = Get-MetadataValue $text '交接状态'
        script_path = Get-MetadataValue $text '剧本路径'
        script_sha256 = Get-MetadataValue $text '剧本SHA256'
        people = @(ConvertFrom-MarkdownTable $text '人物出现')
        scenes = @(ConvertFrom-MarkdownTable $text '场景出现')
        props = @(ConvertFrom-MarkdownTable $text '道具出现')
        unresolved = Get-Section $text '未解决项'
    }
}

function Find-EpisodeFile([string]$ScriptsDir, [int]$Number) {
    if (-not (Test-Path -LiteralPath $ScriptsDir -PathType Container)) { return $null }
    $pattern = '^EP-0*' + $Number + '\.md$'
    return Get-ChildItem -LiteralPath $ScriptsDir -File -Filter 'EP-*.md' |
        Where-Object { $_.Name -match $pattern } |
        Sort-Object Name |
        Select-Object -First 1
}

function Get-PreviousTail([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $body = [regex]::Split($Text, '(?m)^【台账登记块】\s*$')[0]
    $matches = [regex]::Matches($body, '(?m)^场次\s+[^\r\n]+')
    if ($matches.Count -eq 0) { return $body.Trim() }
    $index = [Math]::Max(0, $matches.Count - 2)
    return $body.Substring($matches[$index].Index).Trim()
}

function Get-PlotFieldValues([object[]]$Points, [string]$Field) {
    $values = [Collections.Generic.List[string]]::new()
    foreach ($point in @($Points)) {
        $match = [regex]::Match([string]$point.text, '(?m)^-\s+\*\*' + [regex]::Escape($Field) + '\*\*[：:]\s*(?<value>[^\r\n]+)')
        if ($match.Success -and $match.Groups['value'].Value.Trim()) { $values.Add($match.Groups['value'].Value.Trim()) }
    }
    return $values.ToArray()
}

function Get-PlotFieldValue([string]$Text, [string]$Field) {
    $match = [regex]::Match($Text, '(?m)^-\s+\*\*' + [regex]::Escape($Field) + '\*\*[：:]\s*(?<value>[^\r\n]+)')
    if ($match.Success) { return $match.Groups['value'].Value.Trim() }
    return ''
}

function Get-CompactPlotPoints([object[]]$Points) {
    $result = [Collections.Generic.List[object]]::new()
    $fields = @('原著章节', '原著锚点', '原著内容', '行动主体/承受主体', '信息流', '冲突强度', '情绪钩子', '必保清单', '改编处理', '可拍性')
    foreach ($point in @($Points)) {
        $values = [ordered]@{}
        foreach ($field in $fields) {
            $value = Get-PlotFieldValue ([string]$point.text) $field
            if ($value) { $values[$field] = $value }
        }
        $result.Add([ordered]@{ id = [int]$point.id; title = [string]$point.title; fields = $values })
    }
    return $result.ToArray()
}

function Get-MustKeepCoverage([object[]]$Points, [string]$EpisodeToken) {
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($point in @($Points)) {
        $raw = Get-PlotFieldValue ([string]$point.text) '必保清单'
        $anchor = Get-PlotFieldValue ([string]$point.text) '原著锚点'
        $index = 0
        foreach ($item in @($raw -split '[｜；;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $index++
            $kind = if ($item -match '[「」“”]') { 'quote' } elseif ($item -match '[零一二三四五六七八九十百千万两\d]+(?:日|天|月|年|枚|次|层|级|人|里|丈|成|分|%)') { 'numeric' } elseif ($item -match '知道|知情|得知|揭晓|不得提前|信息') { 'knowledge' } elseif ($item -match '先.+后|主体|归属|因果') { 'causal' } else { 'fact' }
            $rows.Add([ordered]@{
                coverage_id = ('{0}-P{1}-K{2}' -f $EpisodeToken, ([int]$point.id).ToString('D2'), $index.ToString('D2'))
                plot_point = [int]$point.id
                kind = $kind
                item = $item
                source_anchor = $anchor
                status = 'PENDING'
                script_evidence = ''
            })
        }
    }
    return $rows.ToArray()
}

function Get-CompactVisualFacts([object]$SourceFacts, [object]$CurrentVisual, [object]$PreviousVisual) {
    $stateRows = @()
    if ($CurrentVisual) { $stateRows += @($CurrentVisual.people) + @($CurrentVisual.scenes) + @($CurrentVisual.props) }
    if ($PreviousVisual) { $stateRows += @($PreviousVisual.people) + @($PreviousVisual.scenes) + @($PreviousVisual.props) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $result = [Collections.Generic.List[object]]::new()
    foreach ($group in @(
        [ordered]@{ type = '人物/条件'; rows = @($SourceFacts.people_and_conditional); name = '剧本规范名' },
        [ordered]@{ type = '场景'; rows = @($SourceFacts.scenes); name = '场次头规范名' },
        [ordered]@{ type = '道具'; rows = @($SourceFacts.props); name = '剧本正式名' }
    )) {
        foreach ($row in @($group.rows)) {
            $id = [string]$row.'实体ID'
            if (-not $id -or -not $seen.Add($id)) { continue }
            $state = @($stateRows | Where-Object { [string]$_.'实体ID' -eq $id } | Select-Object -First 1)
            $asset = [string]$row.'建议@资产名'
            $anchor = '源事实基线'
            if ($state.Count -gt 0) {
                if ([string]$state[0].'建议状态@') { $asset = [string]$state[0].'建议状态@' }
                foreach ($column in @('生效区间/切换锚', '状态/切换锚', '状态变化/切换锚')) {
                    if ([string]$state[0].$column) { $anchor = [string]$state[0].$column; break }
                }
            }
            $result.Add([ordered]@{ id = $id; type = $group.type; canonical = [string]$row.($group.name); asset = $asset; anchor = $anchor })
        }
    }
    return $result.ToArray()
}

function Get-FocusedProgressSection([string]$SectionText, [string]$Corpus, [bool]$KeepFull) {
    if ([string]::IsNullOrWhiteSpace($SectionText) -or $KeepFull) {
        return [ordered]@{ text = $SectionText; omitted_rows = 0; mode = $(if ($KeepFull) { 'full' } else { 'empty' }) }
    }
    $lines = @($SectionText -split '\r?\n')
    $kept = [Collections.Generic.List[string]]::new()
    $omitted = 0
    $tableHeaderSeen = $false
    foreach ($line in $lines) {
        if ($line -match '^##\s+') { $kept.Add($line); continue }
        if ($line -match '^\s*\|') {
            $cells = @($line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
            $isSeparator = ($line -match '^\s*\|(?:\s*:?-+:?\s*\|)+\s*$')
            if (-not $tableHeaderSeen -or $isSeparator) {
                $kept.Add($line)
                if (-not $isSeparator) { $tableHeaderSeen = $true }
                continue
            }
            $key = if ($cells.Count -gt 0) { [string]$cells[0] } else { '' }
            if ($key -and $Corpus -match [regex]::Escape($key)) { $kept.Add($line) } else { $omitted++ }
            continue
        }
        if ($line -match '^\s*[-*]\s+' -and $line -notmatch '^\s*[-*]\s*无\s*$') {
            $candidate = ($line -replace '^\s*[-*]\s+', '').Trim()
            $key = ([regex]::Split($candidate, '[=：:｜|（(]', 2)[0]).Trim()
            if ($key -and $Corpus -match [regex]::Escape($key)) { $kept.Add($line) } else { $omitted++ }
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($line)) { $kept.Add($line) }
    }
    if ($omitted -gt 0) { $kept.Add("- 其余$omitted 条未命中本集；歧义时回读 progress.md 对应完整章节") }
    return [ordered]@{ text = ($kept -join "`n").Trim(); omitted_rows = $omitted; mode = 'focused' }
}

$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$episodeToken = 'EP-' + $Episode.ToString('D2')
$batchContract = $null
$batchEpisode = $null
$resolvedBatchContractPath = ''
if ($BatchContractPath) {
    $resolvedBatchContractPath = if ([IO.Path]::IsPathRooted($BatchContractPath)) { $BatchContractPath } else { Join-Path $root $BatchContractPath }
    $batchContract = Read-JsonSafe $resolvedBatchContractPath
    if (-not $batchContract -or [string]$batchContract.schema_version -ne 'comic-adapt-batch-contract/1.0') { throw "Invalid batch contract: $resolvedBatchContractPath" }
    if ([string]$batchContract.contract_status -ne 'FROZEN') { throw "Batch contract is not FROZEN: $resolvedBatchContractPath" }
    $batchEpisode = @($batchContract.episode_contracts | Where-Object { [string]$_.episode -eq $episodeToken } | Select-Object -First 1)
    if ($batchEpisode.Count -eq 0) { throw "Batch contract does not contain $episodeToken" }
    $batchEpisode = $batchEpisode[0]
}
$policyPath = Join-Path $root '.comic-adapt\policy.json'
$policy = Read-JsonSafe $policyPath
$previewEnabled = if ($policy) { [bool]$policy.preview_enabled } else { $true }
$sourceRelativeTime = [bool]($policy -and [string]$policy.time_model -eq 'source_relative')
$writerBriefTokenLimit = if ($policy -and $policy.PSObject.Properties['writer_brief_token_limit']) { [int]$policy.writer_brief_token_limit } else { 3500 }
$writePacketTokenLimit = if ($policy -and $policy.PSObject.Properties['write_packet_token_limit']) { [int]$policy.write_packet_token_limit } else { 10000 }
$plotPath = Join-Path $root 'plot-map.md'
$progressPath = Join-Path $root 'progress.md'
$cardsPath = Join-Path $root 'character-cards.md'
$ledgerPath = Join-Path $root 'ledger-foreshadow.md'
$scriptsDir = Join-Path $root 'scripts'
$novelDir = Join-Path $root 'novel'
$visualDir = Join-Path $root 'visual-assets'
$sourceFactsPath = Join-Path $visualDir 'source-facts.md'
$visualManifestPath = Join-Path $visualDir 'handoff.md'
$sourceIndexPath = Join-Path $root '.comic-adapt-cache\source-index.json'
$sourceIndex = Read-JsonSafe $sourceIndexPath
$sourceIndexValid = [bool]($sourceIndex -and $sourceIndex.schema_version -eq 'comic-adapt-source-index/1.0')
$sourceIndexScript = Join-Path $PSScriptRoot 'source-index.ps1'

# Review/Final are mutable deltas over a signed Write packet. Re-parsing every
# novel/map/progress field here used most deterministic packet time and then
# discarded the result. Require the signed Write packet and writer brief so a
# missing or stale cache is rebuilt instead of bypassing the V6 contract gate.
if ($Stage -ne 'Write') {
    $basePacketPath = Join-Path $root ('.comic-adapt-cache\packets\' + $episodeToken + '.json')
    $basePacket = Read-JsonSafe $basePacketPath
    $baseBriefPath = if ($basePacket -and $basePacket.writer_brief -and $basePacket.writer_brief.path) { Join-Path $root ([string]$basePacket.writer_brief.path) } else { '' }
    if ($basePacket -and $baseBriefPath -and (Test-Path -LiteralPath $baseBriefPath -PathType Leaf)) {
        $deltaMissing = [Collections.Generic.List[string]]::new()
        foreach ($item in @($basePacket.missing)) { if ($item) { $deltaMissing.Add([string]$item) } }
        $currentFile = Find-EpisodeFile $scriptsDir $Episode
        if (-not $currentFile) { $deltaMissing.Add('current-script:' + $episodeToken) }
        $currentScriptHash = if ($currentFile) { (Get-FileHash -Algorithm SHA256 -LiteralPath $currentFile.FullName).Hash.ToLowerInvariant() } else { '' }
        $currentVisualPath = Join-Path $visualDir ('episodes\' + $episodeToken + '.md')
        $currentVisual = Get-VisualEpisodeRecord $root $currentVisualPath
        if (-not $currentVisual) { $deltaMissing.Add('visual-handoff:' + $episodeToken + ':missing') }
        elseif ($currentVisual.script_sha256 -ne $currentScriptHash) { $deltaMissing.Add('visual-handoff:' + $episodeToken + ':script-hash') }
        elseif ($Stage -eq 'Review' -and $currentVisual.status -notin @('DRAFT', 'READY')) { $deltaMissing.Add('visual-handoff:' + $episodeToken + ':not-draft-or-ready') }
        elseif ($Stage -eq 'Final' -and $currentVisual.status -ne 'READY') { $deltaMissing.Add('visual-handoff:' + $episodeToken + ':not-ready') }

        $mutableRelatives = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($relative in @(
            'progress.md',
            'ledger-foreshadow.md',
            ('scripts/' + $episodeToken + '.md'),
            ('visual-assets/episodes/' + $episodeToken + '.md'),
            ('.comic-adapt/quality/' + $episodeToken + '.json'),
            'visual-assets/handoff.md'
        )) { [void]$mutableRelatives.Add($relative) }
        foreach ($authority in @($basePacket.authority_files)) {
            $relative = ([string]$authority.path).Replace('\', '/')
            if ($Stage -eq 'Final' -and $mutableRelatives.Contains($relative)) { continue }
            $authorityPath = Join-Path $root $relative
            if (-not (Test-Path -LiteralPath $authorityPath -PathType Leaf)) { $deltaMissing.Add('authority-missing:' + $relative); continue }
            $observed = (Get-FileHash -Algorithm SHA256 -LiteralPath $authorityPath).Hash.ToLowerInvariant()
            if ($observed -ne [string]$authority.sha256) { $deltaMissing.Add('authority-changed:' + $relative) }
        }

        if ($Stage -eq 'Final') {
            $qualityPath = Join-Path $root ('.comic-adapt\quality\' + $episodeToken + '.json')
            $qualityReceipt = Read-JsonSafe $qualityPath
            if (-not $qualityReceipt -or $qualityReceipt.status -ne 'PASS') { $deltaMissing.Add('quality-pass:' + $episodeToken) }
        }

        $deltaAuthorities = [Collections.Generic.List[object]]::new()
        foreach ($path in @($basePacketPath, $baseBriefPath, $(if ($currentFile) { $currentFile.FullName } else { '' }), $currentVisualPath, $progressPath)) {
            if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { $deltaAuthorities.Add((Get-FileRecord $root $path)) }
        }
        $packet = [ordered]@{
            schema_version = '2.1'
            episode = $episodeToken
            stage = $Stage.ToUpperInvariant()
            preview_enabled = $previewEnabled
            generated_at = (Get-Date).ToString('o')
            project_root = $root
            contract_sha256 = [string]$basePacket.contract_sha256
            base_contract_changed = $false
            validation_mode = 'SIGNED_BASE_MUTABLE_DELTA'
            base_packet = Get-FileRecord $root $basePacketPath
            writer_brief = Get-FileRecord $root $baseBriefPath
            current_script = if ($currentFile) { Get-FileRecord $root $currentFile.FullName } else { $null }
            visual_handoff = [ordered]@{
                integrity = if ($deltaMissing.Count -eq 0) { $(if ($Stage -eq 'Review') { 'DRAFT_OK' } else { 'READY' }) } else { 'INVALID' }
                current = if ($currentVisual) { [ordered]@{ file = $currentVisual.file; status = $currentVisual.status; script_path = $currentVisual.script_path; script_sha256 = $currentVisual.script_sha256; people_count = @($currentVisual.people).Count; scene_count = @($currentVisual.scenes).Count; prop_count = @($currentVisual.props).Count } } else { $null }
                errors = @($deltaMissing | Sort-Object -Unique)
                warnings = @()
            }
            risk_flags = @($basePacket.risk_flags)
            review_dimensions = $basePacket.review_dimensions
            authority_files = $deltaAuthorities.ToArray()
            missing = @($deltaMissing | Sort-Object -Unique)
            usage = 'Signed Write-base delta. Checker reads checker brief, script, writer brief and listed source files; full Write JSON is audit fallback only.'
        }
        $fastOutFile = $OutFile
        if ([string]::IsNullOrWhiteSpace($fastOutFile)) {
            $fastOutFile = Join-Path $root ('.comic-adapt-cache\packets\' + $episodeToken + '.' + $Stage.ToLowerInvariant() + '.json')
        } elseif (-not [IO.Path]::IsPathRooted($fastOutFile)) { $fastOutFile = Join-Path $root $fastOutFile }
        Write-TextAtomic $fastOutFile (($packet | ConvertTo-Json -Depth 12) + "`n")
        Write-Output ("CONTEXT-PACKET: {0}" -f $fastOutFile)
        Write-Output ("WRITER-BRIEF: {0}" -f $baseBriefPath)
        Write-Output ("EPISODE: {0} | stage={1} | validation=SIGNED_BASE_MUTABLE_DELTA | missing={2}" -f $episodeToken, $Stage.ToUpperInvariant(), $deltaMissing.Count)
        if ($deltaMissing.Count -gt 0) { Write-Output ('MISSING: ' + (($deltaMissing | Sort-Object -Unique) -join '; ')); exit 2 }
        exit 0
    }
    $missingBase = if (-not $basePacket) { $basePacketPath } elseif (-not $baseBriefPath) { 'writer_brief pointer' } else { $baseBriefPath }
    throw "V6 $Stage packet requires a signed Write packet and writer brief; rebuild Write context first (missing: $missingBase)"
}

if ($sourceIndexValid) {
    & $sourceIndexScript -ProjectRoot $root -Mode ValidateFast -Episode $Episode 2>&1 | Out-Null
    $sourceIndexValid = ($LASTEXITCODE -eq 0)
}
if (-not $sourceIndexValid -and (Test-Path -LiteralPath $plotPath -PathType Leaf)) {
    if (Test-Path -LiteralPath $sourceIndexScript -PathType Leaf) {
        & $sourceIndexScript -ProjectRoot $root -Mode Build | Out-Null
        $sourceIndex = Read-JsonSafe $sourceIndexPath
        $sourceIndexValid = [bool]($sourceIndex -and $sourceIndex.schema_version -eq 'comic-adapt-source-index/1.0')
    }
}
$sourceFactsText = if (Test-Path -LiteralPath $sourceFactsPath -PathType Leaf) { Get-Content -Raw -Encoding UTF8 -LiteralPath $sourceFactsPath } else { '' }
$sourcePeopleRows = if ($sourceIndexValid) { @($sourceIndex.source_facts.people) } elseif ($sourceFactsText) { @(ConvertFrom-MarkdownTable $sourceFactsText '人物与条件类型') } else { @() }
$sourceCharacterLabels = [ordered]@{}
foreach ($row in $sourcePeopleRows) {
    if ([string]$row.'类型' -notin @('角色', '不可见声音角色', '3D Q版小人')) { continue }
    $canonical = ([string]$row.'剧本规范名').Trim()
    if (-not $canonical) { continue }
    foreach ($label in @($canonical) + @(([string]$row.'别名') -split '[、，,；;]')) {
        $cleanLabel = $label.Trim()
        if ($cleanLabel -and $cleanLabel -ne '无') { $sourceCharacterLabels[$cleanLabel] = $canonical }
    }
}

$missing = [Collections.Generic.List[string]]::new()
foreach ($required in @($plotPath, $progressPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        $missing.Add((Get-RelativePathCompat $root $required))
    }
}

$plotText = if (Test-Path -LiteralPath $plotPath) { Get-Content -Raw -Encoding UTF8 -LiteralPath $plotPath } else { '' }
$progressText = if (Test-Path -LiteralPath $progressPath) { Get-Content -Raw -Encoding UTF8 -LiteralPath $progressPath } else { '' }
$cardsText = if (Test-Path -LiteralPath $cardsPath) { Get-Content -Raw -Encoding UTF8 -LiteralPath $cardsPath } else { Get-Section $plotText '角色索引' }

$plotPoints = [Collections.Generic.List[object]]::new()
$chapterNumbers = [Collections.Generic.HashSet[int]]::new()
$characterNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$pointPattern = '(?ms)^###\s+【剧情(?<id>\d+)】(?<title>[^\r\n]*)\r?\n(?<body>.*?)(?=^###\s+【剧情\d+】|^###\s+批次小结|^##\s+批次|\z)'
if ($sourceIndexValid) {
    foreach ($indexedPoint in @($sourceIndex.plot_points)) {
        if (@($indexedPoint.episode_tokens) -notcontains $episodeToken) { continue }
        $plotPoints.Add([ordered]@{ id = [int]$indexedPoint.id; title = [string]$indexedPoint.title; text = [string]$indexedPoint.text })
    }
} else {
    foreach ($match in [regex]::Matches($plotText, $pointPattern)) {
        $full = $match.Value.Trim()
        if ($full -notmatch ('(?m)^-\s+\*\*归属集数\*\*：[^\r\n]*EP-0*' + $Episode + '(?!\d)')) { continue }
        $plotPoints.Add([ordered]@{ id = [int]$match.Groups['id'].Value; title = $match.Groups['title'].Value.Trim(); text = $full })
    }
}
foreach ($plotPoint in $plotPoints) {
    $full = [string]$plotPoint.text
    foreach ($chapterMatch in [regex]::Matches($full, '第(?<start>\d+)章(?:\s*[~～—-]+\s*第?(?<end>\d+)章)?')) {
        $start = [int]$chapterMatch.Groups['start'].Value
        $end = if ($chapterMatch.Groups['end'].Success) { [int]$chapterMatch.Groups['end'].Value } else { $start }
        if ($end -lt $start) { $tmp = $start; $start = $end; $end = $tmp }
        for ($n = $start; $n -le $end; $n++) { [void]$chapterNumbers.Add($n) }
    }

    foreach ($roleMatch in [regex]::Matches($full, '(?m)^-\s+\*\*(?:角色|行动主体/承受主体|信息流|必保清单)\*\*：(?<roles>[^\r\n]+)')) {
        $roleText = $roleMatch.Groups['roles'].Value
        $matchedEntries = @($sourceCharacterLabels.GetEnumerator() | Where-Object {
            $roleText -match [regex]::Escape([string]$_.Key)
        } | Sort-Object { ([string]$_.Key).Length } -Descending)
        foreach ($entry in $matchedEntries) {
            $label = [string]$entry.Key
            $canonical = [string]$entry.Value
            $shadowedBySpecificName = @($matchedEntries | Where-Object {
                ([string]$_.Key).Length -gt $label.Length -and
                ([string]$_.Key).Contains($label) -and
                [string]$_.Value -ne $canonical
            }).Count -gt 0
            $shadowedByKnownCanonical = @($characterNames | Where-Object {
                ([string]$_).Contains($label) -and [string]$_ -ne $canonical
            }).Count -gt 0
            if (-not $shadowedBySpecificName -and -not $shadowedByKnownCanonical) { [void]$characterNames.Add($canonical) }
        }
        if ($roleMatch.Value -match '\*\*角色\*\*') {
            foreach ($name in ($roleText -split '[、，,；;]')) {
                $clean = ($name -replace '[×xX]\d+$', '').Trim()
                if ($clean) { [void]$characterNames.Add($clean) }
            }
        }
    }
}

if ($plotPoints.Count -eq 0) { $missing.Add("plot-map:$episodeToken") }

$sourceFiles = [Collections.Generic.List[object]]::new()
$novelFiles = if ($sourceIndexValid) { @($sourceIndex.novel_files) } elseif (Test-Path -LiteralPath $novelDir -PathType Container) { @(Get-ChildItem -LiteralPath $novelDir -Recurse -File | Sort-Object FullName) } else { @() }
foreach ($chapter in ($chapterNumbers | Sort-Object)) {
    $candidate = if ($sourceIndexValid) { $novelFiles | Where-Object { [int]$_.chapter -eq $chapter } | Select-Object -First 1 } else { $novelFiles | Where-Object { $_.BaseName -match ('(?<!\d)0*' + $chapter + '(?!\d)') } | Select-Object -First 1 }
    if ($candidate) {
        $record = if ($sourceIndexValid) { [ordered]@{ path = [string]$candidate.path; sha256 = [string]$candidate.sha256; bytes = [int64]$candidate.bytes } } else { Get-FileRecord $root $candidate.FullName }
        $record.chapter = $chapter
        $sourceFiles.Add($record)
    } else {
        $missing.Add("novel:chapter-$chapter")
    }
}

$characterRows = [Collections.Generic.List[string]]::new()
if ($cardsText) {
    foreach ($line in ($cardsText -split '\r?\n')) {
        if ($line -notmatch '^\s*\|') { continue }
        $cells = @($line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells.Count -eq 0) { continue }
        if ($characterNames.Contains($cells[0])) { $characterRows.Add($line.Trim()) }
    }
}
$nonCharacterLabels = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($sourceFactsText) {
    foreach ($row in @(ConvertFrom-MarkdownTable $sourceFactsText '人物与条件类型')) {
        if ([string]$row.'类型' -eq '角色') { continue }
        foreach ($label in @([string]$row.'剧本规范名') + @(([string]$row.'别名') -split '[、，,；;]')) {
            $cleanLabel = $label.Trim()
            if ($cleanLabel -and $cleanLabel -ne '无') { [void]$nonCharacterLabels.Add($cleanLabel) }
        }
    }
}
foreach ($name in $characterNames) {
    if (-not ($characterRows | Where-Object { $_ -match ('^\s*\|\s*' + [regex]::Escape($name) + '\s*\|') })) {
        $isGeneric = $nonCharacterLabels.Contains($name) -or $name -match '(?:群|众|百姓|凡魂|魂魄|弟子|杂役|守卫|侍卫|士兵|村民|宾客|围观者)$'
        if (-not $isGeneric) { $missing.Add("character-card:$name") }
    }
}

$sectionPatterns = [ordered]@{
    basic_info = '基本信息'
    character_state = '角色状态快照'
    foreshadow = '待回收伏笔'
    props = '道具.?信物台账'
    scene_names = '场景名登记表'
    source_time = $(if ($sourceRelativeTime) { '原著时间锚' } else { '故事内日历' })
    deadlines = '未了期限'
    action_lines = '开放行动线清单'
    canon = '设定.?数字口径表'
    fingerprints = '高频意象表'
    beats = '全局节拍卡'
    previous_snapshot = '上集末场快照'
}
$progressSectionsFull = [ordered]@{}
foreach ($entry in $sectionPatterns.GetEnumerator()) {
    $progressSectionsFull[$entry.Key] = Get-Section $progressText $entry.Value
}

$previousFile = if ($Episode -gt 1) { Find-EpisodeFile $scriptsDir ($Episode - 1) } else { $null }
$previousText = if ($previousFile) { Get-Content -Raw -Encoding UTF8 -LiteralPath $previousFile.FullName } else { '' }
$previewMatch = if ($previewEnabled) { [regex]::Match($previousText, '(?m)^下集预告(?:〔[^〕\r\n]+〕)?[：:][^\r\n]*(?:\r?\n(?!【台账登记块】)[^\r\n]+)?') } else { $null }
$previous = [ordered]@{
    file = if ($previousFile) { Get-FileRecord $root $previousFile.FullName } else { $null }
    tail = Get-PreviousTail $previousText
    preview = if ($previewMatch -and $previewMatch.Success) { $previewMatch.Value.Trim() } else { '' }
}
if ($Episode -gt 1 -and -not $previousFile) { $missing.Add('previous-script:EP-' + ($Episode - 1).ToString('D2')) }

$focusCorpus = (($plotPoints | ForEach-Object { $_.text }) -join "`n") + "`n" + $previous.tail + "`n" + (($characterNames | Sort-Object) -join "`n") + "`n" + $episodeToken + "`n" + $(if ($Episode -gt 1) { 'EP-' + ($Episode - 1).ToString('D2') } else { '' })
$progressSections = [ordered]@{}
$progressFocusMeta = [ordered]@{}
foreach ($entry in $progressSectionsFull.GetEnumerator()) {
    $keepFull = $entry.Key -in @('basic_info', 'previous_snapshot')
    $focused = Get-FocusedProgressSection ([string]$entry.Value) $focusCorpus $keepFull
    $progressSections[$entry.Key] = [string]$focused.text
    $progressFocusMeta[$entry.Key] = [ordered]@{ mode = [string]$focused.mode; omitted_rows = [int]$focused.omitted_rows }
}

$currentFile = Find-EpisodeFile $scriptsDir $Episode
$currentScriptText = if ($currentFile) { Get-Content -Raw -Encoding UTF8 -LiteralPath $currentFile.FullName } else { '' }
$visualFromEpisode = if ($sourceFactsText) {
    $raw = Get-MetadataValue $sourceFactsText '要求起始集'
    if ($raw -match '^EP-0*(\d+)$') { [int]$Matches[1] } else { 0 }
} else { 0 }
$currentVisualPath = Join-Path $visualDir ("episodes\{0}.md" -f $episodeToken)
$previousVisualPath = if ($Episode -gt 1) { Join-Path $visualDir ("episodes\EP-{0}.md" -f ($Episode - 1).ToString('D2')) } else { $null }
$currentVisual = Get-VisualEpisodeRecord $root $currentVisualPath
$previousVisual = if ($previousVisualPath) { Get-VisualEpisodeRecord $root $previousVisualPath } else { $null }
$visualErrors = [Collections.Generic.List[string]]::new()
$visualWarnings = [Collections.Generic.List[string]]::new()

if ($sourceFactsText) {
    if ((Get-MetadataValue $sourceFactsText 'schema_version') -ne 'comic-adapt-visual-handoff/1.0') { $visualErrors.Add('source-facts:schema') }
    if ($visualFromEpisode -le 0) { $visualErrors.Add('source-facts:required-start') }
    $pendingText = Get-Section $sourceFactsText '待确认'
    if ($pendingText -notmatch '^##\s+' -or $pendingText -notmatch '(?m)^-?\s*无\s*$') { $visualErrors.Add('source-facts:pending') }

    if ($currentFile -and $Episode -ge $visualFromEpisode) {
        $actualCurrentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $currentFile.FullName).Hash.ToLowerInvariant()
        if ($Stage -eq 'Write') {
            if (-not $currentVisual) {
                $visualWarnings.Add("visual-handoff:$episodeToken:not-scaffolded-yet")
            } else {
                if ($currentVisual.status -notin @('DRAFT', 'READY')) { $visualWarnings.Add("visual-handoff:$episodeToken:unknown-status") }
                if ($currentVisual.script_sha256 -ne $actualCurrentHash) { $visualWarnings.Add("visual-handoff:$episodeToken:stale-before-sync") }
            }
        } elseif (-not $currentVisual) {
            $visualErrors.Add("visual-handoff:$episodeToken:missing")
        } else {
            if ($Stage -eq 'Review' -and $currentVisual.status -notin @('DRAFT', 'READY')) { $visualErrors.Add("visual-handoff:$episodeToken:not-draft-or-ready") }
            if ($Stage -eq 'Final' -and $currentVisual.status -ne 'READY') { $visualErrors.Add("visual-handoff:$episodeToken:not-ready") }
            if ($currentVisual.script_sha256 -ne $actualCurrentHash) { $visualErrors.Add("visual-handoff:$episodeToken:script-hash") }
        }
    }
    if ($previousFile -and ($Episode - 1) -ge $visualFromEpisode) {
        $previousToken = 'EP-' + ($Episode - 1).ToString('D2')
        $intraBatchPrevious = [bool]($Stage -eq 'Write' -and $batchContract -and $batchEpisode -and [string]$batchEpisode.incoming_seam_sha256 -and @($batchContract.episode_contracts | Where-Object { [string]$_.episode -eq $previousToken }).Count -eq 1)
        if (-not $previousVisual) {
            $visualErrors.Add("visual-handoff:$previousToken:missing")
        } else {
            if ($intraBatchPrevious) {
                if ($previousVisual.status -notin @('DRAFT', 'READY')) { $visualErrors.Add("visual-handoff:$previousToken:not-draft-or-ready") }
            } elseif ($previousVisual.status -ne 'READY') {
                $visualErrors.Add("visual-handoff:$previousToken:not-ready")
            }
            if ($previousVisual.script_sha256 -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $previousFile.FullName).Hash.ToLowerInvariant()) { $visualErrors.Add("visual-handoff:$previousToken:script-hash") }
        }
    }
} else {
    $visualFromEpisode = 0
}
foreach ($visualError in $visualErrors) { $missing.Add($visualError) }

$visualEntityIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($currentVisual) {
    foreach ($row in @($currentVisual.people) + @($currentVisual.scenes) + @($currentVisual.props)) {
        if ($row.'实体ID') { [void]$visualEntityIds.Add([string]$row.'实体ID') }
    }
}
$previousTailScenes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($tailScene in [regex]::Matches($previous.tail, '(?m)^场次\s+(?<scene>\d+-\d+)[：:]')) {
    [void]$previousTailScenes.Add($tailScene.Groups['scene'].Value)
}
$continuationText = (($plotPoints | ForEach-Object { $_.text }) -join "`n") + "`n" + $currentScriptText + "`n" + $progressSections.previous_snapshot + "`n" + $progressSections.action_lines + "`n" + $progressSections.deadlines + "`n" + $progressSections.source_time
if ($previousVisual) {
    foreach ($row in @($previousVisual.people) + @($previousVisual.scenes) + @($previousVisual.props)) {
        $id = [string]$row.'实体ID'
        if (-not $id) { continue }
        $scene = [string]$row.'场次'
        $labels = @([string]$row.'源标签', [string]$row.'场次头原名', [string]$row.'剧本标签') | Where-Object { $_ }
        $isRelevant = ($scene -and $previousTailScenes.Contains($scene))
        if (-not $isRelevant) {
            foreach ($label in $labels) {
                $normalizedLabel = ($label -replace '^（|）$', '') -replace '（画外）$', ''
                if ($normalizedLabel -and $continuationText -match [regex]::Escape($normalizedLabel)) { $isRelevant = $true; break }
            }
        }
        if ($isRelevant) { [void]$visualEntityIds.Add($id) }
    }
}
$visualSourceFacts = [ordered]@{ people_and_conditional = @(); scenes = @(); props = @() }
if ($sourceFactsText) {
    $visualSourceFacts.people_and_conditional = @(ConvertFrom-MarkdownTable $sourceFactsText '人物与条件类型' | Where-Object { $visualEntityIds.Contains([string]$_.'实体ID') })
    $visualSourceFacts.scenes = @(ConvertFrom-MarkdownTable $sourceFactsText '场景' | Where-Object { $visualEntityIds.Contains([string]$_.'实体ID') })
    $visualSourceFacts.props = @(ConvertFrom-MarkdownTable $sourceFactsText '道具' | Where-Object { $visualEntityIds.Contains([string]$_.'实体ID') })
}
$visualBriefFacts = @(Get-CompactVisualFacts $visualSourceFacts $currentVisual $previousVisual)
$visualIntegrity = if (-not $sourceFactsText) {
    'NOT_INITIALIZED'
} elseif ($visualErrors.Count -gt 0) {
    'INVALID'
} elseif ($Stage -eq 'Write') {
    'WRITE_STAGE_OK'
} elseif ($Stage -eq 'Review' -and $currentVisual -and $currentVisual.status -eq 'DRAFT') {
    'DRAFT_OK'
} else {
    'READY'
}
$riskText = (($plotPoints | ForEach-Object { $_.text }) -join "`n") + "`n" + $currentScriptText
$nameStateText = ($characterRows -join "`n")
$riskFlags = [Collections.Generic.List[string]]::new()
if ($progressText -match '原著保真优先') { $riskFlags.Add('fidelity') }
if ($riskText -match '情绪强度：\s*(9|10)\s*/10|\*\*冲突强度\*\*：\s*S') { $riskFlags.Add('strength-9-plus') }
if ($riskText -match '战斗|斗法|群战|追逐|出招|法术|阵法|剑气|刀光|长剑|剑锋|攻击|击中|倒飞|反杀') { $riskFlags.Add('combat-or-vfx') }
if ($riskText -match '身份|真相|揭晓|凶手|秘密曝光|认出') { $riskFlags.Add('reveal-or-knowledge') }
if ($riskText -match '伏笔(?:埋|收)：(?!无)|待回收|计划EP-') { $riskFlags.Add('foreshadow') }
if ($riskText -match '道具：(?!无)|信物|易主|移交|损毁|遗失') { $riskFlags.Add('prop-state') }
if ($riskText -match '期限：(?!无)|到期|次日|翌日|当日|[一二三四五六七八九十百半\d]+(?:日|天|个月|月|年)(?:后|内|前)|秘境开启前') { $riskFlags.Add('source-time-or-deadline') }
if ($riskText -match '闪回|回忆|回到当下') { $riskFlags.Add('flashback') }
if ($nameStateText -match '→|（仅台词）|（禁）') { $riskFlags.Add('name-state') }
if ($characterNames.Count -gt 5) { $riskFlags.Add('many-named-characters') }

$unresolvedDependencies = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$qualityDir = Join-Path $root '.comic-adapt\quality'
$unresolvedPath = Join-Path $root '.comic-adapt\unresolved.json'
$currentReceiptPath = Join-Path $qualityDir ($episodeToken + '.json')
$previousToken = if ($Episode -gt 1) { 'EP-' + ($Episode - 1).ToString('D2') } else { '' }
$previousReceiptPath = if ($previousToken) { Join-Path $qualityDir ($previousToken + '.json') } else { '' }
foreach ($receiptCandidate in @($currentReceiptPath, $previousReceiptPath)) {
    $candidateReceipt = if ($receiptCandidate) { Read-JsonSafe $receiptCandidate } else { $null }
    if (-not $candidateReceipt) { continue }
    foreach ($dependency in @($candidateReceipt.depends_on)) {
        if ($dependency) { [void]$unresolvedDependencies.Add([string]$dependency) }
    }
    if ($candidateReceipt.status -eq 'UNRESOLVED' -and $candidateReceipt.target) { [void]$unresolvedDependencies.Add([string]$candidateReceipt.target) }
}
$unresolvedItems = Read-JsonSafe $unresolvedPath
foreach ($item in @($unresolvedItems)) {
    if (-not $item -or -not $item.target) { continue }
    $serialized = $item | ConvertTo-Json -Depth 8 -Compress
    $plotIdHit = $false
    foreach ($plotPoint in $plotPoints) {
        if ($serialized -match ('(?i)(?:剧情|plot[-_ ]?point[^0-9]*)0*' + [regex]::Escape([string]$plotPoint.id) + '(?!\d)')) { $plotIdHit = $true; break }
    }
    if ($item.target -eq $episodeToken -or ($previousToken -and $item.target -eq $previousToken) -or $serialized -match [regex]::Escape($episodeToken) -or $plotIdHit) {
        [void]$unresolvedDependencies.Add([string]$item.target)
        foreach ($dependency in @($item.depends_on)) {
            if ($dependency) { [void]$unresolvedDependencies.Add([string]$dependency) }
        }
    }
}

$originalAnchors = @(Get-PlotFieldValues $plotPoints.ToArray() '原著锚点')
$originalContent = @(Get-PlotFieldValues $plotPoints.ToArray() '原著内容')
$subjects = @(Get-PlotFieldValues $plotPoints.ToArray() '行动主体/承受主体')
$knowledgeFlow = @(Get-PlotFieldValues $plotPoints.ToArray() '信息流')
$mustKeep = @(Get-PlotFieldValues $plotPoints.ToArray() '必保清单')
$adaptation = @(Get-PlotFieldValues $plotPoints.ToArray() '改编处理')
$fidelityAnchors = @(Get-PlotFieldValues $plotPoints.ToArray() '保真锚点')
$shootability = @(Get-PlotFieldValues $plotPoints.ToArray() '可拍性')
$compactPlotPoints = @(Get-CompactPlotPoints $plotPoints.ToArray())
$mustKeepCoverage = @(Get-MustKeepCoverage $plotPoints.ToArray() $episodeToken)
$contractIssues = [Collections.Generic.List[string]]::new()
if ($plotPoints.Count -eq 0) { $contractIssues.Add('causal:no-plot-points') }
if ($sourceFiles.Count -eq 0) { $contractIssues.Add('causal:no-source-files') }
if ($originalContent.Count -eq 0) { $contractIssues.Add('causal:no-original-content') }
if ($subjects.Count -eq 0) { $contractIssues.Add('causal:no-subject-boundary') }
if ($knowledgeFlow.Count -eq 0) { $contractIssues.Add('causal:no-knowledge-flow') }
if ($mustKeep.Count -eq 0) { $contractIssues.Add('must-keep:empty') }
if (@($riskFlags) -contains 'fidelity' -and $fidelityAnchors.Count -eq 0) { $contractIssues.Add('fidelity:no-anchor') }
$prewriteContracts = [ordered]@{
    gate_status = if ($contractIssues.Count -eq 0) { 'READY' } else { 'BLOCKED' }
    issues = $contractIssues.ToArray()
    causal = [ordered]@{
        original_content = $originalContent
        subjects = $subjects
        knowledge_flow = $knowledgeFlow
        fidelity_anchors = $fidelityAnchors
    }
    spacetime = [ordered]@{
        previous_tail = $previous.tail
        previous_snapshot = $progressSections.previous_snapshot
        scene_registry = $progressSections.scene_names
        visual_scenes = @($visualBriefFacts | Where-Object { $_.type -eq '场景' })
    }
    timeline = [ordered]@{
        mode = if ($sourceRelativeTime) { 'source_relative' } else { 'legacy_calendar' }
        source_time_contract = $progressSections.source_time
        deadlines = $progressSections.deadlines
        flashback_risk = (@($riskFlags) -contains 'flashback')
        invariants = @('source_event_order_preserved', 'source_relative_duration_unchanged', 'flashback_precedes_current_event')
    }
    must_keep = [ordered]@{
        source_anchors = $originalAnchors
        items = $mustKeep
        adaptation_limits = $adaptation
        shootability = $shootability
        coverage = $mustKeepCoverage
    }
}
$authorityFiles = @($plotPath, $progressPath, $cardsPath, $ledgerPath) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
if ($currentFile) { $authorityFiles += $currentFile.FullName }
if ($previousFile) { $authorityFiles += $previousFile.FullName }
foreach ($visualAuthority in @($sourceFactsPath, $visualManifestPath, $currentVisualPath, $previousVisualPath)) {
    if ($visualAuthority -and (Test-Path -LiteralPath $visualAuthority -PathType Leaf)) { $authorityFiles += $visualAuthority }
}
foreach ($stateAuthority in @($unresolvedPath, $currentReceiptPath, $previousReceiptPath)) {
    if ($stateAuthority -and (Test-Path -LiteralPath $stateAuthority -PathType Leaf)) { $authorityFiles += $stateAuthority }
}
if (Test-Path -LiteralPath $policyPath -PathType Leaf) { $authorityFiles += $policyPath }
if ($sourceIndexValid -and (Test-Path -LiteralPath $sourceIndexPath -PathType Leaf)) { $authorityFiles += $sourceIndexPath }
$authorityFiles += $sourceFiles | ForEach-Object { Join-Path $root $_.path }
$authorityRecords = @($authorityFiles | Sort-Object -Unique | ForEach-Object { Get-FileRecord $root $_ })

$staticPayload = [ordered]@{
    episode = $episodeToken
    plot_points = $compactPlotPoints
    source_files = $sourceFiles.ToArray()
    character_rows = $characterRows.ToArray()
    prewrite_contracts = [ordered]@{
        gate_status = $prewriteContracts.gate_status
        issues = $prewriteContracts.issues
        causal = $prewriteContracts.causal
        must_keep = $prewriteContracts.must_keep
    }
}
$seamPayload = [ordered]@{
    previous = $previous
    progress_sections = $progressSections
    unresolved_dependencies = @($unresolvedDependencies | Sort-Object)
    visual_source_facts = $visualBriefFacts
    spacetime = $prewriteContracts.spacetime
    timeline = $prewriteContracts.timeline
}
$staticSha256 = Get-TextSha256 (($staticPayload | ConvertTo-Json -Depth 12 -Compress))
$seamSha256 = Get-TextSha256 (($seamPayload | ConvertTo-Json -Depth 12 -Compress))
$contractPayload = [ordered]@{
    static_sha256 = $staticSha256
    seam_sha256 = $seamSha256
    preview_enabled = $previewEnabled
}
$contractSha256 = Get-TextSha256 (($contractPayload | ConvertTo-Json -Depth 12 -Compress))

$packet = [ordered]@{
    schema_version = '2.0'
    episode = $episodeToken
    stage = $Stage.ToUpperInvariant()
    preview_enabled = $previewEnabled
    contract_sha256 = $contractSha256
    generated_at = (Get-Date).ToString('o')
    project_root = $root
    current_script = if ($currentFile) { Get-FileRecord $root $currentFile.FullName } else { $null }
    source_index = [ordered]@{ used = $sourceIndexValid; file = if ($sourceIndexValid) { Get-FileRecord $root $sourceIndexPath } else { $null } }
    context_layers = [ordered]@{
        static_sha256 = $staticSha256
        seam_sha256 = $seamSha256
        full_progress_fallback = if (Test-Path -LiteralPath $progressPath -PathType Leaf) { Get-FileRecord $root $progressPath } else { $null }
        rule = 'Read focused packet first; read full progress fallback only for ambiguity or a risk-flagged dependency.'
    }
    plot_points = $compactPlotPoints
    source_files = $sourceFiles.ToArray()
    character_rows = $characterRows.ToArray()
    previous = $previous
    visual_handoff = [ordered]@{
        integrity = $visualIntegrity
        initialized = [bool]$sourceFactsText
        required_from_episode = if ($visualFromEpisode -gt 0) { 'EP-' + $visualFromEpisode.ToString('D2') } else { $null }
        manifest = Get-FileRecord $root $visualManifestPath
        source_facts = Get-FileRecord $root $sourceFactsPath
        current = if ($currentVisual) { [ordered]@{
            file = $currentVisual.file
            status = $currentVisual.status
            script_path = $currentVisual.script_path
            script_sha256 = $currentVisual.script_sha256
            people_count = @($currentVisual.people).Count
            scene_count = @($currentVisual.scenes).Count
            prop_count = @($currentVisual.props).Count
        } } else { $null }
        previous = if ($previousVisual) { [ordered]@{
            file = $previousVisual.file
            status = $previousVisual.status
            script_path = $previousVisual.script_path
            script_sha256 = $previousVisual.script_sha256
            people_count = @($previousVisual.people).Count
            scene_count = @($previousVisual.scenes).Count
            prop_count = @($previousVisual.props).Count
        } } else { $null }
        relevant_source_facts = $visualBriefFacts
        errors = @($visualErrors | Sort-Object -Unique)
        warnings = @($visualWarnings | Sort-Object -Unique)
    }
    progress_sections = $progressSections
    progress_focus = $progressFocusMeta
    risk_flags = @($riskFlags | Sort-Object -Unique)
    review_dimensions = [ordered]@{
        always = @('1', '2', '7', '8')
        risk_routed = @($riskFlags | Sort-Object -Unique)
        scheduled_full = ($Episode -eq 1 -or ($Episode % 10) -eq 0)
    }
    episode_spec = [ordered]@{
        source_anchor_count = $sourceFiles.Count
        plot_point_ids = @($plotPoints | ForEach-Object { $_.id })
        required_characters = @($characterNames | Sort-Object)
        previous_preview = $previous.preview
        previous_tail = $previous.tail
        source_time_contract = $progressSections.source_time
        continuity_contract = $progressSections.previous_snapshot
        unresolved_dependencies = @($unresolvedDependencies | Sort-Object)
        prewrite_gate = $prewriteContracts.gate_status
    }
    prewrite_contracts = $prewriteContracts
    evidence_capsule = [ordered]@{
        coverage = $mustKeepCoverage
        source_files = $sourceFiles.ToArray()
    }
    authority_files = $authorityRecords
    missing = @($missing | Sort-Object -Unique)
    usage = 'Load episode_spec, prewrite_contracts and evidence_capsule first. Focused progress omits unrelated rows; read context_layers.full_progress_fallback only on ambiguity. Canonical files remain authoritative.'
}

if ($Stage -ne 'Write') {
    $defaultCacheDir = Join-Path $root '.comic-adapt-cache\packets'
    $basePacketPath = Join-Path $defaultCacheDir ($episodeToken + '.json')
    $basePacket = $null
    if (Test-Path -LiteralPath $basePacketPath -PathType Leaf) {
        try { $basePacket = Get-Content -Raw -Encoding UTF8 -LiteralPath $basePacketPath | ConvertFrom-Json }
        catch { $missing.Add('base-packet:unreadable') }
    } else {
        $missing.Add('base-packet:missing')
    }
    $baseContractChanged = [bool]($basePacket -and [string]$basePacket.contract_sha256 -ne $contractSha256)
    if ($baseContractChanged) {
        if ($Stage -eq 'Review') { $missing.Add('base-packet:stale-contract') }
        else { $visualWarnings.Add('base contract changed after commit; final packet uses current authoritative state') }
    }
    $incrementAuthorities = [Collections.Generic.List[object]]::new()
    if ($currentFile) { $incrementAuthorities.Add((Get-FileRecord $root $currentFile.FullName)) }
    if (Test-Path -LiteralPath $currentVisualPath -PathType Leaf) { $incrementAuthorities.Add((Get-FileRecord $root $currentVisualPath)) }
    if (Test-Path -LiteralPath $basePacketPath -PathType Leaf) { $incrementAuthorities.Add((Get-FileRecord $root $basePacketPath)) }
    $packet = [ordered]@{
        schema_version = '2.0'
        episode = $episodeToken
        stage = $Stage.ToUpperInvariant()
        preview_enabled = $previewEnabled
        generated_at = (Get-Date).ToString('o')
        project_root = $root
        contract_sha256 = $contractSha256
        base_contract_changed = $baseContractChanged
        base_packet = if (Test-Path -LiteralPath $basePacketPath -PathType Leaf) { Get-FileRecord $root $basePacketPath } else { $null }
        current_script = if ($currentFile) { Get-FileRecord $root $currentFile.FullName } else { $null }
        source_index = [ordered]@{ used = $sourceIndexValid; file = if ($sourceIndexValid) { Get-FileRecord $root $sourceIndexPath } else { $null } }
        visual_handoff = [ordered]@{
            integrity = $visualIntegrity
            initialized = [bool]$sourceFactsText
            required_from_episode = if ($visualFromEpisode -gt 0) { 'EP-' + $visualFromEpisode.ToString('D2') } else { $null }
            current = if ($currentVisual) { [ordered]@{
                file = $currentVisual.file
                status = $currentVisual.status
                script_path = $currentVisual.script_path
                script_sha256 = $currentVisual.script_sha256
                people_count = @($currentVisual.people).Count
                scene_count = @($currentVisual.scenes).Count
                prop_count = @($currentVisual.props).Count
            } } else { $null }
            previous = if ($previousVisual) { [ordered]@{
                file = $previousVisual.file
                status = $previousVisual.status
                script_path = $previousVisual.script_path
                script_sha256 = $previousVisual.script_sha256
            } } else { $null }
            errors = @($visualErrors | Sort-Object -Unique)
            warnings = @($visualWarnings | Sort-Object -Unique)
        }
        risk_flags = @($riskFlags | Sort-Object -Unique)
        review_dimensions = [ordered]@{
            always = @('1', '2', '7', '8')
            risk_routed = @($riskFlags | Sort-Object -Unique)
            scheduled_full = ($Episode -eq 1 -or ($Episode % 10) -eq 0)
        }
        authority_files = $incrementAuthorities.ToArray()
        missing = @($missing | Sort-Object -Unique)
        usage = 'Review/final increment. Prefer the writer/checker brief; dereference base_packet only for audit or ambiguity.'
    }
}

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $cacheDir = Join-Path $root '.comic-adapt-cache\packets'
    [void](New-Item -ItemType Directory -Force -Path $cacheDir)
    $suffix = if ($Stage -eq 'Write') { '' } else { '.' + $Stage.ToLowerInvariant() }
    $OutFile = Join-Path $cacheDir ($episodeToken + $suffix + '.json')
} elseif (-not [IO.Path]::IsPathRooted($OutFile)) {
    $OutFile = Join-Path $root $OutFile
}

$briefDir = Join-Path $root '.comic-adapt-cache\briefs'
$writerBriefPath = Join-Path $briefDir ($episodeToken + '.writer.md')
if ($Stage -eq 'Write') {
    $brief = [Collections.Generic.List[string]]::new()
    $brief.Add('# ' + $episodeToken + ' Writer Brief')
    $brief.Add('')
    $brief.Add('schema_version: comic-adapt-writer-brief/1.1')
    $brief.Add('contract_sha256: ' + $contractSha256)
    $brief.Add('prewrite_gate: ' + $prewriteContracts.gate_status)
    $brief.Add('missing: ' + $(if ($missing.Count) { ($missing | Sort-Object -Unique) -join '；' } else { '无' }))
    $brief.Add('risk_flags: ' + $(if ($riskFlags.Count) { ($riskFlags | Sort-Object -Unique) -join ',' } else { '无' }))
    $brief.Add('')
    $brief.Add('## 读取纪律')
    $brief.Add('先完整读取下列目标原章，再使用本brief聚焦写作；brief不替代原著。只在歧义或风险依赖时回读完整progress。')
    $brief.Add('')
    $brief.Add('## 目标原章')
    foreach ($source in $sourceFiles) {
        $brief.Add(('- 第{0}章｜{1}｜sha256={2}' -f $source.chapter, $source.path, $source.sha256))
    }
    if ($sourceFiles.Count -eq 0) { $brief.Add('- 无') }
    $brief.Add('')
    $brief.Add('## 剧情点与原著契约')
    foreach ($point in $compactPlotPoints) {
        $brief.Add('')
        $brief.Add(('### 【剧情{0}】{1}' -f ([int]$point.id).ToString('D2'), [string]$point.title))
        foreach ($field in $point.fields.GetEnumerator()) { $brief.Add(('- **{0}**：{1}' -f $field.Key, $field.Value)) }
    }
    if ($compactPlotPoints.Count -eq 0) { $brief.Add('- 无') }
    $brief.Add('')
    $brief.Add('## 必保覆盖骨架')
    $brief.Add('| ID | 类型 | 必保项 | 原著锚 | 正文证据槽 |')
    $brief.Add('|:--|:--|:--|:--|:--|')
    foreach ($coverage in $mustKeepCoverage) { $brief.Add(('| {0} | {1} | {2} | {3} | 待写后定位 |' -f $coverage.coverage_id, $coverage.kind, $coverage.item, $coverage.source_anchor)) }
    if ($mustKeepCoverage.Count -eq 0) { $brief.Add('| 无 | 无 | 无 | 无 | 无 |') }
    $brief.Add('')
    $brief.Add('## 角色行')
    foreach ($row in $characterRows) { $brief.Add([string]$row) }
    if ($characterRows.Count -eq 0) { $brief.Add('- 无') }
    $brief.Add('')
    $brief.Add('## 接缝事实（各事实只出现一次）')
    $brief.Add('### 上集末两场')
    $brief.Add($(if ($previous.tail) { [string]$previous.tail } else { '无（EP-01或无前集）' }))
    $sectionLabels = [ordered]@{
        previous_snapshot = '上集末场快照'; character_state = '角色状态'; props = '道具';
        scene_names = '场景规范名'; source_time = '原著时间锚'; deadlines = '期限';
        action_lines = '行动线'; foreshadow = '伏笔'; canon = '设定口径'
    }
    foreach ($entry in $sectionLabels.GetEnumerator()) {
        $value = [string]$progressSections[$entry.Key]
        if (-not $value) { continue }
        if ($entry.Key -eq 'source_time' -and -not $sourceRelativeTime) {
            $value = '旧绝对日历已冻结，不进入新写作；先运行workflow-policy Init建立原著相对时间契约。'
        }
        $brief.Add('')
        $brief.Add('### ' + $entry.Value)
        $brief.Add($value)
    }
    $brief.Add('')
    $brief.Add('## 视觉事实')
    $brief.Add('| 实体ID | 类型 | 规范名 | 当前建议@ | 状态锚 |')
    $brief.Add('|:--|:--|:--|:--|:--|')
    foreach ($fact in $visualBriefFacts) { $brief.Add(('| {0} | {1} | {2} | {3} | {4} |' -f $fact.id, $fact.type, $fact.canonical, $fact.asset, $fact.anchor)) }
    if ($visualBriefFacts.Count -eq 0) { $brief.Add('| 无 | 无 | 无 | 无 | 无 |') }
    $brief.Add('')
    $brief.Add('## 未决依赖')
    $brief.Add($(if ($unresolvedDependencies.Count) { (@($unresolvedDependencies | Sort-Object) -join '；') } else { '无' }))
    $brief.Add('')
    $brief.Add('## 四契约门')
    $brief.Add('- 因果：事件/主体/知识流见剧情点；不得提前揭晓。')
    $brief.Add('- 时空：只用本brief的末两场、快照、场景名与稳定实体状态。')
    $brief.Add('- 时间：只守原著原话、顺序、明确时长数字与闪回边界，不建立绝对日历。')
    $brief.Add('- 必保：逐条兑现剧情点的原著锚、名台词/名场面及改编限制。')
    $brief.Add('')
    $brief.Add('full_progress_fallback: ' + $(if (Test-Path -LiteralPath $progressPath) { (Get-RelativePathCompat $root $progressPath) } else { '无' }))
    $briefText = ($brief -join "`n").TrimEnd() + "`n"
    Write-TextAtomic $writerBriefPath $briefText
    $packet['context_budget'] = [ordered]@{
        writer_brief_chars = $briefText.Length
        writer_brief_estimated_tokens = [Math]::Ceiling($briefText.Length / 2.0)
        writer_brief_token_limit = $writerBriefTokenLimit
        write_packet_token_limit = $writePacketTokenLimit
        status = $(if ([Math]::Ceiling($briefText.Length / 2.0) -le $writerBriefTokenLimit) { 'PASS' } else { 'WARN' })
    }
}

# Long-run workers share one frozen batch contract. Replace the full
# brief with a per-episode delta and keep the complete packet only as an audit
# fallback. This removes repeated progress, visual and plot prose from every
# worker context without weakening source-reading or seam gates.
if ($Stage -eq 'Write' -and $batchEpisode) {
    $brief = [Collections.Generic.List[string]]::new()
    $brief.Add('# ' + $episodeToken + ' Batch Writer Brief')
    $brief.Add('')
    $brief.Add('schema_version: comic-adapt-writer-brief/1.2')
    $brief.Add('batch_id: ' + [string]$batchContract.batch_id)
    $brief.Add('batch_contract: ' + (Get-RelativePathCompat $root $resolvedBatchContractPath))
    $brief.Add('batch_contract_sha256: ' + (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedBatchContractPath).Hash.ToLowerInvariant())
    $brief.Add('episode_contract_sha256: ' + [string]$batchEpisode.contract_sha256)
    $brief.Add('prewrite_gate: ' + $prewriteContracts.gate_status)
    $brief.Add('missing: ' + $(if ($missing.Count) { ($missing | Sort-Object -Unique) -join '；' } else { '无' }))
    $brief.Add('risk_flags: ' + (@($batchEpisode.risk_flags) -join ','))
    $brief.Add('')
    $brief.Add('## 必读原章')
    foreach ($source in @($batchEpisode.source_files)) { $brief.Add(('- {0}｜sha256={1}' -f $source.path, $source.sha256)) }
    if (@($batchEpisode.source_files).Count -eq 0) { $brief.Add('- 无') }
    $brief.Add('')
    $brief.Add('## 本集冻结契约')
    $brief.Add('- 必保：' + (@($batchEpisode.must_keep) -join '｜'))
    $brief.Add('- 集首状态：' + [string]$batchEpisode.entry_state)
    $brief.Add('- 集尾完成态：' + [string]$batchEpisode.exit_state)
    $brief.Add('- 知识变化：' + [string]$batchEpisode.knowledge_delta)
    $brief.Add('- 原著相对时间：' + [string]$batchEpisode.source_time)
    $brief.Add('- 前接缝hash：' + [string]$batchEpisode.incoming_seam_sha256)
    $brief.Add('- 后接缝hash：' + [string]$batchEpisode.outgoing_seam_sha256)
    $brief.Add('')
    $brief.Add('## 结构化交付')
    $brief.Add('候选正文不得直接写权威目录；随稿提交manifest：entity_refs、asset_transitions、ledger_delta、entry_state、exit_state、knowledge_delta、source_time、script_sha256、core_sha256、batch_contract_sha256。')
    $brief.Add('完整批次共享事实只从batch_contract读取一次；本集原章必须完整读取。不得建立绝对日历，不得生成下集预告。')
    $briefText = ($brief -join "`n").TrimEnd() + "`n"
    Write-TextAtomic $writerBriefPath $briefText
    $packet['batch_contract'] = Get-FileRecord $root $resolvedBatchContractPath
    $packet['episode_contract'] = $batchEpisode
    $packet.source_files = @()
    $packet.source_index = [ordered]@{ used = $sourceIndexValid; file = if ($sourceIndexValid) { Get-FileRecord $root $sourceIndexPath } else { $null } }
    $packet.plot_points = @()
    $packet.character_rows = @()
    $packet.progress_sections = [ordered]@{}
    $packet.prewrite_contracts = [ordered]@{ gate_status = $prewriteContracts.gate_status; issues = @($prewriteContracts.issues); contract_source = 'batch_contract' }
    $packet.evidence_capsule = [ordered]@{ coverage = @(); source_files = @(); contract_source = 'batch_contract' }
    $packet.visual_handoff = [ordered]@{ integrity = $visualIntegrity; current = if ($currentVisual) { $currentVisual.file } else { $null }; errors = @($visualErrors | Sort-Object -Unique) }
    $packet.episode_spec = [ordered]@{ prewrite_gate = $prewriteContracts.gate_status; episode_contract_sha256 = [string]$batchEpisode.contract_sha256 }
    $packet.context_layers = [ordered]@{ batch_shared = Get-FileRecord $root $resolvedBatchContractPath; full_progress_fallback = if (Test-Path -LiteralPath $progressPath -PathType Leaf) { Get-FileRecord $root $progressPath } else { $null } }
    $batchAuthorities = [Collections.Generic.List[object]]::new()
    $batchAuthorities.Add((Get-FileRecord $root $resolvedBatchContractPath))
    if ($currentFile) { $batchAuthorities.Add((Get-FileRecord $root $currentFile.FullName)) }
    if (Test-Path -LiteralPath $policyPath -PathType Leaf) { $batchAuthorities.Add((Get-FileRecord $root $policyPath)) }
    $packet.authority_files = $batchAuthorities.ToArray()
    $packet.usage = 'Read the compact writer brief, frozen episode contract and listed source chapters. Batch contract holds shared facts; full authority files are audit fallback only.'
    $packet.context_budget.writer_brief_chars = $briefText.Length
    $packet.context_budget.writer_brief_estimated_tokens = [Math]::Ceiling($briefText.Length / 2.0)
    $packet.context_budget.status = $(if ([Math]::Ceiling($briefText.Length / 2.0) -le $writerBriefTokenLimit) { 'PASS' } else { 'WARN' })
}

if ($Stage -eq 'Write' -and (-not $policy -or [bool]$policy.compact_context)) {
    # The writer brief is the operational view. Keep only hashes, gates and
    # dereference pointers in JSON so audit fallback does not duplicate the
    # same plot/progress prose a second time.
    $packet.plot_points = @()
    $packet.character_rows = @()
    $packet.previous = [ordered]@{
        script = $previous.script
        script_sha256 = $previous.script_sha256
        visual = $previous.visual
    }
    $packet.progress_sections = [ordered]@{}
    if (-not $batchEpisode) {
        $packet.prewrite_contracts = [ordered]@{
            gate_status = $prewriteContracts.gate_status
            issues = @($prewriteContracts.issues)
            contract_source = 'writer_brief'
        }
        $packet.evidence_capsule = [ordered]@{
            coverage = $mustKeepCoverage
            source_files = @()
            contract_source = 'writer_brief_and_authority_files'
        }
    }
    $packet.usage = $(if ($batchEpisode) {
        'Read compact batch writer brief, frozen episode contract and source chapters; JSON holds validation hashes and audit pointers.'
    } else {
        'Read writer brief and source chapters; JSON holds validation hashes, coverage IDs and audit pointers. Do not expand authority files unless ambiguous.'
    })
}

if (Test-Path -LiteralPath $writerBriefPath -PathType Leaf) {
    $packet['writer_brief'] = Get-FileRecord $root $writerBriefPath
}

$outDir = Split-Path -Parent $OutFile
if ($outDir) { [void](New-Item -ItemType Directory -Force -Path $outDir) }
$json = if ($Stage -eq 'Write') { $packet | ConvertTo-Json -Depth 12 -Compress } else { $packet | ConvertTo-Json -Depth 12 }
if ($Stage -eq 'Write' -and $packet.context_budget) {
    $packet.context_budget['write_packet_chars'] = $json.Length
    $packet.context_budget['write_packet_estimated_tokens'] = [Math]::Ceiling($json.Length / 2.0)
    if ([Math]::Ceiling($json.Length / 2.0) -gt $writePacketTokenLimit) { $packet.context_budget.status = 'WARN' }
    $json = $packet | ConvertTo-Json -Depth 12 -Compress
}
[IO.File]::WriteAllText($OutFile, $json, [Text.UTF8Encoding]::new($false))

Write-Output ("CONTEXT-PACKET: {0}" -f $OutFile)
if (Test-Path -LiteralPath $writerBriefPath -PathType Leaf) { Write-Output ("WRITER-BRIEF: {0}" -f $writerBriefPath) }
if ($Stage -eq 'Write' -and $packet.context_budget) { Write-Output ("CONTEXT-BUDGET: writer~{0}tok/{1}; packet~{2}tok/{3}; status={4}" -f $packet.context_budget.writer_brief_estimated_tokens, $packet.context_budget.writer_brief_token_limit, $packet.context_budget.write_packet_estimated_tokens, $packet.context_budget.write_packet_token_limit, $packet.context_budget.status) }
Write-Output ("EPISODE: {0} | stage={1} | plot_points={2} | sources={3} | characters={4} | risks={5} | missing={6} | warnings={7}" -f $episodeToken, $Stage.ToUpperInvariant(), $plotPoints.Count, $sourceFiles.Count, $characterRows.Count, $riskFlags.Count, $missing.Count, $visualWarnings.Count)
if ($visualWarnings.Count -gt 0) { Write-Output ('WARNINGS: ' + (($visualWarnings | Sort-Object -Unique) -join '; ')) }
if ($missing.Count -gt 0) {
    Write-Output ('MISSING: ' + (($missing | Sort-Object -Unique) -join '; '))
    exit 2
}
exit 0

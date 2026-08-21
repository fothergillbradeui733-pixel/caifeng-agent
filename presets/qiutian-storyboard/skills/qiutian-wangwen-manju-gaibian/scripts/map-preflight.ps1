[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [string]$Target = '',
    [string]$Path = 'plot-map.md',
    [string]$MapSpec = '',
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComicAdapt.Common.psm1') -Force
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$sourceRelativeTime = $false
$policyPath = Join-Path $root '.comic-adapt\policy.json'
if (Test-Path -LiteralPath $policyPath -PathType Leaf) {
    try { $sourceRelativeTime = ([string]((Get-Content -Raw -Encoding UTF8 -LiteralPath $policyPath | ConvertFrom-Json).time_model) -eq 'source_relative') }
    catch { throw "Unreadable workflow policy: $policyPath" }
}

function Resolve-InRoot([string]$Value) {
    if ([IO.Path]::IsPathRooted($Value)) { return $Value }
    return Join-Path $root $Value
}

function Get-Section([string]$Text, [string]$Heading) {
    $match = [regex]::Match($Text, '(?ms)^##\s+' + [regex]::Escape($Heading) + '\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
    if ($match.Success) { return $match.Groups['body'].Value }
    return ''
}

function ConvertFrom-MarkdownTable([string]$Text, [string]$Heading) {
    $section = Get-Section $Text $Heading
    $lines = @($section -split '\r?\n' | Where-Object { $_ -match '^\s*\|' })
    if ($lines.Count -lt 2) { return @() }
    $headers = @($lines[0].Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
    $rows = New-Object Collections.Generic.List[object]
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        if ($line -match '^\s*\|(?:\s*:?-+:?\s*\|)+\s*$') { continue }
        $cells = @($line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells.Count -ne $headers.Count) { continue }
        $row = [ordered]@{}
        for ($i = 0; $i -lt $headers.Count; $i++) { $row[$headers[$i]] = $cells[$i] }
        $rows.Add([pscustomobject]$row)
    }
    return $rows.ToArray()
}

function Split-Labels([string]$Value) {
    if (-not $Value -or $Value -eq '无') { return @() }
    return @($Value -split '[、，,；;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '无' })
}

$mapPath = Resolve-InRoot $Path
if (-not (Test-Path -LiteralPath $mapPath -PathType Leaf)) { throw "Missing plot map: $mapPath" }
$mapText = Get-Content -Raw -Encoding UTF8 -LiteralPath $mapPath
$errors = New-Object Collections.Generic.List[string]
$warnings = New-Object Collections.Generic.List[string]

$batchNumber = 0
if ($Target -match '(?i)(?:MAP-)?BATCH-0*(\d+)$') { $batchNumber = [int]$Matches[1] }
$scopeText = $mapText
if ($batchNumber -gt 0) {
    $batchMatch = [regex]::Match($mapText, '(?ms)^##\s+批次\s*' + $batchNumber + '(?:\D[^\r\n]*)?\r?\n.*?(?=^##\s+批次\s*\d+|\z)')
    if ($batchMatch.Success) { $scopeText = $batchMatch.Value } else { $errors.Add("missing batch section: $batchNumber") }
}

$pointMatches = @([regex]::Matches($scopeText, '(?ms)^###\s+【剧情(?<id>\d+)】(?<title>[^\r\n]*)\r?\n(?<body>.*?)(?=^###\s+【剧情\d+】|^###\s+批次小结|^##\s+批次|\z)'))
$allPointMatches = @([regex]::Matches($mapText, '(?m)^###\s+【剧情(?<id>\d+)】'))
$seenIds = [Collections.Generic.HashSet[int]]::new()
foreach ($point in $allPointMatches) {
    $id = [int]$point.Groups['id'].Value
    if (-not $seenIds.Add($id)) { $errors.Add("duplicate plot point ID: 剧情$id") }
}
if ($pointMatches.Count -eq 0) { $errors.Add('no plot points in selected scope') }

$requiredFields = @('原著章节', '原著锚点', '原著内容', '行动主体/承受主体', '信息流', '冲突类型', '冲突强度', '情绪钩子', '必保清单', '改编处理', '归属集数', '状态')
$episodes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$pointIds = New-Object Collections.Generic.List[int]
foreach ($point in $pointMatches) {
    $id = [int]$point.Groups['id'].Value
    $pointIds.Add($id)
    $full = $point.Value
    foreach ($field in $requiredFields) {
        if ($full -notmatch ('(?m)^-\s+\*\*' + [regex]::Escape($field) + '\*\*：[\t ]*\S')) { $errors.Add("剧情$id missing field: $field") }
    }
    if ($full -notmatch '(?m)^-\s+\*\*原著锚点\*\*：\s*第\d+章\s*｜\s*\S+') { $errors.Add("剧情$id invalid source anchor") }
    $owner = [regex]::Match($full, '(?m)^-\s+\*\*归属集数\*\*：(?<value>[^\r\n]+)')
    if ($owner.Success) {
        $ownerEpisodes = @([regex]::Matches($owner.Groups['value'].Value, 'EP-0*\d+') | ForEach-Object { $_.Value.ToUpperInvariant() } | Select-Object -Unique)
        if ($ownerEpisodes.Count -ne 1) { $errors.Add("剧情$id complete unit must belong to exactly one episode") }
        foreach ($episode in $ownerEpisodes) { [void]$episodes.Add($episode) }
    }
    $strength = [regex]::Match($full, '(?m)^-\s+\*\*冲突强度\*\*：\s*(?<value>\S+)')
    if ($strength.Success -and $strength.Groups['value'].Value -notmatch '^[SABCD](?:\s|$)') { $errors.Add("剧情$id invalid strength: $($strength.Groups['value'].Value)") }
}

$summary = [regex]::Match($scopeText, '(?ms)^###\s+批次小结[^\r\n]*\r?\n(?<body>.*?)(?=^##\s+批次|\z)')
if (-not $summary.Success) {
    $errors.Add('missing batch summary')
} else {
    $summaryBody = $summary.Groups['body'].Value
    $summaryFields = @('章范围', '剧情点范围', '分集映射', '强度序列', '视觉事实增量', '未决问题')
    if ($sourceRelativeTime) { $summaryFields += '原著相对时间锚' }
    foreach ($field in $summaryFields) {
        if ($summaryBody -notmatch ('(?m)^-\s+(?:\*\*)?' + [regex]::Escape($field) + '(?:\*\*)?[：:]\s*\S')) { $errors.Add("batch summary missing: $field") }
    }
    foreach ($episode in $episodes) {
        if ($summaryBody -notmatch [regex]::Escape($episode)) { $errors.Add("batch summary mapping missing episode: $episode") }
    }
    foreach ($id in $pointIds) {
        if ($summaryBody -notmatch ('(?i)(?:剧情)?0*' + $id + '(?!\d)')) { $warnings.Add("batch summary does not name 剧情$id explicitly") }
    }
}

$sourcePath = Join-Path $root 'visual-assets\source-facts.md'
$sourceRows = @()
$sourceText = ''
if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
    $sourceText = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourcePath
    $sourceRows = @(ConvertFrom-MarkdownTable $sourceText '人物与条件类型') + @(ConvertFrom-MarkdownTable $sourceText '场景') + @(ConvertFrom-MarkdownTable $sourceText '道具')
    $ids = @{}
    $labels = @{}
    foreach ($row in $sourceRows) {
        $id = [string]$row.'实体ID'
        if (-not $id) { $errors.Add('source-facts row missing entity ID'); continue }
        if ($ids.ContainsKey($id)) { $errors.Add("source-facts duplicate entity ID: $id") } else { $ids[$id] = $true }
        $canonical = @([string]$row.'剧本规范名', [string]$row.'场次头规范名', [string]$row.'剧本正式名') | Where-Object { $_ } | Select-Object -First 1
        $aliasValue = @([string]$row.'别名', [string]$row.'精确别名') | Where-Object { $_ } | Select-Object -First 1
        foreach ($label in @($canonical) + @(Split-Labels $aliasValue)) {
            if (-not $label -or $label -eq '无') { continue }
            $key = $label.ToLowerInvariant()
            if ($labels.ContainsKey($key) -and $labels[$key] -ne $id) { $errors.Add("source-facts name/alias points to multiple entities: $label | $($labels[$key]) | $id") }
            else { $labels[$key] = $id }
        }
    }
} elseif ($summary.Success -and $summary.Groups['body'].Value -match '(?m)视觉事实增量[：:]\s*(?!无\s*$)\S') {
    $errors.Add('visual increment declared but source-facts.md is missing')
}

if ($MapSpec) {
    $specPath = Resolve-InRoot $MapSpec
    if (-not (Test-Path -LiteralPath $specPath -PathType Leaf)) { $errors.Add("missing map-spec: $MapSpec") }
    else {
        $specText = Get-Content -Raw -Encoding UTF8 -LiteralPath $specPath
        $anchorCount = @([regex]::Matches($specText, '(?im)^\s*source_anchor\s*[：:]')).Count
        if ($anchorCount -lt $pointMatches.Count) { $errors.Add("map-spec anchors fewer than plot points: $anchorCount/$($pointMatches.Count)") }
        $specFields = @('event_id', 'event', 'actor', 'receiver', 'cause', 'result', 'knowledge_before', 'knowledge_after', 'must_keep', 'episode_exit', 'visual_deltas')
        if ($sourceRelativeTime) { $specFields += @('source_time_anchor', 'source_relative_time', 'pre_state', 'completed_state', 'reveal_boundary') }
        foreach ($field in $specFields) {
            if ($specText -notmatch ('(?im)^\s*' + [regex]::Escape($field) + '\s*[：:]\s*\S')) { $errors.Add("map-spec missing field: $field") }
        }
        $eventIds = @([regex]::Matches($specText, '(?im)^\s*event_id\s*[：:]\s*(?<id>\S+)') | ForEach-Object { $_.Groups['id'].Value })
        if ($eventIds.Count -lt $pointMatches.Count) { $errors.Add("map-spec event IDs fewer than plot points: $($eventIds.Count)/$($pointMatches.Count)") }
        if (@($eventIds | Sort-Object -Unique).Count -ne $eventIds.Count) { $errors.Add('map-spec duplicate event_id') }
        $deltaLines = @([regex]::Matches($specText, '(?im)^\s*visual_deltas\s*[：:]\s*(?<value>[^\r\n]+)') | ForEach-Object { $_.Groups['value'].Value })
        if ($deltaLines.Count -lt $pointMatches.Count) { $errors.Add("map-spec visual_deltas fewer than plot points: $($deltaLines.Count)/$($pointMatches.Count)") }

        $visibleAction = '抬头|低头|挥手|抬手|转身|走|跑|坐|站|跪|抚须|点头|摇头|打|踢|推|拉|抓|握|看向|望向'
        foreach ($row in @($sourceRows | Where-Object { [string]$_.'类型' -eq '不可见声音角色' -or [string]$_.'实体ID' -match '^VOC-' })) {
            $label = [string]$row.'剧本规范名'
            if ($label -and $specText -match ("(?s)(?:{0}).{{0,24}}(?:{1})|(?:{1}).{{0,24}}(?:{0})" -f [regex]::Escape($label), $visibleAction)) {
                $errors.Add("VOC entity has visible action in map-spec: $label")
            }
        }
        $propChange = '变红|变黑|变白|颜色|形态|裂|碎|破损|损毁|显露|显形|易主|交给|递给|夺走|抢走|遗失|持有人'
        foreach ($row in @($sourceRows | Where-Object { [string]$_.'实体ID' -match '^PRP-' })) {
            $label = [string]$row.'剧本正式名'
            if (-not $label) { continue }
            $changed = $specText -match ("(?s)(?:{0}).{{0,32}}(?:{1})|(?:{1}).{{0,32}}(?:{0})" -f [regex]::Escape($label), $propChange)
            if ($changed -and -not (@($deltaLines | Where-Object { $_ -match [regex]::Escape($label) }).Count)) { $errors.Add("prop visual change missing from visual_deltas: $label") }
        }
    }
}

if (-not $OutFile) {
    $safe = if ($Target) { $Target -replace '[^A-Za-z0-9._-]', '_' } else { 'map' }
    $OutFile = Join-Path $root ('.comic-adapt-cache\map-preflight\' + $safe + '.json')
} else { $OutFile = Resolve-InRoot $OutFile }
$report = [ordered]@{
    schema_version = 'comic-adapt-map-preflight/1.0'
    generated_at = (Get-Date).ToString('o')
    target = $Target
    map_path = $mapPath
    map_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $mapPath).Hash.ToLowerInvariant()
    plot_points = $pointMatches.Count
    episodes = @($episodes | Sort-Object)
    source_entities = $sourceRows.Count
    errors = @($errors | Sort-Object -Unique)
    warnings = @($warnings | Sort-Object -Unique)
}
Write-JsonAtomic $OutFile $report
if ($errors.Count -gt 0) {
    foreach ($issue in ($errors | Sort-Object -Unique)) { Write-Output "MAP-PREFLIGHT-FAIL: $issue" }
    Write-Output "MAP-PREFLIGHT-REPORT: $OutFile"
    exit 1
}
foreach ($warning in ($warnings | Sort-Object -Unique)) { Write-Output "MAP-PREFLIGHT-WARN: $warning" }
Write-Output ("MAP-PREFLIGHT-PASS: target={0}; points={1}; episodes={2}; entities={3}; report={4}" -f $Target, $pointMatches.Count, $episodes.Count, $sourceRows.Count, $OutFile)
exit 0

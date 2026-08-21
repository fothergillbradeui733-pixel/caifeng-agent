[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [string]$PassEp,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Plan', 'Verify')]
    [string]$Mode,

    [string]$ReceiptPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComicAdapt.Common.psm1') -Force
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$sourceRelativeTime = $false
$sourceTimeFromEpisode = 1
$policyPath = Join-Path $root '.comic-adapt\policy.json'
if (Test-Path -LiteralPath $policyPath -PathType Leaf) {
    try {
        $policyData = Get-Content -Raw -Encoding UTF8 -LiteralPath $policyPath | ConvertFrom-Json
        $sourceRelativeTime = ([string]$policyData.time_model -eq 'source_relative')
        if ($policyData.source_time_from_episode) { $sourceTimeFromEpisode = [int]$policyData.source_time_from_episode }
    }
    catch { throw "Unreadable workflow policy: $policyPath" }
}

function Resolve-Episodes([string]$Value) {
    if ($Value -match '^\s*(\d+)\s*$') { return @([int]$Matches[1]) }
    if ($Value -match '^\s*(\d+)\s*[-–—]\s*(\d+)\s*$') {
        $start = [int]$Matches[1]; $end = [int]$Matches[2]
        if ($end -lt $start) { throw "Invalid episode range: $Value" }
        return @($start..$end)
    }
    throw "PassEp must be N or N-M: $Value"
}

function Find-EpisodeFile([string]$ScriptsDir, [int]$Number) {
    $pattern = '^EP-0*' + $Number + '\.md$'
    return Get-ChildItem -LiteralPath $ScriptsDir -File -Filter 'EP-*.md' |
        Where-Object { $_.Name -match $pattern } |
        Sort-Object Name |
        Select-Object -First 1
}

function Get-Key([string]$Field, [string]$Raw, [int]$Episode = 0) {
    $bracket = [regex]::Match($Raw, '〔(?<key>[^〕]+)〕')
    if ($bracket.Success) { return $bracket.Groups['key'].Value.Trim() }
    if ($Field -eq '日历') {
        $parts = $Raw -split '=', 2
        return $parts[0].Trim()
    }
    if ($Field -eq '原著时间') { return 'EP-' + $Episode.ToString('D2') }
    if ($Field -eq '角色状态') { return (($Raw -split '｜', 2)[0]).Trim() }
    if ($Field -eq '期限') {
        $quoted = [regex]::Match($Raw, '[「“\"](?<key>[^」”\"]+)[」”\"]')
        if ($quoted.Success) { return $quoted.Groups['key'].Value.Trim() }
    }
    if ($Field -eq '口径') {
        return (($Raw -split '[=｜]', 2)[0]).Trim()
    }
    if ($Field -eq '行动线') {
        return (($Raw -split '｜', 2)[0]).Trim()
    }
    return (($Raw -split '｜', 2)[0]).Trim()
}

function Get-Destination([string]$Field, [string]$Root) {
    if ($Field -in @('伏笔埋', '伏笔收')) {
        $ledger = Join-Path $Root 'ledger-foreshadow.md'
        if (Test-Path -LiteralPath $ledger -PathType Leaf) { return $ledger }
    }
    return Join-Path $Root 'progress.md'
}

function Test-Key([string]$Text, [string]$Field, [string]$Key, [string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Field -eq '日历') {
        $parts = $Raw -split '=', 2
        return ($parts.Count -eq 2 -and $Text -match ([regex]::Escape($parts[0].Trim()) + '\s*=\s*' + [regex]::Escape($parts[1].Trim())))
    }
    if ($Field -eq '原著时间') {
        return ($Text -match ('(?m)^-\s*' + [regex]::Escape($Key) + '\s*｜') -and (($Text -replace '\s','').Contains(($Raw -replace '\s',''))))
    }
    if ($Field -eq '角色状态') {
        $parts = @($Raw -split '｜')
        return ($parts.Count -ge 2 -and $Text -match ('(?m)^-\s*' + [regex]::Escape($parts[0].Trim()) + '\s*[：:].*' + [regex]::Escape($parts[1].Trim())))
    }
    return $Text.Contains($Key)
}

function Get-BodyHash([string]$Text) {
    $body = [regex]::Replace($Text, '(?ms)^【台账登记块】\s*\r?\n.*\z', '').TrimEnd()
    # 收据证明正文语义未被收割改写；换行风格和行尾空白不属于正文语义。
    $body = $body -replace "`r`n", "`n" -replace "`r", "`n"
    $body = ((@($body -split "`n") | ForEach-Object { $_.TrimEnd() }) -join "`n").TrimEnd()
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-LedgerBody([string]$Text) {
    return ([regex]::Replace($Text, '(?ms)^【台账登记块】\s*\r?\n.*\z', '')).TrimEnd()
}

function Normalize-EvidenceText([string]$Text) {
    return (($Text -replace '\s', '') -replace '[“”"]', '「' -replace '[‘’'']', '『')
}

function Test-QuotedEvidence([string]$Raw, [string]$Body) {
    if ($Raw -notmatch '证据\s*[=＝]\s*(?<evidence>.+)$') { return $true }
    $evidence = $Matches['evidence']
    $quotes = @([regex]::Matches($evidence, '「(?<quote>[^」]+)」') | ForEach-Object { $_.Groups['quote'].Value.Trim() } | Where-Object { $_ })
    if ($quotes.Count -eq 0) { return $true }
    $normalizedBody = Normalize-EvidenceText $Body
    foreach ($quote in $quotes) {
        if (-not $normalizedBody.Contains((Normalize-EvidenceText $quote))) { return $false }
    }
    return $true
}

function Get-SectionText([string]$Text, [string]$HeadingPattern) {
    $match = [regex]::Match($Text, '(?ms)^##\s+' + $HeadingPattern + '[^\r\n]*\r?\n(?<body>.*?)(?=^##\s+|\z)')
    if ($match.Success) { return $match.Groups['body'].Value }
    return ''
}

function Get-CanonParts([string]$Raw) {
    $parts = @($Raw -split '｜')
    if ($parts.Count -ge 3) { return [ordered]@{ entity = $parts[0].Trim(); value = $parts[2].Trim() } }
    $simple = $parts[0].Trim()
    $index = $simple.IndexOfAny(@([char]'=', [char]'＝'))
    if ($index -gt 0 -and $index -lt ($simple.Length - 1)) {
        return [ordered]@{ entity = $simple.Substring(0, $index).Trim(); value = $simple.Substring($index + 1).Trim() }
    }
    return $null
}

function Get-CanonDisposition([string]$ProgressText, [string]$Raw) {
    $parts = Get-CanonParts $Raw
    if (-not $parts) { return [ordered]@{ status = 'UNPARSEABLE'; entity = ''; old_value = ''; new_value = '' } }
    $section = Get-SectionText $ProgressText '设定(?:/|·)?数字口径表'
    foreach ($line in @($section -split '\r?\n')) {
        if ($line -notmatch '^\s*\|') { continue }
        $cells = @($line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells.Count -lt 3 -or (($cells[0] -replace '[\*\s]', '') -ne ($parts.entity -replace '\s', ''))) { continue }
        $oldNorm = $cells[2] -replace '[=＝\s]', ''
        $newNorm = $parts.value -replace '[=＝\s]', ''
        if ($oldNorm.Contains($newNorm)) { return [ordered]@{ status = 'ALREADY_CONTAINS'; entity = $parts.entity; old_value = $cells[2]; new_value = $parts.value } }
        if ($newNorm.Contains($oldNorm)) { return [ordered]@{ status = 'SAFE_EXTENSION'; entity = $parts.entity; old_value = $cells[2]; new_value = $parts.value } }
        return [ordered]@{ status = 'CONFLICT'; entity = $parts.entity; old_value = $cells[2]; new_value = $parts.value }
    }
    return [ordered]@{ status = 'NEW'; entity = $parts.entity; old_value = ''; new_value = $parts.value }
}

function Get-PropInsertSuggestion([string]$ProgressText, [string]$Body, [string]$Raw, [int]$Episode) {
    $key = Get-Key '道具' $Raw $Episode
    $section = Get-SectionText $ProgressText '道具(?:/|·)?信物台账'
    if ($key -and $section -match [regex]::Escape($key)) { return $null }
    $evidence = @($Body -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -match [regex]::Escape($key) -and $_ -notmatch '^场次\s|^出场人物' } | Select-Object -First 1)
    $quote = if ($evidence.Count -gt 0) { ($evidence[0] -replace '^[△※]\s*', '').Trim() } else { '按正文补一条含该道具的原句' }
    $parts = @($Raw -split '｜')
    $change = if ($parts.Count -ge 4) { (@($parts[3..($parts.Count - 1)]) -join '｜').Trim() } else { $Raw }
    $token = 'EP-' + $Episode.ToString('D2')
    return [ordered]@{
        episode = $Episode
        field = '道具'
        key = $key
        destination = 'progress.md#道具/信物台账'
        action = 'INSERT_TABLE_TAIL_BEFORE_NEXT_H2'
        suggested_row = "| $key | $token | 「$quote」 | 无 | 〔按原著确认当前状态/持有人〕 | $token：$change |"
    }
}

$episodes = Resolve-Episodes $PassEp
$rangeLabel = if ($episodes.Count -eq 1) { $episodes[0].ToString('D2') } else { $episodes[0].ToString('D2') + '-' + $episodes[-1].ToString('D2') }
if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $receiptDir = Join-Path $root '.comic-adapt-cache\receipts'
    $ReceiptPath = Join-Path $receiptDir ("ledger-EP-{0}.json" -f $rangeLabel)
} elseif (-not [IO.Path]::IsPathRooted($ReceiptPath)) {
    $ReceiptPath = Join-Path $root $ReceiptPath
}

if ($Mode -eq 'Plan') {
    $scriptsDir = Join-Path $root 'scripts'
    if (-not (Test-Path -LiteralPath $scriptsDir -PathType Container)) { throw "Missing scripts directory: $scriptsDir" }
    $items = [Collections.Generic.List[object]]::new()
    $snapshots = [Collections.Generic.List[object]]::new()
    $sourceFiles = [Collections.Generic.List[object]]::new()
    $parseErrors = [Collections.Generic.List[string]]::new()
    $suggestions = [Collections.Generic.List[object]]::new()
    $progressPlanPath = Join-Path $root 'progress.md'
    $progressPlanText = if (Test-Path -LiteralPath $progressPlanPath -PathType Leaf) { Get-Content -Raw -Encoding UTF8 -LiteralPath $progressPlanPath } else { '' }

    foreach ($episode in $episodes) {
        $file = Find-EpisodeFile $scriptsDir $episode
        if (-not $file) { throw "Missing script for EP-$($episode.ToString('D2'))" }
        $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
        $ledgerBody = Get-LedgerBody $text
        $block = [regex]::Match($text, '(?ms)^【台账登记块】\s*\r?\n(?<body>.*?)^【台账登记块·完】\s*$')
        if (-not $block.Success) { throw "Missing complete ledger block: $($file.FullName)" }
        $sourceFiles.Add([ordered]@{
            episode = $episode
            path = Get-RelativePathCompat $root $file.FullName
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
            body_sha256 = Get-BodyHash $text
        })

        $snapshotMatch = [regex]::Match($block.Groups['body'].Value, '(?ms)^【快照】\s*\r?\n(?<snapshot>.*?)^【快照·完】\s*$')
        if ($snapshotMatch.Success) {
            $sourceMatch = [regex]::Match($snapshotMatch.Groups['snapshot'].Value, '(?m)^快照来源：(?<source>EP-\d+)\s*$')
            $snapshots.Add([ordered]@{
                episode = $episode
                source = if ($sourceMatch.Success) { $sourceMatch.Groups['source'].Value } else { 'EP-' + $episode.ToString('D2') }
            })
        }

        $sawSourceTime = $false
        $useRelativeEpisode = ($sourceRelativeTime -and $episode -ge $sourceTimeFromEpisode)
        foreach ($line in ($block.Groups['body'].Value -split '\r?\n')) {
            $fieldMatch = [regex]::Match($line, '^(?<field>原著时间|日历|角色状态|伏笔埋|伏笔收|道具|期限|场景名|口径|行动线)：(?<raw>.+)$')
            if (-not $fieldMatch.Success) { continue }
            $field = $fieldMatch.Groups['field'].Value
            $raw = $fieldMatch.Groups['raw'].Value.Trim()
            if (-not $raw -or $raw -eq '无') { continue }

            if ($field -eq '原著时间') {
                $sawSourceTime = $true
                $useRelativeEpisode = $true
                foreach ($required in @('上集结束时间锚', '本集原著时间原话', '事件先后', '闪回边界', '本集结束状态')) {
                    if ($raw -notmatch ([regex]::Escape($required) + '\s*[=＝]')) { $parseErrors.Add("EP-$($episode.ToString('D2')) source_time_contract missing: $required") }
                }
            }
            if ($field -eq '期限' -and $useRelativeEpisode -and ($raw -notmatch '「.+?」' -or $raw -notmatch '状态\s*[=＝]\s*(?:待按原著兑现|已按原著兑现|已失效)' -or $raw -notmatch '证据\s*[=＝]\s*\S')) {
                $parseErrors.Add("EP-$($episode.ToString('D2')) invalid relative deadline: $raw")
            }
            if ($field -eq '行动线' -and $raw -match '推进') { $parseErrors.Add("EP-$($episode.ToString('D2')) action verb 推进 must normalize to 提及") }
            if ($field -eq '行动线' -and $raw -notmatch '发起|提及|引爆|了结|撤销') { $parseErrors.Add("EP-$($episode.ToString('D2')) invalid action verb: $raw") }
            if ($field -eq '角色状态' -and $raw -notmatch '^\s*[^｜]+｜[^｜]+｜证据\s*[=＝]\s*\S') { $parseErrors.Add("EP-$($episode.ToString('D2')) invalid role state: $raw") }
            if (-not (Test-QuotedEvidence $raw $ledgerBody)) { $parseErrors.Add("EP-$($episode.ToString('D2')) stale quoted evidence: $raw") }
            if ($field -eq '口径') {
                $canon = Get-CanonDisposition $progressPlanText $raw
                if ($canon.status -eq 'CONFLICT') { $parseErrors.Add("EP-$($episode.ToString('D2')) canon conflict: $($canon.entity) | ledger=$($canon.old_value) | draft=$($canon.new_value)") }
                elseif ($canon.status -eq 'SAFE_EXTENSION') {
                    $suggestions.Add([ordered]@{ episode = $episode; field = '口径'; key = $canon.entity; destination = 'progress.md#设定/数字口径表'; action = 'SAFE_CONTAINING_EXTENSION'; old_value = $canon.old_value; new_value = $canon.new_value })
                }
            }
            if ($field -eq '道具') {
                $propSuggestion = Get-PropInsertSuggestion $progressPlanText $ledgerBody $raw $episode
                if ($propSuggestion) { $suggestions.Add($propSuggestion) }
            }

            $rawValues = if ($field -eq '场景名') { @($raw -split '[；;]' | ForEach-Object { ($_ -replace '（(?:新增|沿用)）', '').Trim() } | Where-Object { $_ }) } else { @($raw) }
            foreach ($value in $rawValues) {
                $key = Get-Key $field $value $episode
                if (-not $key) { continue }
                $destination = Get-Destination $field $root
                $items.Add([ordered]@{
                    episode = $episode
                    field = $field
                    raw = $value
                    key = $key
                    destination = Get-RelativePathCompat $root $destination
                })
            }
        }
        if ($useRelativeEpisode -and -not $sawSourceTime) { $parseErrors.Add("EP-$($episode.ToString('D2')) missing 原著时间 field") }
    }

    if ($parseErrors.Count -gt 0) {
        foreach ($issue in @($parseErrors | Sort-Object -Unique)) { Write-Output "LEDGER-BLOCK-PARSE-FAIL: $issue" }
        exit 1
    }
    Write-Output ("LEDGER-BLOCK-PARSE-PASS: episodes={0}; mode={1}" -f $episodes.Count, $(if ($sourceRelativeTime) { 'source_relative' } else { 'legacy_calendar' }))

    # Episodes are traversed in ascending order, so the last captured snapshot is authoritative.
    # Avoid Sort-Object on ordered dictionaries: Windows PowerShell 5.1 can misorder their keys.
    $latestSnapshots = [Collections.Generic.List[object]]::new()
    if ($snapshots.Count -gt 0) { $latestSnapshots.Add($snapshots[$snapshots.Count - 1]) }
    $receipt = [ordered]@{
        schema_version = '1.2'
        range = $PassEp
        created_at = (Get-Date).ToString('o')
        source_files = @($sourceFiles)
        source_field_count = $items.Count + $latestSnapshots.Count
        items = @($items)
        snapshots = $latestSnapshots
        suggestions = $suggestions.ToArray()
    }
    $receiptDir = Split-Path -Parent $ReceiptPath
    if ($receiptDir) { [void](New-Item -ItemType Directory -Force -Path $receiptDir) }
    $tempReceipt = $ReceiptPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($tempReceipt, ($receipt | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempReceipt -Destination $ReceiptPath -Force
    Write-Output ("LEDGER-PLAN: {0}" -f $ReceiptPath)
    Write-Output ("FIELDS: {0} | items={1} | current_snapshot={2}" -f $receipt.source_field_count, $items.Count, $latestSnapshots.Count)
    foreach ($suggestion in $suggestions) {
        if ($suggestion.action -eq 'INSERT_TABLE_TAIL_BEFORE_NEXT_H2') { Write-Output ("LEDGER-SUGGEST: EP-{0} | {1} | {2} | {3}" -f ([int]$suggestion.episode).ToString('D2'), $suggestion.action, $suggestion.destination, $suggestion.suggested_row) }
        else { Write-Output ("LEDGER-SUGGEST: EP-{0} | {1} | {2} | {3} -> {4}" -f ([int]$suggestion.episode).ToString('D2'), $suggestion.action, $suggestion.key, $suggestion.old_value, $suggestion.new_value) }
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw "Missing receipt plan: $ReceiptPath" }
$receipt = Get-Content -Raw -Encoding UTF8 -LiteralPath $ReceiptPath | ConvertFrom-Json
$results = [Collections.Generic.List[object]]::new()
$destinationCache = @{}

foreach ($source in $receipt.source_files) {
    $sourcePath = Join-Path $root $source.path
    $resolved = $false
    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
        $resolved = ((Get-BodyHash (Get-Content -Raw -Encoding UTF8 -LiteralPath $sourcePath)) -eq $source.body_sha256)
    }
    $results.Add([ordered]@{
        episode = $source.episode
        field = '正文完整性'
        key = $source.body_sha256
        destination = $source.path
        resolved = $resolved
    })
}

foreach ($item in $receipt.items) {
    $destination = Join-Path $root $item.destination
    if (-not $destinationCache.ContainsKey($destination)) {
        $destinationCache[$destination] = if (Test-Path -LiteralPath $destination -PathType Leaf) { Get-Content -Raw -Encoding UTF8 -LiteralPath $destination } else { '' }
    }
    $resolved = Test-Key $destinationCache[$destination] $item.field $item.key $item.raw
    $results.Add([ordered]@{
        episode = $item.episode
        field = $item.field
        key = $item.key
        destination = $item.destination
        resolved = $resolved
    })
}

$progressPath = Join-Path $root 'progress.md'
$progressText = if (Test-Path -LiteralPath $progressPath -PathType Leaf) { Get-Content -Raw -Encoding UTF8 -LiteralPath $progressPath } else { '' }
foreach ($snapshot in $receipt.snapshots) {
    $resolved = $progressText.Contains('快照来源：' + $snapshot.source)
    $results.Add([ordered]@{
        episode = $snapshot.episode
        field = '快照'
        key = $snapshot.source
        destination = 'progress.md'
        resolved = $resolved
    })
}

$unresolved = @($results | Where-Object { -not $_.resolved })
foreach ($item in $unresolved) {
    Write-Output ("UNRESOLVED: EP-{0} | {1} | {2} | {3}" -f ([int]$item.episode).ToString('D2'), $item.field, $item.key, $item.destination)
}
Write-Output ("LEDGER-VERIFY: total={0} | resolved={1} | unresolved={2}" -f $results.Count, ($results.Count - $unresolved.Count), $unresolved.Count)
if ($unresolved.Count -gt 0) { exit 1 }
Write-Output 'LEDGER-RECEIPT-PASS'
exit 0

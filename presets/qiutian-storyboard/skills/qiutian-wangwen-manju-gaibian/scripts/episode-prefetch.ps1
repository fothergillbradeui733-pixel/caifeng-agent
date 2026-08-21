[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 9999)]
    [int]$Episode,
    [ValidateRange(1, 9)]
    [int]$Window = 1
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComicAdapt.Common.psm1') -Force
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$indexScript = Join-Path $PSScriptRoot 'source-index.ps1'
$indexPath = Join-Path $root '.comic-adapt-cache\source-index.json'
function File-Record([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{ path = $item.FullName; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant(); bytes = $item.Length }
}

function Get-PointField([string]$Text, [string]$Field) {
    $match = [regex]::Match($Text, '(?m)^-\s+\*\*' + [regex]::Escape($Field) + '\*\*[：:]\s*(?<value>[^\r\n]+)')
    if ($match.Success) { return $match.Groups['value'].Value.Trim() }
    return ''
}

function Invoke-EpisodePrefetch([int]$Number) {
    $token = 'EP-' + $Number.ToString('D2')
    & $indexScript -ProjectRoot $root -Mode ValidateFast -Episode $Number 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { & $indexScript -ProjectRoot $root -Mode Build | Out-Null }
    $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath | ConvertFrom-Json
    $points = @($index.plot_points | Where-Object { @($_.episode_tokens) -contains $token })
    if ($points.Count -eq 0) { Write-Output "EPISODE-PREFETCH-SKIP: no plot points for $token"; return $false }

    $chapterSet = [Collections.Generic.HashSet[int]]::new()
    foreach ($point in $points) { foreach ($chapter in @($point.chapters)) { [void]$chapterSet.Add([int]$chapter) } }
    $sourceFiles = @($index.novel_files | Where-Object { $chapterSet.Contains([int]$_.chapter) })
    $pointText = ($points | ForEach-Object { $_.text }) -join "`n"
    $entities = New-Object Collections.Generic.List[object]
    foreach ($row in @($index.source_facts.people) + @($index.source_facts.scenes) + @($index.source_facts.props)) {
        $labels = @([string]$row.'剧本规范名', [string]$row.'场次头规范名', [string]$row.'剧本正式名', [string]$row.'别名', [string]$row.'精确别名') | Where-Object { $_ -and $_ -ne '无' }
        $hit = $false
        foreach ($group in $labels) {
            foreach ($label in ($group -split '[、，,；;]')) {
                if ($label.Trim() -and $pointText -match [regex]::Escape($label.Trim())) { $hit = $true; break }
            }
            if ($hit) { break }
        }
        if ($hit) {
            $canonical = @([string]$row.'剧本规范名', [string]$row.'场次头规范名', [string]$row.'剧本正式名') | Where-Object { $_ } | Select-Object -First 1
            $entities.Add([ordered]@{ id = [string]$row.'实体ID'; canonical = [string]$canonical; suggested_asset = [string]$row.'建议@资产名'; aliases = (@([string]$row.'别名', [string]$row.'精确别名') | Where-Object { $_ -and $_ -ne '无' }) -join '、' })
        }
    }

    $coverage = New-Object Collections.Generic.List[object]
    foreach ($point in $points) {
        $mustKeep = Get-PointField ([string]$point.text) '必保清单'
        $anchor = Get-PointField ([string]$point.text) '原著锚点'
        $indexInPoint = 0
        foreach ($item in @($mustKeep -split '[｜；;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $indexInPoint++
            $coverage.Add([ordered]@{ id = ('{0}-P{1}-K{2}' -f $token, ([int]$point.id).ToString('D2'), $indexInPoint.ToString('D2')); item = $item; source_anchor = $anchor; status = 'PENDING' })
        }
    }

    $progressPath = Join-Path $root 'progress.md'
    $progressLines = if (Test-Path -LiteralPath $progressPath -PathType Leaf) { @(Get-Content -LiteralPath $progressPath -Encoding UTF8) } else { @() }
    $ledgerCandidates = New-Object Collections.Generic.List[object]
    foreach ($entity in $entities) {
        # Build a concrete string array. Windows PowerShell 5.1 can retain a
        # pipeline enumerator here and make ConvertTo-Json walk an unbounded
        # graph when the result is nested in an ordered dictionary.
        $matchedLedgerLines = [Collections.Generic.List[string]]::new()
        foreach ($progressLine in $progressLines) {
            if ([string]$entity.canonical -and ([string]$progressLine).Contains([string]$entity.canonical)) {
                $matchedLedgerLines.Add([string]$progressLine)
                if ($matchedLedgerLines.Count -ge 2) { break }
            }
        }
        $ledgerCandidates.Add([ordered]@{ id = [string]$entity.id; canonical = [string]$entity.canonical; existing = ($matchedLedgerLines.Count -gt 0); matched_lines = [string[]]$matchedLedgerLines.ToArray() })
    }

    $mutable = New-Object Collections.Generic.List[object]
    foreach ($path in @((Join-Path $root 'progress.md'), (Join-Path $root ("scripts\EP-{0}.md" -f ($Number - 1).ToString('D2'))), (Join-Path $root ("visual-assets\episodes\EP-{0}.md" -f ($Number - 1).ToString('D2'))))) {
        $record = File-Record $path
        if ($record) { $mutable.Add($record) }
    }
    $staticPayload = [ordered]@{
        plot_points = $points
        source_files = $sourceFiles
        relevant_entities = $entities.ToArray()
        must_keep_coverage = $coverage.ToArray()
        ledger_candidates = $ledgerCandidates.ToArray()
    }
    $staticText = $staticPayload | ConvertTo-Json -Depth 20 -Compress
    $staticBytes = [Text.Encoding]::UTF8.GetBytes($staticText)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $staticHash = ([BitConverter]::ToString($sha.ComputeHash($staticBytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $packet = [ordered]@{
        schema_version = 'comic-adapt-prefetch/1.2'
        generated_at = (Get-Date).ToString('o')
        episode = $token
        source_index_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $indexPath).Hash.ToLowerInvariant()
        static_context_sha256 = $staticHash
        plot_points = $points
        source_files = $sourceFiles
        relevant_entities = $entities.ToArray()
        must_keep_coverage = $coverage.ToArray()
        ledger_candidates = $ledgerCandidates.ToArray()
        mutable_dependencies = $mutable.ToArray()
        status = 'READ_ONLY_PREFETCH'
        usage = 'Immutable preparation only: source hashes, must-keep coverage skeleton, compact visual candidates and existing-ledger hits. Rebuild only the seam delta after the previous episode commits.'
    }
    $outPath = Join-Path $root ('.comic-adapt-cache\prefetch\' + $token + '.json')
    Write-JsonAtomic $outPath $packet
    Write-Output ("EPISODE-PREFETCH-PASS: {0}; points={1}; sources={2}; entities={3}; mutable={4}; static={5}; path={6}" -f $token, $points.Count, $sourceFiles.Count, $entities.Count, $mutable.Count, $staticHash, $outPath)
    return $true
}

$completed = 0
$startCompleted = $false
foreach ($number in $Episode..([Math]::Min(9999, $Episode + $Window - 1))) {
    $ok = Invoke-EpisodePrefetch $number
    if ($number -eq $Episode) { $startCompleted = $ok }
    if ($ok) { $completed++ }
}
if (-not $startCompleted -or $completed -eq 0) { exit 2 }
Write-Output ("EPISODE-PREFETCH-WINDOW: start=EP-{0}; requested={1}; completed={2}" -f $Episode.ToString('D2'), $Window, $completed)
exit 0

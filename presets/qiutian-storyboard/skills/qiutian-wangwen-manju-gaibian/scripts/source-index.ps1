[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [ValidateSet('Build', 'Validate', 'ValidateFast')]
    [string]$Mode,
    [string]$OutFile = '',
    [ValidateRange(0, 9999)]
    [int]$Episode = 0
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComicAdapt.Common.psm1') -Force
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
if (-not $OutFile) { $OutFile = Join-Path $root '.comic-adapt-cache\source-index.json' }
elseif (-not [IO.Path]::IsPathRooted($OutFile)) { $OutFile = Join-Path $root $OutFile }

function Relative([string]$Path) {
    $base = $root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($base.Length).Replace('\', '/') }
    return $full.Replace('\', '/')
}

function File-Record([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{ path = Relative $item.FullName; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant(); bytes = $item.Length }
}

function Get-Section([string]$Text, [string]$Heading) {
    $match = [regex]::Match($Text, '(?ms)^##\s+' + [regex]::Escape($Heading) + '\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
    if ($match.Success) { return $match.Groups['body'].Value }
    return ''
}

function Read-Table([string]$Text, [string]$Heading) {
    $lines = @((Get-Section $Text $Heading) -split '\r?\n' | Where-Object { $_ -match '^\s*\|' })
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

function Test-Index([object]$Index, [bool]$FullNovelScan, [int]$TargetEpisode) {
    $issues = New-Object Collections.Generic.List[string]
    if (-not $Index -or $Index.schema_version -ne 'comic-adapt-source-index/1.0') { $issues.Add('schema'); return $issues.ToArray() }
    $records = New-Object Collections.Generic.List[object]
    foreach ($record in @($Index.authorities)) { $records.Add($record) }
    if ($FullNovelScan) {
        foreach ($record in @($Index.novel_files)) { $records.Add($record) }
    } elseif ($TargetEpisode -gt 0) {
        $token = 'EP-' + $TargetEpisode.ToString('D2')
        $chapters = [Collections.Generic.HashSet[int]]::new()
        foreach ($point in @($Index.plot_points | Where-Object { @($_.episode_tokens) -contains $token })) {
            foreach ($chapter in @($point.chapters)) { [void]$chapters.Add([int]$chapter) }
        }
        foreach ($record in @($Index.novel_files | Where-Object { $chapters.Contains([int]$_.chapter) })) { $records.Add($record) }
        if ($chapters.Count -gt 0 -and @($records | Where-Object { $_.PSObject.Properties['chapter'] }).Count -lt $chapters.Count) {
            $issues.Add("episode-source-count:$token")
        }
    }
    foreach ($record in $records.ToArray()) {
        $path = Join-Path $root ([string]$record.path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $issues.Add("missing:$($record.path)"); continue }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -ne [string]$record.sha256) { $issues.Add("hash:$($record.path)") }
    }
    return $issues.ToArray()
}

if ($Mode -in @('Validate', 'ValidateFast')) {
    if (-not (Test-Path -LiteralPath $OutFile -PathType Leaf)) { Write-Output "SOURCE-INDEX-STALE: missing=$OutFile"; exit 2 }
    $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $OutFile | ConvertFrom-Json
    $full = ($Mode -eq 'Validate')
    $issues = @(Test-Index $index $full $Episode)
    if ($issues.Count -gt 0) { foreach ($issue in $issues) { Write-Output "SOURCE-INDEX-STALE: $issue" }; exit 2 }
    $validationMode = if ($full) { 'full' } elseif ($Episode -gt 0) { 'target-episode' } else { 'authorities-only' }
    if ($full) {
        $stampPath = Join-Path (Split-Path -Parent $OutFile) 'source-index-validation.json'
        $stamp = [ordered]@{
            schema_version = 'comic-adapt-source-index-validation/1.0'
            index_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutFile).Hash.ToLowerInvariant()
            full_validated_at = (Get-Date).ToString('o')
            novel_count = @($index.novel_files).Count
        }
        Write-JsonAtomic $stampPath $stamp
    }
    Write-Output ("SOURCE-INDEX-PASS: mode={0}; episode={1}; points={2}; novels={3}; path={4}" -f $validationMode, $(if ($Episode -gt 0) { 'EP-' + $Episode.ToString('D2') } else { '-' }), @($index.plot_points).Count, @($index.novel_files).Count, $OutFile)
    exit 0
}

$plotPath = Join-Path $root 'plot-map.md'
$sourcePath = Join-Path $root 'visual-assets\source-facts.md'
$cardsPath = Join-Path $root 'character-cards.md'
if (-not (Test-Path -LiteralPath $plotPath -PathType Leaf)) { throw "Missing plot-map.md: $plotPath" }
$plotText = Get-Content -Raw -Encoding UTF8 -LiteralPath $plotPath
$sourceText = if (Test-Path -LiteralPath $sourcePath -PathType Leaf) { Get-Content -Raw -Encoding UTF8 -LiteralPath $sourcePath } else { '' }
$points = New-Object Collections.Generic.List[object]
$pattern = '(?ms)^###\s+【剧情(?<id>\d+)】(?<title>[^\r\n]*)\r?\n(?<body>.*?)(?=^###\s+【剧情\d+】|^###\s+批次小结|^##\s+批次|\z)'
foreach ($match in [regex]::Matches($plotText, $pattern)) {
    $text = $match.Value.Trim()
    $episodes = @([regex]::Matches($text, '(?m)^-\s+\*\*归属集数\*\*：[^\r\n]*?EP-0*\d+') | ForEach-Object {
        [regex]::Matches($_.Value, 'EP-0*\d+') | ForEach-Object { $_.Value.ToUpperInvariant() }
    } | Select-Object -Unique)
    $chapters = New-Object Collections.Generic.HashSet[int]
    foreach ($chapterMatch in [regex]::Matches($text, '第(?<start>\d+)章(?:\s*[~～—-]+\s*第?(?<end>\d+)章)?')) {
        $start = [int]$chapterMatch.Groups['start'].Value
        $end = if ($chapterMatch.Groups['end'].Success) { [int]$chapterMatch.Groups['end'].Value } else { $start }
        foreach ($chapter in $start..$end) { [void]$chapters.Add($chapter) }
    }
    $points.Add([ordered]@{ id = [int]$match.Groups['id'].Value; title = $match.Groups['title'].Value.Trim(); text = $text; episode_tokens = $episodes; chapters = @($chapters | Sort-Object) })
}
$novels = New-Object Collections.Generic.List[object]
$novelDir = Join-Path $root 'novel'
if (Test-Path -LiteralPath $novelDir -PathType Container) {
    foreach ($file in (Get-ChildItem -LiteralPath $novelDir -Recurse -File | Sort-Object FullName)) {
        $chapter = if ($file.BaseName -match '(?<!\d)0*(\d+)(?!\d)') { [int]$Matches[1] } else { 0 }
        $record = File-Record $file.FullName
        $record.chapter = $chapter
        $novels.Add($record)
    }
}
$authorities = New-Object Collections.Generic.List[object]
foreach ($path in @($plotPath, $sourcePath, $cardsPath, (Join-Path $root '.comic-adapt\policy.json'))) {
    $record = File-Record $path
    if ($record) { $authorities.Add($record) }
}
$index = [ordered]@{
    schema_version = 'comic-adapt-source-index/1.0'
    generated_at = (Get-Date).ToString('o')
    authorities = $authorities.ToArray()
    plot_points = $points.ToArray()
    source_facts = [ordered]@{
        people = if ($sourceText) { @(Read-Table $sourceText '人物与条件类型') } else { @() }
        scenes = if ($sourceText) { @(Read-Table $sourceText '场景') } else { @() }
        props = if ($sourceText) { @(Read-Table $sourceText '道具') } else { @() }
    }
    novel_files = $novels.ToArray()
}
Write-JsonAtomic $OutFile $index
$stampPath = Join-Path (Split-Path -Parent $OutFile) 'source-index-validation.json'
$stamp = [ordered]@{
    schema_version = 'comic-adapt-source-index-validation/1.0'
    index_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutFile).Hash.ToLowerInvariant()
    full_validated_at = (Get-Date).ToString('o')
    novel_count = $novels.Count
}
Write-JsonAtomic $stampPath $stamp
Write-Output ("SOURCE-INDEX-BUILD: points={0}; people={1}; scenes={2}; props={3}; novels={4}; path={5}" -f $points.Count, @($index.source_facts.people).Count, @($index.source_facts.scenes).Count, @($index.source_facts.props).Count, $novels.Count, $OutFile)
exit 0

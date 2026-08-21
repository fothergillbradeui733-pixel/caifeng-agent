[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [string]$Range,
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path

function Resolve-Range([string]$Value) {
    if ($Value -match '^\s*(\d+)\s*$') { return @([int]$Matches[1]) }
    if ($Value -match '^\s*(\d+)\s*[-–—]\s*(\d+)\s*$') {
        $start = [int]$Matches[1]; $end = [int]$Matches[2]
        if ($end -lt $start) { throw "Invalid range: $Value" }
        return @($start..$end)
    }
    throw "Range must be N or N-M: $Value"
}

function Find-Script([int]$Episode) {
    $pattern = '^EP-0*' + $Episode + '\.md$'
    return Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -File -Filter 'EP-*.md' |
        Where-Object { $_.Name -match $pattern } | Select-Object -First 1
}

function Strip-Preview([string]$Text) {
    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    return ([regex]::Replace($normalized, '(?m)^下集预告(?:〔[^〕\r\n]+〕)?[：:][^\r\n]*(?:\n(?!【台账登记块】)[^\r\n]+)?\n?', '')).TrimEnd()
}

$policyPath = Join-Path $root '.comic-adapt\policy.json'
$stripLegacyPreview = $false
if (Test-Path -LiteralPath $policyPath -PathType Leaf) {
    $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $policyPath | ConvertFrom-Json
    $stripLegacyPreview = (-not [bool]$policy.preview_enabled -and [string]$policy.legacy_preview_policy -eq 'preserve_source_strip_export')
}

$episodes = Resolve-Range $Range
$sections = New-Object Collections.Generic.List[string]
$missing = New-Object Collections.Generic.List[string]
foreach ($episode in $episodes) {
    $token = 'EP-' + $episode.ToString('D2')
    $receiptPath = Join-Path $root ('.comic-adapt\quality\' + $token + '.json')
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { $missing.Add("${token}:quality-receipt"); continue }
    $receipt = Get-Content -Raw -Encoding UTF8 -LiteralPath $receiptPath | ConvertFrom-Json
    if ($receipt.status -ne 'PASS') { $missing.Add("${token}:status-$($receipt.status)"); continue }
    $script = Find-Script $episode
    if (-not $script) { $missing.Add("${token}:script"); continue }
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $script.FullName
    if ($stripLegacyPreview) { $text = Strip-Preview $text }
    $sections.Add($text.Trim())
}
if ($missing.Count -gt 0) {
    foreach ($issue in $missing) { Write-Output "EXPORT-BLOCKED: $issue" }
    exit 2
}
if (-not $OutFile) {
    $exportDir = Join-Path $root 'export'
    $OutFile = Join-Path $exportDir ("scripts-EP-{0}-EP-{1}.md" -f $episodes[0].ToString('D2'), $episodes[-1].ToString('D2'))
} elseif (-not [IO.Path]::IsPathRooted($OutFile)) { $OutFile = Join-Path $root $OutFile }
$dir = Split-Path -Parent $OutFile
if ($dir) { [void](New-Item -ItemType Directory -Force -Path $dir) }
$temp = $OutFile + '.tmp-' + [guid]::NewGuid().ToString('N')
[IO.File]::WriteAllText($temp, (($sections -join "`n`n---`n`n") + "`n"), [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temp -Destination $OutFile -Force
Write-Output ("EXPORT-PASS: episodes={0}; preview-stripped={1}; path={2}" -f $episodes.Count, $stripLegacyPreview, $OutFile)
exit 0

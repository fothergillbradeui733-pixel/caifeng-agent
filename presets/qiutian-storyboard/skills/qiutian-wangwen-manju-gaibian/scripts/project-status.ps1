[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [switch]$Fast,
    [switch]$Full,
    [switch]$SummaryOnly,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComicAdapt.Common.psm1') -Force
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$lint = Join-Path $PSScriptRoot 'script-lint.ps1'
$assetStatus = Join-Path $PSScriptRoot 'visual-handoff.ps1'
$qualityStatus = Join-Path $PSScriptRoot 'quality-receipt.ps1'
$cacheDir = Join-Path $root '.comic-adapt-cache'
$cachePath = Join-Path $cacheDir 'status.json'
$diagnosticsPath = Join-Path $cacheDir 'status-diagnostics.txt'

function Get-IssueCounts([string[]]$Outputs) {
    $text = @($Outputs | Where-Object { $_ }) -join "`n"
    return [ordered]@{
        fail = [regex]::Matches($text, '(?m)^(?:FAIL\b|ASSET-HANDOFF-[^\r\n]*FAIL(?:\b|:))').Count
        warn = [regex]::Matches($text, '(?m)^WARN\b').Count
        info = [regex]::Matches($text, '(?m)^(?:INFO\b|ASSET-HANDOFF-PASS|QUALITY-ISSUE)').Count
    }
}

function Get-StateFiles([string]$Root) {
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($name in @('progress.md', 'plot-map.md', 'character-cards.md', 'ledger-foreshadow.md')) {
        $path = Join-Path $Root $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { $paths.Add($path) }
    }
    $scripts = Join-Path $Root 'scripts'
    if (Test-Path -LiteralPath $scripts -PathType Container) {
        foreach ($item in (Get-ChildItem -LiteralPath $scripts -File -Filter 'EP-*.md' | Sort-Object FullName)) { $paths.Add($item.FullName) }
    }
    $visualAssets = Join-Path $Root 'visual-assets'
    if (Test-Path -LiteralPath $visualAssets -PathType Container) {
        foreach ($item in (Get-ChildItem -LiteralPath $visualAssets -Recurse -File | Sort-Object FullName)) { $paths.Add($item.FullName) }
    }
    $qualityDir = Join-Path $Root '.comic-adapt'
    if (Test-Path -LiteralPath $qualityDir -PathType Container) {
        foreach ($item in (Get-ChildItem -LiteralPath $qualityDir -Recurse -File | Sort-Object FullName)) { $paths.Add($item.FullName) }
    }
    return $paths.ToArray()
}

function Get-Hashes([string]$Root) {
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($path in (Get-StateFiles $Root)) {
        $item = Get-Item -LiteralPath $path
        $rows.Add([ordered]@{
            path = Get-RelativePathCompat $Root $item.FullName
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
            bytes = $item.Length
        })
    }
    return $rows.ToArray()
}

function Get-Fingerprint([object[]]$Rows) {
    return (($Rows | Sort-Object path | ForEach-Object { $_.path + '=' + $_.sha256 }) -join "`n")
}

function Invoke-ScriptLint([string]$Target) {
    $output = & $lint -Path $Target 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    return [ordered]@{ exit_code = $exitCode; output = $output.TrimEnd() }
}

function Invoke-ProgressLint([string]$Target) {
    $output = & $lint -Path $Target -CheckProgress 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    return [ordered]@{ exit_code = $exitCode; output = $output.TrimEnd() }
}

function Invoke-AssetStatus([string]$Target) {
    $output = & $assetStatus -ProjectRoot $Target -Mode Status 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $state = if ($output -match '(?m)^ASSET-HANDOFF-PASS:') {
        'READY'
    } elseif ($output -match '(?m)^ASSET-HANDOFF-NOT-INITIALIZED\s*$') {
        'NOT_INITIALIZED'
    } elseif ($output -match '(?m)^ASSET-HANDOFF-EMPTY:') {
        'EMPTY'
    } else {
        'FAIL'
    }
    return [ordered]@{ exit_code = $exitCode; state = $state; output = $output.TrimEnd() }
}

function Invoke-QualityStatus([string]$Target) {
    $output = & $qualityStatus -ProjectRoot $Target -Mode Report 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $state = if ($output -match 'unresolved=([1-9]\d*)') { 'UNRESOLVED' } elseif ($output -match 'fail=([1-9]\d*)') { 'FAIL' } else { 'PASS' }
    return [ordered]@{ exit_code = $exitCode; state = $state; output = $output.TrimEnd() }
}

if (-not (Test-Path -LiteralPath $lint -PathType Leaf)) { throw "Missing lint script: $lint" }
if (-not (Test-Path -LiteralPath $assetStatus -PathType Leaf)) { throw "Missing visual handoff script: $assetStatus" }
if (-not (Test-Path -LiteralPath $qualityStatus -PathType Leaf)) { throw "Missing quality receipt script: $qualityStatus" }
$hashes = Get-Hashes $root
$fingerprint = Get-Fingerprint $hashes

if ($Fast -and -not $Full -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
    try {
        $cache = Get-Content -Raw -Encoding UTF8 -LiteralPath $cachePath | ConvertFrom-Json
        if ($cache.schema_version -eq '2.1' -and $cache.valid -eq $true -and $cache.fingerprint -eq $fingerprint) {
            if ($Json) {
                Write-Output ($cache | ConvertTo-Json -Depth 10 -Compress)
                exit 0
            }
            Write-Output ("STATUS-MECHANICAL-CACHE-HIT: {0}" -f $cache.checked_at)
            Write-Output ("FILES: {0} | lint_exit={1} | progress_exit={2} | asset_exit={3} | asset_state={4}" -f $hashes.Count, $cache.lint_exit, $cache.progress_exit, $cache.asset_exit, $cache.asset_state)
            if ($SummaryOnly) {
                Write-Output ("STATUS-ISSUES: fail={0}; warn={1}; info={2}; diagnostics={3}" -f $cache.issue_counts.fail, $cache.issue_counts.warn, $cache.issue_counts.info, (Join-Path $root ([string]$cache.diagnostics_path)))
            }
            if ($cache.asset_state -eq 'NOT_INITIALIZED') {
                Write-Output 'ASSET-HANDOFF-NOT-INITIALIZED'
                Write-Output 'STATUS-NOT-READY: legacy project checks pass, but no visual handoff is initialized.'
            } elseif ($cache.asset_state -eq 'EMPTY') {
                Write-Output 'ASSET-HANDOFF-EMPTY: initialized range has no completed scripts yet.'
            } else {
                Write-Output 'ASSET-HANDOFF-READY: cached hashes still match.'
            }
            Write-Output 'SEMANTIC-SIGNOFF: NOT-EVALUATED; cached status does not prove independent checker PASS or episode acceptance.'
            Write-Output ("QUALITY-RECEIPTS: {0}" -f $cache.quality_state)
            exit 0
        }
        if (-not $Json) { Write-Output 'STATUS-CACHE-MISS: authority file hashes changed; running full checks.' }
    } catch {
        if (-not $Json) { Write-Output 'STATUS-CACHE-MISS: cache unreadable; running full checks.' }
    }
}

$scriptsPath = Join-Path $root 'scripts'
$lintResult = if ((Test-Path -LiteralPath $scriptsPath -PathType Container) -and @(Get-ChildItem -LiteralPath $scriptsPath -File -Filter 'EP-*.md').Count -gt 0) {
    Invoke-ScriptLint -Target $scriptsPath
} else {
    [ordered]@{ exit_code = 0; output = 'INFO: no scripts to lint.' }
}
$progressResult = if (Test-Path -LiteralPath (Join-Path $root 'progress.md') -PathType Leaf) {
    Invoke-ProgressLint -Target $root
} else {
    [ordered]@{ exit_code = 1; output = 'FAIL: progress.md missing.' }
}
$assetResult = Invoke-AssetStatus -Target $root
$qualityResult = Invoke-QualityStatus -Target $root

$diagnosticText = @(
    '## SCRIPT LINT', $lintResult.output, '', '## PROGRESS LINT', $progressResult.output,
    '', '## VISUAL HANDOFF', $assetResult.output, '', '## QUALITY RECEIPTS', $qualityResult.output
) -join "`n"
[void](New-Item -ItemType Directory -Force -Path $cacheDir)
Write-TextAtomic $diagnosticsPath ($diagnosticText.TrimEnd() + "`n")
$issueCounts = Get-IssueCounts @($lintResult.output, $progressResult.output, $assetResult.output, $qualityResult.output)
if (-not $SummaryOnly -and -not $Json) {
    Write-Output $lintResult.output
    Write-Output $progressResult.output
    Write-Output $assetResult.output
    Write-Output $qualityResult.output
} elseif ($SummaryOnly -and -not $Json) {
    Write-Output ("STATUS-ISSUES: fail={0}; warn={1}; info={2}; diagnostics={3}" -f $issueCounts.fail, $issueCounts.warn, $issueCounts.info, $diagnosticsPath)
}

$valid = ($lintResult.exit_code -eq 0 -and $progressResult.exit_code -eq 0 -and $assetResult.exit_code -eq 0)
[void](New-Item -ItemType Directory -Force -Path $cacheDir)
$cacheRecord = [ordered]@{
    schema_version = '2.1'
    checked_at = (Get-Date).ToString('o')
    full_check = $true
    valid = $valid
    fingerprint = $fingerprint
    files = $hashes
    lint_exit = $lintResult.exit_code
    progress_exit = $progressResult.exit_code
    asset_exit = $assetResult.exit_code
    asset_state = $assetResult.state
    quality_exit = $qualityResult.exit_code
    quality_state = $qualityResult.state
    issue_counts = $issueCounts
    diagnostics_path = Get-RelativePathCompat $root $diagnosticsPath
}
[IO.File]::WriteAllText($cachePath, ($cacheRecord | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

if ($Json) {
    Write-Output ($cacheRecord | ConvertTo-Json -Depth 10 -Compress)
    if ($valid) { exit 0 } else { exit 1 }
}

if ($valid) {
    if ($assetResult.state -eq 'NOT_INITIALIZED') {
        Write-Output ("STATUS-MECHANICAL-PASS-WITHOUT-ASSET-HANDOFF: legacy lint/progress checks complete; cache={0}" -f $cachePath)
        Write-Output 'STATUS-NOT-READY: initialize and backfill the required range before downstream visual asset generation.'
    } elseif ($assetResult.state -eq 'EMPTY') {
        Write-Output ("STATUS-MECHANICAL-PASS: lint/progress pass; visual handoff is initialized but has no in-scope scripts; cache={0}" -f $cachePath)
    } else {
        Write-Output ("STATUS-MECHANICAL-PASS: lint, progress, and visual handoff checks complete; cache={0}" -f $cachePath)
    }
    if ($qualityResult.state -eq 'PASS') {
        Write-Output 'SEMANTIC-SIGNOFF: quality receipts contain no active FAIL/UNRESOLVED items.'
    } else {
        Write-Output ("STATUS-NOT-READY: quality receipts state={0}; continue work if allowed, but batch completion/export must report and resolve or obtain user decision." -f $qualityResult.state)
    }
    exit 0
}
Write-Output ("STATUS-MECHANICAL-FAIL: lint_exit={0}; progress_exit={1}; asset_exit={2}; asset_state={3}" -f $lintResult.exit_code, $progressResult.exit_code, $assetResult.exit_code, $assetResult.state)
exit 1

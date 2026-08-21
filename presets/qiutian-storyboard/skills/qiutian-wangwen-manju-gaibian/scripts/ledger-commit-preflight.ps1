[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [string]$PassEp,
    [string]$ScriptLintPath = ''
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
if (-not $ScriptLintPath) { $ScriptLintPath = Join-Path $PSScriptRoot 'script-lint.ps1' }
if (-not (Test-Path -LiteralPath $ScriptLintPath -PathType Leaf)) { throw "Missing script-lint: $ScriptLintPath" }

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$previewRoot = Join-Path $tempBase ('comic-adapt-ledger-preflight-' + [guid]::NewGuid().ToString('N'))
$resolvedPreview = [IO.Path]::GetFullPath($previewRoot)
if (-not $resolvedPreview.StartsWith($tempBase + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($resolvedPreview) -notmatch '^comic-adapt-ledger-preflight-[0-9a-f]{32}$') {
    throw 'Unsafe ledger preflight directory.'
}

try {
    [void](New-Item -ItemType Directory -Force -Path $resolvedPreview)
    foreach ($item in @(Get-ChildItem -LiteralPath $root -File -Filter '*.md')) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $resolvedPreview $item.Name)
    }
    $scriptsSource = Join-Path $root 'scripts'
    if (-not (Test-Path -LiteralPath $scriptsSource -PathType Container)) { throw "Missing scripts directory: $scriptsSource" }
    Copy-Item -LiteralPath $scriptsSource -Destination (Join-Path $resolvedPreview 'scripts') -Recurse
    $policySource = Join-Path $root '.comic-adapt\policy.json'
    if (Test-Path -LiteralPath $policySource -PathType Leaf) {
        $policyPreview = Join-Path $resolvedPreview '.comic-adapt'
        [void](New-Item -ItemType Directory -Force -Path $policyPreview)
        Copy-Item -LiteralPath $policySource -Destination (Join-Path $policyPreview 'policy.json')
    }
    $output = & $ScriptLintPath -Path $resolvedPreview -FixProgress -PassEp $PassEp 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($output)) { Write-Output $line }
    if ($code -ne 0) {
        Write-Output ("LEDGER-COMMIT-PREFLIGHT-FAIL: range={0}; project authority unchanged" -f $PassEp)
        exit $code
    }
    Write-Output ("LEDGER-COMMIT-PREFLIGHT-PASS: range={0}; apply may proceed" -f $PassEp)
    exit 0
} finally {
    if (Test-Path -LiteralPath $resolvedPreview -PathType Container) {
        $confirmed = [IO.Path]::GetFullPath($resolvedPreview)
        if ($confirmed.StartsWith($tempBase + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($confirmed) -match '^comic-adapt-ledger-preflight-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $confirmed -Recurse -Force
        }
    }
}

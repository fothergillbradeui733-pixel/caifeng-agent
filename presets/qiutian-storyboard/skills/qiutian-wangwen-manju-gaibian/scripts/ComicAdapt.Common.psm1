function Write-JsonAtomic([string]$Path, [object]$Value) {
    $dir = Split-Path -Parent $Path
    if ($dir) { [void](New-Item -ItemType Directory -Force -Path $dir) }
    $temp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
}

function Write-TextAtomic([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir) { [void](New-Item -ItemType Directory -Force -Path $dir) }
    $temp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temp, $Text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-RelativePathCompat([string]$BasePath, [string]$Path) {
    $base = [IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $base + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($base.Length + 1).Replace('\', '/')
    }
    if ($full.Equals($base, [StringComparison]::OrdinalIgnoreCase)) { return '.' }
    return $full.Replace('\', '/')
}

function Get-TextSha256([string]$Text) {
    if ($null -eq $Text) { $Text = '' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-ComicScriptCoreText([string]$Text) {
    if ($null -eq $Text) { return '' }
    $normalized = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    $ledger = [regex]::Match($normalized, '(?ms)^\u3010\u53f0\u8d26\u767b\u8bb0\u5757\u3011\s*\n.*\z')
    if ($ledger.Success) { $normalized = $normalized.Substring(0, $ledger.Index).TrimEnd() }
    $normalized = [regex]::Replace($normalized, '(?m)^\u4e0b\u96c6\u9884\u544a(?:\u3014[^\u3015\r\n]+\u3015)?[\uff1a:].*\n?', '')
    return (($normalized -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n").Trim()
}

function Get-ComicScriptHashes([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing script: $Path" }
    $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
    return [ordered]@{
        raw_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
        core_sha256 = Get-TextSha256 (Get-ComicScriptCoreText $raw)
    }
}

function Resolve-ComicEpisodeRange([string]$Value) {
    if ($Value -match '^\s*(\d+)\s*$') { return @([int]$Matches[1]) }
    if ($Value -match '^\s*(\d+)\s*(?:-|\u2013|\u2014)\s*(\d+)\s*$') {
        $start = [int]$Matches[1]; $end = [int]$Matches[2]
        if ($end -lt $start) { throw "Invalid episode range: $Value" }
        return @($start..$end)
    }
    throw "Episode range must be N or N-M: $Value"
}

function Get-ComicEpisodeToken([int]$Episode) {
    return 'EP-' + $Episode.ToString('D2')
}

Export-ModuleMember -Function Write-JsonAtomic, Read-Json, Write-TextAtomic, Get-RelativePathCompat, Get-TextSha256, Get-ComicScriptCoreText, Get-ComicScriptHashes, Resolve-ComicEpisodeRange, Get-ComicEpisodeToken

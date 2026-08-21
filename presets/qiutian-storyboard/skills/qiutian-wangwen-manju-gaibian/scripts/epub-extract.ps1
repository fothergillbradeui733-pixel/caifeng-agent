# EPUB 拆章提取工具
# 用途：WF-START 校验原著前，将 EPUB 提取为 novel/ 下的「第NNNN章 标题.txt」逐章文件（UTF-8 无 BOM）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File epub-extract.ps1 -Epub <epub文件或所在目录> [-OutDir novel]
# 章号来源：优先解析各内容文档标题中的「第N章」；解析不到时按 OPF spine 顺序（或文件名序）对正文体量达标的文档顺序编号。
# 输出末尾给出 计数/号段/缺号/重号 摘要，供与 script-lint -CheckSource 交叉验证。

param(
    [Parameter(Mandatory=$true)][string]$Epub,
    [string]$OutDir = 'novel'
)
$ErrorActionPreference = 'Stop'

# ---------- 定位 EPUB ----------
$epubFile = $null
if (Test-Path $Epub -PathType Leaf) {
    $epubFile = Get-Item $Epub
} elseif (Test-Path $Epub -PathType Container) {
    $cands = @(Get-ChildItem -Path $Epub -Filter *.epub -File)
    if ($cands.Count -eq 0) { throw "目录中未找到 .epub 文件：$Epub" }
    if ($cands.Count -gt 1) { throw ("目录中有多个 .epub，请用 -Epub 指定具体文件：" + (($cands | ForEach-Object { $_.Name }) -join '；')) }
    $epubFile = $cands[0]
} else {
    throw "路径不存在：$Epub"
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$outFull = (Resolve-Path $OutDir).Path

# ---------- 解压到临时目录 ----------
$tmp = Join-Path $env:TEMP ("epub_extract_" + [IO.Path]::GetFileNameWithoutExtension($epubFile.Name) + "_" + $PID)
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$zip = Join-Path $tmp "book.zip"
Copy-Item $epubFile.FullName $zip -Force
Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp 'x') -Force
$root = Join-Path $tmp 'x'

# ---------- 按 OPF spine 取内容文档顺序（失败则回退文件名序） ----------
$docs = @()
try {
    $containerPath = Get-ChildItem -Path $root -Recurse -File -Filter 'container.xml' | Select-Object -First 1
    [xml]$container = Get-Content $containerPath.FullName -Raw -Encoding UTF8
    $opfRel = $container.container.rootfiles.rootfile | Select-Object -First 1 -ExpandProperty 'full-path'
    $opfPath = Join-Path $root ($opfRel -replace '/', '\')
    [xml]$opf = Get-Content $opfPath -Raw -Encoding UTF8
    $opfDir = Split-Path $opfPath -Parent
    $manifest = @{}
    foreach ($item in $opf.package.manifest.item) { $manifest[$item.id] = $item.href }
    foreach ($ref in $opf.package.spine.itemref) {
        $href = $manifest[$ref.idref]
        if ($href) {
            $p = Join-Path $opfDir ([Uri]::UnescapeDataString($href) -replace '/', '\')
            if ((Test-Path $p) -and $p -match '\.x?html?$') { $docs += (Get-Item $p) }
        }
    }
} catch { $docs = @() }
if ($docs.Count -eq 0) {
    $docs = @(Get-ChildItem -Path $root -Recurse -File | Where-Object { $_.Name -match '\.x?html?$' } | Sort-Object FullName)
}
if ($docs.Count -eq 0) { throw "EPUB 内未找到任何 xhtml/html 内容文档" }

# ---------- 逐文档提取 ----------
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$records = @()
$skipped = @()
$seq = 0
foreach ($f in $docs) {
    $raw = Get-Content -Path $f.FullName -Raw -Encoding UTF8

    # 标题：h1 > h2 > <title>
    $title = ''
    foreach ($pat in @('(?s)<h1[^>]*>(.*?)</h1>', '(?s)<h2[^>]*>(.*?)</h2>', '(?s)<title[^>]*>(.*?)</title>')) {
        if ($raw -match $pat) {
            $t = [regex]::Replace($matches[1], '<[^>]+>', '')
            $title = [System.Net.WebUtility]::HtmlDecode($t).Trim()
            if ($title) { break }
        }
    }

    # 正文段落
    $paras = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($raw, '(?s)<p[^>]*>(.*?)</p>')) {
        $t = $m.Groups[1].Value
        $t = [regex]::Replace($t, '<br\s*/?>', "`n")
        $t = [regex]::Replace($t, '<[^>]+>', '')
        $t = [System.Net.WebUtility]::HtmlDecode($t).Trim()
        if ($t.Length -gt 0) { $paras.Add($t) }
    }
    $bodyLen = ($paras | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $bodyLen) { $bodyLen = 0 }

    # 章号：标题「第N章」优先
    $num = $null
    if ($title -match '第\s*(\d+)\s*[章回节]') { $num = [int]$matches[1] }

    # 非章节文档（无章号且正文过短）跳过：封面/目录/nav/简介等
    if ($null -eq $num -and $bodyLen -lt 500) { $skipped += ($f.Name + "（" + $title + "）"); continue }
    if ($null -eq $num) { $seq++; $num = $seq } else { $seq = $num }

    # 标题去「第N章」前缀作文件名部分
    $titlePart = $title
    if ($title -match '^第\s*\d+\s*[章回节][\s：:.、]*(.*)$') { $titlePart = $matches[1].Trim() }
    if (-not $titlePart) { $titlePart = '无题' }
    $safe = $titlePart -replace '[\\/:*?"<>|]', '_'
    if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine($title)
    [void]$sb.AppendLine('')
    foreach ($p in $paras) { [void]$sb.AppendLine($p) }

    $fname = ('第{0:D4}章 {1}.txt' -f $num, $safe)
    [System.IO.File]::WriteAllText((Join-Path $outFull $fname), $sb.ToString(), $utf8NoBom)
    $records += [PSCustomObject]@{ Num = $num; File = $fname; Chars = $sb.Length }
}

# ---------- 摘要 ----------
if ($records.Count -eq 0) { throw "未提取到任何章节（全部文档被判为非章节内容）" }
$nums = $records | ForEach-Object { $_.Num } | Sort-Object
$min = $nums[0]; $max = $nums[-1]
$dupes = $records | Group-Object Num | Where-Object { $_.Count -gt 1 }
$missing = @()
for ($i = $min; $i -le $max; $i++) { if ($nums -notcontains $i) { $missing += $i } }
$totalChars = ($records | Measure-Object -Property Chars -Sum).Sum

Write-Output ("提取完成：{0} 章 → {1}" -f $records.Count, $outFull)
Write-Output ("号段：第{0}章 ~ 第{1}章｜总字符≈{2:N0}" -f $min, $max, $totalChars)
if ($dupes.Count -gt 0) { Write-Output ("[WARN] 重号：" + (($dupes | ForEach-Object { $_.Name }) -join '、')) }
if ($missing.Count -gt 0) { Write-Output ("[WARN] 缺号：" + ($missing -join '、') + "（登记 progress「源文件缺口」并补源）") }
if ($skipped.Count -gt 0) { Write-Output ("跳过非章节文档 {0} 个：{1}" -f $skipped.Count, (($skipped | Select-Object -First 5) -join '；') + $(if ($skipped.Count -gt 5) { ' …' } else { '' })) }
if ($dupes.Count -eq 0 -and $missing.Count -eq 0) { Write-Output "零缺号/零重号——可直接跑 script-lint -CheckSource 交叉验证" }

# 源 EPUB 位于 OutDir 内会被 -CheckSource 误扫，提示移出
if ($epubFile.DirectoryName -eq $outFull) { Write-Output ("[WARN] 源 EPUB 位于输出目录内，请移出 novel/ 归档：" + $epubFile.FullName) }

Remove-Item $tmp -Recurse -Force

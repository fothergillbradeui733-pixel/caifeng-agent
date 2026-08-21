[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Init', 'Scaffold', 'Sync', 'Preflight', 'Ready', 'Validate', 'Index', 'Status')]
    [string]$Mode,

    [string]$PassEp,
    [int]$FromEpisode = 0,
    [string]$BatchContractPath = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComicAdapt.Common.psm1') -Force
$SchemaVersion = 'comic-adapt-visual-handoff/1.0'
$AllowedTypes = @('角色', '场景', '道具', '群像', '生物', '不可见声音角色', '3D Q版小人')
$TypePrefixes = [ordered]@{ '角色' = 'CHR'; '场景' = 'SCN'; '道具' = 'PRP'; '群像' = 'GRP'; '生物' = 'BIO'; '不可见声音角色' = 'VOC'; '3D Q版小人' = 'Q' }
$AllowedTendencies = @('必须建卡', '建议建卡', '逐镜内联', '不资产化', '待确认')
$AllowedDecisions = @('建卡', '逐镜内联', '不资产化')
$PlaceholderPattern = '待补|待确认|待分配|DRAFT|\[[^\]]+\]|\{[^}]+\}'

function Read-Utf8([string]$Path) {
    return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
}

function Write-Utf8([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if ($parent) { [void](New-Item -ItemType Directory -Force -Path $parent) }
    $temp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Resolve-Episodes([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'PassEp is required for Scaffold or Validate.' }
    if ($Value -match '^\s*(\d+)\s*$') { return @([int]$Matches[1]) }
    if ($Value -match '^\s*(\d+)\s*[-–—]\s*(\d+)\s*$') {
        $start = [int]$Matches[1]
        $end = [int]$Matches[2]
        if ($end -lt $start) { throw "Invalid episode range: $Value" }
        return @($start..$end)
    }
    throw "PassEp must be N or N-M: $Value"
}

function Find-EpisodeFile([string]$ScriptsDir, [int]$Episode) {
    if (-not (Test-Path -LiteralPath $ScriptsDir -PathType Container)) { return $null }
    $pattern = '^EP-0*' + $Episode + '\.md$'
    return Get-ChildItem -LiteralPath $ScriptsDir -File -Filter 'EP-*.md' |
        Where-Object { $_.Name -match $pattern } |
        Sort-Object Name |
        Select-Object -First 1
}

function Get-EpisodeNumber([string]$Name) {
    $match = [regex]::Match($Name, '^EP-0*(\d+)\.md$')
    if ($match.Success) { return [int]$match.Groups[1].Value }
    return 0
}

function Get-MetadataValue([string]$Text, [string]$Key) {
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Key) + '[：:]\s*(?<value>[^\r\n]+)\s*$')
    if ($match.Success) { return $match.Groups['value'].Value.Trim() }
    return ''
}

function Get-SectionText([string]$Text, [string]$Heading) {
    $match = [regex]::Match($Text, '(?ms)^##\s+' + [regex]::Escape($Heading) + '\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
    if ($match.Success) { return $match.Groups['body'].Value.Trim() }
    return ''
}

function ConvertFrom-MarkdownTable([string]$Text, [string]$Heading) {
    $section = Get-SectionText $Text $Heading
    if (-not $section) { return @() }
    $lines = @($section -split '\r?\n' | Where-Object { $_ -match '^\s*\|' })
    if ($lines.Count -lt 2) { return @() }
    $headers = @($lines[0].Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
    $rows = New-Object Collections.Generic.List[object]
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

function Split-Aliases([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq '无') { return @() }
    return @($Value -split '[、，,；;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '无' })
}

function Normalize-PersonLabel([string]$Value) {
    $clean = $Value.Trim()
    if ($clean -match '^（(?<name>.+)）$') { $clean = $Matches['name'].Trim() }
    $clean = $clean -replace '（画外）$', ''
    return $clean.Trim()
}

function Test-UnresolvedEmpty([string]$Text, [string]$Heading) {
    $section = Get-SectionText $Text $Heading
    if (-not $section) { return $false }
    $meaningful = @($section -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^<!--' })
    return ($meaningful.Count -eq 1 -and $meaningful[0] -match '^-?\s*无\s*$')
}

function Test-StateRangeAndAnchor([string]$Value, [int]$Episode) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parts = @($Value -split '｜', 2 | ForEach-Object { $_.Trim() })
    if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) { return $false }
    $rangePattern = '^(?:EP-0*\d+\s*[–—-]\s*EP-0*\d+|EP-0*\d+\s+起(?:\s*·\s*.+)?|仅\s+EP-0*\d+|全剧本)$'
    $anchorMatch = [regex]::Match($parts[1], '^EP-0*(?<episode>\d+)(?:\s+场次\s+\d+-\d+|\s+集首)(?:\s*.+)?$')
    return ($parts[0] -match $rangePattern -and $anchorMatch.Success -and [int]$anchorMatch.Groups['episode'].Value -le $Episode)
}

function Test-SceneOrPropAnchor([string]$Value, [int]$Episode) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parts = @($Value -split '｜', 2 | ForEach-Object { $_.Trim() })
    if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) { return $false }
    $anchorMatch = [regex]::Match($parts[1], '^EP-0*(?<episode>\d+)(?:\s+场次\s+\d+-\d+|\s+集首)(?:\s*.+)?$')
    return ($anchorMatch.Success -and [int]$anchorMatch.Groups['episode'].Value -le $Episode)
}

function Get-SourceData([string]$SourcePath) {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw "Missing source facts: $SourcePath" }
    $text = Read-Utf8 $SourcePath
    if ((Get-MetadataValue $text 'schema_version') -ne $SchemaVersion) { throw "Unsupported source-facts schema: $SourcePath" }
    return [ordered]@{
        text = $text
        people = @(ConvertFrom-MarkdownTable $text '人物与条件类型')
        scenes = @(ConvertFrom-MarkdownTable $text '场景')
        props = @(ConvertFrom-MarkdownTable $text '道具')
        from_episode = [int]((Get-MetadataValue $text '要求起始集') -replace '^EP-0*', '')
    }
}

function Get-SourceEntityMap([object]$SourceData) {
    $byId = @{}
    $byName = @{}
    $errors = New-Object Collections.Generic.List[string]
    if (-not (Test-UnresolvedEmpty $SourceData.text '待确认')) { $errors.Add('source-facts pending decisions are not empty') }
    foreach ($group in @(
        [ordered]@{ rows = $SourceData.people; type_column = '类型'; name_column = '剧本规范名'; alias_column = '别名'; asset_column = '建议@资产名'; expected = $null },
        [ordered]@{ rows = $SourceData.scenes; type_column = $null; name_column = '场次头规范名'; alias_column = '精确别名'; asset_column = '建议@资产名'; expected = '场景' },
        [ordered]@{ rows = $SourceData.props; type_column = $null; name_column = '剧本正式名'; alias_column = '别名'; asset_column = '建议@资产名'; expected = '道具' }
    )) {
        foreach ($row in $group.rows) {
            $id = [string]$row.'实体ID'
            $type = if ($group.expected) { $group.expected } else { [string]$row.($group.type_column) }
            $name = [string]$row.($group.name_column)
            $asset = [string]$row.($group.asset_column)
            if (-not $id -or $id -match $PlaceholderPattern) { $errors.Add("source-facts invalid entity ID: $id") }
            if ($id -and $byId.ContainsKey($id)) { $errors.Add("source-facts duplicate entity ID: $id") }
            if ($type -notin $AllowedTypes) { $errors.Add("source-facts invalid type: $id | $type") }
            elseif ($id -notmatch ('^' + $TypePrefixes[$type] + '-\d+$')) { $errors.Add("source-facts invalid entity ID prefix: $id | $type") }
            if (-not $group.expected -and $type -in @('场景', '道具')) { $errors.Add("source-facts entity is in wrong table: $id | $type") }
            if (-not $name -or $name -match $PlaceholderPattern) { $errors.Add("source-facts invalid canonical name: $id | $name") }
            if (-not $asset -or $asset -notmatch '^@') { $errors.Add("source-facts invalid suggested asset: $id | $asset") }
            $entity = [pscustomobject]@{ id = $id; type = $type; name = $name; asset = $asset; row = $row; aliases = @(Split-Aliases ([string]$row.($group.alias_column))) }
            if ($id) { $byId[$id] = $entity }
            foreach ($label in @($name) + $entity.aliases) {
                if (-not $label) { continue }
                $key = $label.ToLowerInvariant()
                if ($byName.ContainsKey($key) -and $byName[$key].id -ne $id) {
                    $errors.Add("source-facts name/alias points to multiple entities: $label | $($byName[$key].id) | $id")
                } else {
                    $byName[$key] = $entity
                }
            }
        }
    }
    return [ordered]@{ by_id = $byId; by_name = $byName; errors = $errors.ToArray() }
}

function Resolve-SourceEntity([object]$SourceMap, [string]$Label, [string]$ExpectedType, [bool]$AllowUniqueContainment = $false) {
    if ([string]::IsNullOrWhiteSpace($Label)) { return $null }
    $key = $Label.Trim().ToLowerInvariant()
    if ($SourceMap.by_name.ContainsKey($key)) {
        $exact = $SourceMap.by_name[$key]
        if (-not $ExpectedType -or [string]$exact.type -eq $ExpectedType) { return $exact }
    }
    if (-not $AllowUniqueContainment) { return $null }
    $candidates = @{}
    foreach ($entry in $SourceMap.by_name.GetEnumerator()) {
        $known = [string]$entry.Key
        $entity = $entry.Value
        if ($known.Length -lt 2 -or ($ExpectedType -and [string]$entity.type -ne $ExpectedType)) { continue }
        if ($key.Contains($known) -or $known.Contains($key)) { $candidates[[string]$entity.id] = $entity }
    }
    if ($candidates.Count -eq 1) { return @($candidates.Values)[0] }
    return $null
}

function Get-ScriptInventory([string]$ScriptText) {
    $body = [regex]::Split($ScriptText, '(?m)^【台账登记块】\s*$')[0]
    $lines = @($body -split '\r?\n')
    $scenes = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $header = [regex]::Match($lines[$i], '^场次\s+(?<scene>\d+-\d+)[：:]\s*(?:内|外)\s+(?<location>.+?)\s+(?<time>日|夜|晨|黄昏(?:·\S+)?)\s*$')
        if (-not $header.Success) { continue }
        $sceneNo = $header.Groups['scene'].Value
        $location = $header.Groups['location'].Value.Trim()
        $time = $header.Groups['time'].Value.Trim()
        $end = $lines.Count - 1
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match '^场次\s+\d+-\d+[：:]') { $end = $j - 1; break }
        }
        $people = New-Object Collections.Generic.List[object]
        for ($j = $i + 1; $j -le $end; $j++) {
            $cast = [regex]::Match($lines[$j], '^出场人物[：:]\s*(?<value>.+)$')
            if (-not $cast.Success) { continue }
            foreach ($raw in ($cast.Groups['value'].Value -split '[；;]')) {
                $label = $raw.Trim()
                if (-not $label) { continue }
                $people.Add([pscustomobject]@{
                    raw = $label
                    normalized = Normalize-PersonLabel $label
                    background = ($label -match '^（.+）$')
                })
            }
            break
        }
        $sceneText = ($lines[$i..$end] -join "`n")
        $scenes.Add([pscustomobject]@{ scene = $sceneNo; location = $location; time = $time; people = $people.ToArray(); text = $sceneText })
    }
    return [ordered]@{ scenes = $scenes.ToArray(); text = $body }
}

function Get-SourceField([object]$Entity, [string]$Column) {
    $property = $Entity.row.PSObject.Properties[$Column]
    if ($property) { return [string]$property.Value }
    return ''
}

function Get-EpisodeValidation([string]$Root, [int]$Episode, [object]$SourceData, [object]$SourceMap, [bool]$AllowDraft = $false) {
    $errors = New-Object Collections.Generic.List[string]
    foreach ($item in $SourceMap.errors) { $errors.Add($item) }
    $scriptsDir = Join-Path $Root 'scripts'
    $scriptFile = Find-EpisodeFile $scriptsDir $Episode
    $episodeToken = 'EP-' + $Episode.ToString('D2')
    $episodePath = Join-Path $Root ("visual-assets\episodes\{0}.md" -f $episodeToken)
    if (-not $scriptFile) { $errors.Add("missing script: $episodeToken") }
    if (-not (Test-Path -LiteralPath $episodePath -PathType Leaf)) { $errors.Add("missing handoff episode: $episodeToken") }
    if ($errors.Count -gt 0) { return [ordered]@{ episode = $Episode; errors = $errors.ToArray(); path = $episodePath; rows = @() } }

    $scriptText = Read-Utf8 $scriptFile.FullName
    $inventory = Get-ScriptInventory $scriptText
    $text = Read-Utf8 $episodePath
    if ((Get-MetadataValue $text 'schema_version') -ne $SchemaVersion) { $errors.Add("$episodeToken unsupported schema") }
    $status = Get-MetadataValue $text '交接状态'
    if ($AllowDraft) {
        if ($status -notin @('DRAFT', 'READY')) { $errors.Add("$episodeToken status is neither DRAFT nor READY") }
    } elseif ($status -ne 'READY') { $errors.Add("$episodeToken status is not READY") }
    $declaredScript = Get-MetadataValue $text '剧本路径'
    $expectedScript = Get-RelativePathCompat $Root $scriptFile.FullName
    if ($declaredScript -ne $expectedScript) { $errors.Add("$episodeToken script path mismatch: $declaredScript") }
    $declaredHash = Get-MetadataValue $text '剧本SHA256'
    $actualHash = Get-Sha256 $scriptFile.FullName
    if ($declaredHash -ne $actualHash) { $errors.Add("$episodeToken stale script hash") }
    if (-not (Test-UnresolvedEmpty $text '未解决项')) { $errors.Add("$episodeToken unresolved items are not empty") }

    $peopleRows = @(ConvertFrom-MarkdownTable $text '人物出现')
    $sceneRows = @(ConvertFrom-MarkdownTable $text '场景出现')
    $propRows = @(ConvertFrom-MarkdownTable $text '道具出现')
    $allRows = @($peopleRows) + @($sceneRows) + @($propRows)

    foreach ($row in $allRows) {
        $id = [string]$row.'实体ID'
        if (-not $SourceMap.by_id.ContainsKey($id)) { $errors.Add("$episodeToken references missing entity: $id") }
        foreach ($property in $row.PSObject.Properties) {
            if ([string]$property.Value -match $PlaceholderPattern) { $errors.Add("$episodeToken placeholder: $id | $($property.Name)=$($property.Value)") }
        }
    }

    foreach ($row in $peopleRows) {
        $id = [string]$row.'实体ID'
        $decision = [string]$row.'资产化决策'
        $asset = [string]$row.'建议状态@'
        if ($decision -notin $AllowedDecisions) { $errors.Add("$episodeToken invalid person decision: $id | $decision") }
        if ($decision -eq '建卡' -and $asset -notmatch '^@') { $errors.Add("$episodeToken person card missing @: $id") }
        if ($decision -ne '建卡' -and $asset -ne '无') { $errors.Add("$episodeToken inline person must use 建议状态@=无: $id") }
        $dimension = [string]$row.'状态维度'
        if ($dimension -notin @('—', '形态', '体态', '服装', '伤势', '身份呈现', '特殊')) { $errors.Add("$episodeToken invalid state dimension: $id | $dimension") }
        $entity = if ($SourceMap.by_id.ContainsKey($id)) { $SourceMap.by_id[$id] } else { $null }
        $isVoicePresentation = ($entity -and $entity.type -eq '不可见声音角色' -and $asset -match '_(?:声音|声线|通灵声|画外声|OS)(?:$|_)')
        if ($asset -match '_' -and $dimension -eq '—' -and -not $isVoicePresentation) { $errors.Add("$episodeToken state asset lacks dimension: $id | $asset") }
        if ($dimension -ne '—' -and $decision -eq '建卡' -and $asset -notmatch '_') { $errors.Add("$episodeToken state dimension lacks state asset name: $id | $dimension") }
        if ($decision -eq '建卡' -and $asset -match '_' -and -not (Test-StateRangeAndAnchor ([string]$row.'生效区间/切换锚') $Episode)) {
            $errors.Add("$episodeToken state asset lacks valid range/switch anchor: $id | $asset")
        }
        if ($entity) {
            foreach ($column in @('设定性别/年龄', '原文稳定外观', '特殊标志', '服装事实', '资产化倾向', '证据')) {
                $value = Get-SourceField $entity $column
                if (-not $value -or $value -match $PlaceholderPattern) { $errors.Add("$episodeToken incomplete source fact: $id | $column") }
            }
            $identity = Get-SourceField $entity '设定性别/年龄'
            if ($entity.type -notin @('群像', '不可见声音角色') -and $identity -match '原文未明示|需用户确认') {
                $errors.Add("$episodeToken unresolved identity fact: $id | 设定性别/年龄=$identity")
            }
            if ($entity.type -eq '不可见声音角色') {
                $voiceFacts = @(@('原文稳定外观', '特殊标志', '服装事实', '证据') | ForEach-Object { Get-SourceField $entity $_ }) -join '｜'
                if ($voiceFacts -notmatch '不可见|未出镜|不露脸|不得设计脸部|不呈现[^｜]*脸|仅声音|声音角色|通灵[^｜]*声音|变声音轨') {
                    $errors.Add("$episodeToken invisible voice source fact must forbid visible face design: $id")
                }
            }
            $tendency = Get-SourceField $entity '资产化倾向'
            if ($tendency -notin $AllowedTendencies) { $errors.Add("$episodeToken invalid source tendency: $id | $tendency") }
        }
    }

    foreach ($row in $sceneRows) {
        $id = [string]$row.'实体ID'
        $decision = [string]$row.'资产化决策'
        $asset = [string]$row.'建议状态@'
        if ($decision -notin $AllowedDecisions) { $errors.Add("$episodeToken invalid scene decision: $id | $decision") }
        if ($decision -eq '建卡' -and $asset -notmatch '^@') { $errors.Add("$episodeToken scene card missing @: $id") }
        if ($decision -ne '建卡' -and $asset -ne '无') { $errors.Add("$episodeToken inline scene must use 建议状态@=无: $id") }
        if ($decision -eq '建卡' -and $asset -match '_' -and -not (Test-SceneOrPropAnchor ([string]$row.'状态/切换锚') $Episode)) {
            $errors.Add("$episodeToken scene state lacks valid switch anchor: $id | $asset")
        }
        $entity = if ($SourceMap.by_id.ContainsKey($id)) { $SourceMap.by_id[$id] } else { $null }
        if ($entity) {
            foreach ($column in @('物理空间身份', '世界层', '固定结构/陈设/视觉符号', '资产化倾向', '证据')) {
                $value = Get-SourceField $entity $column
                if (-not $value -or $value -match $PlaceholderPattern) { $errors.Add("$episodeToken incomplete source fact: $id | $column") }
            }
            $tendency = Get-SourceField $entity '资产化倾向'
            if ($tendency -notin $AllowedTendencies) { $errors.Add("$episodeToken invalid source tendency: $id | $tendency") }
        }
    }

    foreach ($row in $propRows) {
        $id = [string]$row.'实体ID'
        $decision = [string]$row.'资产化决策'
        $asset = [string]$row.'建议状态@'
        if ($decision -notin $AllowedDecisions) { $errors.Add("$episodeToken invalid prop decision: $id | $decision") }
        if ($decision -eq '建卡' -and $asset -notmatch '^@') { $errors.Add("$episodeToken prop card missing @: $id") }
        if ($decision -ne '建卡' -and $asset -ne '无') { $errors.Add("$episodeToken inline prop must use 建议状态@=无: $id") }
        if ($decision -eq '建卡' -and $asset -match '_' -and -not (Test-SceneOrPropAnchor ([string]$row.'状态变化/切换锚') $Episode)) {
            $errors.Add("$episodeToken prop state lacks valid switch anchor: $id | $asset")
        }
        $entity = if ($SourceMap.by_id.ContainsKey($id)) { $SourceMap.by_id[$id] } else { $null }
        if ($entity) {
            foreach ($column in @('尺寸/材质/形状/颜色', '文字/关键标记', '初始持有人/状态', '资产化倾向', '证据')) {
                $value = Get-SourceField $entity $column
                if (-not $value -or $value -match $PlaceholderPattern) { $errors.Add("$episodeToken incomplete source fact: $id | $column") }
            }
            $tendency = Get-SourceField $entity '资产化倾向'
            if ($tendency -notin $AllowedTendencies) { $errors.Add("$episodeToken invalid source tendency: $id | $tendency") }
        }
    }

    foreach ($scene in $inventory.scenes) {
        $sceneHit = @($sceneRows | Where-Object { $_.'场次' -eq $scene.scene -and $_.'场次头原名' -eq $scene.location })
        if ($sceneHit.Count -ne 1) { $errors.Add("$episodeToken scene coverage must be exactly one: $($scene.scene) | $($scene.location)") }
        foreach ($person in $scene.people) {
            $personHit = @($peopleRows | Where-Object {
                $_.'场次' -eq $scene.scene -and (Normalize-PersonLabel ([string]$_.'源标签')) -eq $person.normalized
            })
            if ($personHit.Count -ne 1) { $errors.Add("$episodeToken person coverage must be exactly one: $($scene.scene) | $($person.raw)") }
        }
    }

    return [ordered]@{
        episode = $Episode
        token = $episodeToken
        errors = @($errors | Sort-Object -Unique)
        path = $episodePath
        script = $scriptFile.FullName
        script_hash = $actualHash
        people = $peopleRows
        scenes = $sceneRows
        props = $propRows
    }
}

function Get-MixedBaseStateErrors([object[]]$Results) {
    $assetsById = @{}
    $episodesById = @{}
    $idsByAsset = @{}
    foreach ($result in $Results) {
        foreach ($row in @($result.people) + @($result.scenes) + @($result.props)) {
            if ([string]$row.'资产化决策' -ne '建卡') { continue }
            $id = [string]$row.'实体ID'
            $asset = [string]$row.'建议状态@'
            if (-not $id -or $asset -notmatch '^@') { continue }
            if (-not $assetsById.ContainsKey($id)) { $assetsById[$id] = New-Object Collections.Generic.HashSet[string] }
            [void]$assetsById[$id].Add($asset)
            if (-not $episodesById.ContainsKey($id)) { $episodesById[$id] = New-Object Collections.Generic.HashSet[string] }
            [void]$episodesById[$id].Add(('EP-' + ([int]$result.episode).ToString('D2')))
            if (-not $idsByAsset.ContainsKey($asset)) { $idsByAsset[$asset] = New-Object Collections.Generic.HashSet[string] }
            [void]$idsByAsset[$asset].Add($id)
        }
    }
    $issues = New-Object Collections.Generic.List[string]
    foreach ($id in $assetsById.Keys) {
        $assets = @($assetsById[$id])
        $hasState = @($assets | Where-Object { $_ -match '_' }).Count -gt 0
        $hasBare = @($assets | Where-Object { $_ -notmatch '_' }).Count -gt 0
        if ($hasState -and $hasBare) {
            $affected = @($episodesById[$id] | Sort-Object) -join ','
            $issues.Add("baseline migration required: $id | assets=$($assets -join '、') | affected=$affected | choose one explicit baseline and update every affected handoff")
        }
    }
    foreach ($asset in $idsByAsset.Keys) {
        $ids = @($idsByAsset[$asset])
        if ($ids.Count -gt 1) { $issues.Add("candidate asset name points to multiple entities: $asset | $($ids -join '、')") }
    }
    return $issues.ToArray()
}

function Get-BatchContract([string]$Root, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $path = if ([IO.Path]::IsPathRooted($Value)) { $Value } else { Join-Path $Root $Value }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing batch contract: $path" }
    $contract = Read-Json $path
    if (-not $contract -or [string]$contract.schema_version -ne 'comic-adapt-batch-contract/1.0' -or [string]$contract.contract_status -ne 'FROZEN') {
        throw "Visual contract coverage requires a frozen comic-adapt-batch-contract/1.0: $path"
    }
    return $contract
}

function Get-ContractTransitionErrors([object]$Contract, [object]$Result) {
    if (-not $Contract) { return @() }
    $errors = [Collections.Generic.List[string]]::new()
    $episodeContract = @($Contract.episode_contracts | Where-Object { [string]$_.episode -eq [string]$Result.token } | Select-Object -First 1)
    if ($episodeContract.Count -eq 0) {
        $errors.Add("$($Result.token) missing from frozen batch contract")
        return $errors.ToArray()
    }
    $episodeContract = $episodeContract[0]
    $entityRefs = @($episodeContract.entity_refs | ForEach-Object { ([string]$_).Trim() })
    $propIds = @($Result.props | ForEach-Object { [string]$_.'实体ID' })
    $requiredPropIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($transition in @($episodeContract.asset_transitions)) {
        foreach ($match in [regex]::Matches([string]$transition, '(?<![A-Z0-9-])PRP-\d+(?!\d)')) { [void]$requiredPropIds.Add($match.Value) }
    }
    foreach ($id in @($requiredPropIds | Sort-Object)) {
        if ($id -cnotin $entityRefs) { $errors.Add("$($Result.token) frozen transition entity is absent from entity_refs: $id") }
        if ($id -cnotin $propIds) { $errors.Add("$($Result.token) frozen prop transition is absent from 道具出现: $id") }
    }
    return $errors.ToArray()
}

function New-SourceTemplate([int]$StartEpisode) {
    $start = 'EP-' + $StartEpisode.ToString('D2')
    return @"
# 视觉资产源事实

schema_version: $SchemaVersion
要求起始集：$start

## 人物与条件类型

| 实体ID | 类型 | 剧本规范名 | 建议@资产名 | 别名 | 设定性别/年龄 | 原文稳定外观 | 特殊标志 | 服装事实 | 资产化倾向 | 证据 |
|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|

## 场景

| 实体ID | 场次头规范名 | 物理空间身份 | 建议@资产名 | 精确别名 | 世界层 | 固定结构/陈设/视觉符号 | 资产化倾向 | 证据 |
|:--|:--|:--|:--|:--|:--|:--|:--|:--|

## 道具

| 实体ID | 剧本正式名 | 建议@资产名 | 别名 | 尺寸/材质/形状/颜色 | 文字/关键标记 | 初始持有人/状态 | 资产化倾向 | 证据 |
|:--|:--|:--|:--|:--|:--|:--|:--|:--|

## 待确认

- 无
"@.TrimStart()
}

function New-EmptyIndex([string]$Root, [string]$SourcePath, [int]$StartEpisode) {
    $sourceRelative = Get-RelativePathCompat $Root $SourcePath
    $sourceHash = Get-Sha256 $SourcePath
    return @"
# comic-adapt 视觉资产事实交接

schema_version: $SchemaVersion
交接状态：EMPTY
要求起始集：EP-$($StartEpisode.ToString('D2'))
覆盖范围：无
源事实路径：$sourceRelative
源事实SHA256：$sourceHash
生成时间：$((Get-Date).ToString('o'))

## 分集交接文件

| 集数 | 剧本路径 | 剧本SHA256 | 交接路径 | 交接SHA256 | 状态 |
|:--|:--|:--|:--|:--|:--|

## 全局实体索引

| 实体ID | 类型 | 剧本规范名 | 建议@集合 | 别名 | 出现集 | 源事实路径 |
|:--|:--|:--|:--|:--|:--|:--|

## 未解决项

- 无
"@.TrimStart()
}

function Get-PreviousStableRows([string]$Root, [int]$Episode, [string]$Heading) {
    $rowsById = @{}
    if ($Episode -le 1) { return $rowsById }
    # Per entity, inherit the closest valid READY appearance rather than only EP-N-1.
    # An entity may be absent for several episodes while its stable visual state remains authoritative.
    for ($number = $Episode - 1; $number -ge 1; $number--) {
        $previousPath = Join-Path $Root ("visual-assets\episodes\EP-{0}.md" -f $number.ToString('D2'))
        if (-not (Test-Path -LiteralPath $previousPath -PathType Leaf)) { continue }
        $previousText = Read-Utf8 $previousPath
        if ((Get-MetadataValue $previousText '交接状态') -ne 'READY') { continue }
        $scriptRelative = Get-MetadataValue $previousText '剧本路径'
        $scriptPath = if ([IO.Path]::IsPathRooted($scriptRelative)) { $scriptRelative } else { Join-Path $Root $scriptRelative }
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { continue }
        if ((Get-MetadataValue $previousText '剧本SHA256') -ne (Get-Sha256 $scriptPath)) { continue }
        foreach ($row in @(ConvertFrom-MarkdownTable $previousText $Heading)) {
            $id = [string]$row.'实体ID'
            if ($id -and -not $rowsById.ContainsKey($id)) { $rowsById[$id] = $row }
        }
    }
    return $rowsById
}

function Get-StateScanResults([string]$Root, [int]$ThroughEpisode, [int[]]$DraftEpisodes, [hashtable]$TextOverrides = $null) {
    $results = New-Object Collections.Generic.List[object]
    $draftSet = [Collections.Generic.HashSet[int]]::new()
    foreach ($number in @($DraftEpisodes)) { [void]$draftSet.Add([int]$number) }
    for ($number = 1; $number -le $ThroughEpisode; $number++) {
        $path = Join-Path $Root ("visual-assets\episodes\EP-{0}.md" -f $number.ToString('D2'))
        $hasOverride = ($null -ne $TextOverrides -and $TextOverrides.ContainsKey($number))
        if (-not $hasOverride -and -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $text = if ($hasOverride) { [string]$TextOverrides[$number] } else { Read-Utf8 $path }
        if (-not $draftSet.Contains($number) -and (Get-MetadataValue $text '交接状态') -ne 'READY') { continue }
        $results.Add([ordered]@{
            episode = $number
            people = @(ConvertFrom-MarkdownTable $text '人物出现')
            scenes = @(ConvertFrom-MarkdownTable $text '场景出现')
            props = @(ConvertFrom-MarkdownTable $text '道具出现')
        })
    }
    return $results.ToArray()
}

function Test-EntityVisibleChange([string]$SceneText, [string]$Label, [string]$Kind) {
    if (-not $SceneText -or -not $Label) { return $false }
    $keywords = switch ($Kind) {
        'person' { '换装|换上|脱下|披上|穿上|衣衫|服饰|受伤|伤口|鲜血|断臂|断腿|毁容|化形|变身|形态|衰老|恢复原貌' }
        'scene' { '坍塌|倒塌|烧毁|焚毁|损坏|破碎|改造|重建|开启|关闭|封闭|解封|变成' }
        'prop' { '交给|递给|还给|夺走|抢走|易主|丢弃|遗失|收起|取出|碎裂|破碎|损毁|焚毁|折断|耗尽|恢复' }
    }
    $escaped = [regex]::Escape($Label)
    return ($SceneText -match ("(?s)(?:{0}).{{0,24}}(?:{1})|(?:{1}).{{0,24}}(?:{0})" -f $escaped, $keywords))
}

function Get-AutoEvidence([object]$Scene, [string]$Label, [string]$Kind, [string]$EpisodeToken) {
    $lines = @(([string]$Scene.text) -split '\r?\n')
    $candidate = ''
    if ($Kind -in @('person', 'prop') -and $Label) {
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^[△※]' -and $trimmed -match [regex]::Escape($Label)) { $candidate = $trimmed; break }
        }
    }
    if (-not $candidate -and $Kind -eq 'person' -and $Label) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -ne $Label) { continue }
            for ($j = $i + 1; $j -lt [Math]::Min($lines.Count, $i + 5); $j++) {
                $dialogue = $lines[$j].Trim()
                if (-not $dialogue -or $dialogue -match '^（.*）$') { continue }
                $candidate = $Label + '：' + $dialogue
                break
            }
            if ($candidate) { break }
        }
    }
    if (-not $candidate) {
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^[△※]') { $candidate = $trimmed; break }
        }
    }
    if (-not $candidate) { $candidate = "场次头：$($Scene.location)｜$($Scene.time)" }
    $candidate = ($candidate -replace '\|', '｜').Trim()
    if ($candidate.Length -gt 120) { $candidate = $candidate.Substring(0, 120) }
    return "$EpisodeToken 场次 $($Scene.scene)｜「$candidate」"
}

function Format-TableRow([object[]]$Cells) {
    return '| ' + (($Cells | ForEach-Object { [string]$_ }) -join ' | ') + ' |'
}

function New-EpisodeScaffold([string]$Root, [int]$Episode, [object]$SourceData, [object]$SourceMap) {
    $scriptFile = Find-EpisodeFile (Join-Path $Root 'scripts') $Episode
    if (-not $scriptFile) { throw "Missing script for EP-$($Episode.ToString('D2'))" }
    $episodeToken = 'EP-' + $Episode.ToString('D2')
    $scriptText = Read-Utf8 $scriptFile.FullName
    $inventory = Get-ScriptInventory $scriptText
    $peopleLines = New-Object Collections.Generic.List[string]
    $sceneLines = New-Object Collections.Generic.List[string]
    $propLines = New-Object Collections.Generic.List[string]
    $unresolved = New-Object Collections.Generic.List[string]
    $previousPeople = Get-PreviousStableRows $Root $Episode '人物出现'
    $previousScenes = Get-PreviousStableRows $Root $Episode '场景出现'
    $previousProps = Get-PreviousStableRows $Root $Episode '道具出现'

    foreach ($scene in $inventory.scenes) {
        $sceneEntity = Resolve-SourceEntity $SourceMap $scene.location '场景' $true
        $sceneId = if ($sceneEntity -and $sceneEntity.type -eq '场景') { $sceneEntity.id } else { '待分配' }
        $sceneAsset = if ($sceneEntity -and $sceneEntity.type -eq '场景') { $sceneEntity.asset } else { '@' + $scene.location }
        $sceneDecision = if ($sceneEntity -and (Get-SourceField $sceneEntity '资产化倾向') -in @('必须建卡', '建议建卡')) { '建卡' } else { '待确认' }
        $sceneChanged = Test-EntityVisibleChange $scene.text $scene.location 'scene'
        $sceneEvidence = Get-AutoEvidence $scene $scene.location 'scene' $episodeToken
        $sceneCells = @($scene.scene, $scene.location, $sceneId, $scene.time, $sceneDecision, $sceneAsset, "基础｜$episodeToken 场次 $($scene.scene)", $sceneEvidence)
        if ($previousScenes.ContainsKey($sceneId) -and -not $sceneChanged) {
            $prior = $previousScenes[$sceneId]
            $sceneCells[4] = [string]$prior.'资产化决策'
            $sceneCells[5] = [string]$prior.'建议状态@'
            $sceneCells[6] = [string]$prior.'状态/切换锚'
        } elseif ($previousScenes.ContainsKey($sceneId) -and $sceneChanged) {
            $prior = $previousScenes[$sceneId]
            if ([string]$prior.'建议状态@' -match '_' -and [string]$sceneCells[5] -notmatch '_') {
                $sceneCells[4] = [string]$prior.'资产化决策'
                $sceneCells[5] = [string]$prior.'建议状态@'
                $sceneCells[6] = [string]$prior.'状态/切换锚'
            }
        }
        $sceneLines.Add((Format-TableRow $sceneCells))
        if (-not $sceneEntity) { $unresolved.Add("源事实缺场景：$($scene.location)") }
        elseif ($previousScenes.ContainsKey($sceneId) -and $sceneChanged) { $unresolved.Add("场景稳定状态变化待确认：$($scene.location)｜$episodeToken 场次 $($scene.scene)") }
        foreach ($person in $scene.people) {
            $personEntity = Resolve-SourceEntity $SourceMap $person.normalized '' $false
            $personId = if ($personEntity -and $personEntity.type -ne '场景' -and $personEntity.type -ne '道具') { $personEntity.id } else { '待分配' }
            $personAsset = if ($personEntity) { $personEntity.asset } else { '@' + $person.normalized }
            $tendency = if ($personEntity) { Get-SourceField $personEntity '资产化倾向' } else { '' }
            $personDecision = if ($person.background) { '逐镜内联' } elseif ($tendency -in @('必须建卡', '建议建卡')) { '建卡' } else { '待确认' }
            if ($personDecision -ne '建卡') { $personAsset = '无' }
            $personChanged = Test-EntityVisibleChange $scene.text $person.normalized 'person'
            $personEvidence = Get-AutoEvidence $scene $person.normalized 'person' $episodeToken
            $defaultDimension = if ($personEntity -and $personEntity.type -eq '不可见声音角色' -and $personAsset -match '_(?:声音|声线|通灵声|画外声|OS)(?:$|_)') { '身份呈现' } else { '—' }
            $personCells = @($scene.scene, $person.raw, $personId, $personDecision, $defaultDimension, $personAsset, "全剧本｜$episodeToken 场次 $($scene.scene) 首次出现", $personEvidence)
            if ($previousPeople.ContainsKey($personId) -and -not $personChanged) {
                $prior = $previousPeople[$personId]
                $personCells[3] = [string]$prior.'资产化决策'
                $personCells[4] = [string]$prior.'状态维度'
                $personCells[5] = [string]$prior.'建议状态@'
                $personCells[6] = [string]$prior.'生效区间/切换锚'
            } elseif ($previousPeople.ContainsKey($personId) -and $personChanged) {
                $prior = $previousPeople[$personId]
                if ([string]$prior.'建议状态@' -match '_' -and [string]$personCells[5] -notmatch '_') {
                    $personCells[3] = [string]$prior.'资产化决策'
                    $personCells[4] = [string]$prior.'状态维度'
                    $personCells[5] = [string]$prior.'建议状态@'
                    $personCells[6] = [string]$prior.'生效区间/切换锚'
                }
            }
            $peopleLines.Add((Format-TableRow $personCells))
            if (-not $personEntity) { $unresolved.Add("源事实缺人物/条件类型：$($person.normalized)") }
            elseif ($previousPeople.ContainsKey($personId) -and $personChanged) { $unresolved.Add("人物稳定状态变化待确认：$($person.normalized)｜$episodeToken 场次 $($scene.scene)") }
        }
        foreach ($propRow in $SourceData.props) {
            $propId = [string]$propRow.'实体ID'
            if (-not $SourceMap.by_id.ContainsKey($propId)) { continue }
            $propEntity = $SourceMap.by_id[$propId]
            $matchedLabel = $null
            foreach ($label in @($propEntity.name) + $propEntity.aliases) {
                if ($label -and $scene.text -match [regex]::Escape($label)) { $matchedLabel = $label; break }
            }
            if (-not $matchedLabel) { continue }
            $tendency = Get-SourceField $propEntity '资产化倾向'
            $propDecision = if ($tendency -in @('必须建卡', '建议建卡')) {
                '建卡'
            } elseif ($tendency -in @('逐镜内联', '不资产化')) {
                $tendency
            } else {
                '待确认'
            }
            $propAsset = if ($propDecision -eq '建卡') { $propEntity.asset } else { '无' }
            $propChanged = Test-EntityVisibleChange $scene.text $matchedLabel 'prop'
            $propEvidence = Get-AutoEvidence $scene $matchedLabel 'prop' $episodeToken
            $initialPropState = Get-SourceField $propEntity '初始持有人/状态'
            if (-not $initialPropState) { $initialPropState = '原著当前状态见源事实' }
            $propCells = @($scene.scene, $matchedLabel, $propId, $propDecision, $propAsset, $initialPropState, '无', "复用/首现｜$propEvidence")
            if ($previousProps.ContainsKey($propId) -and -not $propChanged) {
                $prior = $previousProps[$propId]
                $propCells[3] = [string]$prior.'资产化决策'
                $propCells[4] = [string]$prior.'建议状态@'
                $propCells[5] = [string]$prior.'当前状态/持有人'
                $propCells[6] = [string]$prior.'状态变化/切换锚'
            } elseif ($previousProps.ContainsKey($propId) -and $propChanged) {
                $prior = $previousProps[$propId]
                if ([string]$prior.'建议状态@' -match '_' -and [string]$propCells[4] -notmatch '_') {
                    $propCells[3] = [string]$prior.'资产化决策'
                    $propCells[4] = [string]$prior.'建议状态@'
                    $propCells[5] = [string]$prior.'当前状态/持有人'
                    $propCells[6] = [string]$prior.'状态变化/切换锚'
                }
            }
            $propLines.Add((Format-TableRow $propCells))
            if ($propDecision -eq '待确认') { $unresolved.Add("道具资产化待确认：$matchedLabel｜$episodeToken 场次 $($scene.scene)") }
            if ($previousProps.ContainsKey($propId) -and $propChanged) { $unresolved.Add("道具状态/持有人变化待确认：$matchedLabel｜$episodeToken 场次 $($scene.scene)") }
        }
    }
    if ($inventory.scenes.Count -eq 0) { $unresolved.Add('未解析到场次头') }
    $unresolvedText = if ($unresolved.Count -gt 0) { (($unresolved | Sort-Object -Unique | ForEach-Object { '- ' + $_ }) -join "`n") } else { '- 无' }
    $peopleText = if ($peopleLines.Count -gt 0) { $peopleLines -join "`n" } else { '' }
    $sceneText = if ($sceneLines.Count -gt 0) { $sceneLines -join "`n" } else { '' }
    $propText = if ($propLines.Count -gt 0) { $propLines -join "`n" } else { '' }
    $scriptRelative = Get-RelativePathCompat $Root $scriptFile.FullName
    $scriptHash = Get-Sha256 $scriptFile.FullName
    return @"
# $episodeToken 视觉资产交接

schema_version: $SchemaVersion
剧本路径：$scriptRelative
剧本SHA256：$scriptHash
交接状态：DRAFT

## 人物出现

| 场次 | 源标签 | 实体ID | 资产化决策 | 状态维度 | 建议状态@ | 生效区间/切换锚 | 可见变化/证据 |
|:--|:--|:--|:--|:--|:--|:--|:--|
$peopleText

## 场景出现

| 场次 | 场次头原名 | 实体ID | 时段 | 资产化决策 | 建议状态@ | 状态/切换锚 | 可见结构证据 |
|:--|:--|:--|:--|:--|:--|:--|:--|
$sceneText

## 道具出现

| 场次 | 剧本标签 | 实体ID | 资产化决策 | 建议状态@ | 当前状态/持有人 | 状态变化/切换锚 | 近景/复用需求与证据 |
|:--|:--|:--|:--|:--|:--|:--|:--|
$propText

## 未解决项

$unresolvedText
"@.TrimStart()
}

function Get-TableDataLines([string]$Text, [string]$Heading) {
    $section = Get-SectionText $Text $Heading
    if (-not $section) { return @() }
    $tableLines = @($section -split '\r?\n' | Where-Object { $_ -match '^\s*\|' })
    if ($tableLines.Count -le 2) { return @() }
    return @($tableLines | Select-Object -Skip 2)
}

function Get-RowKey([string]$Line, [int[]]$Indexes) {
    $cells = @($Line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
    $parts = New-Object Collections.Generic.List[string]
    foreach ($index in $Indexes) {
        if ($index -lt $cells.Count) { $parts.Add($cells[$index].ToLowerInvariant()) }
    }
    return ($parts -join '|')
}

function Merge-TableSection([string]$Existing, [string]$Scaffold, [string]$Heading, [int[]]$KeyIndexes) {
    $existingMatch = [regex]::Match($Existing, '(?ms)^##\s+' + [regex]::Escape($Heading) + '\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
    $scaffoldMatch = [regex]::Match($Scaffold, '(?ms)^##\s+' + [regex]::Escape($Heading) + '\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
    if (-not $existingMatch.Success -or -not $scaffoldMatch.Success) { return $Existing }
    $existingTable = @($existingMatch.Groups['body'].Value -split '\r?\n' | Where-Object { $_ -match '^\s*\|' })
    $scaffoldTable = @($scaffoldMatch.Groups['body'].Value -split '\r?\n' | Where-Object { $_ -match '^\s*\|' })
    if ($existingTable.Count -lt 2 -or $scaffoldTable.Count -lt 2) { return $Existing }
    $rows = New-Object Collections.Generic.List[string]
    $keys = New-Object Collections.Generic.HashSet[string]
    $rowIndexByKey = @{}
    foreach ($row in ($existingTable | Select-Object -Skip 2)) {
        $key = Get-RowKey $row $KeyIndexes
        $rowIndexByKey[$key] = $rows.Count
        $rows.Add($row.TrimEnd())
        [void]$keys.Add($key)
    }
    foreach ($row in ($scaffoldTable | Select-Object -Skip 2)) {
        $key = Get-RowKey $row $KeyIndexes
        if (-not $keys.Contains($key)) {
            $rowIndexByKey[$key] = $rows.Count
            $rows.Add($row.TrimEnd()); [void]$keys.Add($key)
        } else {
            $index = [int]$rowIndexByKey[$key]
            $oldCells = @($rows[$index].Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
            $newCells = @($row.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
            if ($oldCells.Count -eq $newCells.Count) {
                for ($i = 0; $i -lt $oldCells.Count; $i++) {
                    if ($oldCells[$i] -match $PlaceholderPattern -and $newCells[$i] -notmatch $PlaceholderPattern) { $oldCells[$i] = $newCells[$i] }
                }
                $rows[$index] = Format-TableRow $oldCells
            }
        }
    }
    $replacement = "## $Heading`n`n$($existingTable[0].TrimEnd())`n$($existingTable[1].TrimEnd())"
    if ($rows.Count -gt 0) { $replacement += "`n" + ($rows -join "`n") }
    $replacement += "`n`n"
    return $Existing.Remove($existingMatch.Index, $existingMatch.Length).Insert($existingMatch.Index, $replacement)
}

function Merge-EpisodeScaffold([string]$Existing, [string]$Scaffold) {
    $merged = $Existing
    $sameScriptHash = (Get-MetadataValue $Existing '剧本SHA256') -eq (Get-MetadataValue $Scaffold '剧本SHA256')
    foreach ($key in @('剧本路径', '剧本SHA256')) {
        $value = Get-MetadataValue $Scaffold $key
        if ($merged -match ('(?m)^' + [regex]::Escape($key) + '[：:].*$')) {
            $merged = [regex]::Replace($merged, '(?m)^' + [regex]::Escape($key) + '[：:].*$', ($key + '：' + $value), 1)
        }
    }
    if (-not $sameScriptHash) { $merged = [regex]::Replace($merged, '(?m)^交接状态[：:].*$', '交接状态：DRAFT', 1) }
    $merged = Merge-TableSection $merged $Scaffold '人物出现' @(0, 1)
    $merged = Merge-TableSection $merged $Scaffold '场景出现' @(0, 1)
    $merged = Merge-TableSection $merged $Scaffold '道具出现' @(0, 1, 2)

    $existingIssues = @(Get-SectionText $merged '未解决项' -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^-\s*无\s*$' })
    # 已有文件的人工映射优先。新scaffold中的“源事实缺…”只用于新建文件；若Sync追加了占位行，
    # Preflight会直接从待分配/待补字段报错，避免把已由人工映射解决的旧标签重新写回未解决项。
    $newStateIssues = if ($sameScriptHash -and $existingIssues.Count -eq 0) {
        @()
    } else {
        @(Get-SectionText $Scaffold '未解决项' -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '状态变化待确认|状态/持有人变化待确认|资产化待确认' })
    }
    $issues = @(@($existingIssues) + @($newStateIssues) | Sort-Object -Unique)
    $issueText = if ($issues.Count -gt 0) { $issues -join "`n" } else { '- 无' }
    $issueMatch = [regex]::Match($merged, '(?ms)^##\s+未解决项\s*\r?\n.*\z')
    if ($issueMatch.Success) { $merged = $merged.Substring(0, $issueMatch.Index) + "## 未解决项`n`n$issueText" }
    return $merged.TrimEnd() + "`n"
}

$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$visualDir = Join-Path $root 'visual-assets'
$episodesDir = Join-Path $visualDir 'episodes'
$sourcePath = Join-Path $visualDir 'source-facts.md'
$indexPath = Join-Path $visualDir 'handoff.md'
$scriptsDir = Join-Path $root 'scripts'

if ($Mode -eq 'Init') {
    if ($FromEpisode -le 0) {
        $numbers = if (Test-Path -LiteralPath $scriptsDir -PathType Container) {
            @(Get-ChildItem -LiteralPath $scriptsDir -File -Filter 'EP-*.md' | ForEach-Object { Get-EpisodeNumber $_.Name } | Where-Object { $_ -gt 0 })
        } else { @() }
        $FromEpisode = if ($numbers.Count -gt 0) { (($numbers | Measure-Object -Maximum).Maximum + 1) } else { 1 }
    }
    [void](New-Item -ItemType Directory -Force -Path $episodesDir)
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { Write-Utf8 $sourcePath (New-SourceTemplate $FromEpisode) }
    $sourceData = Get-SourceData $sourcePath
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { Write-Utf8 $indexPath (New-EmptyIndex $root $sourcePath $sourceData.from_episode) }
    Write-Output ("ASSET-HANDOFF-INIT: from=EP-{0}; source={1}; index={2}" -f $sourceData.from_episode.ToString('D2'), $sourcePath, $indexPath)
    exit 0
}

if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    if ($Mode -eq 'Status') { Write-Output 'ASSET-HANDOFF-NOT-INITIALIZED'; exit 0 }
    throw "Visual handoff is not initialized: $sourcePath"
}

$sourceData = Get-SourceData $sourcePath
$sourceMap = Get-SourceEntityMap $sourceData
$batchContract = Get-BatchContract $root $BatchContractPath

if ($Mode -eq 'Scaffold') {
    $episodes = Resolve-Episodes $PassEp
    [void](New-Item -ItemType Directory -Force -Path $episodesDir)
    foreach ($episode in $episodes) {
        $episodePath = Join-Path $episodesDir ("EP-{0}.md" -f $episode.ToString('D2'))
        if (Test-Path -LiteralPath $episodePath -PathType Leaf) {
            Write-Output ("ASSET-HANDOFF-SCAFFOLD-SKIP: {0}" -f $episodePath)
            continue
        }
        Write-Utf8 $episodePath (New-EpisodeScaffold $root $episode $sourceData $sourceMap)
        Write-Output ("ASSET-HANDOFF-SCAFFOLD: {0}" -f $episodePath)
    }
    exit 0
}

if ($Mode -eq 'Sync') {
    $episodes = Resolve-Episodes $PassEp
    [void](New-Item -ItemType Directory -Force -Path $episodesDir)
    $pendingTexts = @{}
    $pendingKinds = @{}
    foreach ($episode in $episodes) {
        $episodePath = Join-Path $episodesDir ("EP-{0}.md" -f $episode.ToString('D2'))
        $scaffold = New-EpisodeScaffold $root $episode $sourceData $sourceMap
        if (Test-Path -LiteralPath $episodePath -PathType Leaf) {
            $pendingTexts[$episode] = Merge-EpisodeScaffold (Read-Utf8 $episodePath) $scaffold
            $pendingKinds[$episode] = 'SYNC'
        } else {
            $pendingTexts[$episode] = $scaffold
            $pendingKinds[$episode] = 'SCAFFOLD'
        }
    }
    $throughEpisode = [int](($episodes | Measure-Object -Maximum).Maximum)
    $stateResults = @(Get-StateScanResults $root $throughEpisode $episodes $pendingTexts)
    $stateErrors = @(Get-MixedBaseStateErrors $stateResults)
    if ($stateErrors.Count -gt 0) {
        foreach ($issue in $stateErrors) { Write-Output ("ASSET-HANDOFF-SYNC-STATE-FAIL: {0}" -f $issue) }
        Write-Output 'ASSET-HANDOFF-SYNC-ROLLBACK: no episode handoff file was changed'
        exit 1
    }
    foreach ($episode in $episodes) {
        $episodePath = Join-Path $episodesDir ("EP-{0}.md" -f $episode.ToString('D2'))
        Write-Utf8 $episodePath ([string]$pendingTexts[$episode])
        Write-Output (("ASSET-HANDOFF-{0}: {1}" -f $pendingKinds[$episode], $episodePath))
    }
    Write-Output ("ASSET-HANDOFF-SYNC-STATE-PASS: through=EP-{0}" -f $throughEpisode.ToString('D2'))
    exit 0
}

if ($Mode -eq 'Preflight') {
    $episodes = Resolve-Episodes $PassEp
    $failed = 0
    foreach ($episode in $episodes) {
        $result = Get-EpisodeValidation $root $episode $sourceData $sourceMap $true
        foreach ($issue in (Get-ContractTransitionErrors $batchContract $result)) { $result.errors += [string]$issue }
        if ($result.errors.Count -gt 0) {
            $failed++
            foreach ($issue in $result.errors) { Write-Output ("ASSET-HANDOFF-PREFLIGHT-FAIL: {0}" -f $issue) }
        } else {
            Write-Output ("ASSET-HANDOFF-PREFLIGHT-PASS: {0}" -f $result.token)
        }
    }
    if ($failed -gt 0) { exit 1 }
    exit 0
}

if ($Mode -eq 'Ready') {
    $episodes = Resolve-Episodes $PassEp
    foreach ($episode in $episodes) {
        $result = Get-EpisodeValidation $root $episode $sourceData $sourceMap $true
        foreach ($issue in (Get-ContractTransitionErrors $batchContract $result)) { $result.errors += [string]$issue }
        if ($result.errors.Count -gt 0) {
            foreach ($issue in $result.errors) { Write-Output ("ASSET-HANDOFF-READY-FAIL: {0}" -f $issue) }
            exit 1
        }
        $episodePath = Join-Path $episodesDir ("EP-{0}.md" -f $episode.ToString('D2'))
        $text = Read-Utf8 $episodePath
        $text = [regex]::Replace($text, '(?m)^交接状态[：:].*$', '交接状态：READY', 1)
        Write-Utf8 $episodePath $text
        Write-Output ("ASSET-HANDOFF-READY: EP-{0}" -f $episode.ToString('D2'))
    }
    exit 0
}

if ($Mode -eq 'Validate') {
    $episodes = Resolve-Episodes $PassEp
    $failed = 0
    $validationIssues = New-Object Collections.Generic.HashSet[string]
    $validationResults = New-Object Collections.Generic.List[object]
    foreach ($episode in $episodes) {
        $result = Get-EpisodeValidation $root $episode $sourceData $sourceMap
        foreach ($issue in (Get-ContractTransitionErrors $batchContract $result)) { $result.errors += [string]$issue }
        $validationResults.Add($result)
        if ($result.errors.Count -gt 0) {
            $failed++
            foreach ($issue in $result.errors) { [void]$validationIssues.Add([string]$issue) }
        } else {
            Write-Output ("ASSET-HANDOFF-PASS: {0}" -f $result.token)
        }
    }
    foreach ($issue in (Get-MixedBaseStateErrors ($validationResults.ToArray()))) {
        $failed++
        [void]$validationIssues.Add([string]$issue)
    }
    if ($failed -gt 0) {
        foreach ($issue in ($validationIssues | Sort-Object)) { Write-Output ("ASSET-HANDOFF-FAIL: {0}" -f $issue) }
        exit 1
    }
    exit 0
}

if ($Mode -eq 'Index') {
    $scriptFiles = if (Test-Path -LiteralPath $scriptsDir -PathType Container) { @(Get-ChildItem -LiteralPath $scriptsDir -File -Filter 'EP-*.md') } else { @() }
    $requiredEpisodes = @($scriptFiles | ForEach-Object { Get-EpisodeNumber $_.Name } | Where-Object { $_ -ge $sourceData.from_episode } | Sort-Object -Unique)
    if ($requiredEpisodes.Count -eq 0) {
        Write-Utf8 $indexPath (New-EmptyIndex $root $sourcePath $sourceData.from_episode)
        Write-Output 'ASSET-HANDOFF-INDEX: EMPTY'
        exit 0
    }
    $incrementalEpisodes = if ($PassEp) { @(Resolve-Episodes $PassEp) } else { @() }
    $useIncremental = ($incrementalEpisodes.Count -gt 0 -and (Test-Path -LiteralPath $indexPath -PathType Leaf))
    $oldIndexRows = if ($useIncremental) { @(ConvertFrom-MarkdownTable (Read-Utf8 $indexPath) '分集交接文件') } else { @() }
    $results = New-Object Collections.Generic.List[object]
    $errors = New-Object Collections.Generic.List[string]
    foreach ($episode in $requiredEpisodes) {
        $result = $null
        if ($useIncremental -and $episode -notin $incrementalEpisodes) {
            $token = 'EP-' + $episode.ToString('D2')
            $oldRow = @($oldIndexRows | Where-Object { $_.'集数' -eq $token }) | Select-Object -First 1
            if ($oldRow) {
                $handoffPath = Join-Path $root ([string]$oldRow.'交接路径')
                $scriptPath = Join-Path $root ([string]$oldRow.'剧本路径')
                if ((Test-Path -LiteralPath $handoffPath -PathType Leaf) -and (Test-Path -LiteralPath $scriptPath -PathType Leaf) -and
                    (Get-Sha256 $handoffPath) -eq [string]$oldRow.'交接SHA256' -and (Get-Sha256 $scriptPath) -eq [string]$oldRow.'剧本SHA256') {
                    $handoffText = Read-Utf8 $handoffPath
                    $result = [ordered]@{
                        episode = $episode; token = $token; errors = @(); path = $handoffPath; script = $scriptPath
                        script_hash = Get-Sha256 $scriptPath
                        people = @(ConvertFrom-MarkdownTable $handoffText '人物出现')
                        scenes = @(ConvertFrom-MarkdownTable $handoffText '场景出现')
                        props = @(ConvertFrom-MarkdownTable $handoffText '道具出现')
                    }
                }
            }
        }
        if (-not $result) { $result = Get-EpisodeValidation $root $episode $sourceData $sourceMap }
        $results.Add($result)
        foreach ($issue in $result.errors) { $errors.Add($issue) }
    }
    foreach ($issue in (Get-MixedBaseStateErrors ($results.ToArray()))) { $errors.Add($issue) }
    if ($errors.Count -gt 0) {
        foreach ($issue in ($errors | Sort-Object -Unique)) { Write-Output ("ASSET-HANDOFF-FAIL: {0}" -f $issue) }
        exit 1
    }

    $fileLines = New-Object Collections.Generic.List[string]
    $referenceById = @{}
    foreach ($result in $results) {
        $handoffRelative = Get-RelativePathCompat $root $result.path
        $scriptRelative = Get-RelativePathCompat $root $result.script
        $fileLines.Add("| $($result.token) | $scriptRelative | $($result.script_hash) | $handoffRelative | $(Get-Sha256 $result.path) | READY |")
        foreach ($row in @($result.people) + @($result.scenes) + @($result.props)) {
            $id = [string]$row.'实体ID'
            if (-not $referenceById.ContainsKey($id)) { $referenceById[$id] = [ordered]@{ episodes = New-Object Collections.Generic.List[string]; assets = New-Object Collections.Generic.List[string] } }
            if (-not $referenceById[$id].episodes.Contains($result.token)) { $referenceById[$id].episodes.Add($result.token) }
            $assetProperty = $row.PSObject.Properties['建议状态@']
            if ($assetProperty -and $assetProperty.Value -match '^@' -and -not $referenceById[$id].assets.Contains([string]$assetProperty.Value)) { $referenceById[$id].assets.Add([string]$assetProperty.Value) }
        }
    }

    $entityLines = New-Object Collections.Generic.List[string]
    foreach ($id in ($referenceById.Keys | Sort-Object)) {
        $entity = $sourceMap.by_id[$id]
        $assets = if ($referenceById[$id].assets.Count -gt 0) { $referenceById[$id].assets -join '、' } else { '无' }
        $episodes = $referenceById[$id].episodes -join '、'
        $aliases = if ($entity.aliases.Count -gt 0) { $entity.aliases -join '、' } else { '无' }
        $entityLines.Add("| $id | $($entity.type) | $($entity.name) | $assets | $aliases | $episodes | $(Get-RelativePathCompat $root $sourcePath) |")
    }
    $coverage = if ($requiredEpisodes.Count -eq 1) { 'EP-' + $requiredEpisodes[0].ToString('D2') } else { 'EP-' + $requiredEpisodes[0].ToString('D2') + '–EP-' + $requiredEpisodes[-1].ToString('D2') }
    $indexText = @"
# comic-adapt 视觉资产事实交接

schema_version: $SchemaVersion
交接状态：READY
要求起始集：EP-$($sourceData.from_episode.ToString('D2'))
覆盖范围：$coverage
源事实路径：$(Get-RelativePathCompat $root $sourcePath)
源事实SHA256：$(Get-Sha256 $sourcePath)
生成时间：$((Get-Date).ToString('o'))

## 分集交接文件

| 集数 | 剧本路径 | 剧本SHA256 | 交接路径 | 交接SHA256 | 状态 |
|:--|:--|:--|:--|:--|:--|
$($fileLines -join "`n")

## 全局实体索引

| 实体ID | 类型 | 剧本规范名 | 建议@集合 | 别名 | 出现集 | 源事实路径 |
|:--|:--|:--|:--|:--|:--|:--|
$($entityLines -join "`n")

## 未解决项

- 无
"@.TrimStart()
    Write-Utf8 $indexPath $indexText
    $indexMode = if ($useIncremental) { 'incremental' } else { 'full' }
    Write-Output ("ASSET-HANDOFF-INDEX-PASS: mode={0}; episodes={1}; entities={2}; path={3}" -f $indexMode, $results.Count, $entityLines.Count, $indexPath)
    exit 0
}

if ($Mode -eq 'Status') {
    $scriptFiles = if (Test-Path -LiteralPath $scriptsDir -PathType Container) { @(Get-ChildItem -LiteralPath $scriptsDir -File -Filter 'EP-*.md') } else { @() }
    $requiredEpisodes = @($scriptFiles | ForEach-Object { Get-EpisodeNumber $_.Name } | Where-Object { $_ -ge $sourceData.from_episode } | Sort-Object -Unique)
    if ($requiredEpisodes.Count -eq 0) { Write-Output ("ASSET-HANDOFF-EMPTY: from=EP-{0}" -f $sourceData.from_episode.ToString('D2')); exit 0 }
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { Write-Output 'ASSET-HANDOFF-FAIL: handoff.md missing'; exit 1 }
    $indexText = Read-Utf8 $indexPath
    $errors = New-Object Collections.Generic.List[string]
    $statusResults = New-Object Collections.Generic.List[object]
    if ((Get-MetadataValue $indexText 'schema_version') -ne $SchemaVersion) { $errors.Add('handoff.md schema mismatch') }
    if ((Get-MetadataValue $indexText '交接状态') -ne 'READY') { $errors.Add('handoff.md is not READY') }
    if ((Get-MetadataValue $indexText '源事实SHA256') -ne (Get-Sha256 $sourcePath)) { $errors.Add('source-facts hash is stale') }
    $indexRows = @(ConvertFrom-MarkdownTable $indexText '分集交接文件')
    $statusEpisodes = if ($PassEp) { @(Resolve-Episodes $PassEp) } else { @($requiredEpisodes) }
    foreach ($episode in $requiredEpisodes) {
        $token = 'EP-' + $episode.ToString('D2')
        $row = @($indexRows | Where-Object { $_.'集数' -eq $token })
        if ($row.Count -ne 1) { $errors.Add("manifest coverage missing or duplicated: $token"); continue }
        $handoffFile = Join-Path $root ([string]$row[0].'交接路径')
        $scriptFile = Join-Path $root ([string]$row[0].'剧本路径')
        if (-not (Test-Path -LiteralPath $handoffFile -PathType Leaf)) { $errors.Add("manifest handoff file missing: $token") }
        elseif ((Get-Sha256 $handoffFile) -ne [string]$row[0].'交接SHA256') { $errors.Add("manifest handoff hash stale: $token") }
        if (-not (Test-Path -LiteralPath $scriptFile -PathType Leaf)) { $errors.Add("manifest script file missing: $token") }
        elseif ((Get-Sha256 $scriptFile) -ne [string]$row[0].'剧本SHA256') { $errors.Add("manifest script hash stale: $token") }
        if ($episode -in $statusEpisodes) {
            $result = Get-EpisodeValidation $root $episode $sourceData $sourceMap
            $statusResults.Add($result)
            foreach ($issue in $result.errors) { $errors.Add($issue) }
        }
    }
    foreach ($issue in (Get-MixedBaseStateErrors ($statusResults.ToArray()))) { $errors.Add($issue) }
    if ($errors.Count -gt 0) {
        foreach ($issue in ($errors | Sort-Object -Unique)) { Write-Output ("ASSET-HANDOFF-FAIL: {0}" -f $issue) }
        exit 1
    }
    $statusMode = if ($PassEp) { 'incremental' } else { 'full' }
    Write-Output ("ASSET-HANDOFF-PASS: mode={0}; checked={1}; indexed={2}; from=EP-{3}" -f $statusMode, $statusEpisodes.Count, $requiredEpisodes.Count, $sourceData.from_episode.ToString('D2'))
    exit 0
}

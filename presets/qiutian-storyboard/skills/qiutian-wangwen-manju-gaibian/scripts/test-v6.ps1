[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('comic-adapt-v6-test-' + [guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$resolvedTest = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTest.StartsWith($resolvedTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($resolvedTest) -notmatch '^comic-adapt-v6-test-[0-9a-f]{32}$') {
    throw "Unsafe test directory: $resolvedTest"
}

$quality = Join-Path $PSScriptRoot 'quality-receipt.ps1'
$ledger = Join-Path $PSScriptRoot 'ledger-receipt.ps1'
$performance = Join-Path $PSScriptRoot 'performance-report.ps1'
$contextPacket = Join-Path $PSScriptRoot 'build-context-packet.ps1'
$mapPreflight = Join-Path $PSScriptRoot 'map-preflight.ps1'
$visual = Join-Path $PSScriptRoot 'visual-handoff.ps1'
$policy = Join-Path $PSScriptRoot 'workflow-policy.ps1'
$exportScripts = Join-Path $PSScriptRoot 'export-scripts.ps1'
$sourceIndex = Join-Path $PSScriptRoot 'source-index.ps1'
$prefetch = Join-Path $PSScriptRoot 'episode-prefetch.ps1'
$goalRunner = Join-Path $PSScriptRoot 'goal-runner.ps1'
$scriptLint = Join-Path $PSScriptRoot 'script-lint.ps1'
$episodePipeline = Join-Path $PSScriptRoot 'episode-pipeline.ps1'
$script:passed = 0

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Name) {
    if ([string]$Actual -ne [string]$Expected) { throw "ASSERT FAILED [$Name]: expected=[$Expected] actual=[$Actual]" }
    $script:passed++
    Write-Output "TEST-PASS: $Name"
}

function Assert-Contains([object[]]$Items, [string]$Expected, [string]$Name) {
    if (@($Items) -notcontains $Expected) { throw "ASSERT FAILED [$Name]: missing=[$Expected] actual=[$(@($Items) -join ',')]" }
    $script:passed++
    Write-Output "TEST-PASS: $Name"
}

function Write-Utf8([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir) { [void](New-Item -ItemType Directory -Force -Path $dir) }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Invoke-Capture([scriptblock]$Command) {
    $output = & $Command 2>&1 | Out-String
    return [ordered]@{ output = $output.TrimEnd(); exit = $LASTEXITCODE }
}

try {
    [void](New-Item -ItemType Directory -Force -Path $testRoot)
    $qualityProject = Join-Path $testRoot 'quality'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $qualityProject 'scripts'))

    $scriptText = @(
        '剧名：《测试》',
        '集数：EP-02  测试',
        '对应剧情点：【剧情01】',
        '原著章节：第1章',
        '',
        '场次 02-1：内  测试屋  晨',
        '出场人物：甲',
        '△ （中景）甲推开门。',
        '甲',
        '原句。',
        '',
        '【卡黑】',
        '下集预告：甲将走出房门。'
    ) -join "`r`n"
    $ep02 = Join-Path $qualityProject 'scripts\EP-02.md'
    Write-Utf8 $ep02 $scriptText

    $result = Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Plan -Target EP-02 -Kind Script -Operation write }
    Assert-Equal $result.exit 0 'new rolling episode plan exits zero'
    $planPath = Join-Path $qualityProject '.comic-adapt-cache\quality-plans\EP-02.json'
    $plan = Get-Content -Raw -Encoding UTF8 -LiteralPath $planPath | ConvertFrom-Json
    Assert-Equal $plan.action 'RUN_DIFFERENTIAL' 'new rolling episode uses differential review'
    if (-not $plan.checker_brief -or -not (Test-Path -LiteralPath (Join-Path $qualityProject $plan.checker_brief.path))) { throw 'ASSERT FAILED [checker brief generated]' }
    $checkerBrief = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $qualityProject $plan.checker_brief.path)
    if ($checkerBrief -notmatch '### 1\.' -or $checkerBrief -notmatch '### 2\.' -or $checkerBrief -notmatch '### 7\.' -or $checkerBrief -notmatch '### 8\.' -or $checkerBrief -match '### 3\.') { throw 'ASSERT FAILED [checker brief dimension trimming]' }
    $script:passed++; Write-Output 'TEST-PASS: quality plan emits dimension-trimmed checker brief'

    $result = Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Record -Target EP-02 -Kind Script -Result PASS -Round 1 -CheckerMode Differential -CheckedDimensions '1,2,7,8' }
    Assert-Equal $result.exit 0 'record initial PASS'

    $changedPreview = $scriptText.Replace('甲将走出房门。', '甲将在门外遇见来客。')
    Write-Utf8 $ep02 $changedPreview
    [void](Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Plan -Target EP-02 -Kind Script -Operation write })
    $plan = Get-Content -Raw -Encoding UTF8 -LiteralPath $planPath | ConvertFrom-Json
    Assert-Equal $plan.action 'RUN_SCOPE_CHECKS' 'preview-only change uses scope check'
    Assert-Contains @($plan.changed_scopes) 'preview' 'preview scope detected'
    if (@($plan.changed_scopes) -contains 'core_semantic') { throw 'ASSERT FAILED [preview isolation]: core_semantic changed' }
    $script:passed++; Write-Output 'TEST-PASS: preview change does not invalidate core semantic'

    [void](Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Record -Target EP-02 -Kind Script -Result PASS -Round 1 -CheckerMode Targeted -CheckedDimensions preview -TouchedScopes 'preview,raw_file' -EventType scope_review })
    [void](Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Plan -Target EP-02 -Kind Script -Operation write })
    $plan = Get-Content -Raw -Encoding UTF8 -LiteralPath $planPath | ConvertFrom-Json
    Assert-Equal $plan.action 'REUSE_PASS' 'scope closure advances only checked baselines'
    $lfOnly = $changedPreview -replace "`r`n", "`n"
    Write-Utf8 $ep02 $lfOnly
    [void](Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Plan -Target EP-02 -Kind Script -Operation format })
    $plan = Get-Content -Raw -Encoding UTF8 -LiteralPath $planPath | ConvertFrom-Json
    Assert-Equal $plan.action 'RUN_MACHINE_ONLY' 'line-ending-only change uses machine check'

    Write-Utf8 $ep02 ($lfOnly.Replace('原句。', '语义已经改变。'))
    [void](Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Plan -Target EP-02 -Kind Script -Operation write })
    $plan = Get-Content -Raw -Encoding UTF8 -LiteralPath $planPath | ConvertFrom-Json
    Assert-Equal $plan.action 'RUN_FULL' 'core semantic change requires full review'

    $checkedBeforeEdit = (Get-FileHash -Algorithm SHA256 -LiteralPath $ep02).Hash.ToLowerInvariant()
    Write-Utf8 $ep02 ((Get-Content -Raw -Encoding UTF8 -LiteralPath $ep02) + "`n△ （近景）门闩轻响。")
    $hashRejected = $false
    try {
        & $quality -ProjectRoot $qualityProject -Mode Record -Target EP-02 -Kind Script -Result PASS -Round 2 -CheckerMode Full -CheckedDimensions '1,2,3,4,5,6,7,8' -CheckedHash $checkedBeforeEdit 2>$null | Out-Null
    } catch {
        $hashRejected = ($_.Exception.Message -match 'Refusing PASS')
    }
    Assert-Equal $hashRejected $true 'PASS rejects stale checked hash'

    $ep08 = Join-Path $qualityProject 'scripts\EP-08.md'
    Write-Utf8 $ep08 ($scriptText.Replace('EP-02', 'EP-08').Replace('场次 02-', '场次 08-'))
    $staleEp08Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ep08).Hash.ToLowerInvariant()
    Write-Utf8 $ep08 ((Get-Content -Raw -Encoding UTF8 -LiteralPath $ep08) + "`n△ （近景）门外落下一片叶子。")
    $inputFail = Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Record -Target EP-08 -Kind Script -Result FAIL -Round 1 -CheckerMode Differential -CheckedDimensions '1,2,7,8' -FailedDimensions 2 -CheckedHash $staleEp08Hash }
    Assert-Equal $inputFail.exit 2 'stale checker failure routes to FAIL_INPUT'
    $inputReceipt = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $qualityProject '.comic-adapt\quality\EP-08.json') | ConvertFrom-Json
    Assert-Equal $inputReceipt.status 'FAIL_INPUT' 'FAIL_INPUT is persisted distinctly'
    Assert-Equal $inputReceipt.failure_count 0 'FAIL_INPUT does not consume semantic failure budget'
    Assert-Equal $inputReceipt.next_action 'REBUILD_REVIEW_INPUT' 'FAIL_INPUT requests packet rebuild'

    $ep07 = Join-Path $qualityProject 'scripts\EP-07.md'
    Write-Utf8 $ep07 ($scriptText.Replace('EP-02', 'EP-07').Replace('场次 02-', '场次 07-'))
    $freshFail = Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Record -Target EP-07 -Kind Script -Result FAIL -Round 1 -CheckerMode Differential -CheckedDimensions '1,2,7,8' -FailedDimensions 2 -FreshCheckerRequired -StructuralChange }
    Assert-Equal $freshFail.exit 1 'fresh-checker failure records normally'
    [void](Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Plan -Target EP-07 -Kind Script -Operation write })
    $freshPlan = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $qualityProject '.comic-adapt-cache\quality-plans\EP-07.json') | ConvertFrom-Json
    Assert-Equal $freshPlan.action 'RUN_FULL' 'first failure with structural flag routes to FULL'
    [void](Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Record -Target EP-07 -Kind Script -Result PASS -Round 1 -CheckerMode Machine -EventType machine_closure })
    $freshReceipt = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $qualityProject '.comic-adapt\quality\EP-07.json') | ConvertFrom-Json
    Assert-Equal $freshReceipt.failure_count 1 'machine closure PASS preserves semantic failure count'

    $ep03 = Join-Path $qualityProject 'scripts\EP-03.md'
    Write-Utf8 $ep03 ($scriptText.Replace('EP-02', 'EP-03').Replace('场次 02-', '场次 03-'))
    $fail1 = Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Record -Target EP-03 -Kind Script -Result FAIL -Round 1 -CheckerMode Differential -CheckedDimensions '1,2,7,8' -FailedDimensions 2 }
    $fail2 = Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Record -Target EP-03 -Kind Script -Result FAIL -Round 2 -CheckerMode Targeted -CheckedDimensions 2 -FailedDimensions 2 }
    $fail3 = Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Record -Target EP-03 -Kind Script -Result FAIL -Round 3 -CheckerMode Full -CheckedDimensions '1,2,3,4,5,6,7,8' -FailedDimensions 2 -DependsOn EP-02 }
    Assert-Equal $fail1.exit 1 'first failure exits FAIL'
    Assert-Equal $fail2.exit 1 'second failure exits FAIL'
    Assert-Equal $fail3.exit 2 'third failure exits UNRESOLVED'
    $ep03Receipt = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $qualityProject '.comic-adapt\quality\EP-03.json') | ConvertFrom-Json
    Assert-Equal $ep03Receipt.status 'UNRESOLVED' 'third failure persists unresolved state'
    Assert-Equal $ep03Receipt.next_action 'CONTINUE_AND_REPORT_AT_BATCH_END' 'third failure continues work'
    $revalidatePlanResult = Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Revalidate -Target EP-03 -Kind Script -Operation write }
    Assert-Equal $revalidatePlanResult.exit 0 'UNRESOLVED can enter formal revalidation'
    $revalidatePlan = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $qualityProject '.comic-adapt-cache\quality-plans\EP-03.json') | ConvertFrom-Json
    Assert-Equal $revalidatePlan.action 'RUN_FULL_REVALIDATION' 'formal revalidation always generates a Full checker plan'
    $ep03CurrentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ep03).Hash.ToLowerInvariant()
    $revalidatePass = Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Revalidate -Target EP-03 -Kind Script -Result PASS -Round 4 -CheckerMode Full -CheckedDimensions '1,2,3,4,5,6,7,8,F' -CheckedHash $ep03CurrentHash -Note 'historical issue repaired and independently rechecked' }
    Assert-Equal $revalidatePass.exit 0 'Full hash-locked revalidation can close historical UNRESOLVED'
    $ep03Receipt = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $qualityProject '.comic-adapt\quality\EP-03.json') | ConvertFrom-Json
    Assert-Equal $ep03Receipt.status 'PASS' 'historical closure persists PASS receipt'
    Assert-Equal ([string]$ep03Receipt.events[-1].event_type) 'historical_closure' 'historical closure preserves the audit trail as a distinct event'
    $remainingUnresolved = @(Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $qualityProject '.comic-adapt\unresolved.json') | ConvertFrom-Json)
    Assert-Equal (@($remainingUnresolved | Where-Object { $_.target -eq 'EP-03' }).Count) 0 'Full PASS atomically removes only the matching unresolved item'

    $legacyProject = Join-Path $testRoot 'legacy'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $legacyProject 'scripts'))
    Write-Utf8 (Join-Path $legacyProject 'progress.md') "- 各集字数·质检：EP-01=1000字·PASS(2轮)；EP-04=1000字·PASS(2轮)`n"
    Write-Utf8 (Join-Path $legacyProject 'scripts\EP-01.md') ($scriptText.Replace('EP-02', 'EP-01').Replace('场次 02-', '场次 01-'))
    Write-Utf8 (Join-Path $legacyProject 'scripts\EP-04.md') ($scriptText.Replace('EP-02', 'EP-04').Replace('场次 02-', '场次 04-'))
    $migrate = Invoke-Capture { & $quality -ProjectRoot $legacyProject -Mode MigrateLegacy }
    Assert-Equal $migrate.exit 0 'legacy migration exits zero'
    [void](Invoke-Capture { & $quality -ProjectRoot $legacyProject -Mode Plan -Target EP-04 -Kind Script -Operation write })
    $legacyPlan = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $legacyProject '.comic-adapt-cache\quality-plans\EP-04.json') | ConvertFrom-Json
    Assert-Equal $legacyPlan.action 'REUSE_LEGACY_PASS' 'unchanged legacy PASS is reused'
    [void](Invoke-Capture { & $quality -ProjectRoot $legacyProject -Mode Plan -Target EP-01 -Kind Script -Operation write })
    $legacyFirstPlan = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $legacyProject '.comic-adapt-cache\quality-plans\EP-01.json') | ConvertFrom-Json
    Assert-Equal $legacyFirstPlan.action 'REUSE_LEGACY_PASS' 'unchanged legacy EP-01 is not forced through full review'

    $ledgerProject = Join-Path $testRoot 'ledger'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $ledgerProject 'scripts'))
    $ledgerScript = @(
        '剧名：《测试》',
        '集数：EP-05  收据',
        '场次 05-1：内  测试屋  晨',
        '出场人物：甲',
        '△ （中景）甲推开门。',
        '',
        '【卡黑】',
        '下集预告：无。',
        '【台账登记块】',
        '日历：EP-05=第1天·晨',
        '【快照】',
        '快照来源：EP-05',
        '- 末场时间点：第1天·晨',
        '- 地点：测试屋',
        '- 在场人物：甲',
        '- 已完成事件：开门',
        '- 未了动作：无',
        '- 集尾钩子：无',
        '【快照·完】',
        '场景名：测试屋（新增）',
        '【台账登记块·完】'
    ) -join "`r`n"
    $ledgerEp = Join-Path $ledgerProject 'scripts\EP-05.md'
    Write-Utf8 $ledgerEp $ledgerScript
    Write-Utf8 (Join-Path $ledgerProject 'progress.md') "## 故事内日历`n- 各集跨度：EP-05=第1天·晨`n`n## 场景名登记表`n| 场景名 | 首次出现集 | 说明 |`n|---|---|---|`n| 测试屋 | EP-05 | 无 |`n`n## 上集末场快照`n快照来源：EP-05`n"
    $ledgerPlan = Invoke-Capture { & $ledger -ProjectRoot $ledgerProject -PassEp 5 -Mode Plan }
    Assert-Equal $ledgerPlan.exit 0 'ledger plan exits zero'
    $bodyOnly = [regex]::Replace($ledgerScript, '(?ms)^【台账登记块】\s*\r?\n.*\z', '').TrimEnd() -replace "`r`n", "`n"
    Write-Utf8 $ledgerEp $bodyOnly
    $ledgerVerify = Invoke-Capture { & $ledger -ProjectRoot $ledgerProject -PassEp 5 -Mode Verify }
    Assert-Equal $ledgerVerify.exit 0 'ledger receipt survives CRLF to LF change'
    if ($ledgerVerify.output -notmatch 'LEDGER-RECEIPT-PASS') { throw 'ASSERT FAILED [ledger receipt marker]' }
    $script:passed++; Write-Output 'TEST-PASS: ledger receipt emits PASS marker'

    $staleEvidenceScript = @(
        '剧名：《测试》', '集数：EP-06  证据失效', '场次 06-1：内  测试屋  晨', '出场人物：甲',
        '△ （中景）甲关上门。', '【卡黑】', '【台账登记块】',
        '角色状态：甲｜已经关门｜证据=场次06-1「甲推开门」', '【台账登记块·完】'
    ) -join "`n"
    Write-Utf8 (Join-Path $ledgerProject 'scripts\EP-06.md') $staleEvidenceScript
    $staleEvidencePlan = Invoke-Capture { & $ledger -ProjectRoot $ledgerProject -PassEp 6 -Mode Plan }
    Assert-Equal $staleEvidencePlan.exit 1 'ledger plan blocks stale quoted evidence before checker'
    if ($staleEvidencePlan.output -notmatch 'stale quoted evidence') { throw "ASSERT FAILED [stale evidence diagnostic]: $($staleEvidencePlan.output)" }
    $script:passed++; Write-Output 'TEST-PASS: stale ledger evidence reports the exact draft entry'

    $progressWithCanon = (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $ledgerProject 'progress.md')) + "`n`n## 设定/数字口径表`n| 实体 | 类型 | 口径 | 首次确认集 | 依据 |`n|:--|:--|:--|:--|:--|`n| 灵戒 | 等级 | 五级 | EP-01 | 原著 |`n"
    Write-Utf8 (Join-Path $ledgerProject 'progress.md') $progressWithCanon
    $safeCanonScript = @(
        '剧名：《测试》', '集数：EP-07  口径补充', '场次 07-1：内  测试屋  晨', '出场人物：甲',
        '△ （近景）甲托起五级灵戒，戒内可存活物。', '【卡黑】', '【台账登记块】',
        '口径：灵戒｜等级｜五级、可存活物｜依据=原著第1章', '【台账登记块·完】'
    ) -join "`n"
    $ledgerEp07 = Join-Path $ledgerProject 'scripts\EP-07.md'
    Write-Utf8 $ledgerEp07 $safeCanonScript
    $safeCanonPlan = Invoke-Capture { & $ledger -ProjectRoot $ledgerProject -PassEp 7 -Mode Plan }
    Assert-Equal $safeCanonPlan.exit 0 'ledger plan accepts containing canon extension'
    $safeCanonReceipt = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $ledgerProject '.comic-adapt-cache\receipts\ledger-EP-07.json') | ConvertFrom-Json
    Assert-Contains @($safeCanonReceipt.suggestions | ForEach-Object { $_.action }) 'SAFE_CONTAINING_EXTENSION' 'ledger plan distinguishes safe canon extension'
    Write-Utf8 $ledgerEp07 ($safeCanonScript.Replace('五级、可存活物', '六级、可存活物'))
    $conflictCanonPlan = Invoke-Capture { & $ledger -ProjectRoot $ledgerProject -PassEp 7 -Mode Plan }
    Assert-Equal $conflictCanonPlan.exit 1 'ledger plan blocks non-containing canon conflict before checker'

    $newPropScript = @(
        '剧名：《测试》', '集数：EP-08  新道具', '场次 08-1：内  测试屋  晨', '出场人物：甲',
        '△ （近景）甲把缺角玉牌收入袖中。', '【卡黑】', '【台账登记块】',
        '道具：缺角玉牌｜首次出现｜场次08-1｜甲收入袖中', '【台账登记块·完】'
    ) -join "`n"
    Write-Utf8 (Join-Path $ledgerProject 'scripts\EP-08.md') $newPropScript
    $newPropPlan = Invoke-Capture { & $ledger -ProjectRoot $ledgerProject -PassEp 8 -Mode Plan }
    Assert-Equal $newPropPlan.exit 0 'ledger plan accepts new prop and emits routing suggestion'
    $newPropReceipt = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $ledgerProject '.comic-adapt-cache\receipts\ledger-EP-08.json') | ConvertFrom-Json
    $propSuggestion = @($newPropReceipt.suggestions | Where-Object { $_.action -eq 'INSERT_TABLE_TAIL_BEFORE_NEXT_H2' })
    if ($propSuggestion.Count -ne 1 -or $propSuggestion[0].suggested_row -notmatch '缺角玉牌.*EP-08') { throw 'ASSERT FAILED [precise prop insertion suggestion]' }
    $script:passed++; Write-Output 'TEST-PASS: first-appearance prop gets an exact section/action/row suggestion before Commit'

    $contextProject = Join-Path $testRoot 'context'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $contextProject 'scripts'))
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $contextProject 'novel'))
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $contextProject 'visual-assets\episodes'))
    Write-Utf8 (Join-Path $contextProject 'plot-map.md') @"
## 批次 1：第1章 ~ 第1章

### 【剧情01】接续
- **原著章节**：第1章
- **原著锚点**：第1章｜开门
- **原著内容**：甲与乙继续行动。
- **行动主体/承受主体**：甲｜乙
- **信息流**：甲知道门后有异响 → 告知乙 → 乙得知
- **冲突类型**：悬念揭示
- **冲突强度**：B
- **情绪钩子**：❓悬念牵引
- **必保清单**：甲开门｜归属甲｜先开门后见乙
- **改编处理**：原序保留｜不变项为主体与知情顺序
- **归属集数**：EP-02
- **状态**：待用

### 批次小结
- 章范围：第1章
- 剧情点范围：剧情01
- 分集映射：EP-02=剧情01
- 强度序列：EP-02=B
- 视觉事实增量：甲、乙
- 未决问题：无
"@
    Write-Utf8 (Join-Path $contextProject 'progress.md') "## 故事内日历`n- EP-01=第1天·晨`n`n## 上集末场快照`n- 甲与乙仍在屋内`n`n## 开放行动线清单`n- 甲继续开门`n`n## 未了期限`n- 无`n"
    Write-Utf8 (Join-Path $contextProject 'character-cards.md') "| 资产名 | 定位 |`n|---|---|`n| 甲 | 主角 |`n| 乙 | 同伴 |`n"
    Write-Utf8 (Join-Path $contextProject 'novel\第1章.txt') ('第1章 开门。' + ('原文事实。' * 200))
    $contextEp1Text = @(
        '剧名：《测试》', '集数：EP-01  前集', '场次 01-1：内  旧屋  晨', '出场人物：丙', '△ （中景）丙离开。',
        '场次 01-2：内  测试屋  晨', '出场人物：甲', '△ （中景）甲走到门边。',
        '场次 01-3：内  测试屋  晨', '出场人物：乙', '△ （近景）乙看向门闩。', '【卡黑】', '下集预告〔暂定〕：甲开门，乙听见异响。'
    ) -join "`n"
    $contextEp1 = Join-Path $contextProject 'scripts\EP-01.md'
    Write-Utf8 $contextEp1 $contextEp1Text
    $contextHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $contextEp1).Hash.ToLowerInvariant()
    $sourceFacts = @"
# 视觉资产源事实
schema_version: comic-adapt-visual-handoff/1.0
要求起始集：EP-01

## 人物与条件类型
| 实体ID | 类型 | 剧本规范名 | 建议@资产名 | 别名 | 设定性别/年龄 | 原文稳定外观 | 特殊标志 | 服装事实 | 资产化倾向 | 证据 |
|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|
| CHR-001 | 角色 | 甲 | @甲 | 无 | 男｜青年 | 黑发 | 无 | 白袍 | 必须建卡 | 原著第1章｜甲 |
| CHR-002 | 角色 | 乙 | @乙 | 无 | 女｜青年 | 长发 | 无 | 青衣 | 必须建卡 | 原著第1章｜乙 |
| CHR-003 | 角色 | 丙 | @丙 | 无 | 男｜青年 | 短发 | 无 | 灰衣 | 必须建卡 | 原著第1章｜丙 |

## 场景
| 实体ID | 场次头规范名 | 物理空间身份 | 建议@资产名 | 精确别名 | 世界层 | 固定结构/陈设/视觉符号 | 资产化倾向 | 证据 |
|:--|:--|:--|:--|:--|:--|:--|:--|:--|
| SCN-001 | 测试屋 | 独立房间 | @测试屋 | 无 | 现实层 | 木门 | 必须建卡 | 原著第1章｜屋 |
| SCN-002 | 旧屋 | 独立旧房 | @旧屋 | 无 | 现实层 | 旧门 | 建议建卡 | 原著第1章｜旧屋 |

## 道具
| 实体ID | 剧本正式名 | 建议@资产名 | 别名 | 尺寸/材质/形状/颜色 | 文字/关键标记 | 初始持有人/状态 | 资产化倾向 | 证据 |
|:--|:--|:--|:--|:--|:--|:--|:--|:--|
| PRP-001 | 长剑 | @长剑 | 剑 | 三尺｜金属 | 无 | 甲持有｜完整 | 必须建卡 | 原著第1章｜剑 |

## 待确认
- 无
"@
    Write-Utf8 (Join-Path $contextProject 'visual-assets\source-facts.md') $sourceFacts
    $contextVisual = @"
# EP-01 视觉资产交接
schema_version: comic-adapt-visual-handoff/1.0
剧本路径：scripts/EP-01.md
剧本SHA256：$contextHash
交接状态：READY

## 人物出现
| 场次 | 源标签 | 实体ID | 资产化决策 | 状态维度 | 建议状态@ | 生效区间/切换锚 | 可见变化/证据 |
|:--|:--|:--|:--|:--|:--|:--|:--|
| 01-1 | 丙 | CHR-003 | 建卡 | — | @丙 | 全剧本｜EP-01 集首 | EP-01 场次 01-1｜丙离开 |
| 01-2 | 甲 | CHR-001 | 建卡 | 服装 | @甲_白袍 | EP-01 起｜EP-01 集首 | EP-01 场次 01-2｜白袍 |
| 01-3 | 乙 | CHR-002 | 建卡 | — | @乙 | 全剧本｜EP-01 集首 | EP-01 场次 01-3｜乙看门 |

## 场景出现
| 场次 | 场次头原名 | 实体ID | 时段 | 资产化决策 | 建议状态@ | 状态/切换锚 | 可见结构证据 |
|:--|:--|:--|:--|:--|:--|:--|:--|
| 01-2 | 测试屋 | SCN-001 | 晨 | 建卡 | @测试屋 | 基础｜EP-01 集首 | 木门 |

## 道具出现
| 场次 | 剧本标签 | 实体ID | 资产化决策 | 建议状态@ | 当前状态/持有人 | 状态变化/切换锚 | 近景/复用需求与证据 |
|:--|:--|:--|:--|:--|:--|:--|:--|
| 01-2 | 长剑 | PRP-001 | 建卡 | @长剑 | 完整｜甲持有 | 无 | 关键近景 |

## 未解决项
- 无
"@
    Write-Utf8 (Join-Path $contextProject 'visual-assets\episodes\EP-01.md') $contextVisual
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $contextProject '.comic-adapt\quality'))
    Write-Utf8 (Join-Path $contextProject '.comic-adapt\quality\EP-01.json') '{"target":"EP-01","status":"PASS","depends_on":["MAP-BATCH-0"]}'
    Write-Utf8 (Join-Path $contextProject '.comic-adapt\unresolved.json') '[{"target":"MAP-BATCH-1","note":"affects EP-02 and 剧情01","depends_on":["EP-99"]}]'
    $missingWriteBlocked = $false
    try {
        & $contextPacket -ProjectRoot $contextProject -Episode 2 -Stage Review 2>&1 | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch 'requires a signed Write packet and writer brief') { throw }
        $missingWriteBlocked = $true
    }
    Assert-Equal $missingWriteBlocked $true 'review packet requires signed Write context'
    $contextResult = Invoke-Capture { & $contextPacket -ProjectRoot $contextProject -Episode 2 -Stage Write }
    Assert-Equal $contextResult.exit 0 'context packet optimized fixture builds'
    $packetData = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $contextProject '.comic-adapt-cache\packets\EP-02.json') | ConvertFrom-Json
    $writerBriefPath = Join-Path $contextProject '.comic-adapt-cache\briefs\EP-02.writer.md'
    Assert-Equal (Test-Path -LiteralPath $writerBriefPath) $true 'write packet emits writer brief'
    Assert-Equal ([string]$packetData.writer_brief.sha256) ((Get-FileHash -Algorithm SHA256 -LiteralPath $writerBriefPath).Hash.ToLowerInvariant()) 'write packet signs writer brief'
    $writerBriefText = Get-Content -Raw -Encoding UTF8 -LiteralPath $writerBriefPath
    if ($writerBriefText -match '当前故事日：第') { throw 'ASSERT FAILED [legacy absolute calendar leaked into writer brief]' }
    $script:passed++; Write-Output 'TEST-PASS: writer brief freezes legacy absolute calendar'
    if ($packetData.episode_spec.previous_preview -notmatch '下集预告〔暂定〕') { throw 'ASSERT FAILED [tentative preview extraction]' }
    $script:passed++; Write-Output 'TEST-PASS: tentative preview is extracted'
    Assert-Contains @($packetData.episode_spec.required_characters) '甲' 'actor field supplies character'
    Assert-Contains @($packetData.episode_spec.required_characters) '乙' 'information flow supplies character'
    Assert-Contains @($packetData.episode_spec.unresolved_dependencies) 'MAP-BATCH-1' 'unresolved map dependency propagates'
    Assert-Contains @($packetData.episode_spec.unresolved_dependencies) 'EP-99' 'nested unresolved dependency propagates'
    Assert-Equal $packetData.prewrite_contracts.gate_status 'READY' 'four-contract prewrite gate is ready'
    Assert-Equal $packetData.episode_spec.prewrite_gate 'READY' 'episode spec exposes prewrite gate'
    if (-not $packetData.context_layers.static_sha256 -or -not $packetData.context_layers.seam_sha256) { throw 'ASSERT FAILED [layered context hashes]' }
    $script:passed++; Write-Output 'TEST-PASS: write packet separates static and seam hashes'
    $visualIds = @($packetData.visual_handoff.relevant_source_facts.people_and_conditional | ForEach-Object { $_.'实体ID' })
    if ($visualIds -contains 'CHR-003') { throw 'ASSERT FAILED [write packet visual trimming]: stale first-scene entity leaked' }
    $script:passed++; Write-Output 'TEST-PASS: write packet excludes irrelevant previous visual entities'
    if ($writerBriefText -notmatch '## 必保覆盖骨架' -or @($packetData.evidence_capsule.coverage).Count -lt 1) { throw 'ASSERT FAILED [must-keep coverage skeleton]' }
    $script:passed++; Write-Output 'TEST-PASS: write packet emits deterministic must-keep coverage skeleton'
    Assert-Equal $packetData.context_budget.status 'PASS' 'context packet stays inside compact writer/packet budgets'
    if ([int]$packetData.context_budget.writer_brief_estimated_tokens -gt 3500 -or [int]$packetData.context_budget.write_packet_estimated_tokens -gt 10000) { throw 'ASSERT FAILED [context budget limits]' }
    $script:passed++; Write-Output 'TEST-PASS: compact writer brief and write packet stay below configured token limits'

    $contextEp2 = Join-Path $contextProject 'scripts\EP-02.md'
    Write-Utf8 $contextEp2 @"
剧名：《测试》
集数：EP-02  开门
场次 02-1：内  测试屋  晨
出场人物：甲；乙
△ （中景）甲推开木门，乙侧身看向门外。
甲
门开了。
【卡黑】
"@
    Assert-Equal (Invoke-Capture { & $visual -ProjectRoot $contextProject -Mode Sync -PassEp 2 }).exit 0 'current visual sync prepares review delta'
    Assert-Equal (Invoke-Capture { & $contextPacket -ProjectRoot $contextProject -Episode 2 -Stage Write }).exit 0 'write packet refresh signs current script and visual'
    $reviewDelta = Invoke-Capture { & $contextPacket -ProjectRoot $contextProject -Episode 2 -Stage Review }
    Assert-Equal $reviewDelta.exit 0 'review packet uses signed-base delta path'
    $reviewData = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $contextProject '.comic-adapt-cache\packets\EP-02.review.json') | ConvertFrom-Json
    Assert-Equal $reviewData.validation_mode 'SIGNED_BASE_MUTABLE_DELTA' 'review packet avoids full authority reparse'

    $mapProject = Join-Path $testRoot 'map-preflight'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $mapProject 'visual-assets'))
    Write-Utf8 (Join-Path $mapProject 'plot-map.md') (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $contextProject 'plot-map.md'))
    $badSourceFacts = $sourceFacts.Replace('| CHR-002 | 角色 | 乙 | @乙 | 无 |', '| CHR-002 | 角色 | 乙 | @乙 | 甲 |').Replace('| SCN-001 | 测试屋 |', '| CHR-001 | 测试屋 |')
    Write-Utf8 (Join-Path $mapProject 'visual-assets\source-facts.md') $badSourceFacts
    $mapCheck = Invoke-Capture { & $mapPreflight -ProjectRoot $mapProject -Target MAP-BATCH-1 }
    Assert-Equal $mapCheck.exit 1 'map preflight blocks invalid source facts'
    if ($mapCheck.output -notmatch 'duplicate entity ID' -or $mapCheck.output -notmatch 'multiple entities') { throw "ASSERT FAILED [map preflight diagnostics]: $($mapCheck.output)" }
    $script:passed++; Write-Output 'TEST-PASS: map preflight reports duplicate IDs and alias conflicts'

    $ep02VisualScript = @(
        '剧名：《测试》', '集数：EP-02  继承', '场次 02-1：内  测试屋  晨', '出场人物：甲',
        '△ （中景）甲按住长剑，望向木门。', '【卡黑】', '下集预告：甲继续前行。'
    ) -join "`n"
    Write-Utf8 (Join-Path $contextProject 'scripts\EP-02.md') $ep02VisualScript
    $visualSync = Invoke-Capture { & $visual -ProjectRoot $contextProject -Mode Sync -PassEp 2 }
    Assert-Equal $visualSync.exit 0 'visual sync with inheritance exits zero'
    $ep02HandoffPath = Join-Path $contextProject 'visual-assets\episodes\EP-02.md'
    $ep02Handoff = Get-Content -Raw -Encoding UTF8 -LiteralPath $ep02HandoffPath
    if ($ep02Handoff -notmatch '@甲_白袍' -or $ep02Handoff -notmatch '完整｜甲持有') { throw 'ASSERT FAILED [stable visual inheritance]' }
    $script:passed++; Write-Output 'TEST-PASS: stable visual state and prop holder inherit'
    if ($ep02Handoff -match '待补') { throw 'ASSERT FAILED [automatic visual evidence]: stable rows still contain 待补' }
    $script:passed++; Write-Output 'TEST-PASS: stable visual rows receive automatic scene evidence'
    $visualContractPath = Join-Path $contextProject '.comic-adapt-cache\batches\BATCH-VISUAL.contract.json'
    Write-Utf8 $visualContractPath (([ordered]@{
        schema_version = 'comic-adapt-batch-contract/1.0'; batch_id = 'BATCH-VISUAL'; range = '2-2'; contract_status = 'FROZEN'
        episode_contracts = @([ordered]@{ episode = 'EP-02'; entity_refs = @('PRP-001'); asset_transitions = @('PRP-001:本集确认持有人状态'); ledger_delta = @() })
    } | ConvertTo-Json -Depth 8))
    Assert-Equal (Invoke-Capture { & $visual -ProjectRoot $contextProject -Mode Preflight -PassEp 2 -BatchContractPath $visualContractPath }).exit 0 'visual preflight covers explicit frozen prop transitions'
    $ep02WithoutProp = [regex]::Replace($ep02Handoff, '(?m)^\| 02-1 \| 长剑 \| PRP-001 \|.*\r?\n', '')
    Write-Utf8 $ep02HandoffPath $ep02WithoutProp
    $transitionCoverageFail = Invoke-Capture { & $visual -ProjectRoot $contextProject -Mode Preflight -PassEp 2 -BatchContractPath $visualContractPath }
    Assert-Equal $transitionCoverageFail.exit 1 'visual preflight blocks a frozen prop transition missing from the episode handoff'
    if ($transitionCoverageFail.output -notmatch 'frozen prop transition is absent') { throw 'ASSERT FAILED [visual contract transition diagnostic]' }
    $script:passed++; Write-Output 'TEST-PASS: visual transition failure names the missing frozen prop ID'
    Write-Utf8 $ep02HandoffPath $ep02Handoff
    $ep02Ready = $ep02Handoff.Replace('交接状态：DRAFT', '交接状态：READY')
    Write-Utf8 $ep02HandoffPath $ep02Ready
    $ep03VisualScript = @(
        '剧名：《测试》', '集数：EP-03  换装', '场次 03-1：内  测试屋  晨', '出场人物：甲',
        '△ （中景）甲换上黑袍，按住长剑。', '【卡黑】', '下集预告：无。'
    ) -join "`n"
    Write-Utf8 (Join-Path $contextProject 'scripts\EP-03.md') $ep03VisualScript
    [void](Invoke-Capture { & $visual -ProjectRoot $contextProject -Mode Sync -PassEp 3 })
    $ep03Handoff = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $contextProject 'visual-assets\episodes\EP-03.md')
    if ($ep03Handoff -notmatch '@甲_白袍' -or $ep03Handoff -notmatch '人物稳定状态变化待确认') { throw 'ASSERT FAILED [changed visual state routing]: historical state family or unresolved route missing' }
    if ($ep03Handoff -match '\|\s*@甲\s*\|') { throw 'ASSERT FAILED [changed visual state routing]: bare base asset was reintroduced' }
    $script:passed++; Write-Output 'TEST-PASS: visible clothing change preserves state family and routes unresolved without inventing a new state'
    $ep04VisualScript = @(
        '剧名：《测试》', '集数：EP-04  跨集继承', '场次 04-1：内  羊头坡测试屋  晨', '出场人物：甲',
        '△ （中景）甲按住长剑，环顾屋内。', '【卡黑】'
    ) -join "`n"
    Write-Utf8 (Join-Path $contextProject 'scripts\EP-04.md') $ep04VisualScript
    $visualSync04 = Invoke-Capture { & $visual -ProjectRoot $contextProject -Mode Sync -PassEp 4 }
    Assert-Equal $visualSync04.exit 0 'visual sync scans past non-ready/missing previous appearances'
    $ep04Handoff = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $contextProject 'visual-assets\episodes\EP-04.md')
    if ($ep04Handoff -notmatch '@甲_白袍' -or $ep04Handoff -notmatch '完整｜甲持有') { throw 'ASSERT FAILED [nearest READY state inheritance across gap]' }
    $script:passed++; Write-Output 'TEST-PASS: nearest READY person and prop states inherit across multi-episode gaps'
    if ($ep04Handoff -notmatch '\| 04-1 \| 羊头坡测试屋 \| SCN-001 \|') { throw 'ASSERT FAILED [unique scene containment alias]' }
    $script:passed++; Write-Output 'TEST-PASS: unique scene canonical/alias containment resolves compound scene headers'

    $ep05VisualScript = @(
        '剧名：《测试》', '集数：EP-05  原子同步', '场次 05-1：内  测试屋  晨', '出场人物：甲',
        '△ （中景）甲按住长剑。', '【卡黑】'
    ) -join "`n"
    Write-Utf8 (Join-Path $contextProject 'scripts\EP-05.md') $ep05VisualScript
    Assert-Equal (Invoke-Capture { & $visual -ProjectRoot $contextProject -Mode Sync -PassEp 5 }).exit 0 'visual sync creates an inherited transaction baseline'
    $ep05HandoffPath = Join-Path $contextProject 'visual-assets\episodes\EP-05.md'
    $ep05Bare = (Get-Content -Raw -Encoding UTF8 -LiteralPath $ep05HandoffPath).Replace('@甲_白袍', '@甲')
    Write-Utf8 $ep05HandoffPath $ep05Bare
    Write-Utf8 (Join-Path $contextProject 'scripts\EP-05.md') ($ep05VisualScript.Replace('甲按住长剑。', '甲按住长剑，向门边走去。'))
    $beforeFailedSyncHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ep05HandoffPath).Hash.ToLowerInvariant()
    $atomicSyncFail = Invoke-Capture { & $visual -ProjectRoot $contextProject -Mode Sync -PassEp 5 }
    Assert-Equal $atomicSyncFail.exit 1 'mixed base/state naming blocks visual Sync before authority write'
    Assert-Equal ((Get-FileHash -Algorithm SHA256 -LiteralPath $ep05HandoffPath).Hash.ToLowerInvariant()) $beforeFailedSyncHash 'failed visual Sync leaves the episode handoff byte-identical'
    if ($atomicSyncFail.output -notmatch 'baseline migration required' -or $atomicSyncFail.output -notmatch 'ROLLBACK') { throw 'ASSERT FAILED [visual atomic rollback diagnostic]' }
    $script:passed++; Write-Output 'TEST-PASS: failed visual Sync emits affected baseline migration and rollback diagnostics'

    $voiceSourceFacts = (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $contextProject 'visual-assets\source-facts.md')).Replace(
        '## 场景',
        "| VOC-001 | 不可见声音角色 | 门外人 | @门外人_声音 | 无 | 原文未明示 | 不可见｜不得设计脸部 | 仅声音 | 不适用 | 必须建卡 | 原著第1章｜门外只传来声音 |`n`n## 场景"
    )
    Write-Utf8 (Join-Path $contextProject 'visual-assets\source-facts.md') $voiceSourceFacts
    Write-Utf8 (Join-Path $contextProject 'scripts\EP-06.md') @"
剧名：《测试》
集数：EP-06  画外声
场次 06-1：内  测试屋  晨
出场人物：门外人（画外）
门外人（画外）
（低声）
别开门。
【卡黑】
"@
    Assert-Equal (Invoke-Capture { & $visual -ProjectRoot $contextProject -Mode Sync -PassEp 6 }).exit 0 'invisible voice asset syncs without false state-family failure'
    $voicePreflight = Invoke-Capture { & $visual -ProjectRoot $contextProject -Mode Preflight -PassEp 6 }
    Assert-Equal $voicePreflight.exit 0 'invisible voice permits unknown identity only with explicit no-face source fact'
    $voiceHandoff = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $contextProject 'visual-assets\episodes\EP-06.md')
    if ($voiceHandoff -notmatch '\| 身份呈现 \| @门外人_声音 \|') { throw 'ASSERT FAILED [invisible voice identity presentation dimension]' }
    $script:passed++; Write-Output 'TEST-PASS: invisible voice _声音 suffix is routed as identity presentation'

    $oldPolicyProject = Join-Path $testRoot 'policy-old'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $oldPolicyProject 'scripts'))
    Write-Utf8 (Join-Path $oldPolicyProject 'scripts\EP-01.md') $scriptText.Replace('EP-02', 'EP-01').Replace('场次 02-', '场次 01-')
    Write-Utf8 (Join-Path $oldPolicyProject 'scripts\EP-04.md') $scriptText.Replace('EP-02', 'EP-04').Replace('场次 02-', '场次 04-')
    Assert-Equal (Invoke-Capture { & $policy -ProjectRoot $oldPolicyProject -Mode Init }).exit 0 'V6 policy initializes old project'
    $oldPolicy = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $oldPolicyProject '.comic-adapt\policy.json') | ConvertFrom-Json
    Assert-Equal $oldPolicy.preview_disabled_from_episode 5 'old project disables preview from next episode'
    Assert-Equal $oldPolicy.report_policy 'final_only' 'V6 defaults to final-only reporting'
    Assert-Equal $oldPolicy.parallel_mode 'safe_pipeline' 'V6 defaults to safe pipeline parallelism'
    Assert-Equal $oldPolicy.prefetch_window 3 'V6 defaults to three-episode prefetch window'
    Assert-Equal $oldPolicy.pre_review_scheduler 'adaptive' 'V6 defaults to adaptive pre-review scheduling'
    Assert-Equal $oldPolicy.commit_journal $true 'V6 enables commit journal'
    Assert-Equal $oldPolicy.time_model 'source_relative' 'V6 freezes legacy calendar and uses source-relative time'
    Assert-Equal $oldPolicy.draft_gate_before_parallel $true 'V6 gates draft before parallel workers'
    Assert-Equal $oldPolicy.visual_history_inheritance 'nearest_ready_per_entity' 'V6 uses per-entity nearest READY visual inheritance'

    $newPolicyProject = Join-Path $testRoot 'policy-new'
    [void](New-Item -ItemType Directory -Force -Path $newPolicyProject)
    Assert-Equal (Invoke-Capture { & $policy -ProjectRoot $newPolicyProject -Mode Init }).exit 0 'V6 policy initializes new project'
    $newPolicy = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $newPolicyProject '.comic-adapt\policy.json') | ConvertFrom-Json
    Assert-Equal $newPolicy.preview_disabled_from_episode 1 'new project disables preview from EP-01'
    $obsoletePolicyKeys = @('legacy_calendar_policy', 'compatibility_mode', 'legacy_preview_scope', 'legacy_calendar_scope') | Where-Object { $newPolicy.PSObject.Properties[$_] }
    Assert-Equal @($obsoletePolicyKeys).Count 0 'new policy omits unused compatibility metadata'

    $missingPipelineProject = Join-Path $testRoot 'pipeline-missing-packet'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $missingPipelineProject 'scripts'))
    Write-Utf8 (Join-Path $missingPipelineProject 'scripts\EP-01.md') $scriptText.Replace('EP-02', 'EP-01').Replace('场次 02-', '场次 01-')
    $missingPipelineBlocked = $false
    try {
        & $episodePipeline -ProjectRoot $missingPipelineProject -Episode 1 -Mode PreReview 2>&1 | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch 'Missing V6 Write packet') { throw }
        $missingPipelineBlocked = $true
    }
    Assert-Equal $missingPipelineBlocked $true 'pipeline blocks missing V6 Write packet'

    $lintProject = Join-Path $testRoot 'lint-v6'
    [void](New-Item -ItemType Directory -Force -Path $lintProject)
    [void](Invoke-Capture { & $policy -ProjectRoot $lintProject -Mode Init })
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $lintProject 'scripts'))
    $validExample = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot '..\references\script-example.md')
    $validNoPreview = [regex]::Replace($validExample, '(?m)^下集预告(?:〔[^〕\r\n]+〕)?[：:][^\r\n]*\r?\n?', '')
    $validNoPreview = $validNoPreview.Replace('8. 下集预告只指事不报答案→结尾块', '8. 单集以【卡黑】收束→结尾块')
    $lintEp = Join-Path $lintProject 'scripts\EP-01.md'
    Write-Utf8 $lintEp $validNoPreview
    $noPreviewLint = Invoke-Capture { & $scriptLint -Path $lintEp -Draft }
    Assert-Equal $noPreviewLint.exit 0 'V6 script ending at card-black passes lint'
    $relativeLedgerPlan = Invoke-Capture { & $ledger -ProjectRoot $lintProject -PassEp 1 -Mode Plan }
    Assert-Equal $relativeLedgerPlan.exit 0 'source-relative ledger block parses before review'
    if ($relativeLedgerPlan.output -notmatch 'LEDGER-BLOCK-PARSE-PASS') { throw "ASSERT FAILED [relative ledger parse marker]: $($relativeLedgerPlan.output)" }
    $script:passed++; Write-Output 'TEST-PASS: source-relative ledger plan emits parse gate'
    Write-Utf8 $lintEp ($validNoPreview.Replace('｜引爆', '｜推进'))
    $badActionLint = Invoke-Capture { & $scriptLint -Path $lintEp -Draft }
    Assert-Equal $badActionLint.exit 1 'draft lint rejects action verb 推进 before Commit'
    Write-Utf8 $lintEp $validNoPreview
    Write-Utf8 $lintEp ($validNoPreview.Replace('【卡黑】', "【卡黑】`n`n下集预告：禁用后不应出现。"))
    $previewLint = Invoke-Capture { & $scriptLint -Path $lintEp -Draft }
    Assert-Equal $previewLint.exit 1 'V6 preview is rejected from disabled episode'
    if ($previewLint.output -notmatch 'V6策略自EP-01起禁用下集预告') { throw "ASSERT FAILED [V6 preview diagnostic]: $($previewLint.output)" }
    $script:passed++; Write-Output 'TEST-PASS: V6 preview lint reports policy boundary'
    $legacyPreviewLint = Invoke-Capture { & $scriptLint -Path (Join-Path $oldPolicyProject 'scripts\EP-04.md') -Draft }
    if ($legacyPreviewLint.output -match 'V6策略自EP-05起禁用下集预告') { throw 'ASSERT FAILED [legacy preview compatibility]: old preview was rejected' }
    $script:passed++; Write-Output 'TEST-PASS: pre-boundary legacy preview remains compatible'

    $v6QualityProject = Join-Path $testRoot 'quality-v6'
    [void](New-Item -ItemType Directory -Force -Path $v6QualityProject)
    [void](Invoke-Capture { & $policy -ProjectRoot $v6QualityProject -Mode Init })
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $v6QualityProject 'scripts'))
    $v6Ep = Join-Path $v6QualityProject 'scripts\EP-02.md'
    Write-Utf8 $v6Ep $scriptText
    [void](Invoke-Capture { & $quality -ProjectRoot $v6QualityProject -Mode Record -Target EP-02 -Kind Script -Result PASS -Round 1 -CheckerMode Differential -CheckedDimensions '1,2,7,8' })
    Write-Utf8 $v6Ep $scriptText.Replace('甲将走出房门。', '这段旧预告文字变化但不再属于签发作用域。')
    [void](Invoke-Capture { & $quality -ProjectRoot $v6QualityProject -Mode Plan -Target EP-02 -Kind Script -Operation write })
    $v6Plan = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $v6QualityProject '.comic-adapt-cache\quality-plans\EP-02.json') | ConvertFrom-Json
    Assert-Equal $v6Plan.preview_enabled $false 'V6 quality plan disables preview scope'
    Assert-Equal $v6Plan.action 'RUN_MACHINE_ONLY' 'preview-only legacy text edit requires machine check only under V6'
    if (@($v6Plan.changed_scopes) -contains 'preview') { throw 'ASSERT FAILED [V6 quality preview scope]: preview leaked into changed scopes' }
    $script:passed++; Write-Output 'TEST-PASS: V6 quality receipt ignores preview scope'

    $ep10 = Join-Path $v6QualityProject 'scripts\EP-10.md'
    Write-Utf8 $ep10 $scriptText
    $ep10FirstPlan = Invoke-Capture { & $quality -ProjectRoot $v6QualityProject -Mode Plan -Target EP-10 -Kind Script -Operation write }
    if ($ep10FirstPlan.output -notmatch 'action=RUN_FULL') { throw "ASSERT FAILED [scheduled full first plan]: $($ep10FirstPlan.output)" }
    [void](Invoke-Capture { & $quality -ProjectRoot $v6QualityProject -Mode Record -Target EP-10 -Kind Script -Result PASS -Round 1 -CheckerMode Full -CheckedDimensions '1,2,3,4,5,6,7,8' })
    [void](Invoke-Capture { & $quality -ProjectRoot $v6QualityProject -Mode Plan -Target EP-10 -Kind Script -Operation write })
    $ep10Reuse = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $v6QualityProject '.comic-adapt-cache\quality-plans\EP-10.json') | ConvertFrom-Json
    Assert-Equal $ep10Reuse.action 'REUSE_PASS' 'scheduled FULL does not repeat after current core is signed'

    [void](New-Item -ItemType Directory -Force -Path (Join-Path $v6QualityProject 'visual-assets\episodes'))
    $ep06 = Join-Path $v6QualityProject 'scripts\EP-06.md'
    Write-Utf8 $ep06 $scriptText
    $visual06 = Join-Path $v6QualityProject 'visual-assets\episodes\EP-06.md'
    Write-Utf8 $visual06 "# EP-06 视觉资产交接`n剧本路径：scripts/EP-06.md`n剧本SHA256：abc`n交接状态：DRAFT`n`n## 人物出现`n`n| 场次 | 实体ID |`n|:--|:--|`n| 06-1 | CHR-001 |`n"
    [void](Invoke-Capture { & $quality -ProjectRoot $v6QualityProject -Mode Record -Target EP-06 -Kind Script -Result PASS -Round 1 -CheckerMode Differential -CheckedDimensions '1,2,7,8' })
    Write-Utf8 $visual06 ((Get-Content -Raw -Encoding UTF8 -LiteralPath $visual06).Replace('交接状态：DRAFT', '交接状态：READY').Replace('剧本SHA256：abc', '剧本SHA256：def'))
    [void](Invoke-Capture { & $quality -ProjectRoot $v6QualityProject -Mode Plan -Target EP-06 -Kind Script -Operation format })
    $visualStatusPlan = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $v6QualityProject '.comic-adapt-cache\quality-plans\EP-06.json') | ConvertFrom-Json
    Assert-Equal $visualStatusPlan.action 'REUSE_PASS' 'visual READY and script-SHA refresh do not change visual semantic scope'
    Write-Utf8 $visual06 ((Get-Content -Raw -Encoding UTF8 -LiteralPath $visual06).Replace('CHR-001', 'CHR-009'))
    [void](Invoke-Capture { & $quality -ProjectRoot $v6QualityProject -Mode Plan -Target EP-06 -Kind Script -Operation format })
    $visualSemanticPlan = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $v6QualityProject '.comic-adapt-cache\quality-plans\EP-06.json') | ConvertFrom-Json
    Assert-Equal $visualSemanticPlan.action 'RUN_SCOPE_CHECKS' 'visual semantic-only change is isolated from script core'
    $pipelineSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $episodePipeline
    if ($pipelineSource -notmatch 'unsignedVisualSemanticChange') { throw 'ASSERT FAILED [Commit visual semantic safety route]' }
    $script:passed++; Write-Output 'TEST-PASS: Commit preserves targeted checker routing for unsigned visual semantic changes'
    Write-Utf8 $visual06 ((Get-Content -Raw -Encoding UTF8 -LiteralPath $visual06).Replace('CHR-009', 'CHR-001'))
    Write-Utf8 $ep06 ($scriptText + "`n【台账登记块】`n口径：门=木门`n【台账登记块·完】`n")
    [void](Invoke-Capture { & $quality -ProjectRoot $v6QualityProject -Mode Plan -Target EP-06 -Kind Script -Operation format })
    $ledgerScopePlan = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $v6QualityProject '.comic-adapt-cache\quality-plans\EP-06.json') | ConvertFrom-Json
    Assert-Equal $ledgerScopePlan.action 'RUN_SCOPE_CHECKS' 'ledger/raw-only change is isolated from script core'
    $ep06Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ep06).Hash.ToLowerInvariant()
    Assert-Equal (Invoke-Capture { & $quality -ProjectRoot $v6QualityProject -Mode Record -Target EP-06 -Kind Script -Operation format -Result PASS -CheckerMode Machine -EventType machine_closure -TouchedScopes 'ledger,raw_file' -CheckedHash $ep06Hash }).exit 0 'machine closure signs validated ledger/raw-only scopes'
    [void](Invoke-Capture { & $quality -ProjectRoot $v6QualityProject -Mode Plan -Target EP-06 -Kind Script -Operation format })
    $ledgerClosedPlan = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $v6QualityProject '.comic-adapt-cache\quality-plans\EP-06.json') | ConvertFrom-Json
    Assert-Equal $ledgerClosedPlan.action 'REUSE_PASS' 'machine closure removes post-commit ledger/raw scope work'
    if ($pipelineSource -notmatch "RUN_MACHINE_ONLY', 'RUN_SCOPE_CHECKS" -or $pipelineSource -notmatch 'post-commit-machine-closure') { throw 'ASSERT FAILED [Commit scope closure routing]' }
    $script:passed++; Write-Output 'TEST-PASS: Commit route auto-closes validated ledger/raw-only scopes and preserves core semantics'

    [void](Invoke-Capture { & $policy -ProjectRoot $contextProject -Mode Init })
    $v6ContextResult = Invoke-Capture { & $contextPacket -ProjectRoot $contextProject -Episode 2 -Stage Write }
    Assert-Equal $v6ContextResult.exit 0 'V6 write packet builds without preview dependency'
    $v6Packet = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $contextProject '.comic-adapt-cache\packets\EP-02.json') | ConvertFrom-Json
    Assert-Equal $v6Packet.preview_enabled $false 'V6 context packet marks preview disabled'
    Assert-Equal $v6Packet.episode_spec.previous_preview '' 'V6 context packet omits previous preview'
    $v6WriterBrief = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $contextProject '.comic-adapt-cache\briefs\EP-02.writer.md')
    if ($v6WriterBrief -match '故事内日历|第\d+天') { throw 'ASSERT FAILED [absolute story calendar in V6 writer brief]' }
    $script:passed++; Write-Output 'TEST-PASS: V6 writer brief carries source-relative time only and no frozen absolute calendar'

    [void](New-Item -ItemType Directory -Force -Path (Join-Path $oldPolicyProject '.comic-adapt\quality'))
    Write-Utf8 (Join-Path $oldPolicyProject '.comic-adapt\quality\EP-04.json') '{"target":"EP-04","status":"PASS"}'
    $sourceBeforeExport = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $oldPolicyProject 'scripts\EP-04.md')
    $exportResult = Invoke-Capture { & $exportScripts -ProjectRoot $oldPolicyProject -Range 4 }
    Assert-Equal $exportResult.exit 0 'V6 export accepts signed legacy episode'
    $exported = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $oldPolicyProject 'export\scripts-EP-04-EP-04.md')
    if ($exported -match '(?m)^下集预告') { throw 'ASSERT FAILED [legacy preview export strip]: preview remains in export' }
    $script:passed++; Write-Output 'TEST-PASS: V6 export strips legacy preview'
    Assert-Equal (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $oldPolicyProject 'scripts\EP-04.md')) $sourceBeforeExport 'V6 export does not modify source script'

    $unrelatedNovel = Join-Path $contextProject 'novel\第99章.txt'
    Write-Utf8 $unrelatedNovel '第99章 尚未映射。'
    $indexBuild = Invoke-Capture { & $sourceIndex -ProjectRoot $contextProject -Mode Build }
    Assert-Equal $indexBuild.exit 0 'source index builds'
    Assert-Equal (Invoke-Capture { & $sourceIndex -ProjectRoot $contextProject -Mode Validate }).exit 0 'source index validates while authorities are unchanged'
    $indexData = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $contextProject '.comic-adapt-cache\source-index.json') | ConvertFrom-Json
    Assert-Equal @($indexData.plot_points).Count 1 'source index stores plot points'
    Assert-Equal @($indexData.novel_files).Count 2 'source index stores novel file facts'
    $prefetchResult = Invoke-Capture { & $prefetch -ProjectRoot $contextProject -Episode 2 -Window 2 }
    Assert-Equal $prefetchResult.exit 0 'episode prefetch builds from source index'
    $prefetchData = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $contextProject '.comic-adapt-cache\prefetch\EP-02.json') | ConvertFrom-Json
    Assert-Equal $prefetchData.status 'READ_ONLY_PREFETCH' 'episode prefetch is explicitly read-only'
    Assert-Equal $prefetchData.schema_version 'comic-adapt-prefetch/1.2' 'prefetch stores reusable static context and preflight skeletons'
    if (@($prefetchData.must_keep_coverage).Count -lt 1 -or @($prefetchData.ledger_candidates).Count -lt 1) { throw 'ASSERT FAILED [prefetch static coverage/ledger candidates]' }
    $script:passed++; Write-Output 'TEST-PASS: checker-wait prefetch computes coverage, visual candidates and ledger hits without drafting ahead'
    Write-Utf8 $unrelatedNovel '第99章 未映射内容已经变化。'
    Assert-Equal (Invoke-Capture { & $sourceIndex -ProjectRoot $contextProject -Mode ValidateFast -Episode 2 }).exit 0 'target-fast index validation ignores unrelated novel'
    Assert-Equal (Invoke-Capture { & $sourceIndex -ProjectRoot $contextProject -Mode Validate }).exit 2 'full index validation catches unrelated novel change'
    Write-Utf8 $unrelatedNovel '第99章 尚未映射。'
    Assert-Equal (Invoke-Capture { & $sourceIndex -ProjectRoot $contextProject -Mode Validate }).exit 0 'full index validation recovers after unrelated novel restore'
    Write-Utf8 (Join-Path $contextProject 'character-cards.md') "| 资产名 | 定位 |`n|---|---|`n| 甲 | 主角·已改 |`n"
    Assert-Equal (Invoke-Capture { & $sourceIndex -ProjectRoot $contextProject -Mode Validate }).exit 2 'source index becomes stale after authority edit'

    $goalProject = Join-Path $testRoot 'goal-run'
    [void](New-Item -ItemType Directory -Force -Path $goalProject)
    $goalInit = Invoke-Capture { & $goalRunner -ProjectRoot $goalProject -Mode Init -Task write -Range 19-20 }
    Assert-Equal $goalInit.exit 0 'goal runner initializes target range'
    $goalNext = Invoke-Capture { & $goalRunner -ProjectRoot $goalProject -Mode Next }
    if ($goalNext.output -notmatch 'target=EP-19; state=PENDING; action=RUN_EPISODE_PREFETCH') { throw "ASSERT FAILED [goal next action]: $($goalNext.output)" }
    $script:passed++; Write-Output 'TEST-PASS: goal runner returns next executable action'
    if ($goalNext.output -notmatch 'GOAL-RUN-COMMAND:.*episode-prefetch\.ps1.*-Episode 19') { throw "ASSERT FAILED [goal next command]: $($goalNext.output)" }
    $script:passed++; Write-Output 'TEST-PASS: goal runner returns an exact next command'
    if ($goalNext.output -notmatch '-Window 3' -or $goalNext.output -notmatch 'GOAL-RUN-BRIEF:') { throw "ASSERT FAILED [goal next brief/window]: $($goalNext.output)" }
    $nextAction = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $goalProject '.comic-adapt-cache\next-action.json') | ConvertFrom-Json
    Assert-Equal $nextAction.prefetch_window 3 'goal runner uses policy prefetch window in next-action brief'
    Assert-Equal (Invoke-Capture { & $goalRunner -ProjectRoot $goalProject -Mode Advance -UnitTarget EP-19 -State PREFETCHED }).exit 0 'goal runner accepts legal transition'
    $invalidTransition = $false
    try { & $goalRunner -ProjectRoot $goalProject -Mode Advance -UnitTarget EP-19 -State REVIEWED 2>$null | Out-Null } catch { $invalidTransition = ($_.Exception.Message -match 'Invalid transition') }
    Assert-Equal $invalidTransition $true 'goal runner rejects skipped transition'
    $goalReport = Invoke-Capture { & $goalRunner -ProjectRoot $goalProject -Mode Report }
    Assert-Equal $goalReport.exit 2 'goal report remains incomplete before target is reached'
    $goalUnit19Path = Join-Path $goalProject '.comic-adapt-cache\performance\units'
    $goalRunState = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $goalProject '.comic-adapt\goal-run.json') | ConvertFrom-Json
    $goalUnit19File = Join-Path $goalUnit19Path (([string]$goalRunState.run_id) + '__EP-19.json')
    Assert-Equal (Test-Path -LiteralPath $goalUnit19File) $true 'goal Next auto-starts episode timer'
    foreach ($nextState in @('DRAFTED', 'MACHINE_PASS', 'REVIEWED', 'SEMANTIC_PASS', 'COMMITTED', 'COMPLETE')) {
        Assert-Equal (Invoke-Capture { & $goalRunner -ProjectRoot $goalProject -Mode Advance -UnitTarget EP-19 -State $nextState }).exit 0 ("goal auto-timing transition EP-19->$nextState")
    }
    $goalUnit19 = Get-Content -Raw -Encoding UTF8 -LiteralPath $goalUnit19File | ConvertFrom-Json
    Assert-Equal $goalUnit19.status 'COMPLETED' 'goal COMPLETE auto-finishes episode timer'
    Assert-Equal $goalUnit19.result 'PASS' 'goal COMPLETE records PASS timing result'
    if (@($goalUnit19.marks | Where-Object { $_.category -eq 'checker_wait' }).Count -lt 1) { throw 'ASSERT FAILED [goal checker-wait timing mark]' }
    $script:passed++; Write-Output 'TEST-PASS: goal transitions automatically segment checker time'
    [void](Invoke-Capture { & $goalRunner -ProjectRoot $goalProject -Mode Next })
    foreach ($nextState in @('PREFETCHED', 'DRAFTED', 'MACHINE_PASS', 'REVIEWED', 'SEMANTIC_PASS', 'COMMITTED', 'COMPLETE')) {
        Assert-Equal (Invoke-Capture { & $goalRunner -ProjectRoot $goalProject -Mode Advance -UnitTarget EP-20 -State $nextState }).exit 0 ("goal auto-timing transition EP-20->$nextState")
    }
    $goalTerminalReport = Invoke-Capture { & $goalRunner -ProjectRoot $goalProject -Mode Report }
    Assert-Equal $goalTerminalReport.exit 0 'goal terminal report succeeds even when run finish waits for scope closure'
    if ($goalTerminalReport.output -notmatch 'PERF-RUN-FINISH-DEFERRED') { throw 'ASSERT FAILED [goal performance finish retry/deferred marker]' }
    $script:passed++; Write-Output 'TEST-PASS: target completion retries run Finish and reports deferred scope closure without losing unit times'

    $lockProject = Join-Path $testRoot 'pipeline-lock'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $lockProject 'scripts'))
    Write-Utf8 (Join-Path $lockProject 'scripts\EP-01.md') $validNoPreview
    Write-Utf8 (Join-Path $lockProject '.comic-adapt-cache\packets\EP-01.json') '{"missing":[],"prewrite_contracts":{"gate_status":"READY"}}'
    $lockDir = Join-Path $lockProject '.comic-adapt-cache\locks'
    [void](New-Item -ItemType Directory -Force -Path $lockDir)
    Write-Utf8 (Join-Path $lockDir 'EP-01.pre-review.lock') 'held'
    $lockRejected = $false
    try { & $episodePipeline -ProjectRoot $lockProject -Episode 1 -Mode PreReviewParallel 2>$null | Out-Null } catch { $lockRejected = $true }
    Assert-Equal $lockRejected $true 'parallel pre-review rejects an existing episode lock'

    $parallelProject = Join-Path $testRoot 'pipeline-parallel'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $parallelProject 'scripts'))
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $parallelProject 'visual-assets'))
    Write-Utf8 (Join-Path $parallelProject 'scripts\EP-01.md') $validNoPreview
    Write-Utf8 (Join-Path $parallelProject '.comic-adapt-cache\packets\EP-01.json') '{"missing":[],"prewrite_contracts":{"gate_status":"READY"}}'
    Write-Utf8 (Join-Path $parallelProject 'visual-assets\source-facts.md') $sourceFacts
    [void](Invoke-Capture { & $policy -ProjectRoot $parallelProject -Mode Init })
    $parallelScriptPath = Join-Path $parallelProject 'scripts\EP-01.md'
    $parallelHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $parallelScriptPath).Hash
    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $parallelHost = (Get-Process -Id $PID).Path
        $parallelOutput = & $parallelHost -NoProfile -ExecutionPolicy Bypass -File $episodePipeline -ProjectRoot $parallelProject -Episode 1 -Mode PreReviewParallel 2>&1 | Out-String
        $parallelAttempt = [ordered]@{ output = $parallelOutput.TrimEnd(); exit = $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $savedErrorAction
    }
    Assert-Equal $parallelAttempt.exit 1 'parallel pre-review reaches expected visual completion gate on incomplete fixture'
    if ($parallelAttempt.output -notmatch 'PIPELINE-STEP: draft-gate') { throw "ASSERT FAILED [draft gate precedes workers]: $($parallelAttempt.output)" }
    $script:passed++; Write-Output 'TEST-PASS: cheap draft gate runs before parallel workers'
    foreach ($workerName in @('visual-sync', 'ledger-plan')) {
        if ($parallelAttempt.output -notmatch ('PIPELINE-PARALLEL-STEP: ' + [regex]::Escape($workerName))) { throw "ASSERT FAILED [parallel worker $workerName]: $($parallelAttempt.output)" }
    }
    $script:passed++; Write-Output 'TEST-PASS: all safe parallel pre-review workers execute'
    if ($parallelAttempt.output -notmatch 'PIPELINE-SNAPSHOT-PASS') { throw "ASSERT FAILED [parallel snapshot receipt]: $($parallelAttempt.output)" }
    $script:passed++; Write-Output 'TEST-PASS: parallel pre-review verifies locked script hash'
    if ($parallelAttempt.output -notmatch 'PIPELINE-STEP: refresh-write-packet') { throw "ASSERT FAILED [mutable contract refresh route]: $($parallelAttempt.output)" }
    $script:passed++; Write-Output 'TEST-PASS: pre-review routes worker changes through Write-packet refresh before Review'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $parallelScriptPath).Hash $parallelHashBefore 'parallel pre-review does not modify script'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $parallelProject '.comic-adapt-cache\locks\EP-01.pre-review.lock')) $false 'parallel pre-review removes exact lock after completion'
    $pipelineTelemetry = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $parallelProject '.comic-adapt-cache\performance\pipeline-events.jsonl')
    if ($pipelineTelemetry -notmatch 'pre-review-parallel-summary' -or $pipelineTelemetry -notmatch 'scheduler') { throw 'ASSERT FAILED [pipeline telemetry]' }
    $script:passed++; Write-Output 'TEST-PASS: pipeline records scheduler and step timing telemetry'

    $runId = 'test-run'
    Assert-Equal (Invoke-Capture { & $performance -ProjectRoot $qualityProject -Mode Start -RunId $runId -Task write -Range 1-2 }).exit 0 'performance start'
    Assert-Equal (Invoke-Capture { & $performance -ProjectRoot $qualityProject -Mode Mark -RunId $runId -Stage review }).exit 0 'performance mark'
    Assert-Equal (Invoke-Capture { & $performance -ProjectRoot $qualityProject -Mode Finish -RunId $runId -Units 2 -FirstPass 1 -CheckerRounds 3 -TargetedRepairs 1 -FullReviews 1 }).exit 0 'performance finish'
    $perfReport = Invoke-Capture { & $performance -ProjectRoot $qualityProject -Mode Report -RunId $runId }
    Assert-Equal $perfReport.exit 0 'performance report'
    if ($perfReport.output -notmatch 'first-pass=50%') { throw "ASSERT FAILED [performance first pass]: $($perfReport.output)" }
    $script:passed++; Write-Output 'TEST-PASS: performance report calculates first-pass rate'
    $perfRunData = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $qualityProject ".comic-adapt-cache\performance\runs\$runId.json") | ConvertFrom-Json
    if (-not $perfRunData.stage_seconds.PSObject.Properties['active'] -or $perfRunData.stage_seconds.PSObject.Properties['start']) { throw 'ASSERT FAILED [performance active stage classification]' }
    $script:passed++; Write-Output 'TEST-PASS: performance wall clock is no longer misclassified as start'

    $unitRunId = 'unit-run'
    Assert-Equal (Invoke-Capture { & $performance -ProjectRoot $qualityProject -Mode Start -RunId $unitRunId -Task write -Range 19-20 }).exit 0 'unit performance run starts'
    Assert-Equal (Invoke-Capture { & $performance -ProjectRoot $qualityProject -Mode StartUnit -RunId $unitRunId -UnitTarget EP-19 -Category active }).exit 0 'episode timer starts'
    Assert-Equal (Invoke-Capture { & $performance -ProjectRoot $qualityProject -Mode UnitMark -RunId $unitRunId -UnitTarget EP-19 -Category checker }).exit 0 'episode timer marks checker phase'
    Assert-Equal (Invoke-Capture { & $performance -ProjectRoot $qualityProject -Mode FinishUnit -RunId $unitRunId -UnitTarget EP-19 -UnitResult PASS }).exit 0 'episode timer finishes'
    Assert-Equal (Invoke-Capture { & $performance -ProjectRoot $qualityProject -Mode AmendUnitResult -RunId $unitRunId -UnitTarget EP-19 -UnitResult UNRESOLVED -Note 'post-finish correction' }).exit 0 'finished unit result can be amended idempotently'
    $amendedUnit = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $qualityProject ".comic-adapt-cache\performance\units\$unitRunId`__EP-19.json") | ConvertFrom-Json
    Assert-Equal $amendedUnit.result 'UNRESOLVED' 'unit amendment persists corrected result'
    $runningReport = Invoke-Capture { & $performance -ProjectRoot $qualityProject -Mode Report -RunId $unitRunId }
    if ($runningReport.output -notmatch 'status=RUNNING' -or $runningReport.output -notmatch 'PERF-UNIT: EP-19') { throw "ASSERT FAILED [running unit report]: $($runningReport.output)" }
    $script:passed++; Write-Output 'TEST-PASS: running report lists per-episode timing'
    Assert-Equal (Invoke-Capture { & $performance -ProjectRoot $qualityProject -Mode Finish -RunId $unitRunId -FirstPass 1 -CheckerRounds 1 }).exit 0 'unit performance run finishes with inferred unit count'

    $autoRunId = 'auto-metrics-run'
    Assert-Equal (Invoke-Capture { & $performance -ProjectRoot $qualityProject -Mode Start -RunId $autoRunId -Task write -Range 8-8 }).exit 0 'auto-metrics run starts'
    Assert-Equal (Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Record -Target EP-08 -Kind Script -Result FAIL -Round 1 -CheckerMode Differential -CheckedDimensions '1,2,7,8' -FailedDimensions 2 }).exit 1 'auto-metrics semantic fail records'
    Assert-Equal (Invoke-Capture { & $quality -ProjectRoot $qualityProject -Mode Record -Target EP-08 -Kind Script -Result PASS -Round 2 -CheckerMode Targeted -CheckedDimensions '2,8' }).exit 0 'auto-metrics targeted pass records'
    Assert-Equal (Invoke-Capture { & $performance -ProjectRoot $qualityProject -Mode Finish -RunId $autoRunId }).exit 0 'performance finish derives quality metrics'
    $autoRunData = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $qualityProject ".comic-adapt-cache\performance\runs\$autoRunId.json") | ConvertFrom-Json
    Assert-Equal ([int]$autoRunData.first_failure_sources.dimension_2) 1 'performance classifies the first semantic failure source'
    $autoRun = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $qualityProject ".comic-adapt-cache\performance\runs\$autoRunId.json") | ConvertFrom-Json
    Assert-Equal $autoRun.metrics.first_pass 0 'auto metrics derives first-pass count'
    Assert-Equal $autoRun.metrics.checker_rounds 2 'auto metrics derives checker rounds'
    Assert-Equal $autoRun.metrics.targeted_repairs 1 'auto metrics derives targeted repairs'

    $batchSuite = Invoke-Capture { & (Join-Path $PSScriptRoot 'test-v6-batch.ps1') }
    Assert-Equal $batchSuite.exit 0 'V6 long-run batch regression suite passes'
    Write-Output ("TEST-SUMMARY: PASS={0}; FAIL=0" -f $script:passed)
    exit 0
} finally {
    if (Test-Path -LiteralPath $resolvedTest -PathType Container) {
        $confirmed = [IO.Path]::GetFullPath($resolvedTest)
        if ($confirmed.StartsWith($resolvedTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($confirmed) -match '^comic-adapt-v6-test-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $confirmed -Recurse -Force
        }
    }
}

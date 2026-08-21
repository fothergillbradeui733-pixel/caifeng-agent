# script-lint.ps1 — comic-adapt 剧本机检脚本（数值与格式机扫，script-checker 的事实依据）
# 当前契约：V6。规则速查由 -Rules 从脚本内同源变量生成。
# 用法：
#   单集：powershell -File script-lint.ps1 -Path "scripts\EP-01.md" -Mode 动态漫
#   全量：powershell -File script-lint.ps1 -Path "scripts" -Mode 动态漫
#   源完整性：powershell -File script-lint.ps1 -Path "novel" -CheckSource
#   台账新鲜度：powershell -File script-lint.ps1 -Path "." -CheckProgress   （核对 progress.md 快照/序列跟到最新成稿集；可加 -ExpectLatest N 锁死基准）
#   台账同步：powershell -File script-lint.ps1 -Path "." -FixProgress -PassEp 61   （EP-61 质检 PASS 后：机械项落账+登记块收割+新鲜度核对；-PassEp 58-61=批量区间；缺省 -PassEp=历史补账）
#   启动检查：powershell -File script-lint.ps1 -Path "." -Startup   （~start/~write/~map 启动：载体区块+七列角色卡+缓存+全套 -CheckProgress，一条命令替代逐区块目检）
# 输出：逐项报告 + SUMMARY 行；存在 [FAIL] 项时退出码=1
param(
  [string]$Path = '.',     # -Rules不依赖Path；其余模式对无效路径照常FAIL
  [ValidateSet('动态漫')][string]$Mode = '动态漫',   # 固定单模式；保留参数供既有命令调用
  [switch]$CheckSource,
  [switch]$CheckProgress,
  [switch]$Startup,        # 载体区块+七列角色卡+避让缓存+CheckProgress
  [switch]$FixProgress,    # 台账机械项同步（各集字数/强度自动落账+台账登记块收割，判断项出 TODO），随后照常跑 -CheckProgress 核对
  [string]$PassEp = '',    # -FixProgress 专用：刚质检 PASS 的集号「N」或区间「N-M」（覆盖更新字数/强度+收割登记块）；缺省=补登全部未登记成稿集
  [string]$PlotMap = '',   # 角色卡来源（资产名唯一性机扫）；缺省自动找项目根 character-cards.md，无则 scripts 同级 plot-map.md
  [int]$ExpectLatest = 0,  # -CheckProgress 专用：显式指定期望最新成稿集号为新鲜度基准（>0 生效，指定时跳过草稿自动推断）
  [switch]$Draft,          # 草稿只读机检；读取但不写.lint-cache.json
  [switch]$Rules           # 输出同源规则速查后退出
)

$ErrorActionPreference = 'Stop'
$script:failCount = 0
function Out-Issue([string]$lvl,[string]$file,[int]$line,[string]$msg){
  if($lvl -eq 'FAIL'){ $script:failCount++ }
  Write-Output ("[{0}] {1}:{2}  {3}" -f $lvl,$file,$line,$msg)
}

# 保留原文件 UTF-8 BOM、LF/CRLF 与末尾换行。WriteAllLines 在 Windows PowerShell 下会把 LF 静默改成 CRLF，
# 造成台账收割前后的正文哈希假失败。
function Write-Utf8LinesPreserve([string]$FilePath,[object[]]$Lines){
  $bytes=[System.IO.File]::ReadAllBytes($FilePath)
  $hasBom=($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $old=[System.IO.File]::ReadAllText($FilePath,[System.Text.Encoding]::UTF8)
  $newline=if($old.Contains("`r`n")){"`r`n"}else{"`n"}
  $hadTrailing=($old.EndsWith("`r`n") -or $old.EndsWith("`n") -or $old.EndsWith("`r"))
  $text=(@($Lines) -join $newline)
  if($hadTrailing -and -not $text.EndsWith($newline)){ $text += $newline }
  $temp=$FilePath+'.tmp-'+[guid]::NewGuid().ToString('N')
  [System.IO.File]::WriteAllText($temp,$text,(New-Object System.Text.UTF8Encoding($hasBom)))
  Move-Item -LiteralPath $temp -Destination $FilePath -Force
}

# 道具索引别名表解析（plot-map/progress 中「## …道具…」小节下的表：道具名列 + 别名列）；修改时同步核对审计脚本的对应实现
# 别名语义：某名（禁）→ 禁用名；其余别名 → 出现在 △/※ 画面行即提示（台词里可保留叫法）；本脚本创作期一律 WARN 输出
function Get-PropRules([string]$mdPath){
  $rules=@()
  if(-not ($mdPath -and (Test-Path $mdPath))){ return $rules }
  $inProp=$false; $colAsset=-1; $colAlias=-1
  foreach($row in (Get-Content $mdPath -Encoding UTF8)){
    $r=$row.Trim()
    if($r -match '^#{1,4}\s'){ $inProp = ($r -match '道具'); $colAsset=-1; $colAlias=-1; continue }
    if(-not $inProp -or $r -notmatch '^\|'){ continue }
    $cells = @($r.Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
    if($colAsset -lt 0){
      for($c=0;$c -lt $cells.Count;$c++){
        if($cells[$c] -match '^(道具|名称|资产|信物)'){ $colAsset=$c }
        if($cells[$c] -match '别名'){ $colAlias=$c }
      }
      continue
    }
    if($r -match '^\|[\s:：\-]+\|'){ continue }
    if($colAsset -ge $cells.Count -or $colAlias -lt 0 -or $colAlias -ge $cells.Count){ continue }
    $main = (($cells[$colAsset] -replace '\*','' -replace '（[^）]*）','') -split '[·/、]')[0].Trim()
    if(-not $main){ continue }
    $cell = $cells[$colAlias] -replace '\*',''
    if(-not $cell -or $cell -match '^(无|—|－|-)$'){ continue }
    foreach($item in ($cell -split '、')){
      $it=$item.Trim(); if(-not $it){ continue }
      if($it -match '^(.+?)（禁）$'){ $alias=$Matches[1].Trim(); $kind='禁' }
      else { $alias=($it -replace '（[^）]*）','').Trim(); $kind='别名' }
      if($alias -and $alias -ne $main){ $rules += @{ Alias=$alias; Asset=$main; Kind=$kind } }
    }
  }
  return $rules
}

# 序列区块解析：兼容「- 各集字数（字）：EP-01=…」单行式与「- 各集字数（字）：」头行＋缩进「- EP-01=…」续行式
function Get-SeqBlock([string[]]$prog,[string]$pattern){
  for($i=0;$i -lt $prog.Count;$i++){
    if($prog[$i] -match $pattern){
      $lastIdx=$i; $text=$prog[$i]
      for($j=$i+1;$j -lt $prog.Count;$j++){
        $tj="$($prog[$j])".Trim()
        if(($tj -match '^(-\s*)?EP-?\d+\s*=') -or ($prog[$j] -match '^\s+\S' -and $tj -match 'EP-?\d+\s*=' -and $tj -notmatch '^(-\s*)?(各集|最新|已完成|快照)')){
          $lastIdx=$j; $text = $text + '；' + $tj
        } else { break }
      }
      return @{ Found=$true; HeaderIdx=$i; LastIdx=$lastIdx; Text=$text }
    }
  }
  return @{ Found=$false; HeaderIdx=-1; LastIdx=-1; Text='' }
}

# 序列条目写入：块内已有 EP-n= 则原位替换值（保留 ·PASS 等尾注），否则追加到块末行
function Update-SeqEntry([ref]$progRef,$blk,[int]$n,[string]$newEntry,[string]$valPat){
  $lines=$progRef.Value
  $pat='EP-0*' + $n + '\s*=\s*' + $valPat
  for($i=$blk.HeaderIdx;$i -le $blk.LastIdx;$i++){
    if($lines[$i] -match $pat){
      if($lines[$i].Contains($newEntry)){ return 'same' }
      $lines[$i]=$lines[$i] -replace $pat,$newEntry
      $progRef.Value=$lines; return 'updated'
    }
  }
  $sep='；'; if($lines[$blk.LastIdx].TrimEnd() -match '[：:]$'){ $sep='' }
  $lines[$blk.LastIdx]=$lines[$blk.LastIdx].TrimEnd()+$sep+$newEntry
  $progRef.Value=$lines; return 'appended'
}

# ---------- 台账登记块：剥离 + 解析 ----------
# 块语法（write-card「九」定义）：【台账登记块】…【台账登记块·完】；块内单行字段「字段名：值」（可重复，值=无则忽略），
# 快照子块【快照】…【快照·完】＝progress「上集末场快照」目标格式原样行
function Strip-LedgerBlock([string[]]$ls){
  $out=@(); $in=$false
  foreach($l in $ls){
    $t="$l".Trim()
    if(-not $in -and $t -match '^【台账登记块】'){ $in=$true; continue }
    if($in){ if($t -match '^【台账登记块·完】'){ $in=$false }; continue }
    $out += $l
  }
  return $out   # 调用侧一律 @(Strip-LedgerBlock …) 包裹（return ,$out 会被 @() 二次包裹成单元素）
}
function Get-LedgerBlock([string[]]$ls){
  $res=@{ Found=$false; StartIdx=-1; EndIdx=-1; Fields=@{}; Snapshot=@() }
  $in=$false; $inSnap=$false
  for($i=0;$i -lt $ls.Count;$i++){
    $t="$($ls[$i])".Trim()
    if(-not $in){ if($t -match '^【台账登记块】'){ $in=$true; $res.Found=$true; $res.StartIdx=$i }; continue }
    if($t -match '^【台账登记块·完】'){ $res.EndIdx=$i; break }
    if($t -match '^【快照】'){ $inSnap=$true; continue }
    if($t -match '^【快照·完】'){ $inSnap=$false; continue }
    if($inSnap){ if($t){ $res.Snapshot += $t }; continue }
    if($t -match '^(原著时间|日历|角色状态|伏笔埋|伏笔收|道具|期限|场景名|口径|行动线)[:：]\s*(.*)$'){
      $k=$Matches[1]; $v=$Matches[2].Trim()
      if($v -and $v -ne '无'){ if(-not $res.Fields.ContainsKey($k)){ $res.Fields[$k]=@() }; $res.Fields[$k] += $v }
    }
  }
  if($res.Found -and $res.EndIdx -lt 0){ $res.EndIdx = $ls.Count-1 }   # 缺结束标记：按到文件尾（主机检另报 WARN）
  return $res
}
# 登记块字段取键：｜分段取首段，剥〔〕「」『』（…）与空白——用于台账在账核对的宽松匹配
function Get-LBKey([string]$v){
  $k=("$v" -split '｜')[0]
  return ($k -replace '（[^）]*）','' -replace '[〔〕「」『』\s]','').Trim()
}

# ---------- 收割自动落账辅助（仅 -FixProgress 收割路径使用，不触机检判据） ----------
# progress 区块区间定位：区间＝(HeaderIdx, EndIdx)，EndIdx＝下一个「## 」行号或行数（仿「上集末场快照」区间定位先例）
function Get-BlockRange([string[]]$ls,[string]$headerPat){
  for($i=0;$i -lt $ls.Count;$i++){
    if($ls[$i] -match $headerPat){
      $end=$ls.Count
      for($j=$i+1;$j -lt $ls.Count;$j++){ if($ls[$j] -match '^##\s'){ $end=$j; break } }
      return @{ Found=$true; HeaderIdx=$i; EndIdx=$end }
    }
  }
  return @{ Found=$false; HeaderIdx=-1; EndIdx=-1 }
}
# 区间内按归一键（剥空白）找行号；$shapePat 非空时先按行形过滤（如 '^-\s' 只看顶层 bullet、'^\s*\|' 只看表行）。找不到返回 -1
function Find-KeyLineIdx([string[]]$ls,$rng,[string]$key,[string]$shapePat=''){
  if(-not $rng.Found){ return -1 }
  $nk=("$key" -replace '\s','')
  if(-not $nk){ return -1 }
  $end=[Math]::Min($rng.EndIdx,$ls.Count)
  for($i=$rng.HeaderIdx+1;$i -lt $end;$i++){
    $raw="$($ls[$i])"
    if($shapePat -and $raw -notmatch $shapePat){ continue }
    if((($raw) -replace '\s','').Contains($nk)){ return $i }
  }
  return -1
}
# 区间尾插入行并返回新数组（mode=table：插到区间内最后一个表格行之后；mode=list：插到最后一个 bullet/子行之后；均无则区块头行后）
# 调用侧一律 @(Insert-BlockLines …) 包裹接收
function Insert-BlockLines([string[]]$ls,$rng,[string[]]$newLines,[string]$mode){
  if($ls.Count -eq 0){ return @($newLines) }
  $at=-1
  $end=[Math]::Min($rng.EndIdx,$ls.Count)
  for($i=$end-1;$i -gt $rng.HeaderIdx;$i--){
    if($i -lt 0){ break }
    $t="$($ls[$i])".Trim()
    if($mode -eq 'table'){ if($t -match '^\|'){ $at=$i; break } }
    else { if($t -match '^-\s'){ $at=$i; break } }
  }
  if($at -lt 0){
    if($rng.HeaderIdx -ge 0){ $at=$rng.HeaderIdx } else { $at=$ls.Count-1 }
  }
  $out=@($ls[0..$at]) + @($newLines)
  if(($at+1) -le ($ls.Count-1)){ $out += @($ls[($at+1)..($ls.Count-1)]) }
  return $out
}

# 单集统计（-FixProgress 用）：字数（框架行排除口径与主机检一致；先剥离台账登记块）+ 集头「情绪强度：N/10」
function Get-EpStats([string]$fullPath){
  $ls=@(Strip-LedgerBlock @(Get-Content $fullPath -Encoding UTF8))
  $w=0; $int=-1
  foreach($l in $ls){
    $t="$l".Trim(); if($t -eq ''){ continue }
    if($int -lt 0 -and $t -match '^情绪强度：\s*(\d+)'){ $int=[int]$Matches[1] }
    $isFrame = ($t -match '^[━─═]+$') -or ($t -match '^(剧名|集数|模式|对应剧情点|原著章节|情绪类型|情绪强度)：') -or ($t -match '^出场人物：') -or ($t -eq '【卡黑】')
    if(-not $isFrame -and -not ($t -match '^场次\s')){ $w += ($t -replace '\s','').Length }
  }
  return @{ Words=$w; Intensity=$int }
}

# 场景名词面相似判定（单集缓存拦截用；与目录模式同地异名聚类同口径：全等/包含/同长差一字·层级父地不同跳过）
function Test-LocSimilar([string]$x,[string]$y){
  $nx=($x -replace '[·．.、\-—（）()【】\s]',''); $ny=($y -replace '[·．.、\-—（）()【】\s]','')
  if(-not $nx -or -not $ny){ return $false }
  if($nx -eq $ny){ return $true }
  if($nx.Length -ge 2 -and $ny.Length -ge 2 -and ($nx.Contains($ny) -or $ny.Contains($nx))){ return $true }
  if($nx.Length -eq $ny.Length -and $nx.Length -ge 3){
    $px=($x -split '·')[0].Trim(); $py=($y -split '·')[0].Trim()
    if(($x.Contains('·') -or $y.Contains('·')) -and $px -ne $py){ return $false }
    $diff=0; $firstDiff=-1
    for($k=0;$k -lt $nx.Length;$k++){ if($nx[$k] -ne $ny[$k]){ if($firstDiff -lt 0){ $firstDiff=$k }; $diff++; if($diff -gt 1){ return $false } } }
    if($diff -le 1 -and $firstDiff -ge 1){ return $true }
  }
  return $false
}

# 跨集避让缓存读写：.lint-cache.json（项目根）——目录模式全量重建，单集模式读取拦截并增量更新本集条目
function Read-LintCache([string]$path){
  if(-not ($path -and (Test-Path $path))){ return $null }
  try{
    $o = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $c=@{ fingerprints=@{}; previews=@{}; locations=@{} }
    if($o.fingerprints){ foreach($p in $o.fingerprints.PSObject.Properties){ $c.fingerprints[$p.Name]=@($p.Value) } }
    if($o.previews){ foreach($p in $o.previews.PSObject.Properties){ $c.previews[$p.Name]=@($p.Value) } }
    if($o.locations){ foreach($p in $o.locations.PSObject.Properties){ $c.locations[$p.Name]=@($p.Value) } }
    return $c
  } catch { return $null }
}
function Write-LintCache([string]$path,$cache){
  try{
    $o=[ordered]@{ note='script-lint 跨集避让缓存：目录模式全量重建、单集模式增量更新本集条目；机器维护勿手工编辑'; updated=(Get-Date -Format 'yyyy-MM-dd HH:mm'); fingerprints=$cache.fingerprints; previews=$cache.previews; locations=$cache.locations }
    # 原子写：先写同目录 .tmp 再 Move-Item -Force 替换，防写中断留半截 JSON
    $tmp = $path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
  } catch { Write-Output "INFO 避让缓存写入失败：$($_.Exception.Message)" }
}

# ---------- 规则词表（机检与 -Rules 速查同源同变量，禁止两处手抄防漂移） ----------
$minWords  = 800; $maxWords = 0           # 动态漫：≥800 不设上限
$maxSent   = 35
$shotWhite = @('全景','中景','近景','特写','大特写','远景','蒙太奇')   # 景别白名单
$slotWhite = '^(日|夜|晨|黄昏)(·[一-龥]{1,3})?$|^(日→夜|夜→晨|夜→日|晨→日)$'  # 时段白名单（可带·天气后缀）
# △/※ 不可拍词表·强词（明确心理/全知/无意识，硬 FAIL）
# 补缺口词面：未觉(?!醒)〔守"灵根未觉醒"〕/没发现/未发现/没察觉/[没未岂哪]料到/[没未岂哪]料想
$mindFail = '浑然不觉|未察觉|没注意|不曾发觉|毫无防备|还不知道|又是那个|众人皆知|殊不知|却不知|心想|暗想|暗自|意识到|脑海|只觉|生怕|唯恐|打定主意|备好.{0,4}说辞|恍然|这才明白|后知后觉|未曾留意|老怀甚慰|福至心灵|像隔了|未觉(?!醒)|没发现|未发现|没察觉|[没未岂哪]料到|[没未岂哪]料想'
# △/※ 不可拍词表·弱词/歧义词（WARN 语义复核——可能是可拍画面里的合法字，如"手心中的玉佩"、信纸引文"便知分晓"）
$mindWarn = '心中|心头|心里|觉得|便知|预感|到头来|知道|想起|回想|认出|发觉'
# 自检提示组（WARN·写作自检提示·非checker判罚依据）：评价总结式旁白/动机推断尾巴/有标记心声——写作端自检裁决，
# checker 不得机械升格为维度7 FAIL、写作端已裁决保留者不修；提示不给单一替换建议（防"皱眉"类口癖跨集膨胀触≥3集避让线）。
# 守卫：道尽(?!头)防"街道尽头"；不解带表情锚定豁免（一脸/满脸/面露/眼中/神色+不解＝可拍表情已PASS惯例）与(?!释)防"不解释"。
$mindSelfCheck = '演活了|道尽(?!头)|尽显|把.{0,12}演绎得|(?<!一脸|满脸|面露|眼中|神色)不解(?!释)|像[是在]{0,2}.{0,8}提醒|像[是在]{0,2}.{0,8}暗示|仿佛[是在]{0,2}.{0,8}提醒|仿佛[是在]{0,2}.{0,8}暗示|似乎[是在]{0,2}.{0,8}提醒|似乎[是在]{0,2}.{0,8}暗示'
# 高频意象计数词表（对照 progress 高频意象表；目录模式跨集聚合，≥3集自动标避让）
$fingerprints = @('攥','猛地','咬牙','一字一句','一字一顿','千钧一发','瞳孔骤缩','瞳孔一缩','沉声','踉跄','莞尔','嘴角','挑眉','叹气','眼睛一亮','咧嘴','压低声','眯起眼','倒吸','冷笑','冷哼','嗤笑','抿唇','皱眉','扬眉','一愣','愣住','顿了顿','凑近','深吸一口气','翻白眼','勾唇','眼神一厉','嘴角上扬')
# 预告骨架指纹（跨集复读检测；抽掉专名的开头句型/转折/收尾模具）
$previewSkeletons = @(
  @{ Name='还没X已经Y'; Pat='(还没|没来得及|尚未|还未).{0,14}(已经|却已|就已|才刚|便已|竟已)' },
  @{ Name='当X那一刻所有人'; Pat='当.{0,24}(那一刻|之时|的时候).{0,24}(所有|全场|全部|众人|每个人)' },
  @{ Name='谁也没想到'; Pat='(谁(也|都)|没人|无人).{0,6}(想到|料到|预料|想过|明白)' },
  @{ Name='就在此时反转'; Pat='(可就在|然而就在|就在这时|不料|岂料|殊不知|谁曾想)' }
)
# 道具台账触发词（-CheckProgress 粗筛 d) 与 -Rules 共用一份）
$propTrig = '炸毁|炸飞|尽毁|拆下|拆获|夺走|易主|交给|移交|上交|损毁|遗失|摔碎|折断|烧毁'

# ---------- -Rules 规则速查模式（先于其他模式，不依赖 -Path 有效性） ----------
if($Rules){
  Write-Output "script-lint V6 规则速查（词表与机检同源；模型只读本输出，不读取脚本源码）"
  Write-Output ""
  Write-Output "== 检查项速查（模式｜项名｜级别） =="
  Write-Output "剧本机检｜编码非UTF-8（乱码占比>5%，跳过该文件）｜FAIL"
  Write-Output "剧本机检｜集标题跨集重名｜FAIL"
  Write-Output "剧本机检｜场次头三要素（内/外｜地点｜时段白名单：日/夜/晨/黄昏[·天气]/箭头跨时）｜FAIL"
  Write-Output "剧本机检｜闪回写进时段位/地点位（场级须【字幕：X·闪回】、拍级「※ 闪回：」）｜FAIL"
  Write-Output "剧本机检｜场次头「日」场内含夜间词（时段错标）｜强词FAIL/弱词WARN"
  Write-Output ("剧本机检｜景别位白名单（{0}）｜FAIL；（音效）占景别位｜FAIL" -f ($shotWhite -join '/'))
  Write-Output "剧本机检｜△/※不可拍心理/全知词｜强词FAIL/弱词WARN/自检提示组WARN（非checker判罚依据）"
  Write-Output "剧本机检｜台词嵌△（说话动词+冒号+引号，含续行）｜FAIL"
  Write-Output "剧本机检｜△/※ 长引号借壳、概述说话（听说/告诉类）、※承载叙事动作｜WARN"
  Write-Output "剧本机检｜字幕唯一形【字幕：…】（全角冒号，变体皆禁）｜FAIL；字幕内容>18字｜WARN"
  Write-Output "剧本机检｜OS背靠背连缀、【旁白·人物名】｜FAIL"
  Write-Output ("剧本机检｜台词单句>{0}字｜FAIL" -f $maxSent)
  Write-Output "剧本机检｜同角色连续台词块≥3（其间无△/他人台词）｜FAIL"
  Write-Output "剧本机检｜缺（指示）行（台词三行结构强制）｜FAIL"
  Write-Output "剧本机检｜预告超过2句｜FAIL"
  Write-Output "剧本机检｜说话人未列入出场人物表（群杂/画外亦须列名）｜FAIL"
  Write-Output "剧本机检｜角色资产名唯一（别名仅台词/改名生效集/禁用名）｜FAIL"
  Write-Output "剧本机检｜道具别名/禁用名（△/※统一资产名，台词可保留叫法）｜WARN"
  Write-Output ("剧本机检｜全字符<{0}｜FAIL；<880贴近下限｜WARN；场次数<下限｜FAIL" -f $minWords)
  Write-Output "剧本机检｜台账登记块缺【台账登记块·完】结束标记｜WARN"
  Write-Output "目录模式｜跨集聚合：口癖≥3集/预告骨架复读/场景同地异名/泛名并存｜WARN"
  Write-Output "单集模式｜AVOID-LIST 缓存拦截（口癖/场景名/预告骨架触≥3集避让线）｜WARN"
  Write-Output "-CheckSource｜novel 源txt完整性/章节缺号｜FAIL"
  Write-Output "-CheckProgress｜17区块齐备/快照新鲜度/字数强度与原著时间锚缺集/伏笔状态白名单/待埋设超期；旧日历冻结忽略｜FAIL"
  Write-Output "-CheckProgress｜角色快照双条/伏笔双载体/道具触发词粗筛（入账核对）｜WARN/INFO"
  Write-Output "-Startup｜载体区块+七列角色卡+避让缓存 → 随后自动全套 -CheckProgress｜FAIL/WARN"
  Write-Output "-FixProgress｜字数/强度/原著时间锚/角色状态落账+登记块收割（期限兑现/行动线/伏笔/口径等自动写；道具人工TODO）｜—"
  Write-Output ""
  Write-Output "== 词表全量（引自脚本变量） =="
  Write-Output ("△※不可拍·强词（FAIL）：" + (($mindFail -split '\|') -join '，'))
  Write-Output ("△※不可拍·弱词（WARN 语义复核）：" + (($mindWarn -split '\|') -join '，'))
  Write-Output "△※不可拍·自检提示组（WARN·非checker判罚依据）：演活了，道尽（'街道尽头'豁免），尽显（有动作锚可裁决保留），把…演绎得，不解（表情锚与'不解释'豁免），像/仿佛/似乎…提醒/暗示——与脚本变量 `$mindSelfCheck 同源"
  Write-Output ("口癖词表（跨集≥3集避让；progress 高频意象表另有项目自定义补充）：" + ($fingerprints -join '，'))
  Write-Output ("预告骨架模式（≥3集须换写骨架）：" + (($previewSkeletons | ForEach-Object { $_.Name + '＝' + $_.Pat }) -join '；'))
  Write-Output ("道具台账触发词（INFO 入账核对）：" + (($propTrig -split '\|') -join '，'))
  Write-Output ""
  Write-Output "== 参数速查 =="
  Write-Output "-Path｜检查目标：EP-XX.md 单集 / scripts 目录 / novel（配-CheckSource）/ 项目根（配-CheckProgress 系）；默认 '.'"
  Write-Output "-Mode｜固定'动态漫'（供既有命令调用）"
  Write-Output "-Draft｜草稿只读机检：检查全跑并读取AVOID-LIST，但不写.lint-cache.json"
  Write-Output "-CheckSource｜源目录 txt 完整性检查（截断/缺号）"
  Write-Output "-CheckProgress｜progress.md 台账新鲜度核对（快照/序列跟到最新成稿集）"
  Write-Output "-Startup｜启动检查＝17区块+七列角色卡+缓存，随后自动全套 -CheckProgress"
  Write-Output "-FixProgress｜台账同步（字数/强度落账+登记块收割自动落账；场景名/期限/行动线/伏笔/口径自动写、道具人工、冲突FAIL不改写；缺结束标记自动补），随后照常 -CheckProgress"
  Write-Output "-PassEp｜-FixProgress 专用：刚 PASS 的集号 N 或区间 N-M；缺省=补登全部未登记成稿集"
  Write-Output "-PlotMap｜角色卡来源；缺省自动找项目根 character-cards.md，无则 scripts 同级 plot-map.md"
  Write-Output "-ExpectLatest｜-CheckProgress 专用：显式指定最新成稿基准集号（>0 生效，跳过草稿自动推断）"
  Write-Output "-Rules｜本速查（检查项/词表/参数），供 LLM 查规则，禁止 Read 源码"
  exit 0
}

# ---------- 源完整性模式 ----------
if($CheckSource){
  $files = @(Get-ChildItem $Path -Filter *.txt -File)
  if($files.Count -eq 0){ Out-Issue 'FAIL' $Path 0 "源目录无 .txt 文件（空目录/错路径）"; Write-Output "SUMMARY(source): 0 个文件，1 个问题"; exit 1 }
  $bad=0; $nums=@()
  foreach($f in $files){
    $flag=$null
    if($f.Length -lt 500){ $flag="字节数过小($($f.Length)B)" }
    # 占位符探测：源可能是 GBK（UTF8 读会乱码、正则永不命中），UTF8/GBK 双解码各查一次
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $take = [Math]::Min(600, $bytes.Length)
    $headU = [System.Text.Encoding]::UTF8.GetString($bytes,0,$take)
    try { $headG = [System.Text.Encoding]::GetEncoding(936).GetString($bytes,0,$take) } catch { $headG='' }
    if($headU -match '下载失败|内容缺失|章节缺失|加载失败|\[error\]' -or $headG -match '下载失败|内容缺失|章节缺失|加载失败|\[error\]'){ $flag = "$flag 含占位符" }
    if($flag){ Out-Issue 'FAIL' $f.Name 1 "源文件不完整：$flag"; $bad++ }
    if($f.Name -match '(\d+)'){ $nums += [int]$Matches[1] }
  }
  # 章节缺号检测（整章缺失是真实事故类，如姊妹项目"缺 EP21"）
  if($nums.Count -gt 1){
    $sorted = @($nums | Sort-Object -Unique)
    $miss=@(); for($n=$sorted[0]; $n -le $sorted[-1]; $n++){ if($sorted -notcontains $n){ $miss += $n } }
    if($miss.Count -gt 0){ Out-Issue 'FAIL' $Path 0 ("章节缺号：{0}（区间 {1}~{2}）" -f ($miss -join ','),$sorted[0],$sorted[-1]); $bad++ }
  }
  Write-Output ("SUMMARY(source): {0} 个文件，{1} 个问题" -f $files.Count,$bad)
  if($bad -gt 0){ exit 1 } else { exit 0 }
}

# ---------- progress 台账新鲜度/同步模式（-CheckProgress / -FixProgress / -Startup）----------
if($Startup){ $CheckProgress = $true }   # -Startup＝载体检查 + 全套 -CheckProgress
if($CheckProgress -or $FixProgress){
  $progPath=''; $projDir=''
  if(Test-Path $Path -PathType Container){ $projDir=(Get-Item $Path).FullName; $progPath=Join-Path $projDir 'progress.md' }
  elseif((Get-Item $Path).Name -eq 'progress.md'){ $progPath=(Get-Item $Path).FullName; $projDir=(Get-Item $Path).DirectoryName }
  else { $progPath=(Get-Item $Path).FullName; $projDir=(Get-Item $Path).DirectoryName }
  if(-not (Test-Path $progPath)){ Out-Issue 'FAIL' $Path 0 "未找到 progress.md"; Write-Output "SUMMARY(progress): 无法检查"; exit 1 }

  $scriptsDir=Join-Path $projDir 'scripts'
  $epFiles=@(); if(Test-Path $scriptsDir){ $epFiles=@(Get-ChildItem $scriptsDir -Filter 'EP-*.md' -File) }
  $epNums=@($epFiles | ForEach-Object { if($_.Name -match 'EP-?(\d+)'){ [int]$Matches[1] } } | Sort-Object)
  $maxEp = if($epNums.Count){ $epNums[-1] } else { 0 }
  $prog=@(Get-Content $progPath -Encoding UTF8)   # 强制数组：单行/空文件下标取值仍安全
  $sourceTimeMode=$false
  $sourceTimeFrom=1
  $workflowPolicyPath=Join-Path $projDir '.comic-adapt\policy.json'
  if(Test-Path $workflowPolicyPath){
    try {
      $workflowPolicyData=Get-Content -Raw -Encoding UTF8 $workflowPolicyPath | ConvertFrom-Json
      $sourceTimeMode=([string]$workflowPolicyData.time_model -eq 'source_relative')
      if($workflowPolicyData.source_time_from_episode){ $sourceTimeFrom=[int]$workflowPolicyData.source_time_from_episode }
    }
    catch { Out-Issue 'FAIL' 'policy.json' 0 "无法读取 time_model：$($_.Exception.Message)" }
  }

  # —— -Startup：载体齐备性检查（ledger-rules「二」区块清单 + 七列角色卡 + 避让缓存），随后照常跑全套新鲜度核对 ——
  if($Startup){
    $reqBlocks=@(
      @{N='基本信息';P='^##\s*基本信息'},@{N='拆解进度';P='^##\s*拆解进度'},@{N='创作进度';P='^##\s*创作进度'},
      @{N='角色状态快照';P='^##\s*角色状态快照'},@{N='快照史';P='^##\s*快照史'},@{N='待回收伏笔';P='^##\s*待回收伏笔'},
      @{N='道具/信物台账';P='^##\s*道具'},@{N='场景名登记表';P='^##\s*场景名登记表'},@{N='原著时间锚';P='^##\s*(?:原著时间锚|故事内日历)'},
      @{N='未了期限';P='^##\s*未了期限'},@{N='开放行动线清单';P='^##\s*开放行动线'},@{N='设定/数字口径表';P='^##\s*设定'},
      @{N='高频意象表';P='^##\s*高频意象表'},@{N='全局节拍卡';P='^##\s*全局节拍卡'},@{N='上集末场快照';P='^##\s*上集末场快照'},
      @{N='源文件缺口';P='^##\s*源文件缺口'},@{N='迁移记录';P='^##\s*迁移记录'}
    )
    $missBlocks=@()
    foreach($rb in $reqBlocks){ $hit=$false; foreach($l in $prog){ if($l -match $rb.P){ $hit=$true; break } }; if(-not $hit){ $missBlocks += $rb.N } }
    if($missBlocks.Count){ Out-Issue 'FAIL' 'progress.md' 0 ("载体缺失 {0}/17 区块：{1} —— 先按 ledger-rules「二」迁移回填再创作（严禁缺载体 ~write）" -f $missBlocks.Count,($missBlocks -join '、')) }
    else { Write-Output "INFO 载体区块 17/17 齐备" }
    $ccPathS=Join-Path $projDir 'character-cards.md'; $pmPathS=Join-Path $projDir 'plot-map.md'
    $cardSrc=''; if(Test-Path $ccPathS){ $cardSrc=$ccPathS } elseif(Test-Path $pmPathS){ $cardSrc=$pmPathS }
    if($cardSrc){
      $ok7=$false; $inIdxS=$false
      foreach($row in (Get-Content $cardSrc -Encoding UTF8)){
        $r="$row".Trim()
        if($r -match '^##\s*角色索引'){ $inIdxS=$true; continue }
        if($inIdxS -and $r -match '^##?\s'){ break }
        if($inIdxS -and $r -match '^\|'){
          $cellsS=@($r.Trim('|') -split '\|'); if($cellsS.Count -ge 7 -and $r -match '别名'){ $ok7=$true }; break
        }
      }
      if($ok7){ Write-Output ("INFO 角色卡七列 OK（{0}）" -f (Split-Path $cardSrc -Leaf)) }
      else { Out-Issue 'FAIL' (Split-Path $cardSrc -Leaf) 0 "角色卡缺「角色索引」七列表或缺「别名/改名」列——先按模板迁移七列角色卡（资产名机扫依赖）" }
    } else { Out-Issue 'FAIL' $projDir 0 "未找到 character-cards.md / plot-map.md 角色卡——先建档再创作" }
    $cachePS=Join-Path $projDir '.lint-cache.json'
    if($epFiles.Count -gt 0 -and -not (Test-Path $cachePS)){ Out-Issue 'WARN' $projDir 0 "缺 .lint-cache.json 跨集避让缓存——跑一次目录模式（-Path scripts）重建，单集机检才有跨集拦截" }
  }

  # —— -FixProgress：台账机械项同步——能机器算/机器搬的自动落账，无法安全落账项打成 TODO；随后照常跑新鲜度核对 ——
  if($FixProgress){
    $fixed=@(); $todo=@()
    # -PassEp 解析（单集「N」或区间「N-M」）
    $passList=@()
    if("$PassEp".Trim()){
      if("$PassEp" -match '^\s*(\d+)\s*[-~]\s*(\d+)\s*$'){ $pa=[int]$Matches[1]; $pb=[int]$Matches[2]; if($pb -lt $pa){ $pt=$pa;$pa=$pb;$pb=$pt }; $passList=@($pa..$pb) }
      elseif("$PassEp" -match '^\s*(\d+)\s*$'){ $passList=@([int]$Matches[1]) }
      else { Out-Issue 'FAIL' 'args' 0 "-PassEp 格式非法「$PassEp」（支持 N 或 N-M）" }
    }
    $isPass = ($passList.Count -gt 0)
    $wcBlk  = Get-SeqBlock $prog '^\s*-?\s*各集字数'
    $intBlk = Get-SeqBlock $prog '^\s*-?\s*各集强度序列'
    $calBlk = if($sourceTimeMode){ @{Found=$false;Text='';LastIdx=-1} }else{ Get-SeqBlock $prog '^\s*-?\s*各集跨度' }
    if(-not $wcBlk.Found){ Out-Issue 'WARN' 'progress.md' 0 "未找到「各集字数」序列行，-FixProgress 跳过字数同步（按模板补建「创作进度」区块）" }
    $regW=@(); if($wcBlk.Found){ foreach($m in [regex]::Matches($wcBlk.Text,'EP-?(\d+)\s*=')){ $regW += [int]$m.Groups[1].Value } }
    $regI=@(); if($intBlk.Found){ foreach($m in [regex]::Matches($intBlk.Text,'EP-?(\d+)\s*=')){ $regI += [int]$m.Groups[1].Value } }
    $targetsFix=@()
    if($isPass){
      foreach($pn in $passList){ if($epNums -contains $pn){ $targetsFix += $pn } else { Out-Issue 'FAIL' 'scripts' 0 "-PassEp 指定的 EP-$pn 不存在于 scripts/" } }
    } else {
      # 历史补账：字数或强度任一序列缺登的成稿集都是目标；已登记值不改写（保留 ~status 对账信号），只补缺
      $targetsFix=@($epNums | Where-Object { ($regW -notcontains $_) -or ($intBlk.Found -and ($regI -notcontains $_)) })
      if($targetsFix.Count){ Out-Issue 'WARN' 'progress.md' 0 ("历史补账模式：{0} 的字数/强度缺登项将补登（质检状态未知，PASS 与否请人工核对；已登记值不改写）" -f (($targetsFix|ForEach-Object{"EP-$_"}) -join ',')) }
    }
    $wantEp = 0; if($isPass){ $wantEp=($passList | Measure-Object -Maximum).Maximum } elseif($epNums.Count){ $wantEp=$epNums[-1] }
    $snapWritten=$false
    $useZi = (-not $wcBlk.Found) -or ($wcBlk.Text -match 'EP-?\d+\s*=\s*\d+\s*字')
    foreach($n in $targetsFix){
      $epf=$epFiles | Where-Object { $_.Name -match ('^EP-0*{0}\.md$' -f $n) } | Select-Object -First 1
      if(-not $epf){ continue }
      $st=Get-EpStats $epf.FullName
      if($wcBlk.Found -and ($isPass -or ($regW -notcontains $n))){   # 批量补账模式不改写已登记字数
        $suffix=''; if($useZi){ $suffix='字' }
        $qualitySuffix=''
        if($isPass){
          $qualityPath=Join-Path $projDir ('.comic-adapt\quality\EP-{0:d2}.json' -f $n)
          if(Test-Path $qualityPath){
            try {
              $qualityData=Get-Content -Raw -Encoding UTF8 $qualityPath | ConvertFrom-Json
              $semanticRounds=@($qualityData.events | Where-Object { $_.event_type -eq 'semantic_review' -and $_.result -ne 'FAIL_INPUT' }).Count
              if($qualityData.status -eq 'PASS'){ $qualitySuffix=("·PASS({0}轮)" -f $semanticRounds) }
              elseif($qualityData.status -eq 'UNRESOLVED'){ $qualitySuffix=("·UNRESOLVED({0}轮)" -f $semanticRounds) }
            } catch {}
          }
        }
        $r = Update-SeqEntry ([ref]$prog) $wcBlk $n ("EP-{0:d2}={1}{2}{3}" -f $n,$st.Words,$suffix,$qualitySuffix) '\d+\s*字?(?:·(?:PASS|UNRESOLVED)\([^\)]*\))?'
        if($r -ne 'same'){ $fixed += ("「各集字数」EP-{0:d2}={1}{2}（{3}）" -f $n,$st.Words,$suffix,$r) }
      }
      if($intBlk.Found){
        if($st.Intensity -lt 0){ $todo += ("EP-{0:d2} 集头缺「情绪强度：N/10」字段，强度序列无法同步——补集头字段后重跑，或人工登记" -f $n) }
        elseif($isPass -or ($regI -notcontains $n)){   # 批量补账模式不改写已登记强度
          $r2 = Update-SeqEntry ([ref]$prog) $intBlk $n ("EP-{0:d2}={1}" -f $n,$st.Intensity) '\d+'
          if($r2 -ne 'same'){ $fixed += ("「各集强度序列」EP-{0:d2}={1}（{2}·取自集头「情绪强度」）" -f $n,$st.Intensity,$r2) }
        }
      } elseif($st.Intensity -ge 0){ $todo += "未找到「各集强度序列」行——按模板补建「全局节拍卡」区块后重跑" }

      # —— 随稿台账登记块收割 ——
      $rawEp=@(Get-Content $epf.FullName -Encoding UTF8)
      # 有【台账登记块】但缺【台账登记块·完】→ 解析前自动在文件尾补一行结束标记（收割豁免类修改，防剥离误吞正文）
      $lbHasS=$false; $lbHasE=$false
      foreach($rl0 in $rawEp){ $rt0="$rl0".Trim(); if($rt0 -match '^【台账登记块】'){ $lbHasS=$true }; if($rt0 -match '^【台账登记块·完】'){ $lbHasE=$true } }
      if($lbHasS -and -not $lbHasE){
        $rawEp = @($rawEp) + @('【台账登记块·完】')
        $bytesEp0=[System.IO.File]::ReadAllBytes($epf.FullName)
        $bomEp0=($bytesEp0.Length -ge 3 -and $bytesEp0[0] -eq 0xEF -and $bytesEp0[1] -eq 0xBB -and $bytesEp0[2] -eq 0xBF)
        Write-Utf8LinesPreserve $epf.FullName $rawEp
        $fixed += ("EP-{0:d2} 台账登记块缺【台账登记块·完】结束标记——已在文件尾自动补一行（收割豁免类）" -f $n)
      }
      $blkLB=Get-LedgerBlock $rawEp
      $epIssue=0   # 本集收割期 TODO/FAIL 计数：清零才删块（防证据丢失；重跑即收敛）
      if($blkLB.Found){
        $epTag=("EP-{0:d2}" -f $n)
        $useSourceTimeForEp=($sourceTimeMode -and ($n -ge $sourceTimeFrom -or $blkLB.Fields.ContainsKey('原著时间')))
        # ① 原著相对时间模式只搬运原文时间锚，不建立或校验人工绝对日历。
        if($useSourceTimeForEp){
          if($blkLB.Fields.ContainsKey('原著时间')){
            foreach($tv in $blkLB.Fields['原著时间']){
              $requiredTimeParts=@('上集结束时间锚','本集原著时间原话','事件先后','闪回边界','本集结束状态')
              $missingTimeParts=@($requiredTimeParts | Where-Object { $tv -notmatch ([regex]::Escape($_)+'\s*[=＝]') })
              if($missingTimeParts.Count){ $todo += ("EP-{0:d2} 原著时间契约缺字段：{1}（须保留原著相对时间原话，不补算绝对日期）" -f $n,($missingTimeParts -join '、')); $epIssue++; continue }
              $rngTime=Get-BlockRange $prog '^##\s*原著时间锚'
              $timeLine=("- {0}｜{1}" -f $epTag,$tv.Trim())
              if(-not $rngTime.Found){
                $prog=@($prog)+@('','## 原著时间锚',$timeLine)
                $progDirtyLB=$true
                $fixed += ("补建「原著时间锚」并新增 {0}" -f $epTag)
                continue
              }
              $existingTime=Find-KeyLineIdx $prog $rngTime $epTag '^\s*-\s'
              if($existingTime -ge 0){
                $oldTime="$($prog[$existingTime])"
                if((($oldTime -replace '\s','')) -ne (($timeLine -replace '\s',''))){ Out-Issue 'FAIL' 'progress.md' ($existingTime+1) ("「原著时间锚」{0} 已登记内容与登记块冲突——回原著归一，禁止补算绝对日期" -f $epTag); $epIssue++ }
              } else {
                $prog=@(Insert-BlockLines $prog $rngTime @($timeLine) 'list')
                $progDirtyLB=$true
                $fixed += ("「原著时间锚」新增 {0}（自登记块）" -f $epTag)
              }
            }
          } else { $todo += ("EP-{0:d2} 登记块缺「原著时间：」source_time_contract" -f $n); $epIssue++ }
        }
        # 旧项目无V6相对时间策略时保留历史日历兼容；一旦启用 source_relative 就冻结且不再读取/更新。
        elseif(-not $sourceTimeMode -and $blkLB.Fields.ContainsKey('日历')){
          foreach($cv in $blkLB.Fields['日历']){
            $cvn=($cv -replace '\s','')
            if($cvn -notmatch ('^EP-0*' + $n + '=第[\d~至]+天·\S+$')){ $todo += ("EP-{0:d2} 登记块日历格式非法「{1}」（应 EP-{0:d2}=第X天·晨/日/黄昏/夜，跨时段用→）——修正登记块后重跑" -f $n,$cv); $epIssue++; continue }
            $newV=($cvn -replace ('^EP-0*' + $n + '='),'')
            if($calBlk.Found){
              if($calBlk.Text -match ('EP-0*' + $n + '\s*=\s*([^；;]+)')){
                $exist=(($Matches[1].Trim()) -replace '\s','')
                if($exist -ne $newV){ Out-Issue 'FAIL' 'progress.md' 0 ("「各集跨度」EP-{0:d2} 已登记「{1}」与登记块「{2}」冲突——人工归一（lint 不改写已登记跨度）" -f $n,$exist,$newV); $epIssue++ }
              } else {
                $sepC='；'; if($prog[$calBlk.LastIdx].TrimEnd() -match '[：:]$'){ $sepC='' }
                $prog[$calBlk.LastIdx]=$prog[$calBlk.LastIdx].TrimEnd()+$sepC+("EP-{0:d2}={1}" -f $n,$newV)
                $fixed += ("「各集跨度」EP-{0:d2}={1}（自登记块落账）" -f $n,$newV)
                $calBlk=Get-SeqBlock $prog '^\s*-?\s*各集跨度'
              }
            } else { $todo += "未找到「各集跨度」序列行——按模板补建「故事内日历」区块后重跑（登记块日历待落账）"; $epIssue++ }
          }
        } elseif($calBlk.Found -and ($calBlk.Text -notmatch ('EP-0*' + $n + '\s*='))){
          $todo += ("「各集跨度」缺 EP-{0:d2} 且登记块无日历字段 → 补登记块「日历：」字段重跑，或人工追加" -f $n); $epIssue++
        }
        # ② 末场快照整段刷新（仅最新 PASS 集；登记块【快照】子块＝目标格式原样行）
        if($blkLB.Snapshot.Count -gt 0 -and $n -eq $wantEp){
          $first="$($blkLB.Snapshot[0])"
          if($first -notmatch ('^快照来源[:：]\s*EP-0*' + $n + '\s*$')){ $todo += ("EP-{0:d2} 登记块【快照】首行须为「快照来源：EP-{0:d2}」——修正后重跑" -f $n); $epIssue++ }
          else {
            $hIdx=-1
            for($si=0;$si -lt $prog.Count;$si++){ if($prog[$si] -match '^##\s*上集末场快照'){ $hIdx=$si; break } }
            if($hIdx -ge 0){
              $endIdx=$prog.Count
              for($sj=$hIdx+1;$sj -lt $prog.Count;$sj++){ if($prog[$sj] -match '^##\s'){ $endIdx=$sj; break } }
              $newProg=@(); $newProg+=@($prog[0..$hIdx]); $newProg+=@($blkLB.Snapshot); $newProg+=@(''); if($endIdx -lt $prog.Count){ $newProg+=@($prog[$endIdx..($prog.Count-1)]) }
              $prog=$newProg
              $fixed += ("「上集末场快照」整段刷新（来源=EP-{0:d2}·自登记块；旧值未移快照史，需留痕人工移）" -f $n)
              $snapWritten=$true
              $wcBlk=Get-SeqBlock $prog '^\s*-?\s*各集字数'; $intBlk=Get-SeqBlock $prog '^\s*-?\s*各集强度序列'; $calBlk=Get-SeqBlock $prog '^\s*-?\s*各集跨度'   # 行号已变，重取
            } else { $todo += "未找到「## 上集末场快照」区块——按模板补建后重跑（登记块快照待落账）"; $epIssue++ }
          }
        } elseif($blkLB.Snapshot.Count -eq 0 -and $n -eq $wantEp){
          $todo += ("EP-{0:d2} 登记块缺【快照】子块 → 补填后重跑，或人工刷新「上集末场快照」" -f $n); $epIssue++
        }
        # ③ 在账核对＋自动落账（场景名/期限/行动线/伏笔埋收/口径自动落账；道具保持人工 TODO；已在账冲突 FAIL 不改写）
        #   在账存在性检查一律限定目标区块行区间（仿快照区块头定位法，严禁全文匹配误判「已在账」）；写入后重取区间防行号漂移；
        #   解析失败/键不存在等无法安全落账项仍出 TODO 计 $epIssue（登记块保留、重跑收敛）
        $fyLedgerP=Join-Path $projDir 'ledger-foreshadow.md'
        $fyLines=$null; $fyDirty=$false
        if(Test-Path $fyLedgerP){ $fyLines=@(Get-Content $fyLedgerP -Encoding UTF8) }
        $progDirtyLB=$false
        $epBound='EP-0*' + $n + '(?!\d)'
        $epTag=("EP-{0:d2}" -f $n)
        # —— 角色当前状态：登记块提供明确状态与证据时就地覆盖；旧值自动移入快照史。——
        if($blkLB.Fields.ContainsKey('角色状态')){
          foreach($v in $blkLB.Fields['角色状态']){
            $partsRs=@("$v" -split '｜')
            $nameRs=if($partsRs.Count -ge 1){$partsRs[0].Trim()}else{''}
            $stateRs=if($partsRs.Count -ge 2){$partsRs[1].Trim()}else{''}
            $evidenceRs=''; if($v -match '证据\s*[=＝]\s*(.+)$'){ $evidenceRs=$Matches[1].Trim() }
            if((-not $nameRs) -or (-not $stateRs) -or (-not $evidenceRs)){ $todo += ("[角色状态] 需 角色｜当前状态｜证据=场次/原著锚：{0}" -f $v); $epIssue++; continue }
            $rngRs=Get-BlockRange $prog '^##\s*角色状态快照'
            $rngHist=Get-BlockRange $prog '^##\s*快照史'
            if(-not $rngRs.Found -or -not $rngHist.Found){ $todo += '[角色状态] 缺角色状态快照或快照史区块'; $epIssue++; continue }
            $idxRs=Find-KeyLineIdx $prog $rngRs $nameRs '^\s*-\s'
            $newRs=("- {0}：{1}（更新于{2}｜{3}）" -f $nameRs,$stateRs,$epTag,$evidenceRs)
            if($idxRs -lt 0){
              $prog=@(Insert-BlockLines $prog $rngRs @($newRs) 'list'); $progDirtyLB=$true
              $fixed += ("「角色状态快照」新增 {0}（{1}）" -f $nameRs,$epTag)
            } else {
              $oldRs="$($prog[$idxRs])"
              if((($oldRs -replace '\s','')) -eq (($newRs -replace '\s','')) -or $oldRs -match ([regex]::Escape($stateRs)+'（更新于'+[regex]::Escape($epTag))){ continue }
              $rolePattern='^\s*-\s*'+[regex]::Escape($nameRs)+'\s*[：:]\s*'
              $oldStateRs=($oldRs -replace $rolePattern,'').Trim()
              $prog[$idxRs]=$newRs
              $rngHist=Get-BlockRange $prog '^##\s*快照史'
              $histLine=("- {0}（覆盖于{1}）：{2}" -f $nameRs,$epTag,$oldStateRs)
              if((Find-KeyLineIdx $prog $rngHist ($nameRs+'（覆盖于'+$epTag+'）') '^\s*-\s') -lt 0){ $prog=@(Insert-BlockLines $prog $rngHist @($histLine) 'list') }
              $progDirtyLB=$true
              $fixed += ("「角色状态快照」{0} 就地覆盖，旧值移快照史（{1}）" -f $nameRs,$epTag)
            }
          }
        }
        # —— 伏笔埋/伏笔收：载体优先 ledger-foreshadow.md 分表（存在即写分表），无分表落 progress「待回收伏笔」区块 ——
        foreach($fk in @('伏笔埋','伏笔收')){
          if(-not $blkLB.Fields.ContainsKey($fk)){ continue }
          foreach($v in $blkLB.Fields[$fk]){
            $key=Get-LBKey $v; if(-not $key){ continue }   # Get-LBKey＝先按｜取首段再提键（多段值防护）
            $useFy=($null -ne $fyLines)
            if($useFy){ $car=$fyLines; $rngFy=@{ Found=$true; HeaderIdx=-1; EndIdx=$fyLines.Count }; $carL='ledger-foreshadow.md' }
            else {
              $car=$prog; $rngFy=Get-BlockRange $prog '^##\s*待回收伏笔'; $carL='progress.md「待回收伏笔」'
              if(-not $rngFy.Found){ $todo += ("[{0}] 未找到 ledger-foreshadow.md 且 progress 缺「## 待回收伏笔」区块——按模板补建后重跑（登记块：{1}）" -f $fk,$v); $epIssue++; continue }
            }
            $hi=Find-KeyLineIdx $car $rngFy $key '^-\s'
            if($fk -eq '伏笔收'){
              if($hi -lt 0){ $todo += ("[伏笔收] 「{0}」未见于伏笔台账（{1}）→ 人工登记后再收（登记块：{2}）" -f $key,$carL,$v); $epIssue++ }
              else {
                $hl="$($car[$hi])"
                if($hl -match ('状态[:：]\s*已回收（\s*' + $epBound)){ }   # 已回收于同集：no-op（幂等）
                elseif($hl -match '状态[:：]\s*待回收'){
                  $car[$hi]=($hl -replace '(状态[:：]\s*)待回收',('${1}已回收（'+$epTag+'）'))
                  $fixed += ("[伏笔收] {0}「{1}」状态 待回收→已回收（{2}）（自登记块）" -f $carL,$key,$epTag)
                  if($useFy){ $fyDirty=$true } else { $progDirtyLB=$true }
                }
                else { $todo += ("[伏笔收] 「{0}」{1} 状态非『待回收』，无法自动转已回收 → 人工核对（账面行：{2}）" -f $key,$carL,$hl.Trim()); $epIssue++ }
              }
              if($useFy){ $fyLines=$car } else { $prog=$car }
              continue
            }
            # —— 伏笔埋 ——
            $exc=''; if($v -match '摘录[^「]*「(.+)」'){ $exc=$Matches[1] }
            $sceneTag=''; foreach($sg in ("$v" -split '｜')){ if($sg -match '场次\s*[\d\-－~至]+'){ $sceneTag=$Matches[0].Trim(); break } }
            $excSuffix=$epTag; if($sceneTag){ $excSuffix=$epTag+' '+$sceneTag }
            if($hi -lt 0){
              # 名字无条目 → append 新条目（状态待回收、计划回收=待定、关联道具=无、摘录照登记块）
              $excLine=('  - 埋设原文摘录：（暂空·'+$epTag+' 登记块未附摘录）')
              if($exc){ $excLine=('  - 埋设原文摘录：「{0}」（{1}）' -f $exc,$excSuffix) }
              $entry=@(
                ('- {0} — 埋设于{1}，计划回收=待定，状态：待回收' -f $key,$epTag),
                $excLine,
                '  - 关联道具/信物：无'
              )
              $car=@(Insert-BlockLines $car $rngFy $entry 'list')
              $fixed += ("[伏笔埋] {0} 新增条目「{1}」（埋设于{2}·状态待回收·自登记块）" -f $carL,$key,$epTag)
              if($useFy){ $fyLines=$car; $fyDirty=$true } else { $prog=$car; $progDirtyLB=$true }
              continue
            }
            $hl="$($car[$hi])"
            if($hl -match '状态[:：]\s*待埋设'){
              $car[$hi]=($hl -replace '(状态[:：]\s*)待埋设','${1}待回收')
              $fixed += ("[伏笔埋] {0}「{1}」状态 待埋设→待回收（自{2}登记块）" -f $carL,$key,$epTag)
              if($useFy){ $fyDirty=$true } else { $progDirtyLB=$true }
            }
            if($exc){
              # 条目区间＝头行至下一个顶层 bullet/区间尾；找「埋设原文摘录」子行
              $entEnd=[Math]::Min($rngFy.EndIdx,$car.Count)
              for($si=$hi+1;$si -lt $entEnd;$si++){ if("$($car[$si])" -match '^-\s'){ $entEnd=$si; break } }
              $exIdx=-1
              for($si=$hi+1;$si -lt $entEnd;$si++){ if("$($car[$si])" -match '埋设原文摘录'){ $exIdx=$si; break } }
              $newExLine=('  - 埋设原文摘录：「{0}」（{1}）' -f $exc,$excSuffix)
              if($exIdx -ge 0){
                $curBody=(("$($car[$exIdx])") -replace '^\s*-?\s*埋设原文摘录[:：]\s*','').Trim()
                $isPh=$false
                if(-not $curBody){ $isPh=$true } elseif($curBody -match '暂空'){ $isPh=$true } elseif($curBody -match '（待'){ $isPh=$true }
                if($isPh){
                  $car[$exIdx]=$newExLine
                  $fixed += ("[伏笔埋] {0}「{1}」摘录写入（{2}·自登记块）" -f $carL,$key,$excSuffix)
                  if($useFy){ $fyDirty=$true } else { $progDirtyLB=$true }
                } elseif((($curBody -replace '\s','')).Contains(($exc -replace '\s',''))){ }   # 已有同摘录：no-op（幂等）
                else { $todo += ("[伏笔埋] 「{0}」{1} 摘录子行已有实质内容且与登记块摘录不同 → 不覆盖，人工比对后归一（登记块：{2}）" -f $key,$carL,$v); $epIssue++ }
              } else {
                # 条目无摘录子行 → 头行后补建
                $ins=@($car[0..$hi]) + @($newExLine)
                if(($hi+1) -le ($car.Count-1)){ $ins += @($car[($hi+1)..($car.Count-1)]) }
                $car=$ins
                $fixed += ("[伏笔埋] {0}「{1}」补建摘录子行（{2}·自登记块）" -f $carL,$key,$excSuffix)
                if($useFy){ $fyDirty=$true } else { $progDirtyLB=$true }
              }
            }
            if($useFy){ $fyLines=$car } else { $prog=$car }
          }
        }
        if($fyDirty){   # 分表独立写路径（BOM 保真，仿 progress 写盘先例）
          $fyB=[System.IO.File]::ReadAllBytes($fyLedgerP)
          $fyBom=($fyB.Length -ge 3 -and $fyB[0] -eq 0xEF -and $fyB[1] -eq 0xBB -and $fyB[2] -eq 0xBF)
          Write-Utf8LinesPreserve $fyLedgerP $fyLines
          $fyDirty=$false
        }
        # —— 道具：保持人工 TODO 不自动化（卡上明定人工从宽项；键经 Get-LBKey 已含｜首段防护）——
        $progText=($prog -join "`n")
        if($blkLB.Fields.ContainsKey('道具')){
          foreach($v in $blkLB.Fields['道具']){
            $key=Get-LBKey $v; if(-not $key){ continue }
            if($progText -notmatch [regex]::Escape($key)){ $todo += ("[道具] 「{0}」未见于道具/信物台账 → 搬运登记：{1}" -f $key,$v); $epIssue++ }
            elseif($progText -notmatch ([regex]::Escape($key) + '[^\r\n]*' + $epBound)){ $todo += ("[道具] 「{0}」台账行未见 EP-{1:d2} 变动记录 → 补记（登记块：{2}）" -f $key,$n,$v); $epIssue++ }
          }
        }
        # —— 场景名：逐名拆分（；;、），「沿用」判断下沉到每名；不在「场景名登记表」区间 → append 表行 ——
        if($blkLB.Fields.ContainsKey('场景名')){
          foreach($v in $blkLB.Fields['场景名']){
            $partsSc=@("$v" -split '｜')   # 先取｜首段，防说明尾巴里的；、被拆成假名
            $headSc=$partsSc[0]
            $descSc=''; if($partsSc.Count -gt 1){ $descSc=(@($partsSc[1..($partsSc.Count-1)]) -join '｜').Trim() }
            foreach($seg in ($headSc -split '[；;、]')){
              $segT="$seg".Trim(); if(-not $segT){ continue }
              if($segT -match '沿用'){ continue }
              $nameSc=($segT -replace '（[^）]*）','' -replace '[〔〕「」『』]','').Trim()
              if(-not $nameSc){ continue }
              $rngSc=Get-BlockRange $prog '^##\s*场景名登记表'
              if(-not $rngSc.Found){ $todo += ("[场景名] 未找到「## 场景名登记表」区块——按模板补建后重跑（登记块：{0}）" -f $v); $epIssue++; continue }
              if((Find-KeyLineIdx $prog $rngSc $nameSc '^\s*\|') -ge 0){ continue }   # 已在账
              $noteSc=$descSc; if(-not $noteSc){ $noteSc='无' }
              $prog=@(Insert-BlockLines $prog $rngSc @(("| {0} | {1} | {2}·自{1}登记块 |" -f $nameSc,$epTag,$noteSc)) 'table')
              $progDirtyLB=$true
              $fixed += ("「场景名登记表」新增 {0}（{1}·自登记块）" -f $nameSc,$epTag)
            }
          }
        }
        # —— 期限：source_relative 只保存原著原话、兑现状态和原著证据，不计算立约日/到期日。——
        if($blkLB.Fields.ContainsKey('期限')){
          foreach($v in $blkLB.Fields['期限']){
            $quoteDl=''; if($v -match '「(.+?)」'){ $quoteDl=$Matches[1] }
            $rngDl=Get-BlockRange $prog '^##\s*未了期限'
            if(-not $rngDl.Found){ $todo += ("[期限] 未找到「## 未了期限」区块——按模板补建后重跑（登记块：{0}）" -f $v); $epIssue++; continue }
            if($useSourceTimeForEp){
              $statusDl=''; if($v -match '状态\s*[=＝]\s*(待按原著兑现|已按原著兑现|已失效)'){ $statusDl=$Matches[1] }
              $evidenceDl=''; if($v -match '证据\s*[=＝]\s*(.+)$'){ $evidenceDl=$Matches[1].Trim() }
              if((-not $quoteDl) -or (-not $statusDl) -or (-not $evidenceDl)){
                $todo += ("[期限] 登记块解析失败（需 「原著时间原话」｜状态=待按原著兑现/已按原著兑现/已失效｜证据=原著第X章…）→ {0}" -f $v); $epIssue++; continue
              }
              $kiDl=Find-KeyLineIdx $prog $rngDl $quoteDl '^\s*-\s'
              if($kiDl -lt 0){
                $prog=@(Insert-BlockLines $prog $rngDl @(("- 「{0}」 — 登记于{1}｜状态：{2}｜证据：{3}" -f $quoteDl,$epTag,$statusDl,$evidenceDl)) 'list')
                $progDirtyLB=$true
                $fixed += ("「未了期限」新增 「{0}」（{1}·{2}·自登记块）" -f $quoteDl,$epTag,$statusDl)
              } else {
                $oldDl="$($prog[$kiDl])"
                if($oldDl -match ('状态[:：]\s*'+[regex]::Escape($statusDl))){ continue }
                if($statusDl -in @('已按原著兑现','已失效') -and $oldDl -match '状态[:：]\s*待按原著兑现'){
                  $prog[$kiDl]=($oldDl -replace '状态[:：]\s*待按原著兑现',('状态：'+$statusDl))
                  $progDirtyLB=$true
                  $fixed += ("「未了期限」{0} 状态→{1}（{2}）" -f $quoteDl,$statusDl,$epTag)
                } else { $todo += ("[期限] 「{0}」账面状态与登记块冲突，回原著归一：{1}" -f $quoteDl,$v); $epIssue++ }
              }
            } else {
              $dS=-1; if($v -match '立约日\s*[=＝]\s*第?\s*(\d+)\s*天?'){ $dS=[int]$Matches[1] }
              $dE=-1; if($v -match '到期日\s*[=＝]\s*第?\s*(\d+)\s*天?'){ $dE=[int]$Matches[1] }
              if((-not $quoteDl) -or $dS -lt 0 -or $dE -lt 0){ $todo += ("[期限] 旧格式解析失败（需 「原话」｜立约日=第X天｜到期日=第Y天）→ {0}" -f $v); $epIssue++; continue }
              if((Find-KeyLineIdx $prog $rngDl $quoteDl '') -ge 0){ continue }
              $prog=@(Insert-BlockLines $prog $rngDl @(("- 「{0}」 — 立约于{1}（故事第{2}天），期限{3}天 → 到期=故事第{4}天，状态：未到期" -f $quoteDl,$epTag,$dS,($dE-$dS),$dE)) 'list')
              $progDirtyLB=$true
            }
          }
        }
        # —— 行动线：键=首段；发起=append，提及/引爆/了结/撤销=原位改。终态允许幂等重跑。——
        if($blkLB.Fields.ContainsKey('行动线')){
          foreach($v in $blkLB.Fields['行动线']){
            $partsAc=@("$v" -split '｜')
            $keyAc=$partsAc[0].Trim()
            if(-not $keyAc){ continue }
            $tailAc=''; if($partsAc.Count -gt 1){ $tailAc=(@($partsAc[1..($partsAc.Count-1)]) -join '｜') }
            $mAct=[regex]::Match($tailAc,'发起|提及|引爆|了结|撤销')
            if(-not $mAct.Success){ $todo += ("[行动线] 「{0}」登记块尾段未见 发起/提及/引爆/了结/撤销 动词 → 人工登记：{1}" -f $keyAc,$v); $epIssue++; continue }
            $rngAc=Get-BlockRange $prog '^##\s*开放行动线'
            if(-not $rngAc.Found){ $todo += ("[行动线] 未找到「## 开放行动线清单」区块——按模板补建后重跑（登记块：{0}）" -f $v); $epIssue++; continue }
            $ki=Find-KeyLineIdx $prog $rngAc $keyAc '^-\s'
            if($mAct.Value -eq '发起'){
              if($ki -ge 0){ continue }   # 已在账（幂等）
              $prog=@(Insert-BlockLines $prog $rngAc @(("- {0} — 发起于{1}｜最后提及{1}｜状态：进行中" -f $keyAc,$epTag)) 'list')
              $progDirtyLB=$true
              $fixed += ("「开放行动线清单」新增 {0}（发起于{1}·自登记块）" -f $keyAc,$epTag)
            } elseif($mAct.Value -eq '提及'){
              if($ki -lt 0){ $todo += ("[行动线·提及] 「{0}」不在开放行动线清单 → 先人工登记发起行（登记块：{1}）" -f $keyAc,$v); $epIssue++; continue }
              $oldAc="$($prog[$ki])"
              if($oldAc -match '最后提及EP-?\d+'){
                $newAc=($oldAc -replace '最后提及EP-?\d+',('最后提及'+$epTag))
                if($newAc -ne $oldAc){ $prog[$ki]=$newAc; $progDirtyLB=$true; $fixed += ("「开放行动线清单」{0} 最后提及→{1}（自登记块）" -f $keyAc,$epTag) }
              } else { $todo += ("[行动线·提及] 「{0}」账面行缺「最后提及EP-XX」字段，无法自动更新 → 人工补（账面行：{1}）" -f $keyAc,$oldAc.Trim()); $epIssue++ }
            } elseif($mAct.Value -eq '引爆') {
              if($ki -lt 0){ $todo += ("[行动线·引爆] 「{0}」不在开放行动线清单 → 人工登记（登记块：{1}）" -f $keyAc,$v); $epIssue++; continue }
              $oldAc="$($prog[$ki])"
              if($oldAc -match '状态[:：]\s*进行中'){
                $prog[$ki]=($oldAc -replace '(状态[:：]\s*)进行中',('${1}已引爆('+$epTag+')'))
                $progDirtyLB=$true
                $fixed += ("「开放行动线清单」{0} 状态 进行中→已引爆({1})（自登记块）" -f $keyAc,$epTag)
              } elseif($oldAc -match ('已引爆\(\s*' + $epBound)){ }   # 已引爆于同集：no-op（幂等）
              else { $todo += ("[行动线·引爆] 「{0}」账面状态非『进行中』，无法自动引爆 → 人工核对（账面行：{1}）" -f $keyAc,$oldAc.Trim()); $epIssue++ }
            } else {
              if($ki -lt 0){ $todo += ("[行动线·{0}] 「{1}」不在开放行动线清单 → 人工登记（登记块：{2}）" -f $mAct.Value,$keyAc,$v); $epIssue++; continue }
              $oldAc="$($prog[$ki])"
              $finalState=if($mAct.Value -eq '了结'){'已了结'}else{'已撤销'}
              if($oldAc -match ('状态[:：]\s*' + [regex]::Escape($finalState))){ continue }
              if($oldAc -match '状态[:：]\s*(?:进行中|已引爆\([^\)]*\))'){
                $prog[$ki]=($oldAc -replace '(状态[:：]\s*)(?:进行中|已引爆\([^\)]*\))',('${1}'+$finalState))
                $newLine="$($prog[$ki])"
                if($newLine -match '最后提及EP-?\d+'){
                  $prog[$ki]=($newLine -replace '最后提及EP-?\d+',('最后提及'+$epTag))
                }
                $progDirtyLB=$true
                $fixed += ("「开放行动线清单」{0} 状态→{1}（{2}·自登记块）" -f $keyAc,$finalState,$epTag)
              } else { $todo += ("[行动线·{0}] 「{1}」账面状态无法自动转为『{2}』 → 人工核对（账面行：{3}）" -f $mAct.Value,$keyAc,$finalState,$oldAc.Trim()); $epIssue++ }
            }
          }
        }
        # —— 口径：简形/全形双支持；新实体 append；旧值被新值完整包含时是确定性补充，可原位扩展；非包含差异仍按冲突拦截。——
        if($blkLB.Fields.ContainsKey('口径')){
          foreach($v in $blkLB.Fields['口径']){
            $partsCb=@("$v" -split '｜')
            $entCb=''; $typCb='待定'; $valCb=''; $basCb='自登记块'
            if($partsCb.Count -ge 3){
              $entCb=$partsCb[0].Trim(); $typCb=$partsCb[1].Trim(); $valCb=$partsCb[2].Trim()
              if($partsCb.Count -ge 4){ $basCb=(@($partsCb[3..($partsCb.Count-1)]) -join '｜').Trim() }
              if(-not $typCb){ $typCb='待定' }
              if(-not $basCb){ $basCb='自登记块' }
            } else {
              $simpleCb=$partsCb[0].Trim()
              if($partsCb.Count -eq 2 -and $partsCb[1].Trim()){ $basCb=$partsCb[1].Trim() }
              $eqCb=$simpleCb.IndexOfAny(@([char]'=',[char]'＝'))
              if($eqCb -gt 0 -and $eqCb -lt ($simpleCb.Length-1)){
                $entCb=$simpleCb.Substring(0,$eqCb).Trim(); $valCb=$simpleCb.Substring($eqCb+1).Trim()
              }
            }
            if((-not $entCb) -or (-not $valCb)){ $todo += ("[口径] 登记块解析失败（简形 实体=值 或 全形 实体｜类型｜值｜依据）→ 人工登记：{0}" -f $v); $epIssue++; continue }
            $rngCb=Get-BlockRange $prog '^##\s*设定'
            if(-not $rngCb.Found){ $todo += ("[口径] 未找到「## 设定/数字口径表」区块——按模板补建后重跑（登记块：{0}）" -f $v); $epIssue++; continue }
            $rowCb=-1
            for($ri=$rngCb.HeaderIdx+1;$ri -lt [Math]::Min($rngCb.EndIdx,$prog.Count);$ri++){
              $rl="$($prog[$ri])"
              if($rl -notmatch '^\s*\|'){ continue }
              if($rl -match '^\s*\|[\s:：\-]+\|'){ continue }   # 分隔行
              $cellsCb=@($rl.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
              if($cellsCb.Count -lt 1){ continue }
              if((($cellsCb[0] -replace '[\*\s]','')) -eq (($entCb -replace '\s',''))){ $rowCb=$ri; break }
            }
            if($rowCb -lt 0){
              $prog=@(Insert-BlockLines $prog $rngCb @(("| {0} | {1} | {2} | {3} | {4} |" -f $entCb,$typCb,$valCb,$epTag,$basCb)) 'table')
              $progDirtyLB=$true
              $fixed += ("「设定/数字口径表」新增 {0}={1}（{2}·自登记块）" -f $entCb,$valCb,$epTag)
            } else {
              $rowNorm=(("$($prog[$rowCb])") -replace '[=＝\s]','')
              $valNorm=($valCb -replace '[=＝\s]','')
              if($valNorm -and $rowNorm.Contains($valNorm)){ }   # 已在账且含本值：no-op
              elseif($cellsCb.Count -ge 3){
                $oldValNorm=($cellsCb[2] -replace '[=＝\s]','')
                if($oldValNorm -and $valNorm.Contains($oldValNorm)){
                  $cellsCb[2]=$valCb
                  $prog[$rowCb]='| ' + ($cellsCb -join ' | ') + ' |'
                  $progDirtyLB=$true
                  $fixed += ("「设定/数字口径表」{0} 包含式补充（{1}·自登记块）" -f $entCb,$epTag)
                } else {
                  Out-Issue 'FAIL' 'progress.md' ($rowCb+1) ("「设定/数字口径表」实体「{0}」已在账且与登记块口径「{1}」不存在包含关系——口径冲突，人工归一（lint 不合并冲突数字）" -f $entCb,$valCb)
                  $epIssue++
                }
              }
              else {
                Out-Issue 'FAIL' 'progress.md' ($rowCb+1) ("「设定/数字口径表」实体「{0}」已在账且账面行不含登记块口径「{1}」——口径冲突，人工归一（lint 不改写已登记口径）" -f $entCb,$valCb)
                $epIssue++
              }
            }
          }
        }
        if($progDirtyLB){   # ③ 写入后 progress 行号已变，重取三序列区块（仿②快照刷新先例，防下一集用旧行号错位写入）
          $wcBlk=Get-SeqBlock $prog '^\s*-?\s*各集字数'; $intBlk=Get-SeqBlock $prog '^\s*-?\s*各集强度序列'; $calBlk=Get-SeqBlock $prog '^\s*-?\s*各集跨度'
        }
        # ④ 收割完成即删块（本集 TODO/FAIL 清零才删——留证据、重跑收敛；仅删本块适用 PASS 失效豁免）
        if($epIssue -eq 0){
          $newEp=@()
          if($blkLB.StartIdx -gt 0){ $newEp+=@($rawEp[0..($blkLB.StartIdx-1)]) }
          if($blkLB.EndIdx -lt ($rawEp.Count-1)){ $newEp+=@($rawEp[($blkLB.EndIdx+1)..($rawEp.Count-1)]) }
          while($newEp.Count -gt 0 -and "$($newEp[-1])".Trim() -eq ''){ $newEp=@($newEp[0..($newEp.Count-2)]) }
          $bytesEp=[System.IO.File]::ReadAllBytes($epf.FullName)
          $hasBomEp=($bytesEp.Length -ge 3 -and $bytesEp[0] -eq 0xEF -and $bytesEp[1] -eq 0xBB -and $bytesEp[2] -eq 0xBF)
          Write-Utf8LinesPreserve $epf.FullName $newEp
          $fixed += ("EP-{0:d2} 台账登记块已收割删除（字数按剥离口径不变；仅删本块适用 PASS 失效豁免）" -f $n)
        } else {
          Write-Output ("INFO EP-{0:d2} 登记块保留（本集收割 TODO/FAIL {1} 项——按 TODO 落账后重跑 -FixProgress -PassEp {0} 即收割删除）" -f $n,$epIssue)
        }
      } else {
        # 无登记块（旧流程/已收割）：跨度缺登按判断项 TODO 提示
        if($calBlk.Found -and ($calBlk.Text -notmatch ('EP-0*' + $n + '\s*='))){
          $todo += ("「各集跨度」缺 EP-{0:d2} → 人工追加：EP-{0:d2}=第X天·晨/日/黄昏/夜（判断项：依据集内【字幕】与剧情推算，跨时段用→）" -f $n)
        }
      }
    }
    # 创作进度汇总由已落账字数序列确定，避免人工维护“已完成/最新完成”漂移。
    $wcFinal=Get-SeqBlock $prog '^\s*-?\s*各集字数'
    if($wcFinal.Found){
      $registeredFinal=@([regex]::Matches($wcFinal.Text,'EP-?(\d+)\s*=') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
      if($registeredFinal.Count -gt 0){
        [int]$latestFinal=($registeredFinal | Measure-Object -Maximum).Maximum
        for($pi=0;$pi -lt $prog.Count;$pi++){
          if($prog[$pi] -match '^\s*-\s*已完成集数[：:]'){
            $newCompleted=("- 已完成集数：{0}集" -f $registeredFinal.Count)
            if($prog[$pi] -ne $newCompleted){ $prog[$pi]=$newCompleted; $fixed += ("创作进度已完成集数={0}" -f $registeredFinal.Count) }
          } elseif($prog[$pi] -match '^\s*-\s*最新完成[：:]'){
            $newLatest=("- 最新完成：EP-{0:d2}" -f $latestFinal)
            if($prog[$pi] -ne $newLatest){ $prog[$pi]=$newLatest; $fixed += ("创作进度最新完成=EP-{0:d2}" -f $latestFinal) }
          }
        }
      }
    }
    # 快照来源核对（登记块已刷新则此处自然通过；未刷新按判断项 TODO，不代写）
    $snapF=($prog | Select-String '快照来源[:：]\s*EP-?(\d+)' | Select-Object -First 1)
    if($wantEp -gt 0 -and -not $snapWritten){
      if(-not $snapF){ $todo += ("「上集末场快照」缺『快照来源：EP-XX』首行 → 人工按 EP-{0:d2} 末场刷新快照并补该行（或在登记块补【快照】子块重跑）" -f $wantEp) }
      elseif($snapF.Line -match '快照来源[:：]\s*EP-?(\d+)' -and [int]$Matches[1] -ne $wantEp){ $todo += ("「上集末场快照」来源=EP-{0}，应按 EP-{1:d2} 末场刷新（含末场时间/地点/在场人物/已完成事件/未了动作/钩子——或在登记块补【快照】子块重跑）" -f $Matches[1],$wantEp) }
    }
    if($fixed.Count){
      $bytes=[System.IO.File]::ReadAllBytes($progPath)
      $hasBom=($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
      Write-Utf8LinesPreserve $progPath $prog
      foreach($fx in $fixed){ Write-Output ("FIXED: {0}" -f $fx) }
      $prog=@(Get-Content $progPath -Encoding UTF8)
    } else { Write-Output "INFO -FixProgress：无机械项需要同步" }
    foreach($td in $todo){ Write-Output ("TODO {0}" -f $td) }
  }

  # —— 草稿排除 / -ExpectLatest 基准 ——
  # scripts 已落盘但「各集字数」台账未登记的**最大连续尾部** EP＝草稿态（本集刚写完、尚未走 ~write 台账收割），
  # 自动从 maxEp 新鲜度基准与三序列差集中排除，防「草稿已落盘 → 快照来源被判过期/三序列把草稿判成缺集」假 FAIL；
  # 未登记但**非**连续尾部（中间缺集）不排除，仍照常 FAIL（那是真缺）。
  # 注意：「已登记但 scripts 文件缺失」目前无专项检查，仅靠快照/序列差集间接暴露（待补反向差集）。
  # -ExpectLatest > 0 时以其为基准，跳过自动推断。
  $draftEps=@()
  if($ExpectLatest -gt 0){
    $draftEps=@($epNums | Where-Object { $_ -gt $ExpectLatest })
    $maxEp=$ExpectLatest
    Write-Output ("INFO -ExpectLatest 指定台账新鲜度基准=EP-{0}（跳过自动推断{1}）" -f $ExpectLatest,$(if($draftEps.Count){ '；其后 '+(($draftEps|ForEach-Object{"EP-$_"}) -join ',')+' 按草稿排除' }else{ '' }))
  } else {
    $wcBlk0=Get-SeqBlock $prog '^\s*-?\s*各集字数'
    $regEps=@(); if($wcBlk0.Found){ foreach($m0 in [regex]::Matches($wcBlk0.Text,'EP-?(\d+)\s*=')){ $regEps += [int]$m0.Groups[1].Value } }
    if($regEps.Count -gt 0 -and $maxEp -gt 0){
      $maxReg=@($regEps | Sort-Object)[-1]
      if($maxEp -gt $maxReg -and ($epNums -contains $maxReg)){
        $tail=@(); $contig=$true
        for($n0=$maxReg+1; $n0 -le $maxEp; $n0++){
          if(($epNums -contains $n0) -and ($regEps -notcontains $n0)){ $tail += $n0 } else { $contig=$false; break }
        }
        if($contig -and $tail.Count -gt 0){
          $draftEps=$tail; $maxEp=$maxReg
          Write-Output ("INFO 检测到草稿 {0}（scripts 已落盘、「各集字数」未登记的连续尾部），已从台账新鲜度基准排除；基准=EP-{1}（如需锁死基准可传 -ExpectLatest）" -f (($draftEps|ForEach-Object{"EP-$_"}) -join ','),$maxReg)
        }
      }
    }
  }

  # a) 快照来源核对（「上集末场快照」须含『快照来源：EP-XX』首行，且等于最新成稿集）
  $snap=($prog | Select-String '快照来源[:：]\s*EP-?(\d+)' | Select-Object -First 1)
  if($snap -and $snap.Line -match '快照来源[:：]\s*EP-?(\d+)'){
    $snapEp=[int]$Matches[1]
    if($snapEp -gt $maxEp){ Out-Issue 'FAIL' 'progress.md' $snap.LineNumber "上集末场快照来源=EP-$snapEp，超前于新鲜度基准 EP-$maxEp（-ExpectLatest 指定或草稿排除后的基准）——请核对基准设置或快照来源" }
    elseif($snapEp -ne $maxEp){ Out-Issue 'FAIL' 'progress.md' $snap.LineNumber "上集末场快照来源=EP-$snapEp，但最新成稿=EP-$maxEp（快照停更 $($maxEp-$snapEp) 集，~write 台账收割未刷新）" }
  } else {
    Out-Issue 'WARN' 'progress.md' 0 "「上集末场快照」缺『快照来源：EP-XX』首行，无法核对新鲜度，请补该行"
  }

  # b) source_relative 只要求字数、强度和原著时间契约；旧日历「各集跨度」冻结，不再读写或校验。
  $requiredSequences=@(@{L='各集字数';P='^\s*-?\s*各集字数'},@{L='各集强度序列';P='^\s*-?\s*各集强度序列'})
  if(-not $sourceTimeMode){ $requiredSequences=@($requiredSequences)+@(@{L='各集跨度';P='^\s*-?\s*各集跨度'}) }
  foreach($sq in $requiredSequences){
    $blk=Get-SeqBlock $prog $sq.P   # 支持「头行＋缩进续行」格式
    if(-not $blk.Found){ Out-Issue 'WARN' 'progress.md' 0 "未找到「$($sq.L)」序列行"; continue }
    $eps=@(); foreach($m in [regex]::Matches($blk.Text,'EP-?(\d+)\s*=')){ $eps += [int]$m.Groups[1].Value }
    $miss=@($epNums | Where-Object { ($eps -notcontains $_) -and ($draftEps -notcontains $_) })   # 草稿态尾部集不计缺集
    if($miss.Count){
      $hint=''
      if($blk.Text -match '(?<!EP-)(?<![\d=])\d{1,3}\s*=\s*\d'){ $hint='；该行含疑似无 EP- 前缀的条目（如「01=8」格式变体）——若数据实存请归一为 EP-XX=… 再重检' }
      Out-Issue 'FAIL' 'progress.md' ($blk.HeaderIdx+1) ("「$($sq.L)」缺集：{0}（scripts 已成稿未登记，台账停更{1}）" -f (($miss|ForEach-Object{"EP-$_"}) -join ','),$hint)
    }
  }
  if($sourceTimeMode){
    $timeRequiredEps=@($epNums | Where-Object { $_ -ge $sourceTimeFrom -and ($draftEps -notcontains $_) })
    $timeRange=Get-BlockRange $prog '^##\s*原著时间锚'
    if($timeRequiredEps.Count -eq 0){ Write-Output ("INFO 旧绝对日历已冻结；原著时间锚从 EP-{0:d2} 起启用" -f $sourceTimeFrom) }
    elseif(-not $timeRange.Found){ Out-Issue 'FAIL' 'progress.md' 0 ("缺「## 原著时间锚」区块（从 EP-{0:d2} 起必填）" -f $sourceTimeFrom) }
    else {
      $timeBody=(@($prog[($timeRange.HeaderIdx+1)..([Math]::Max($timeRange.HeaderIdx+1,$timeRange.EndIdx-1))]) -join "`n")
      $timeEps=@([regex]::Matches($timeBody,'(?m)^-\s*EP-0*(\d+)\s*｜') | ForEach-Object { [int]$_.Groups[1].Value })
      $missingTimeEps=@($timeRequiredEps | Where-Object { $timeEps -notcontains $_ })
      if($missingTimeEps.Count){ Out-Issue 'FAIL' 'progress.md' ($timeRange.HeaderIdx+1) ("「原著时间锚」缺集：{0}" -f (($missingTimeEps|ForEach-Object{"EP-$_"}) -join ',')) }
    }
  }

  # c) 角色状态快照 bullet 去重（同角色多条 = 双口径并存）
  $inSnap=$false; $chars=@{}
  for($i=0;$i -lt $prog.Count;$i++){
    $l=$prog[$i].Trim()
    if($l -match '^##\s*角色状态快照'){ $inSnap=$true; continue }
    if($inSnap -and $l -match '^##\s'){ break }
    if($inSnap -and $l -match '^-\s*([^：:]+?)[：:]'){ $cn=($Matches[1].Trim() -replace '\*',''); if($chars.ContainsKey($cn)){ $chars[$cn]++ } else { $chars[$cn]=1 } }
  }
  foreach($cn in $chars.Keys){ if($chars[$cn] -ge 2){ Out-Issue 'WARN' 'progress.md' 0 "角色状态快照「$cn」有 $($chars[$cn]) 条 bullet → 就地覆盖为唯一条、旧值移『快照史』（防双口径）" } }

  # c2) 伏笔状态白名单 + 待埋设逾期——progress 区块与分表 ledger-foreshadow.md 双兼容
  $fyEntries=@()
  $inFy=$false; $progHasFy=$false
  for($i=0;$i -lt $prog.Count;$i++){
    $l=$prog[$i].Trim()
    if($l -match '^##\s*待回收伏笔'){ $inFy=$true; continue }
    if($inFy -and $l -match '^##\s'){ break }
    if($inFy -and $l -match '^-\s'){
      $fyEntries += @{File='progress.md';Ln=($i+1);Text=$l}
      if($l -match '状态[:：]'){ $progHasFy=$true }
    }
  }
  $fyLedger=Join-Path $projDir 'ledger-foreshadow.md'
  if(Test-Path $fyLedger){
    $ll=@(Get-Content $fyLedger -Encoding UTF8); $ledgerHasFy=$false
    for($i=0;$i -lt $ll.Count;$i++){
      $l="$($ll[$i])".Trim()
      if($l -match '^-\s'){ $fyEntries += @{File='ledger-foreshadow.md';Ln=($i+1);Text=$l}; if($l -match '状态[:：]'){ $ledgerHasFy=$true } }
    }
    if($ledgerHasFy -and $progHasFy){ Out-Issue 'WARN' 'progress.md' 0 "伏笔台账双载体：progress「待回收伏笔」与 ledger-foreshadow.md 同时有状态条目——分表布局下 progress 区块只留指针行，防双口径" }
  }
  foreach($e in $fyEntries){
    $l=$e.Text
    if($l -match '状态[:：]\s*(.+?)\s*$'){
      $st=(($Matches[1].Trim()) -replace '[（(].*$','' -replace '\*','').Trim()
      if($st -notmatch '^(待埋设|待回收|已回收)'){ Out-Issue 'WARN' $e.File $e.Ln "伏笔状态词「$st」不在白名单｛待埋设/待回收/已回收（EP-XX）｝——请归一（『开放留白/进行中』等需先白名单化）" }
      elseif($st -match '^待埋设' -and $l -match '埋设[于自]?\s*EP-?(\d+)'){
        $fyEp=[int]$Matches[1]; if($maxEp -gt 0 -and $fyEp -le $maxEp){ Out-Issue 'FAIL' $e.File $e.Ln "伏笔埋设集 EP-$fyEp ≤ 最新成稿 EP-$maxEp 却仍『待埋设』——埋设集已成稿须转『待回收』并补埋设原文摘录" }
      }
    }
  }

  # d) 道具台账触发词粗筛（INFO 清单，供 checker/人工核对变动是否入账）
  $trig=$propTrig   # 与「规则词表」区及 -Rules 速查同源
  foreach($f in $epFiles){
    $fl=@(Strip-LedgerBlock @(Get-Content $f.FullName -Encoding UTF8)); $hits=@()   # 剥离台账登记块，防其「易主/损毁」字段误报
    foreach($ll in $fl){ if($ll -match $trig){ $hits += $Matches[0] } }
    if($hits.Count){ Out-Issue 'INFO' $f.Name 0 ("含道具台账触发词【{0}】→ 核对『道具/信物台账』有无本集变动记录" -f (($hits|Select-Object -Unique|Select-Object -First 5) -join '/')) }
  }

  # e) 仅旧策略兼容绝对日历校验。source_relative 下场次头时段只作拍摄时段，不反推故事日期。
  $calBlk2=if($sourceTimeMode){ @{Found=$false} }else{ Get-SeqBlock $prog '^\s*-?\s*各集跨度' }
  if(-not $sourceTimeMode -and $calBlk2.Found){
    $struct=0
    foreach($m in [regex]::Matches($calBlk2.Text,'EP-?(\d+)\s*=\s*第[\d~至]+天·([日夜晨黄昏]+(?:→[日夜晨黄昏]+)?)')){
      $struct++
      $ep=[int]$m.Groups[1].Value; $calSlots=$m.Groups[2].Value
      $calSet=@($calSlots -split '→' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
      $epf=$epFiles | Where-Object { $_.Name -match ('^EP-0*{0}\.md$' -f $ep) } | Select-Object -First 1
      if(-not $epf){ continue }
      $efl=@(Strip-LedgerBlock @(Get-Content $epf.FullName -Encoding UTF8)); $hdr=@()   # 剥离台账登记块，防其「闪回」等字样误豁免末场
      for($k=0;$k -lt $efl.Count;$k++){ if($efl[$k].Trim() -match '^场次\s+[\d\-]+：\s*\S+\s+\S+\s+(\S+)\s*$'){ $hdr += @{Slot=$Matches[1]; Idx=$k} } }
      for($si=0;$si -lt $hdr.Count;$si++){
        $start=$hdr[$si].Idx; $end=if($si+1 -lt $hdr.Count){ $hdr[$si+1].Idx }else{ $efl.Count }
        # 闪回场按闪回时空判、豁免。场级闪回字幕【字幕：…·闪回】规范写在所属场次头之前（官方示例写法），
        # ①回看本场头前 3 行内有无「·闪回」字幕（豁免本场，不落到上一场）
        #           ②本场区间尾部紧贴下一场次头的「·闪回」字幕属于下一场的头前标记，不豁免本场
        $fb=$false
        for($lb=[Math]::Max(0,$start-3); $lb -lt $start; $lb++){ if("$($efl[$lb])".Trim() -match '^【字幕：[^】]*·闪回】'){ $fb=$true; break } }
        if(-not $fb){
          for($ci=$start; $ci -lt $end; $ci++){
            if(($si+1 -lt $hdr.Count) -and ($ci -ge $end-3) -and ("$($efl[$ci])".Trim() -match '^【字幕：[^】]*·闪回】')){ continue }
            if($efl[$ci] -match '闪回'){ $fb=$true; break }
          }
        }
        if($fb){ continue }
        $hs=($hdr[$si].Slot -replace '·.*',''); $hsBase=($hs -split '→')[0]
        if(($calSet -notcontains $hs) -and ($calSet -notcontains $hsBase)){
          Out-Issue 'FAIL' $epf.Name ($start+1) "场次头时段「$hs」不在故事内日历声明的 EP-$ep 时段〔$calSlots〕内（接缝⑤·时段错标）"
        }
      }
    }
    if($struct -eq 0){ Out-Issue 'WARN' 'progress.md' ($calBlk2.HeaderIdx+1) "「各集跨度」未用结构化日内时段后缀（EP-XX=第X天·晨/日/黄昏/夜）→ 无法机检场次头时段锚定，建议升级格式" }
  }

  $sumLabel = if($Startup){ 'startup' } else { 'progress' }
  Write-Output ("SUMMARY({0}): 最新成稿=EP-{1}，FAIL 项 {2} 个" -f $sumLabel,$maxEp,$script:failCount)
  if($script:failCount -gt 0){ exit 1 } else { exit 0 }
}

# ---------- 剧本机检 ----------
# 数值阈值/景别时段白名单/△※词表/口癖/预告骨架定义集中在「规则词表」区，与 -Rules 速查同源
# 从 progress「高频意象表」第1列动态补充项目自定义口癖
try {
  $pbase = if(Test-Path $Path -PathType Container){ (Get-Item $Path).Parent.FullName } else { (Get-Item $Path).Directory.Parent.FullName }
  $pcand = Join-Path $pbase 'progress.md'
  if(Test-Path $pcand){
    $inImg=$false
    foreach($row in (Get-Content $pcand -Encoding UTF8)){
      $r=$row.Trim()
      if($r -match '^##\s*高频意象表'){ $inImg=$true; continue }
      if($inImg -and $r -match '^##\s'){ break }
      if($inImg -and $r -match '^\|'){
        $c0=(($r.Trim('|') -split '\|')[0]).Trim()
        if($c0 -and $c0 -notmatch '意象|句模' -and $c0 -notmatch '^[:\-\s]+$'){
          $w=($c0 -replace '（[^）]*）','' -replace '如[:：]','' -replace '\[|\]','').Trim()
          if($w -and $w.Length -ge 2 -and $fingerprints -notcontains $w){ $fingerprints += $w }
        }
      }
    }
  }
} catch {}
# ---------- 角色卡资产名/别名注册表（资产名唯一性机扫，防一人多名被制作端拆成多个角色资产） ----------
# 别名列机器可读格式（plot-map 角色卡「别名/改名（生效集）」列，项目登记、本脚本解析）：
#   旧名→新名（EP-XX起）  改名：旧名在 EP-XX 之后的出场表/说话人行失效；新名在 EP-XX 之前不得出现（生效集当集双名均合法）
#   某名（仅台词）        并存别名：只许出现在台词/△ 内，出场表/说话人行一律用第1列资产名
#   某名（禁）            项目禁用名：全文任何位置出现即 FAIL（如改名约定淘汰的旧译名）
$aliasRules = @()
$pmPath = $PlotMap
if(-not $pmPath){
  try{
    $base = if(Test-Path $Path -PathType Container){ (Get-Item $Path).Parent.FullName } else { (Get-Item $Path).Directory.Parent.FullName }
    $ccand = Join-Path $base 'character-cards.md'   # 分表布局：角色卡独立文件优先
    $cand  = Join-Path $base 'plot-map.md'
    if(Test-Path $ccand){ $pmPath = $ccand }
    elseif(Test-Path $cand){ $pmPath = $cand }
  } catch {}
}
if($pmPath -and (Test-Path $pmPath)){
  $inIdx=$false; $colAsset=-1; $colAlias=-1
  foreach($row in (Get-Content $pmPath -Encoding UTF8)){
    $r=$row.Trim()
    if($r -match '^##\s*角色索引'){ $inIdx=$true; continue }
    if($inIdx -and $r -match '^##?\s'){ break }
    if(-not $inIdx -or $r -notmatch '^\|'){ continue }
    $cells = @($r.Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
    if($colAsset -lt 0){
      for($c=0;$c -lt $cells.Count;$c++){
        if($cells[$c] -match '^角色'){ $colAsset=$c }
        if($cells[$c] -match '别名'){ $colAlias=$c }
      }
      continue
    }
    if($r -match '^\|[\s:：\-]+\|'){ continue }
    if($colAsset -ge $cells.Count){ continue }
    $main = (($cells[$colAsset] -replace '\*','' -replace '（[^）]*）','') -split '[·/、]')[0].Trim()
    if(-not $main){ continue }
    if($colAlias -ge 0 -and $colAlias -lt $cells.Count){
      $cell = $cells[$colAlias] -replace '\*',''
      if($cell -and $cell -notmatch '^(无|—|－|-)$'){
        foreach($item in ($cell -split '、')){
          $it=$item.Trim(); if(-not $it){ continue }
          if($it -match '^(.+?)→(.+?)（[^）]*EP-?(\d+)[^）]*）$'){
            $aliasRules += @{ Alias=$Matches[1].Trim(); Asset=$Matches[2].Trim(); Kind='旧名'; EP=[int]$Matches[3] }
            $aliasRules += @{ Alias=$Matches[2].Trim(); Asset=$Matches[2].Trim(); Kind='新名'; EP=[int]$Matches[3] }
          } elseif($it -match '^(.+?)（[^）]*仅台词[^）]*）$'){
            $aliasRules += @{ Alias=$Matches[1].Trim(); Asset=$main; Kind='台词'; EP=0 }
          } elseif($it -match '^(.+?)（[^）]*禁[^）]*）$'){
            $aliasRules += @{ Alias=$Matches[1].Trim(); Asset=$main; Kind='禁'; EP=0 }
          } else {
            Out-Issue 'WARN' (Split-Path $pmPath -Leaf) 0 "角色卡别名条目无法解析：「$it」（须含 →…EP…起 / 仅台词 / 禁）——机扫将跳过该条，防静默丢弃"
          }
        }
      }
    }
  }
  if($colAlias -lt 0){ Write-Output "INFO 角色卡未发现「别名/改名」列，资产名唯一性机扫跳过（建议按模板迁移七列角色卡）" }
} else {
  Write-Output "INFO 未找到 character-cards.md / plot-map.md（可用 -PlotMap 指定），资产名唯一性机扫跳过"
}
$characterProtectedNames = @($aliasRules | ForEach-Object { @([string]$_.Asset, [string]$_.Alias) } | Where-Object { $_ } | Sort-Object @{Expression={$_.Length};Descending=$true}, @{Expression={$_}} -Unique)

# ---------- 道具索引别名表（character-cards/plot-map 优先，无表时以 progress.md 兜底）——道具一物两名是资产库杀手，创作期拦截（一律 WARN） ----------
$propRules = @(Get-PropRules $pmPath)
try{
  $base2 = if(Test-Path $Path -PathType Container){ (Get-Item $Path).Parent.FullName } else { (Get-Item $Path).Directory.Parent.FullName }
  if($propRules.Count -eq 0 -and $pmPath -and $pmPath -match 'character-cards'){   # 角色卡分表无道具表时回落 plot-map
    $pm2 = Join-Path $base2 'plot-map.md'
    if(Test-Path $pm2){ $propRules = @(Get-PropRules $pm2) }
  }
  $prog2 = Join-Path $base2 'progress.md'
  if($propRules.Count -eq 0 -and (Test-Path $prog2)){ $propRules = @(Get-PropRules $prog2) }
} catch {}
if($propRules.Count -eq 0){ Write-Output "INFO 未发现「道具索引」别名表（plot-map/progress），道具名唯一性机扫跳过（可增设表：| 道具 | 别名 | 说明 |，别名支持「某名（禁）」）" }
$propProtectedNames = @($propRules | ForEach-Object { @([string]$_.Asset, [string]$_.Alias) } | Where-Object { $_ } | Sort-Object @{Expression={$_.Length};Descending=$true}, @{Expression={$_}} -Unique)

# ---------- 场景名注册表（跨集同地异名聚类，防同一场景被拆成多个资产） ----------
$locRegistry = @{}

# ---------- 跨集避让缓存路径（项目根 .lint-cache.json；目录模式全量重建、单集模式读取拦截+增量更新） ----------
$cacheFile = ''
try{
  $cacheBase = if(Test-Path $Path -PathType Container){ (Get-Item $Path).Parent.FullName } else { (Get-Item $Path).Directory.Parent.FullName }
  if($cacheBase){ $cacheFile = Join-Path $cacheBase '.lint-cache.json' }
} catch {}

$targets = @()
if(Test-Path $Path -PathType Container){ $targets = @(Get-ChildItem $Path -Filter 'EP-*.md' -File | Sort-Object Name) }
else{ $targets = @(Get-Item $Path) }
if($targets.Count -eq 0){ Out-Issue 'FAIL' $Path 0 "未找到 EP-*.md 文件（空目录/错路径）"; Write-Output "SUMMARY: 0 个文件，FAIL 项 1 个"; exit 1 }
$previewDisabledFrom = 0
$sourceRelativeTime = $false
$sourceRelativeFrom = 1
try{
  $policyPath = if($cacheBase){ Join-Path $cacheBase '.comic-adapt\policy.json' } else { '' }
  if($policyPath -and (Test-Path $policyPath)){
    $policy = Get-Content -Raw -Encoding UTF8 $policyPath | ConvertFrom-Json
    if(-not [bool]$policy.preview_enabled){ $previewDisabledFrom = [int]$policy.preview_disabled_from_episode }
    $sourceRelativeTime = ([string]$policy.time_model -eq 'source_relative')
    if($policy.source_time_from_episode){ $sourceRelativeFrom=[int]$policy.source_time_from_episode }
  }
} catch { Out-Issue 'FAIL' 'policy.json' 0 "V6策略文件无法读取：$($_.Exception.Message)" }

$wordTable = @()
$titles = @{}   # 机扫⑨：集标题唯一（跨文件）
$fpAgg = @{}    # 指纹词 → 命中集列表（跨集聚合）
$prevAgg = @{}  # 预告骨架 → 命中集列表
foreach($f in $targets){
  $rawLines = @(Get-Content $f.FullName -Encoding UTF8)   # 强制数组：单行/空文件下标取值仍安全
  $name = $f.Name
  # —— 台账登记块剥离（成稿元数据非正文：字数/机扫/指纹/预告聚合一律不含）——
  $hasLB=$false; $hasLBEnd=$false
  foreach($rl in $rawLines){ $rt="$rl".Trim(); if($rt -match '^【台账登记块】'){ $hasLB=$true }; if($rt -match '^【台账登记块·完】'){ $hasLBEnd=$true } }
  if($hasLB -and -not $hasLBEnd){ Out-Issue 'WARN' $name 0 "台账登记块缺【台账登记块·完】结束标记——剥离按文件尾处理，补标记防误吞正文" }
  if($hasLB){
    $draftLedger=Get-LedgerBlock $rawLines
    $draftActions=if($draftLedger.Fields.ContainsKey('行动线')){@($draftLedger.Fields['行动线'])}else{@()}
    foreach($actionValue in $draftActions){
      if("$actionValue" -match '推进'){ Out-Issue 'FAIL' $name 0 "行动线动词『推进』非法；使用 发起/提及/引爆/了结/撤销（一般推进归一为『提及』）" }
      elseif("$actionValue" -notmatch '发起|提及|引爆|了结|撤销'){ Out-Issue 'FAIL' $name 0 "行动线缺合法动词：$actionValue" }
    }
    $draftRoleStates=if($draftLedger.Fields.ContainsKey('角色状态')){@($draftLedger.Fields['角色状态'])}else{@()}
    foreach($roleStateValue in $draftRoleStates){
      if("$roleStateValue" -notmatch '^\s*[^｜]+｜[^｜]+｜证据\s*[=＝]\s*\S'){ Out-Issue 'FAIL' $name 0 "角色状态格式非法；使用 角色｜当前状态｜证据=场次/原著锚" }
    }
    $targetEpisodeNumber=0; if($name -match '^EP-0*(\d+)\.md$'){ $targetEpisodeNumber=[int]$Matches[1] }
    $requiresSourceTime=($sourceRelativeTime -and ($targetEpisodeNumber -ge $sourceRelativeFrom -or $draftLedger.Fields.ContainsKey('原著时间')))
    if($requiresSourceTime){
      if(-not $draftLedger.Fields.ContainsKey('原著时间')){ Out-Issue 'FAIL' $name 0 ("台账登记块缺「原著时间：」source_time_contract（EP-{0:d2}起必填）" -f $sourceRelativeFrom) }
      foreach($timeValue in @($draftLedger.Fields['原著时间'])){
        foreach($field in @('上集结束时间锚','本集原著时间原话','事件先后','闪回边界','本集结束状态')){
          if("$timeValue" -notmatch ([regex]::Escape($field)+'\s*[=＝]')){ Out-Issue 'FAIL' $name 0 "原著时间契约缺字段「$field」" }
        }
      }
      $draftDeadlines=if($draftLedger.Fields.ContainsKey('期限')){@($draftLedger.Fields['期限'])}else{@()}
      foreach($deadlineValue in $draftDeadlines){
        if("$deadlineValue" -notmatch '「.+?」' -or "$deadlineValue" -notmatch '状态\s*[=＝]\s*(?:待按原著兑现|已按原著兑现|已失效)' -or "$deadlineValue" -notmatch '证据\s*[=＝]\s*\S'){
          Out-Issue 'FAIL' $name 0 "期限格式非法；使用「原著时间原话」｜状态=待按原著兑现/已按原著兑现/已失效｜证据=原著第X章…"
        }
      }
    }
  }
  $lines = @(Strip-LedgerBlock $rawLines)

  # —— 编码定性诊断：U+FFFD（UTF-8 解码替换符）占比 >5% ＝ 疑似 GBK 等非 UTF-8 编码 ——
  # 先定性再跳过本文件后续检查，防把乱码文件报成「场次数 0」等误导性结构错、把改稿引向改格式而非转码
  $rawAll = ($lines -join '')
  if($rawAll.Length -gt 0){
    $fffd = $rawAll.Split([char]0xFFFD).Count - 1
    if($fffd * 20 -gt $rawAll.Length){
      Out-Issue 'FAIL' $name 0 ("文件疑似非 UTF-8 编码（GBK?，乱码替换符占比 {0}%），请转码为 UTF-8 后重检" -f [int][Math]::Round($fffd*100.0/$rawAll.Length))
      continue
    }
  }
  $full=0; $scenes=0; $shotCount=0
  $sceneCast=@{}; $sceneSpeakers=@{}; $curScene=''
  $prevType=''   # 用于 OS 连缀检测：上一非空行类型
  $osChain=0
  $previewLines=@()
  $lastSpeaker=''; $speakerRun=0   # 同角色连续台词块计数
  $sceneSlot=''; $sceneNightStrong=$false; $sceneNightWeak=$false; $sceneFlashback=$false; $sceneStartLn=0   # 机扫④：时段一致性
  $pendingFlashback=$false   # 机扫④：场次头之前的【字幕：…·闪回】置 pending，由下一个场次头消费

  for($i=0;$i -lt $lines.Count;$i++){
    $t=$lines[$i].Trim()
    if($t -eq ''){ continue }
    $ln=$i+1

    # —— 框架行排除后计字数（全字符口径，与 progress 登记一致）——
    $isFrame = ($t -match '^[━─═]+$') -or ($t -match '^(剧名|集数|模式|对应剧情点|原著章节|情绪类型|情绪强度)：') -or ($t -match '^出场人物：') -or ($t -eq '【卡黑】')
    if(-not $isFrame -and -not ($t -match '^场次\s')){ $full += ($t -replace '\s','').Length }

    # —— 机扫⑨：集标题唯一（跨文件重名）——
    if($t -match '^集数：\S+\s+(.+?)\s*$'){
      $title=$Matches[1].Trim()
      if($title){ if($titles.ContainsKey($title) -and $titles[$title] -ne $name){ Out-Issue 'FAIL' $name $ln "集标题「$title」与 $($titles[$title]) 重名（机扫⑨）" } else { $titles[$title]=$name } }
    }

    # —— 机扫④：时段词收集（与场次头时段一致性核对，闪回场豁免）——
    # 场级闪回字幕【字幕：…·闪回】规范写在所属场次头之前（examples/script-example.md 官方写法）：
    #   置 pending 旗标、由下一个场次头消费，避免把豁免点到上一场；
    #   后方近处无场次头（头后/场中写法）则豁免当前场——两种位置均兼容
    if($t -match '^【字幕：[^】]*·闪回】'){
      $isPreHdr=$false
      for($la=$i+1; $la -lt [Math]::Min($i+6,$lines.Count); $la++){
        $laT=$lines[$la].Trim()
        if($laT -eq '' -or $laT -match '^[━─═]+$'){ continue }
        if($laT -match '^场次\s'){ $isPreHdr=$true }
        break
      }
      if($isPreHdr){ $pendingFlashback=$true } else { $sceneFlashback=$true }
    }
    elseif($t -match '闪回'){ $sceneFlashback=$true }
    if(-not $isFrame){
      if($t -match '当晚|深夜|入夜|夜里|夜色|华灯|夜幕|半夜|月光|星空'){ $sceneNightStrong=$true }
      elseif($t -match '今晚|晚上|今夜'){ $sceneNightWeak=$true }
    }

    # —— 场次头校验 ——
    if($t -match '^场次\s+[\d\-]+：\s*(\S+)\s+(\S+)\s+(\S+)\s*$'){
      # 结算上一场时段（机扫④）
      if($sceneSlot -eq '日' -and -not $sceneFlashback){
        if($sceneNightStrong){ Out-Issue 'FAIL' $name $sceneStartLn "场次头「日」但场内含明确夜间词（当晚/深夜/入夜等）→ 拍摄时段错标，核对原著当场时间" }
        elseif($sceneNightWeak){ Out-Issue 'WARN' $name $sceneStartLn "场次头「日」但场内含『今晚/晚上』→ 若指当前时段应『夜』（下午说『今晚X点』属合法未来指示可放行）" }
      }
      $scenes++
      $curScene="场$scenes"
      $inout=$Matches[1]; $loc=$Matches[2]; $slot=$Matches[3]
      if($inout -notmatch '^(内|外|内→外|外→内)$'){ Out-Issue 'FAIL' $name $ln "场次头内外位非法「$inout」" }
      if($slot -notmatch $slotWhite){ Out-Issue 'FAIL' $name $ln "场次头时段位非法「$slot」（白名单：日/夜/晨/黄昏[·天气]/箭头跨时）" }
      if($slot -match '闪回'){ Out-Issue 'FAIL' $name $ln "闪回禁止写进时段位，用【字幕：X·闪回】" }
      if($loc -match '闪回|回忆|梦境|往昔'){ Out-Issue 'FAIL' $name $ln "闪回禁止写进地点位「$loc」——场级用【字幕：X·闪回】、拍级用「※ 闪回：…」" }
      $sceneCast[$curScene]=@(); $sceneSpeakers[$curScene]=@()
      $locKey=$loc.Trim()
      if($locKey){ if(-not $locRegistry.ContainsKey($locKey)){ $locRegistry[$locKey]=@() }; $locRegistry[$locKey] += $name }
      $sceneSlot=$slot; $sceneNightStrong=$false; $sceneNightWeak=$false; $sceneFlashback=$pendingFlashback; $pendingFlashback=$false; $sceneStartLn=$ln   # 消费头前闪回 pending
      $lastSpeaker=''; $speakerRun=0
      $prevType='scene'; continue
    }
    if($t -match '^场次\s'){ $scenes++; $curScene="场$scenes"; Out-Issue 'FAIL' $name $ln "场次头三要素解析失败（须：内/外  地点  时段）"; $sceneCast[$curScene]=@(); $sceneSpeakers[$curScene]=@(); $sceneSlot=''; $sceneNightStrong=$false; $sceneNightWeak=$false; $sceneFlashback=$pendingFlashback; $pendingFlashback=$false; $lastSpeaker=''; $speakerRun=0; $prevType='scene'; continue }

    # —— 出场人物收集 ——
    if($t -match '^出场人物：(.+)$'){
      $cast = $Matches[1] -split '；|;' | ForEach-Object { ($_ -replace '（.*?）','').Trim() } | Where-Object { $_ }
      $sceneCast[$curScene]=$cast; $prevType='cast'; continue
    }

    # —— △ / ※ 行校验 ——
    if($t -match '^[△※]'){
      $isDelta = $t.StartsWith('△')
      $lastSpeaker=''; $speakerRun=0   # △/※ 打断台词流
      if($isDelta -and $t -match '^△\s*(（[^）]*）\s*)?字幕[:：]'){ Out-Issue 'FAIL' $name $ln "△ 行内借『字幕：』壳承载文字 → 时间/地点用【字幕：…】独立行、文内文本用△（特写）字迹" }
      # 景别 token 白名单
      if($t -match '^[△※]\s*（([^）]+)）'){
        $paren = $Matches[1]   # 先存副本：后续 -match 会覆盖 $Matches
        $tok = $paren -split '·' | Select-Object -First 1
        if($isDelta){
          $shotCount++
          if($shotWhite -notcontains $tok){ Out-Issue 'FAIL' $name $ln "景别位非法 token「（$paren）」（白名单：$($shotWhite -join '/')）" }
        } else {
          if($paren -match '演绎|闪回|蒙太奇|场景变幻'){ Out-Issue 'FAIL' $name $ln "※ 括号位时空token「$paren」非法（闪回走【字幕：X·闪回】/拍级用「※ 闪回：」）" }
        }
        if($paren -match '音效'){ Out-Issue 'FAIL' $name $ln "禁止（音效）占景别位——改【音效】行或裸拟声行" }
      }
      # 台词嵌△：说话动词+冒号+引号＝人声台词写进画面行 → FAIL 拆独立台词块；长引号内容 WARN 语义复核
      if($t -match '(说|道|问|喊|骂|斥|吼|叫|答|回|应)[了道]?\s*[：:]\s*[「“]'){ Out-Issue 'FAIL' $name $ln "台词嵌△（说话动词+引号）→ 人声台词拆独立台词块（三行结构）" }
      elseif($t -match '[「“]'){
        $qLong=$false
        foreach($qm in [regex]::Matches($t,'「([^」]*)」')){ $qc=$qm.Groups[1].Value; if($qc.Length -ge 8 -or $qc -match '[，。！？…]'){ $qLong=$true; break } }
        if($qLong -and $t -notmatch '字迹|写着|刻着|刻有|牌匾|匾额|字条|信纸|信上|书页|纸上|话本|书卷|卷轴|榜文|榜单|屏上|屏幕|光屏|光幕|弹幕|热搜|一行字|口型|字样|大字|小字|标语|条幅|封面|标题|手势'){
          Out-Issue 'WARN' $name $ln "△/※ 引号内容疑似台词/叙述借壳 → 人声拆台词块；文内文本用 △（特写）…字迹：「」形（语义复核）" }
      }
      # 不可拍词表（扫描前剥离 「…」引文段 与 括号内景别/指示，避免信纸引文/台词引号误伤）
      $scan = $t -replace '「[^」]*」','' -replace '（[^）]*）',''
      if($scan -match $mindFail){ Out-Issue 'FAIL' $name $ln "△/※ 含不可拍心理/全知词「$($Matches[0])」→ 并置演出/OS/窃语台词" }
      elseif($scan -match $mindWarn){ Out-Issue 'WARN' $name $ln "△/※ 疑似不可拍词「$($Matches[0])」→ 语义复核（若非可拍画面须转 OS/动作；如『手心中的玉佩』属可拍可放行）" }
      elseif($scan -match $mindSelfCheck){ Out-Issue 'WARN' $name $ln "△/※ 命中自检提示词「$($Matches[0])」〔写作自检提示·非checker判罚依据〕→ 自检：评价总结/动机推断/代写心声拍不出——改具体可拍动作或删；带动作锚点（如『瞪眼跺脚尽显跋扈』）可裁决保留" }
      # 概述说话：△ 叙述「谁说了什么/谁被告知」拍不出 → 落成台词块或删（WARN 语义复核）
      if($scan -match '(听说|据说|转告|告知|告诉|禀报|嘱咐|交代|讲述|商议|盘问)'){ Out-Issue 'WARN' $name $ln "△/※ 疑似概述说话「$($Matches[1])」（叙述'谁说了什么'拍不出）→ 落成台词块/画外台词，或删（语义复核）" }
      # ※ 承载主语叙事动作（粗判：※ 后含人名+动词的叙事——交语义复核）
      if(-not $isDelta -and $t -match '^※(?!\s*（)[^：]*?(被|冲向|按在|拔出|抓起|杀|斩|挥|跑|奔)'){ Out-Issue 'WARN' $name $ln "※ 疑似承载叙事动作（动作应回 △）：$($t.Substring(0,[Math]::Min(24,$t.Length)))…" }
      $prevType='delta'; continue
    }

    # —— 字幕唯一形 ——
    if($t -match '^【字幕】'){ Out-Issue 'FAIL' $name $ln "字幕变体「【字幕】＋块外文字」→ 唯一形【字幕：…】" }
    if($t -match '^【字幕:'){ Out-Issue 'FAIL' $name $ln "字幕半角冒号变体「【字幕:」→【字幕：】（全角冒号）" }
    if($t -match '^【字幕[·.]'){ Out-Issue 'FAIL' $name $ln "字幕变体「【字幕·】」→ 唯一形【字幕：…】；叙事文字改插入镜头△（特写）字迹" }
    if($t -match '^[〔\[]字幕'){ Out-Issue 'FAIL' $name $ln "字幕变体（〔字幕〕/[字幕]）→ 唯一形【字幕：…】" }
    if($t -match '^（字幕'){ Out-Issue 'FAIL' $name $ln "（字幕·…）占括号位非法 → 改 △（特写）书页/信纸字迹" }
    if($t -match '^【字幕：([^】]+)】'){
      if($Matches[1].Length -gt 18){ Out-Issue 'WARN' $name $ln "字幕内容偏长，核查是否叙事借壳（只许时间/地点[·闪回]）" }
      $lastSpeaker=''; $speakerRun=0
      $prevType='subtitle'; continue
    }

    # —— OS 连缀 ——
    if($t -match '^【内心OS·'){
      if($prevType -eq 'os'){ Out-Issue 'FAIL' $name $ln "OS 背靠背连缀（两块间须隔台词或新△）" }
      $lastSpeaker=''; $speakerRun=0
      $prevType='os'; continue
    }

    # —— 面板/音效/旁白 ——
    if($t -match '^【面板'){ $lastSpeaker=''; $speakerRun=0; $prevType='panel'; continue }
    if($t -match '^【音效】'){ $lastSpeaker=''; $speakerRun=0; $prevType='se'; continue }
    if($t -match '^【旁白·'){ Out-Issue 'FAIL' $name $ln "禁用【旁白·人物名】（人物画外用 角色名+（画外·…）台词形）" ; $lastSpeaker=''; $speakerRun=0; $prevType='narr'; continue }

    # —— 裸拟声行（合法音效短行 ≤8字符，仅拟声+标点）——
    if($t -match '^[一-龥]{1,4}[！？…—－]{1,4}$' -and $t.Length -le 8){ $lastSpeaker=''; $speakerRun=0; $prevType='se'; continue }

    # —— 台词三行结构：角色名 → （指示） → 正文 ——
    if($t -match '^（.+）$'){
      # 上一行应为角色名
      $prevType='ind'; continue
    }
    if($prevType -eq 'ind'){
      # 台词正文：单句长度
      foreach($s in ($t -split '[。！？…]')){
        $sl=($s -replace '\s','').Length
        if($sl -gt $maxSent){ Out-Issue 'FAIL' $name $ln "台词单句超限 ${sl}>${maxSent}：$($s.Substring(0,[Math]::Min(20,$s.Length)))…" }
      }
      $prevType='dlg'; continue
    }
    # 角色名行（启发式：短行、无标点、下一行是（指示））
    if($t.Length -le 16 -and $t -notmatch '[，。：！？△※】]' -and ($i+1 -lt $lines.Count) -and ($lines[$i+1].Trim() -match '^（.+）$')){
      $spk = ($t -replace '（.*?）','').Trim()
      if($curScene -and $sceneSpeakers.ContainsKey($curScene)){ $sceneSpeakers[$curScene] += $spk }
      # 连续台词块计数（同名紧邻、其间无△/他人台词）
      if($spk -eq $lastSpeaker){ $speakerRun++ } else { $lastSpeaker=$spk; $speakerRun=1 }
      if($speakerRun -ge 3){ Out-Issue 'FAIL' $name $ln "同角色「$spk」连续台词块 $speakerRun（≥3，其间无△/他人台词）→ 插对手反应△/他人台词/合并" }
      $prevType='speaker'; continue
    }
    # 缺（指示）行的台词块——某行==本场出场成员/资产名，但下一行非（指示）→ 三行结构违规（连锁令单句/交叉/别名闸门逃逸）
    if($t.Length -le 16 -and $t -notmatch '[，。：！？△※】「」（）]'){
      $bareName=$t.Trim(); $castHit=$false
      if($curScene -and $sceneCast.ContainsKey($curScene)){ foreach($c in $sceneCast[$curScene]){ if($c -and $c -eq $bareName){ $castHit=$true; break } } }
      if(-not $castHit -and $aliasRules.Count -gt 0){ foreach($ar in $aliasRules){ if($bareName -eq $ar.Asset){ $castHit=$true; break } } }
      if($castHit){
        Out-Issue 'FAIL' $name $ln "缺（指示）行：说话人「$bareName」后应接（语气/动作指示）（三行结构强制）"
        if($curScene -and $sceneSpeakers.ContainsKey($curScene)){ $sceneSpeakers[$curScene] += $bareName }
        if($bareName -eq $lastSpeaker){ $speakerRun++ } else { $lastSpeaker=$bareName; $speakerRun=1 }
        if($speakerRun -ge 3){ Out-Issue 'FAIL' $name $ln "同角色「$bareName」连续台词块 $speakerRun（≥3，其间无△/他人台词）" }
        $prevType='ind'; continue   # 置 ind 使下一行（台词正文）过单句闸
      }
    }

    # —— 下集预告 ——
    if($t -match '^下集预告(?:〔[^〕]+〕)?[：:](.+)$'){
      $p=$Matches[1]
      $fileEp = if($name -match '^EP-0*(\d+)\.md$'){ [int]$Matches[1] } else { 0 }
      if($previewDisabledFrom -gt 0 -and $fileEp -ge $previewDisabledFrom){ Out-Issue 'FAIL' $name $ln "V6策略自EP-$($previewDisabledFrom.ToString('D2'))起禁用下集预告；剧本应以【卡黑】结束" }
      $sc = ([regex]::Matches($p,'[。！？]')).Count; if($sc -eq 0){$sc=1}
      if($sc -gt 2){ Out-Issue 'FAIL' $name $ln "预告超过2句（$sc 句）" }
      $previewLines += $p
      $lastSpeaker=''; $speakerRun=0
      $prevType='preview'; continue
    }

    # —— △/※ 续行（缩进接续，非结构/框架行）——同样过不可拍词表 ——
    if($prevType -eq 'delta' -and -not $isFrame){
      $scan2 = $t -replace '「[^」]*」','' -replace '（[^）]*）',''
      if($scan2 -match $mindFail){ Out-Issue 'FAIL' $name $ln "△/※ 续行含不可拍心理/全知词「$($Matches[0])」→ 并置演出/OS/窃语台词" }
      elseif($scan2 -match $mindWarn){ Out-Issue 'WARN' $name $ln "△/※ 续行疑似不可拍词「$($Matches[0])」→ 语义复核" }
      elseif($scan2 -match $mindSelfCheck){ Out-Issue 'WARN' $name $ln "△/※ 续行命中自检提示词「$($Matches[0])」〔写作自检提示·非checker判罚依据〕→ 自检裁决：改可拍动作或删；带动作锚点可保留" }
      if($scan2 -match '(听说|据说|转告|告知|告诉|禀报|嘱咐|交代|讲述|商议|盘问)'){ Out-Issue 'WARN' $name $ln "△/※ 续行疑似概述说话「$($Matches[1])」→ 落成台词块/画外台词，或删（语义复核）" }
      if($t -match '(说|道|问|喊|骂|斥|吼|叫|答|回|应)[了道]?\s*[：:]\s*[「“]'){ Out-Issue 'FAIL' $name $ln "台词嵌△续行（说话动词+引号）→ 人声台词拆独立台词块" }
      continue   # 保持 prevType='delta' 以便多行续接
    }
    $prevType='other'
  }

  # —— 机扫④：结算最后一场时段 ——
  if($sceneSlot -eq '日' -and -not $sceneFlashback){
    if($sceneNightStrong){ Out-Issue 'FAIL' $name $sceneStartLn "场次头「日」但场内含明确夜间词（当晚/深夜/入夜等）→ 拍摄时段错标，核对原著当场时间" }
    elseif($sceneNightWeak){ Out-Issue 'WARN' $name $sceneStartLn "场次头「日」但场内含『今晚/晚上』→ 若指当前时段应『夜』（下午说『今晚X点』属合法未来指示可放行）" }
  }

  # —— 出场表 vs 说话人交叉核对 ——
  foreach($k in $sceneSpeakers.Keys){
    $cast = $sceneCast[$k]; if(-not $cast){ $cast=@() }
    foreach($spk in ($sceneSpeakers[$k] | Select-Object -Unique)){
      $bare = ($spk -replace '（.*?）','').Trim()
      $hit = $false
      foreach($c in $cast){ if($bare -like "*$c*" -or $c -like "*$bare*"){ $hit=$true; break } }
      if(-not $hit){ Out-Issue 'FAIL' $name 0 "$k 说话人「$bare」未列入出场人物表（群杂/画外亦须列名）" }
    }
  }

  # —— 资产名唯一性机扫（别名拦截 + 改名生效集 + 禁用名全文扫）——
  if($aliasRules.Count -gt 0){
    $epNum = 0; if($name -match 'EP-?(\d+)'){ $epNum=[int]$Matches[1] }
    $rosterNames = @()
    foreach($k in $sceneCast.Keys){ $rosterNames += $sceneCast[$k] }
    foreach($k in $sceneSpeakers.Keys){ $rosterNames += @($sceneSpeakers[$k] | ForEach-Object { ($_ -replace '（.*?）','').Trim() }) }
    $rosterNames = @($rosterNames | Where-Object { $_ } | Select-Object -Unique)
    $reported=@{}
    foreach($n in $rosterNames){
      foreach($a in $aliasRules){
        if($n -ne $a.Alias){ continue }
        $key = "$n|$($a.Kind)"; if($reported.ContainsKey($key)){ continue }
        if($a.Kind -eq '台词'){
          Out-Issue 'FAIL' $name 0 "出场表/说话人「$n」是「$($a.Asset)」的别名（角色卡：仅台词可用）——资产名唯一，防制作端一人拆两资产"; $reported[$key]=1
        } elseif($a.Kind -eq '旧名' -and $epNum -gt $a.EP){
          Out-Issue 'FAIL' $name 0 "出场表/说话人旧名「$n」已于 EP-$($a.EP) 改名「$($a.Asset)」，此后失效"; $reported[$key]=1
        } elseif($a.Kind -eq '新名' -and $epNum -gt 0 -and $epNum -lt $a.EP){
          Out-Issue 'FAIL' $name 0 "出场表/说话人新名「$n」于 EP-$($a.EP) 才生效，提前用名穿帮"; $reported[$key]=1
        }
      }
    }
    foreach($a in @($aliasRules | Where-Object { $_.Kind -eq '禁' })){
      $esc=[regex]::Escape($a.Alias); $hitFail=$false; $warnLn=0
      for($j=0;$j -lt $lines.Count;$j++){
        $aliasProbe = [string]$lines[$j]
        foreach($protected in $characterProtectedNames){
          if($protected.Length -gt ([string]$a.Alias).Length -and $protected.Contains([string]$a.Alias)){ $aliasProbe = $aliasProbe -replace [regex]::Escape($protected),'' }
        }
        if($aliasProbe -match "(?<![一-龥])$esc(?![一-龥])"){ Out-Issue 'FAIL' $name ($j+1) "项目禁用名「$($a.Alias)」（角色卡登记，统一用「$($a.Asset)」）"; $hitFail=$true; break }
        elseif($warnLn -eq 0 -and $aliasProbe -match $esc){ $warnLn=$j+1 }
      }
      if(-not $hitFail -and $warnLn -gt 0){ Out-Issue 'WARN' $name $warnLn "疑似禁用名「$($a.Alias)」出现在更长词中（人工核对是否应为「$($a.Asset)」）" }
    }
  }

  # —— 道具别名/禁用名机扫（创作期一律 WARN 线索，不设 FAIL）——
  if($propRules.Count -gt 0){
    $pReported=@{}
    for($j=0;$j -lt $lines.Count;$j++){
      $lt="$($lines[$j])".Trim(); if(-not $lt){ continue }
      foreach($p in @($propRules | Sort-Object @{Expression={([string]$_.Alias).Length};Descending=$true})){
        $key="$($p.Alias)|$($p.Kind)"
        if($pReported.ContainsKey($key)){ continue }
        # 别名可能是正式资产名的子串（玉佩⊂麒麟玉佩）：先剔除行内的正式名再匹配，防写对全名仍被误报
        $probe = $lt -replace [regex]::Escape($p.Asset),''
        foreach($protected in $propProtectedNames){
          if($protected.Length -gt ([string]$p.Alias).Length -and $protected.Contains([string]$p.Alias)){ $probe = $probe -replace [regex]::Escape($protected),'' }
        }
        if($probe -notmatch [regex]::Escape($p.Alias)){ continue }
        if($p.Kind -eq '禁'){
          Out-Issue 'WARN' $name ($j+1) "道具禁用名「$($p.Alias)」（道具索引登记，统一用「$($p.Asset)」）"; $pReported[$key]=1
        } elseif($lt -match '^[△※]'){
          Out-Issue 'WARN' $name ($j+1) "画面行使用道具别名「$($p.Alias)」→ 资产名唯一，△/※ 统一用「$($p.Asset)」（台词可保留叫法）"; $pReported[$key]=1
        }
      }
    }
  }

  # —— 字数闸门 ——
  if($full -lt $minWords){ Out-Issue 'FAIL' $name 0 "全字符 $full < 下限 $minWords" }
  if($maxWords -gt 0 -and $full -gt $maxWords){ Out-Issue 'FAIL' $name 0 "全字符 $full > 上限 $maxWords" }
  if($full -ge $minWords -and $full -lt 880){ Out-Issue 'WARN' $name 0 "字数 $full 贴近下限（创作目标带 880-1200，下限 800 仅红线）——删改无余量，高潮/S级集尤忌；优先补拍（对手反应→围观反应→代价特写→先压后弹）而非注水" }

  # —— 场次数下限（维度6）——
  $sceneMin = 3
  if($scenes -lt $sceneMin){ Out-Issue 'FAIL' $name 0 "场次数 $scenes < 下限 $sceneMin（动态漫）" }

  # —— 高频指纹计数（信息项 + 跨集聚合累积）——
  $fp=@()
  $body = ($lines -join "`n")
  $epShort = ($name -replace '\.md','')
  foreach($w in $fingerprints){
    $c=([regex]::Matches($body,[regex]::Escape($w))).Count
    if($c -gt 0){ $fp += "$w=$c"; if(-not $fpAgg.ContainsKey($w)){ $fpAgg[$w]=@() }; $fpAgg[$w] += $epShort }
  }
  Write-Output ("INFO {0}: 字数={1} 场次={2} 景别={3} 指纹[{4}]" -f $name,$full,$scenes,$shotCount,($fp -join ' '))
  # 预告骨架聚合（激活 $previewLines）
  foreach($pv in $previewLines){
    foreach($sk in $previewSkeletons){
      if($pv -match $sk.Pat){ if(-not $prevAgg.ContainsKey($sk.Name)){ $prevAgg[$sk.Name]=@() }; if($prevAgg[$sk.Name] -notcontains $epShort){ $prevAgg[$sk.Name] += $epShort } }
    }
  }
  $wordTable += [pscustomobject]@{ EP=$name; Words=$full }
}

Write-Output ("SUMMARY: {0} 个文件，FAIL 项 {1} 个" -f $targets.Count,$script:failCount)
Write-Output ("WORDS: " + (($wordTable | ForEach-Object { "$($_.EP -replace '\.md','')=$($_.Words)" }) -join '；'))

# —— 跨集聚合段（目录模式；单集模式无跨集信息，跳过）——
if($targets.Count -gt 1){
  $aggFp = @($fpAgg.GetEnumerator() | Where-Object { @($_.Value | Select-Object -Unique).Count -ge 2 } | Sort-Object { @($_.Value | Select-Object -Unique).Count } -Descending)
  if($aggFp.Count){
    Write-Output "FINGERPRINT-AGG（跨集口癖聚合；≥3集应登记 progress 高频意象表并避让）："
    foreach($e in $aggFp){ $eps=@($e.Value | Select-Object -Unique); Write-Output ("  {0}={1}集[{2}]{3}" -f $e.Key,$eps.Count,($eps -join ','),$(if($eps.Count -ge 3){' ⚠应避让'}else{''})) }
  }
  if($prevAgg.Count){
    Write-Output "PREVIEW-SKELETON（预告骨架跨集复用；≥3集须换写骨架）："
    foreach($e in ($prevAgg.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending)){ $eps=@($e.Value | Select-Object -Unique); Write-Output ("  [{0}]={1}集[{2}]{3}" -f $e.Key,$eps.Count,($eps -join ','),$(if($eps.Count -ge 3){' ⚠骨架复读'}else{''})) }
  }

  # —— 场景同地异名聚类（跨集，词面级：全等/包含/同长差一字；换述类靠语义审。创作期一律 WARN）——
  $locNames=@($locRegistry.Keys)
  $locPairs=@()
  for($a=0;$a -lt $locNames.Count;$a++){
    for($b=$a+1;$b -lt $locNames.Count;$b++){
      $x=$locNames[$a]; $y=$locNames[$b]
      $nx=($x -replace '[·．.、\-—（）()【】\s]',''); $ny=($y -replace '[·．.、\-—（）()【】\s]','')
      if(-not $nx -or -not $ny){ continue }
      $suspect=$false; $hub=''
      if($nx -eq $ny){ $suspect=$true }
      elseif($nx.Length -ge 2 -and $ny.Length -ge 2 -and $nx.Contains($ny)){ $suspect=$true; $hub=$y }
      elseif($nx.Length -ge 2 -and $ny.Length -ge 2 -and $ny.Contains($nx)){ $suspect=$true; $hub=$x }
      elseif($nx.Length -eq $ny.Length -and $nx.Length -ge 3){
        # 差一字比较：层级名（含·）父地点不同＝不同场景（苏家·客厅≠谢家·客厅）；首字不同多为不同主体（苏家≠谢家），均跳过
        $px=($x -split '·')[0].Trim(); $py=($y -split '·')[0].Trim()
        $hier = ($x.Contains('·') -or $y.Contains('·'))
        if(-not ($hier -and $px -ne $py)){
          $diff=0; $firstDiff=-1
          for($k=0;$k -lt $nx.Length;$k++){ if($nx[$k] -ne $ny[$k]){ if($firstDiff -lt 0){ $firstDiff=$k }; $diff++; if($diff -gt 1){ break } } }
          if($diff -le 1 -and $firstDiff -ge 1){ $suspect=$true }
        }
      }
      if($suspect){ $locPairs += @{ X=$x; Y=$y; Hub=$hub } }
    }
  }
  # 泛名 hub 聚合：某场景名被 ≥3 个更长名包含（如裸「宿舍」「定国公府」）→ 汇总一条，不逐对刷屏
  $hubCount=@{}
  foreach($p in $locPairs){ if($p.Hub){ if(-not $hubCount.ContainsKey($p.Hub)){ $hubCount[$p.Hub]=0 }; $hubCount[$p.Hub]++ } }
  $hubs=@($hubCount.Keys | Where-Object { $hubCount[$_] -ge 3 })
  foreach($h in $hubs){
    $others=@($locPairs | Where-Object { $_.Hub -eq $h } | ForEach-Object { if($_.X -eq $h){ $_.Y } else { $_.X } })
    $sample=(@($others | Select-Object -First 5) -join '」「')
    $eh=(@($locRegistry[$h] | Select-Object -Unique | Select-Object -First 3) -join ',')
    Out-Issue 'WARN' '(跨集)' 0 "泛化场景名「$h」($eh) 与 $($others.Count) 个含它的场景名并存（如「$sample」）——裸泛名做场次头会让资产库无法定位，建议统一到具体场景名"
  }
  $locPairs=@($locPairs | Where-Object { -not ($_.Hub -and $hubs -contains $_.Hub) })
  $shown=0
  foreach($p in $locPairs){
    $shown++
    if($shown -le 30){
      $ex=(@($locRegistry[$p.X] | Select-Object -Unique | Select-Object -First 3) -join ',')
      $ey=(@($locRegistry[$p.Y] | Select-Object -Unique | Select-Object -First 3) -join ',')
      Out-Issue 'WARN' '(跨集)' 0 "场景名疑似同地异名：「$($p.X)」($ex) ↔「$($p.Y)」($ey)——若为同一场景资产请统一命名，防制作端一景拆两资产"
    }
  }
  if($shown -gt 30){ Write-Output "INFO 同地异名疑似对共 $shown 组，仅显示前 30 组" }

  # —— 跨集避让缓存全量重建（目录模式是缓存的唯一权威重建方）——
  if($cacheFile){
    $cacheW=@{ fingerprints=@{}; previews=@{}; locations=@{} }
    foreach($k in $fpAgg.Keys){ $cacheW.fingerprints[$k]=@($fpAgg[$k] | Select-Object -Unique) }
    foreach($k in $prevAgg.Keys){ $cacheW.previews[$k]=@($prevAgg[$k] | Select-Object -Unique) }
    foreach($k in $locRegistry.Keys){ $cacheW.locations[$k]=@($locRegistry[$k] | Select-Object -Unique) }
    if($Draft){ Write-Output "INFO -Draft 只读模式：跳过缓存全量重建（.lint-cache.json 未写入）" }
    else {
      Write-LintCache $cacheFile $cacheW
      Write-Output "INFO 跨集避让缓存已全量重建：.lint-cache.json（单集机检将据此拦截口癖/场景名/预告骨架）"
    }
  }
}
elseif($targets.Count -eq 1){
  # —— 单集模式跨集拦截（读缓存补上「写前避让只在目录模式可见」的断链）——
  $epShort1 = ($targets[0].Name -replace '\.md','')
  $cache = Read-LintCache $cacheFile
  if($null -eq $cache){
    Write-Output "INFO 未找到跨集避让缓存（.lint-cache.json）——先跑一次目录模式（-Path scripts）生成，单集机检才能做口癖/场景名/预告骨架的跨集拦截"
  } else {
    # a) 避让名单展示 + 本集口癖拦截：某词其它集已 ≥2 集、本集再用即触 ≥3 集避让线
    $avoid=@()
    foreach($k in $cache.fingerprints.Keys){ $others=@($cache.fingerprints[$k] | Where-Object { $_ -ne $epShort1 }); if($others.Count -ge 3){ $avoid += "$k=$($others.Count)集" } }
    if($avoid.Count){ Write-Output ("AVOID-LIST（缓存·已达避让线的口癖，本集写作必须换写）： " + (($avoid | Select-Object -First 12) -join '  ')) }
    foreach($k in $fpAgg.Keys){
      $others=@(); if($cache.fingerprints.ContainsKey($k)){ $others=@($cache.fingerprints[$k] | Where-Object { $_ -ne $epShort1 }) }
      if($others.Count -ge 2){ Out-Issue 'WARN' $targets[0].Name 0 "口癖「$k」已在 $($others.Count) 集使用（缓存），本集再用触及 ≥3 集避让线 → 换写（对照 progress 高频意象表）" }
    }
    # b) 场景名：与已登记名相似的新名 → 同地异名预警；全新名 → 提示登记
    foreach($loc in @($locRegistry.Keys)){
      $known=$false; $sim=''
      foreach($cl in $cache.locations.Keys){
        $clOthers=@($cache.locations[$cl] | Where-Object { ($_ -replace '\.md','') -ne $epShort1 })
        if($clOthers.Count -eq 0){ continue }
        if($cl -eq $loc){ $known=$true; break }
        if(-not $sim -and (Test-LocSimilar $loc $cl)){ $sim=$cl }
      }
      if(-not $known){
        if($sim){ Out-Issue 'WARN' $targets[0].Name 0 "场次头地点「$loc」与已用场景名「$sim」疑似同地异名 → 同一场景沿用已登记写法（查 progress「场景名登记表」），防制作端一景拆两资产" }
        else { Write-Output "INFO 新场景名「$loc」——若确为新场景，成稿后登记 progress「场景名登记表」" }
      }
    }
    # c) 预告骨架拦截
    foreach($k in $prevAgg.Keys){
      $others=@(); if($cache.previews.ContainsKey($k)){ $others=@($cache.previews[$k] | Where-Object { $_ -ne $epShort1 }) }
      if($others.Count -ge 2){ Out-Issue 'WARN' $targets[0].Name 0 "预告骨架「$k」已在 $($others.Count) 集使用（缓存），本集再用即 ⚠骨架复读 → 换写骨架" }
    }
    # d) 增量更新缓存：清本集旧条目 → 写入本集现状（目录模式仍是全量重建的权威方）；-Draft 只读跳过
    if($Draft){ Write-Output "INFO -Draft 只读模式：本集指纹未写入缓存（草稿预机检·防污染 .lint-cache.json）" }
    else {
      foreach($k in @($cache.fingerprints.Keys)){ $cache.fingerprints[$k]=@($cache.fingerprints[$k] | Where-Object { $_ -ne $epShort1 }); if(@($cache.fingerprints[$k]).Count -eq 0){ $cache.fingerprints.Remove($k) } }
      foreach($k in @($cache.previews.Keys)){ $cache.previews[$k]=@($cache.previews[$k] | Where-Object { $_ -ne $epShort1 }); if(@($cache.previews[$k]).Count -eq 0){ $cache.previews.Remove($k) } }
      foreach($k in @($cache.locations.Keys)){ $cache.locations[$k]=@($cache.locations[$k] | Where-Object { ($_ -replace '\.md','') -ne $epShort1 }); if(@($cache.locations[$k]).Count -eq 0){ $cache.locations.Remove($k) } }
      foreach($k in $fpAgg.Keys){ if(-not $cache.fingerprints.ContainsKey($k)){ $cache.fingerprints[$k]=@() }; $cache.fingerprints[$k]=@($cache.fingerprints[$k]) + @($epShort1) }
      foreach($k in $prevAgg.Keys){ if(-not $cache.previews.ContainsKey($k)){ $cache.previews[$k]=@() }; $cache.previews[$k]=@($cache.previews[$k]) + @($epShort1) }
      foreach($k in $locRegistry.Keys){ if(-not $cache.locations.ContainsKey($k)){ $cache.locations[$k]=@() }; $cache.locations[$k]=@($cache.locations[$k]) + @($targets[0].Name) }
      Write-LintCache $cacheFile $cache
    }
  }
}
if($script:failCount -gt 0){ exit 1 } else { exit 0 }

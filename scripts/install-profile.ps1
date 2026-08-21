# 才丰 Agent 首次安装脚本（Windows PowerShell）
# 用法：右键“以管理员身份运行 PowerShell”，执行：
#   powershell -ExecutionPolicy Bypass -File .\install-profile.ps1
# 或（仓库根目录）：
#   .\scripts\install-profile.ps1
#
# 作用：
#   1. 复制内置「秋天短剧制作」预设到 ~\.dsh\.agent-presets\qiutian-storyboard
#   2. 若桌面 profile 不存在，写入预置插件清单（~\.dsh\profiles\desktop\package.json）
#   3. 设置默认 Agent 预设为 qiutian-storyboard（不覆盖已有配置）
# 之后启动才丰 Agent，应用会自动安装 profile 里的插件（首次较慢，属正常现象）。

$ErrorActionPreference = 'Stop'

# 仓库根目录：脚本位于 <root>\scripts\
$RepoRoot = Split-Path -Parent $PSScriptRoot
$DshHome = Join-Path $HOME '.dsh'

Write-Host '=== 才丰 Agent 首次安装 ===' -ForegroundColor Cyan

# 1. 复制 qiutian-storyboard 预设
$PresetSrc = Join-Path $RepoRoot 'presets\qiutian-storyboard'
$PresetDst = Join-Path $DshHome '.agent-presets\qiutian-storyboard'
if (Test-Path $PresetDst) {
  Write-Host "预设已存在，跳过复制：$PresetDst" -ForegroundColor Yellow
} else {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PresetDst) | Out-Null
  Copy-Item -Recurse -Force $PresetSrc $PresetDst
  Write-Host "已复制「秋天短剧制作」预设 → $PresetDst" -ForegroundColor Green
}

# 2. 写入桌面 profile 模板（不存在时）
$ProfileDir = Join-Path $DshHome 'profiles\desktop'
$ProfileManifest = Join-Path $ProfileDir 'package.json'
if (Test-Path $ProfileManifest) {
  Write-Host "桌面 profile 已存在，跳过写入：$ProfileManifest" -ForegroundColor Yellow
} else {
  New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null
  Copy-Item -Force (Join-Path $RepoRoot 'profiles\desktop\package.json') $ProfileManifest
  Write-Host "已写入预置插件清单（19 个 bundle）→ $ProfileManifest" -ForegroundColor Green
}

# 3. 设置默认 Agent 预设（仅当用户未配置时）
$SettingsPath = Join-Path $DshHome 'settings.yaml'
if (Test-Path $SettingsPath) {
  $Content = Get-Content -Raw -Encoding UTF8 $SettingsPath
  if ($Content -match '(?m)^agent-presets:') {
    if ($Content -notmatch '(?m)^\s*default:\s*qiutian-storyboard') {
      Write-Host '检测到已配置 agent-presets（非 qiutian-storyboard），未改动你的设置。' -ForegroundColor Yellow
      Write-Host '如需启用秋天短剧预设，请手动在 settings.yaml 中设置：' -ForegroundColor Yellow
      Write-Host '  agent-presets:' -ForegroundColor Yellow
      Write-Host '    default: qiutian-storyboard' -ForegroundColor Yellow
    } else {
      Write-Host 'agent-presets.default 已是 qiutian-storyboard ✅' -ForegroundColor Green
    }
  } else {
    Add-Content -Encoding UTF8 -Path $SettingsPath -Value "`nagent-presets:`n  default: qiutian-storyboard`n"
    Write-Host '已在 settings.yaml 追加 agent-presets.default = qiutian-storyboard' -ForegroundColor Green
  }
} else {
  New-Item -ItemType Directory -Force -Path $DshHome | Out-Null
  Set-Content -Encoding UTF8 -Path $SettingsPath -Value "agent-presets:`n  default: qiutian-storyboard`n"
  Write-Host "已创建 settings.yaml 并设置默认预设 → $SettingsPath" -ForegroundColor Green
}

Write-Host ''
Write-Host '=== 完成 ✅ ===' -ForegroundColor Cyan
Write-Host '现在启动「才丰 Agent」，等待插件自动安装完成即可使用。'
Write-Host '首次启动可能需要几分钟下载插件依赖，请耐心等待。'

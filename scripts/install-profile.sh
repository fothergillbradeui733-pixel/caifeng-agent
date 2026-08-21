#!/usr/bin/env bash
# 才丰 Agent 首次安装脚本（macOS / Linux）
# 用法：
#   chmod +x scripts/install-profile.sh
#   ./scripts/install-profile.sh
#
# 作用：
#   1. 复制内置「秋天短剧制作」预设到 ~/.dsh/.agent-presets/qiutian-storyboard
#   2. 若桌面 profile 不存在，写入预置插件清单（~/.dsh/profiles/desktop/package.json）
#   3. 设置默认 Agent 预设为 qiutian-storyboard（不覆盖已有配置）
# 之后启动才丰 Agent，应用会自动安装 profile 里的插件（首次较慢，属正常现象）。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"

echo '=== 才丰 Agent 首次安装 ==='

# 1. 复制 qiutian-storyboard 预设
PRESET_SRC="$REPO_ROOT/presets/qiutian-storyboard"
PRESET_DST="$DSH_HOME/.agent-presets/qiutian-storyboard"
if [ -d "$PRESET_DST" ]; then
  echo "预设已存在，跳过复制：$PRESET_DST"
else
  mkdir -p "$DSH_HOME/.agent-presets"
  cp -R "$PRESET_SRC" "$PRESET_DST"
  echo "已复制「秋天短剧制作」预设 → $PRESET_DST"
fi

# 2. 写入桌面 profile 模板（不存在时）
PROFILE_DIR="$DSH_HOME/profiles/desktop"
PROFILE_MANIFEST="$PROFILE_DIR/package.json"
if [ -f "$PROFILE_MANIFEST" ]; then
  echo "桌面 profile 已存在，跳过写入：$PROFILE_MANIFEST"
else
  mkdir -p "$PROFILE_DIR"
  cp "$REPO_ROOT/profiles/desktop/package.json" "$PROFILE_MANIFEST"
  echo "已写入预置插件清单（19 个 bundle）→ $PROFILE_MANIFEST"
fi

# 3. 设置默认 Agent 预设（仅当用户未配置时）
SETTINGS_PATH="$DSH_HOME/settings.yaml"
if [ -f "$SETTINGS_PATH" ]; then
  if grep -q '^agent-presets:' "$SETTINGS_PATH"; then
    if grep -q '^[[:space:]]*default:[[:space:]]*qiutian-storyboard' "$SETTINGS_PATH"; then
      echo 'agent-presets.default 已是 qiutian-storyboard ✅'
    else
      echo '检测到已配置 agent-presets（非 qiutian-storyboard），未改动你的设置。'
      echo '如需启用秋天短剧预设，请手动在 settings.yaml 中设置：'
      echo '  agent-presets:'
      echo '    default: qiutian-storyboard'
    fi
  else
    printf '\nagent-presets:\n  default: qiutian-storyboard\n' >> "$SETTINGS_PATH"
    echo '已在 settings.yaml 追加 agent-presets.default = qiutian-storyboard'
  fi
else
  mkdir -p "$DSH_HOME"
  printf 'agent-presets:\n  default: qiutian-storyboard\n' > "$SETTINGS_PATH"
  echo "已创建 settings.yaml 并设置默认预设 → $SETTINGS_PATH"
fi

echo ''
echo '=== 完成 ✅ ==='
echo '现在启动「才丰 Agent」，等待插件自动安装完成即可使用。'
echo '首次启动可能需要几分钟下载插件依赖，请耐心等待。'

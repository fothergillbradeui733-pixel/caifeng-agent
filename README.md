# 才丰 Agent

[English](README.en.md)

**才丰 Agent** 是面向中文短剧制作团队的 DeepSeek Harness 桌面端社区发行版：以 MIT 开源的 [deepseek-harness-desktop](https://github.com/anywhere-labs/deepseek-harness-desktop)（DSH Desktop）为基础，预置了 19 个经过验证的社区插件，并内置「**秋天短剧制作**」全流程工作流（原创剧本 → 网文改编 → 视觉资产库 → 分镜 Block → 飞书多维表格上传）。

> ⚠️ 本项目是**社区非官方发行版**，与 DeepSeek 官方无隶属关系。上游 DeepSeek Harness 仍处于 Developer Preview 阶段，可能存在破坏性变更。

## 功能特性

- 🎬 **秋天短剧制作工作流**（内置 Agent 预设）：剧本转分镜（仿真人竖屏 / 横屏 / 3D 漫 V10）、爆款拆解与原创立项、长篇网文漫剧改编、视觉资产库与文生图提示词、飞书多维表格上传
- 🧩 **预置 19 个社区插件**：中文优化（deepseek-harness-zh_pro）、AI 生图（dsh-imagegen）、记忆库（dsh-memory）、视觉路由（dsh-vision-router）、通知（dsh-notifier）、更好的侧边栏（dsh-better-sidebar）等
- 🖥️ **Windows / macOS 双平台**：Windows 提供安装版（NSIS）与免安装版（Portable）
- 🔄 **自动更新**：通过 GitHub Releases 发布新版本，应用内检查并引导下载安装
- 🔒 **本地优先**：会话、记忆、设置全部存储在本地 `~/.dsh`，不强制上传任何数据

## 下载安装

### Windows（推荐）

从 [Releases](https://github.com/fothergillbradeui733-pixel/caifeng-agent/releases) 下载：

| 文件 | 说明 |
|---|---|
| `CaiFeng-Agent-<版本>-x64-Setup.exe` | 安装版（推荐），支持自定义安装目录、开始菜单/桌面快捷方式 |
| `CaiFeng-Agent-<版本>-x64-Portable.zip` | 免安装版，解压后直接运行 `才丰 Agent.exe` |

安装后首次启动会自动安装预置插件（需联网，约几分钟），请耐心等待。

### macOS

macOS 版需自行从源码构建（见下文「开发构建」），或等待后续 Release。

### 启用「秋天短剧制作」预设

插件安装完成后，运行仓库内脚本以启用内置的短剧工作流预设：

```powershell
# Windows（PowerShell）
.\scripts\install-profile.ps1
```

```bash
# macOS / Linux
chmod +x scripts/install-profile.sh
./scripts/install-profile.sh
```

脚本会复制 `qiutian-storyboard` 预设到 `~/.dsh/.agent-presets/`，并设置默认 Agent 预设。重启应用后，新开会话即进入「秋天短剧制作」模式。

## 首次使用

1. 启动后如需配置模型 API，在「设置 → 模型」中填入你的模型服务商配置
2. 「AI 生图」插件需在「设置 → 插件 → 可配置」中配置图像生成 API（密钥仅存于本机）
3. 所有会话、记忆、数据均保存在 `~/.dsh/`，请自行备份

## 更新机制

- 应用内会定期检查 GitHub Releases 是否有新版本（检查端点：`api.github.com/repos/fothergillbradeui733-pixel/caifeng-agent/releases/latest`）
- 发布新版本：推送 `vX.Y.Z` 标签，GitHub Actions 自动构建并发布 Windows 安装包

## 开发构建

```bash
# 前置：Node.js ^22.19.0 或 >=24.0.0，Yarn 4（Corepack）
git submodule update --init --recursive
corepack yarn install --immutable

# 开发模式
corepack yarn dev

# 构建
corepack yarn build

# 完整检查（构建 + 类型 + 测试 + 许可证验证）
corepack yarn check
```

Windows 打包（需在 Windows 环境或 GitHub Actions）：

```bash
corepack yarn dist:win          # NSIS 安装版
corepack yarn dist:win-portable # 免安装版
```

## 目录结构

```
├── dsh-plugin-desktop/        # 桌面壳（Electron + Cordis Host/Client）
├── presets/qiutian-storyboard/ # 秋天短剧制作预设（persona + 5 个技能）
├── profiles/desktop/          # 默认 profile 模板（19 个预置插件）
├── scripts/                   # 安装脚本等
├── deepseek-harness/          # 上游 DeepSeek Harness（git submodule，勿改）
└── .github/workflows/         # CI 与发布流水线
```

## 免责声明

- 本项目为社区作品，非 DeepSeek 官方产品，与 DeepSeek 官方无任何关联
- 上游 DeepSeek Harness 处于 Developer Preview 阶段，功能与接口可能发生破坏性变更
- 预置的第三方插件版权归各自作者所有，使用前请查阅其开源许可证
- 本项目按 MIT 协议提供，**不提供任何担保**；因使用本软件造成的任何损失由使用者自行承担

## 许可证

本项目基于 [MIT License](LICENSE)，上游版权归 [Anywhere Labs](https://github.com/anywhere-labs/deepseek-harness-desktop) 与 [DeepSeek AI](https://github.com/deepseek-ai/deepseek-harness) 所有。第三方组件许可声明见 [dsh-plugin-desktop/THIRD_PARTY_NOTICES.md](dsh-plugin-desktop/THIRD_PARTY_NOTICES.md)。

## 致谢

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) — MIT 开源的 Agent 运行时
- [DSH Desktop](https://github.com/anywhere-labs/deepseek-harness-desktop) — 桌面端壳层
- 全部 19 个预置社区插件及其作者

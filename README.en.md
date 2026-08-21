# CaiFeng Agent (才丰 Agent)

[中文](README.md)

**CaiFeng Agent** is a community distribution of the DeepSeek Harness desktop client, tailored for Chinese short-drama production teams. It is built on the MIT-licensed [deepseek-harness-desktop](https://github.com/anywhere-labs/deepseek-harness-desktop) (DSH Desktop), ships with 19 verified community plugins, and embeds the **Qiutian Short-Drama** end-to-end workflow (original scripts → web-novel adaptation → visual asset library → storyboard Blocks → Feishu Bitable upload).

> ⚠️ This is an **unofficial community build** with no affiliation to DeepSeek. Upstream DeepSeek Harness is still in Developer Preview and may introduce breaking changes.

## Features

- 🎬 **Qiutian Short-Drama workflow** (built-in agent preset): storyboard conversion (live-action portrait / landscape / 3D comic V10), hit-drama teardown and original pitching, long web-novel adaptation, visual asset library with text-to-image prompts, Feishu Bitable upload
- 🧩 **19 preloaded community plugins**: Chinese optimization (deepseek-harness-zh_pro), AI image generation (dsh-imagegen), memory (dsh-memory), vision routing (dsh-vision-router), notifications (dsh-notifier), better sidebar (dsh-better-sidebar), and more
- 🖥️ **Windows / macOS**: Windows ships both an NSIS installer and a portable build
- 🔄 **Auto-update** via GitHub Releases
- 🔒 **Local-first**: sessions, memory, and settings stay in `~/.dsh` on your machine

## Download & Install

### Windows (recommended)

Grab the latest files from [Releases](https://github.com/fothergillbradeui733-pixel/caifeng-agent/releases):

| File | Description |
|---|---|
| `CaiFeng-Agent-<version>-x64-Setup.exe` | Installer (recommended), custom install dir, shortcuts |
| `CaiFeng-Agent-<version>-x64-Portable.zip` | Portable build — unzip and run `才丰 Agent.exe` |

The first launch automatically installs the preloaded plugins (needs network, a few minutes).

### macOS

Build from source (see "Development" below), or wait for a future Release.

### Enable the Qiutian preset

After the plugins are installed, run the repo script to enable the built-in short-drama workflow:

```powershell
# Windows (PowerShell)
.\scripts\install-profile.ps1
```

```bash
# macOS / Linux
chmod +x scripts/install-profile.sh
./scripts/install-profile.sh
```

The script copies the `qiutian-storyboard` preset into `~/.dsh/.agent-presets/` and sets it as the default agent preset. Restart the app and open a new session to enter the Qiutian Short-Drama mode.

## First Run

1. Configure your model provider in Settings → Models
2. The image-generation plugin needs an image API key in Settings → Plugins (stored locally only)
3. All sessions and data live under `~/.dsh/` — back them up yourself

## Updates

- The app polls `api.github.com/repos/fothergillbradeui733-pixel/caifeng-agent/releases/latest` for new versions
- To publish a release: push a `vX.Y.Z` tag — GitHub Actions builds and publishes the Windows packages automatically

## Development

```bash
# Prereqs: Node.js ^22.19.0 or >=24.0.0, Yarn 4 via Corepack
git submodule update --init --recursive
corepack yarn install --immutable

corepack yarn dev          # dev mode
corepack yarn build        # build
corepack yarn check        # full gate (build + typecheck + tests + license checks)
```

Windows packaging (run on Windows or in GitHub Actions):

```bash
corepack yarn dist:win          # NSIS installer
corepack yarn dist:win-portable # portable zip
```

## Repository Layout

```
├── dsh-plugin-desktop/        # Desktop shell (Electron + Cordis Host/Client)
├── presets/qiutian-storyboard/ # Qiutian preset (persona + 5 skills)
├── profiles/desktop/          # Default profile template (19 preloaded plugins)
├── scripts/                   # Install scripts
├── deepseek-harness/          # Upstream DeepSeek Harness (git submodule, do not edit)
└── .github/workflows/         # CI and release pipelines
```

## Disclaimer

- Community project, not an official DeepSeek product and not affiliated with DeepSeek in any way
- Upstream DeepSeek Harness is in Developer Preview; features and APIs may change breaking-ly
- Third-party plugins belong to their respective authors; check their licenses before use
- Provided under the MIT License **without any warranty**; use at your own risk

## License

MIT — see [LICENSE](LICENSE). Upstream copyright belongs to [Anywhere Labs](https://github.com/anywhere-labs/deepseek-harness-desktop) and [DeepSeek AI](https://github.com/deepseek-ai/deepseek-harness). Third-party notices: [dsh-plugin-desktop/THIRD_PARTY_NOTICES.md](dsh-plugin-desktop/THIRD_PARTY_NOTICES.md).

## Credits

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) — MIT-licensed agent runtime
- [DSH Desktop](https://github.com/anywhere-labs/deepseek-harness-desktop) — desktop shell
- All 19 preloaded community plugins and their authors

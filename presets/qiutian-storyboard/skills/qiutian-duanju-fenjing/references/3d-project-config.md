# Project Configuration Template

Use this file to create a fresh configuration for each new drama. Do not copy old project names, character voices, Q-version rules, or scene style into a new project unless the user explicitly requests it.

## Required Project Config

Before generating episode storyboards, define:

```text
项目名称：
题材类型：年代乡村 / 玄幻修仙 / 都市豪门 / 团宠萌娃 / 古风权谋 / 校园青春 / other
画幅与类型：横屏3D漫剧
用户自定义风格/禁忌：
项目锁定模块：
  · V10通用底座：启用
  · 视觉风格包：ID / version / hash
  · 题材导演包：ID / version / hash
  · 特殊机制许可：无 / Q版内心OS / 系统UI / 兽语 / other
锁定修订号：
模块优先级：用户剧情与自定义风格 > V10通用底座 > 风格增强包 > 题材增强包 > 已确认特殊机制包
视频整体基调：
固定禁用提示词：
Q版内心OS规则：不用 / 全剧使用 / 指定角色使用 / 指定集数使用
固定声线表：
输出文件夹：
命名规则：剧名-第X集-分镜.txt
审计参数：是否强制 exact tone，允许Q版集数，必保台词清单路径
```

When the user asks to convert a single episode from a confirmed serial script, generate the storyboard directly after this config is clear. When the source is an unsegmented novel or outline, output episode planning first and wait for confirmation.

## Style Anchor Formula

Each project needs one exact style anchor line. Every Block repeats the exact line.

```text
视频整体基调：{3D类型/画风}，{人物风格}，{渲染/材质}，{题材世界/时代场景}，{色调光影}，{镜头质感}，无字幕、无水印。
```

Examples below are only references. Match two or three candidates from the complete script, let the user confirm one before sample generation, and then freeze the pack ID/version/hash and exact line. Do not copy an example if the genre, era, or custom style differs.

```text
视频整体基调：写实国漫3D风格，半写实美型人物，虚幻引擎渲染，PBR材质，年代乡村生活场景，暖色自然光，浅景深，电影感调色，无字幕、无水印。
```

```text
视频整体基调：国漫玄幻3D风格，半写实仙侠人物，虚幻引擎渲染，PBR材质，仙门山阶、灵雾、法器光效，冷暖对比光，体积光，史诗感电影调色，无字幕、无水印。
```

```text
视频整体基调：轻喜卡通3D风格，圆润萌系人物，风格化渲染，干净明亮的家庭生活场景，柔和暖光，节奏轻快，清晰轮廓，无字幕、无水印。
```

Do not add extra scene mood or per-Block style adjectives to `视频整体基调` unless the user changes the project anchor. Put temporary weather, emotional performance, and local environment details in `画面描述`.

## Ban Line

Default universal ban line:

```text
🚫 无BGM，无字幕，无水印，无非剧情画面文字，人物外观沿用参考图，禁止生成同一张脸的角色，禁止生成双胞胎，禁止生成角色一样的人物。
```

Add project-specific bans only when the script or user requires them.

## Voice Config

Build a fixed voice table before batch generation.

```text
@角色名 — 固定声线：年龄/性别/音色/气质，不写临场情绪
```

Dialogue voice line normal format:

```text
声线/语气：@角色名｜固定声线：音色｜语速正常/语速快/语速慢｜状态：情绪/动作状态｜语气：具体说法
```

If the user gives a simplified custom format, use it consistently for that character:

```text
声线/语气：@角色名｜固定音色｜语速状态｜动作/状态｜语气
```

Voice drift is a global consistency error. Temporary emotion belongs in `状态` and `语气`, not in the fixed voice.

## Q-Version OS Policy

Q-version inner OS is opt-in. Define the policy before generation:

```text
Q版内心OS规则：不用；未确认，不自动启用。
```

or:

```text
Q版内心OS规则：@主角，第1-10集使用；Q版小人在主角头侧或肩侧半空；本体嘴巴不动；同3D风格，不做2D贴纸。
```

If Q-version is enabled:

- Every affected Block must add the Q asset to `👤 出场`.
- The visual description must show Q appearance/action and body mouth not moving before the OS line.
- Q placement defaults to head-side/shoulder-side 3D space.
- Do not write `实体Q版小人`.
- Store Q-generation complexity and its handling strategy internally; never add a public risk/fallback line.

## Style Revision

Later episodes read `项目锁定模块` and the exact tone; they never select packs again. A user-requested style change creates a new revision, preserves earlier approved outputs, and marks affected storyboards, scene/character visual briefs, and image prompts for re-review.

## Dialogue Retention Config

For high-retention adaptations, create a required-dialogue file before generation or revision:

```text
D:\Codex\work\<project>\required-dialogue-第X集.txt
```

One line per S-level or must-retain A-level snippet. Use it with:

```bash
python3 scripts/audit_3d_storyboards.py --root <storyboard-folder> --required-dialogue <required-dialogue-file>
```

# Module Packs Reference

Use this reference when a storyboard needs explicit `本集调用模块` or when style, genre, or special mechanisms affect how Blocks are written.

## Priority

Apply modules in this order:

0. **Confirm before production.** For any NEW show or script, the first action is a one-line confirmation of 题材 + 画幅(横屏/竖屏) + 渲染风格(3D/仿真人/动态漫). A mode tag written in the script header is NOT sufficient to skip confirmation. Only proceed after the user confirms.
1. User source and user custom requirements.
2. V10 common base.
3. Project-locked visual-style pack.
4. Project-locked genre directing constraints.
5. Project-allowed special mechanism pack when the current episode triggers it.

If modules conflict, the user source and custom instructions win. Modules guide expression; they must not invent plot.

## Always-On Base

```text
V10通用底座：3D横屏漫剧 / 只拆不编 / 导演编剧先判断 / 剧本提纯成画面 / 台词S-A-B-C分级 / Block≤15s优先 / 每个Block独立完整 / 声线一致 / 风格锚一致 / 审计返工
```

## Style Enhancement Packs

At project initialization, match two or three candidates from the complete script and user instructions, then let the user lock one. Later episodes must read the locked pack ID/version/hash; they cannot choose again. If uncertain, use a general 3D horizontal manju candidate rather than forcing a niche style.

- 写实国漫3D：semi-realistic character performance, PBR material, cinematic light, grounded facial/body acting.
- 轻喜卡通3D：rounder poses, quicker timing, cleaner silhouettes, more elastic facial beats, warmer domestic staging.
- 玄幻仙侠3D：larger spatial depth, magic/material effects, ritualized pose, weapon/prop punctuation, epic contrast light.
- 古风权谋3D：formal blocking, eye-line pressure, sleeve/hand/tea/letter prop punctuation, restrained emotional reveal.
- 都市豪门3D：clean interiors, status blocking, glass/metal/material detail, controlled performance, sharper cut rhythm.
- 年代乡村3D：earthy environments, cooking/yard/work actions, warm practical light, textured props, lived-in small movements.

Record the locked style pack in the project configuration and run receipt. `🧩 本集调用模块` may display it read-only but cannot select or mutate it.

## Genre Directing Constraint Index (OPEN REGISTRY)

**This is an open registry of directing-constraint examples, NOT a closed menu.** Genres are infinite; the constraint dimensions are finite (reaction timing, prop punctuation, information conceal/reveal, emotion windows, staging/blocking, hook landing). Rules:

- **Never force-fit** a show into the nearest listed pack. If the genre is not in the registry, derive constraints from the script itself (identify the sub-genre, its rhythm, its signature beats), state them as ad-hoc constraints, and report to the user for confirmation. NEVER invent pack names that look like registered packs.
- **Two-level confirmation** for a new show: Level 1 asks the major category (closed list below, easy to pick); Level 2 uses open sub-tags (校园/职场/重生/系统/银发/电竞/无限流...) — read them from the script and report for confirmation, never make the user recite a list.
- **Natural growth**: when a show in a new genre is completed and accepted, sediment its proven constraints back into this registry as a new entry (genre name + constraint skeleton).

### Major Category Index (8)

1. 都市情感 (urban romance/emotion)
2. 家庭伦理/年代生活 (family ethics / period life)
3. 复仇打脸 (revenge / face-slapping payoff)
4. 悬疑惊悚 (suspense / thriller)
5. 喜剧群像 (comedy ensemble)
6. 玄幻仙侠 (xuanhuan / xianxia fantasy)
7. 银发题材 (silver-hair / senior protagonist)
8. 年代古风/权谋 (period / court intrigue)

Sub-tags are open-ended and not enumerated here.

### Constraint Examples (from past productions)

Use as writing samples for how constraints are expressed, not as a picklist:

- 家庭伦理/年代生活：relationship labels, chores, food, doorway/yard/table blocking, small social pressure reactions.
- 复仇爽剧：entry pressure, opponent reaction, prop evidence, reversal punctuation, payoff close-up.
- 喜剧/轻喜：quick reaction timing, deadpan pauses, prop misread, verbal rhythm, but keep causal information.
- 悬疑/阴谋：information conceal/reveal, prop close-ups, controlled eye-lines, silence, next-hook landing.
- 情感虐恋：slower emotion windows, breath/hand/eye detail, fewer gag mechanisms, stronger reaction carry.
- 团宠萌娃：height-level staging, adult reaction field, gentle physical comedy, soft but readable emotion.
- 系统/金手指：system information must be visualized through allowed plot text or character reaction; keep complexity and handling strategy internal.
- 校园甜宠/沙雕群像（沉淀自《失恋后，发现好兄弟是清冷校花》EP-94）：comedy→tension tone-shift at the mid-episode hinge; rapid cut rhythm with escalating gag ladder; deadpan-vs-hyperactive duo contrast; flashback desaturation (做旧褪色) for backstory reveal; sweet UI screen as prop punctuation; final block strips comedy warmth to land the hook.

### Ad-hoc Constraint Template (when genre is not registered)

```text
题材导演约束（临场推导，待确认）：
- 大类：<8类之一>
- 子标签：<从剧本识别>
- 节奏：<快切/慢推/变调点位置>
- 反应镜头：<谁的反应是笑点/泪点/钩子的落点>
- 道具点彩：<承载信息的道具>
- 信息藏露：<什么藏、什么露、何时揭>
- 情绪窗口：<给情绪留几秒>
```

## Special Mechanism Packs

Special mechanisms are not automatic. Use only when the user confirms or the project config explicitly enables them.

### Q-Version Inner OS

- Ask before enabling.
- Candidate: light comedy OS, inner calculation,爽点反讽.
- Avoid: trauma, solemn exposition, heavy worldbuilding.
- Must bind Q visual and Q-OS dialogue in the same lens.
- Must add the Q asset to `👤 出场` only in visible Q Blocks.
- Default placement is head-side/shoulder-side 3D space.
- Do not write `实体Q版小人`.
- Keep Q complexity and handling strategy internal; do not render a public risk/fallback field.

### System UI Or Plot Text

- Use only when it is in the source or confirmed style.
- Keep on-screen plot text at 8 Chinese characters or fewer when possible.
- If the information can be performed by reaction or prop, prefer performance.
- Keep screen-text complexity and handling strategy internal; do not render a public risk/fallback field.

### Animal/Nonhuman Speech

- Keep speaker identity explicit.
- Use body/mouth/eye/gesture animation to support speech.
- Keep nonhuman-speech complexity and handling strategy internal; do not render a public risk/fallback field.

## Module Call Format

```text
🧩 本集调用模块：
  项目锁定：V10通用底座 + 写实国漫3D视觉风格包 + 年代乡村题材导演约束
  特殊机制：未确认Q版内心OS，不自动启用
```

When the genre is not in the registry:

```text
🧩 本集调用模块：
  项目锁定：V10通用底座 + <风格包>
  题材导演约束：临场推导（大类+子标签+约束骨架），已报用户确认
  特殊机制：无
```

When the user says continue:

```text
【规则锚定】V10通用底座 / 导演编剧先判断 / 模块调用已确认 / 3D横屏 / 只拆不编 / Block≤15s / 每个Block必写视频整体基调 / 3D漫剧节奏略快 / 角色@引用 / 台词分级 / 承重台词落画面 / 角色有事可做 / 动画节拍 / 风格包一致 / 题材约束拍法生效 / 特殊机制仅触发时使用 / 结尾留钩
```

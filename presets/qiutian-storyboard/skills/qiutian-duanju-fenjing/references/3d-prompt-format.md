# Prompt Format Reference

Every Block must be directly copyable into a video-generation tool. Do not rely on "same as above", episode-level tone only, or hidden context from previous Blocks.

## Episode Header

```text
══════════════════════════════════════
《剧名》第X集 · 标题
══════════════════════════════════════

📖 剧情摘要：...

🎬 导演/编剧处理：
  戏剧目标：...
  拍法策略：...
  观看入口：...
  台词处理：S级完整保留，A级压缩保核，B级视觉化，C级仅在因果不断时删除。

🎵 节奏走向：
  开场钩子 → ...
  铺垫/递进 → ...
  爆发/爽点 → ...
  收束+钩子 → ...

🧩 本集调用模块：
  只读展示项目已锁定的 V10 底座、3D视觉风格包、题材导演包和本集触发的已许可特殊机制；不得按集重新选包

📦 本集新增资产：
  ...

🎬 抽卡/资产参考基调（仅供抽卡师统一资产，不替代Block视频整体基调）：
  固定风格锚：{根据本剧题材、时代、画风、渲染方式确定；不能照搬示例}
  ...

👤 本集使用人物/资产索引：
  @角色名 — 固定声线：...
```

## Block

```text
── Block X | Ys ──

📍 场景：@场景（时间）
👤 出场：@角色A，@角色B
🧭 起始空间状态：@角色A(姿态+位置锚点，持物/动作，朝向·仅有依据时)｜@角色B(...)

视频整体基调：{exact project style anchor; every Block repeats it; no 同上}

镜头 1 持续时间: Ys【取景主体景别 + 主运镜】
镜头角度：平视/俯拍/仰拍/侧面/过肩/主观/顶视
画面描述：@角色A面朝@角色B，做可见动作；@角色B有可见反应；写清位置、朝向、表情、身体动作、材质/环境/道具细节和动画节拍。
@角色A情绪/动作地对@角色B说：“台词。”
声线/语气：@角色A｜固定声线：音色｜语速正常｜状态：情绪/动作状态｜语气：具体说法

镜头 2 持续时间: Ys【取景主体景别 + 主运镜】
镜头角度：...
画面描述：...

🚫 无BGM，无字幕，无水印，无非剧情画面文字，人物外观沿用参考图，禁止生成同一张脸的角色，禁止生成双胞胎，禁止生成角色一样的人物。
```

The `视频整体基调` line above is a placeholder. In real output, replace it with the exact style anchor from the current project configuration. The line must match the current script's genre and any user custom style.

## Block Field Rules

- `📍 场景` uses @scene when the scene needs consistency.
- `👤 出场` 只列镜头可见角色主体，不是场景人物或资产库存；`🧭 起始空间状态` 只列同一批镜头可见角色主体。
- 3D 横屏优先 2–5 个镜头可见角色主体；这是建议值，不是画面人数硬上限。
- 剧情动作与横向构图需要的群像可以超过建议值；把 `群像必要性`、复杂度原因和处理策略写入内部 Block skeleton，并在公开 `画面描述` 明确左/中/右、前/中/后与主要表演焦点，不因人数本身强制拆 Block。
- 只承担氛围的背景龙套、路人、宾客、士兵或背景人群不逐个写入 `👤 出场`；出现台词、关键动作、道具交互或推动剧情时才升级为主表演主体并进入空间台账。
- 非镜头主体保留在内部空间台账，记录最后位置、持物、伤势和画外状态；再次入画必须有可见承接。
- `🧭 起始空间状态` appears exactly once after scene/cast. Keep the prior Block end state internal, audit it against this start state, record movement as `从 A 到 B`, and never add G1/G2 below or above the Block.
- For action scenes, state the horizontal left/center/right relationship, 战斗轴线, and 攻击方向 when evidenced or explicitly declared as a screen convention.
- Props and non-character assets do not belong in `👤 出场`: phones, tablets, evidence, food, bones, bowls, chopsticks, tables, dust, curtains, doors, clothing, steam, rain, smoke, screens, effects, and UI remain in visual-description, held-prop, screen-state, or asset-ledger fields.
- `视频整体基调` appears once in every Block after scene/cast. It must not say `同上`, `延续上个Block`, or `参考本集基调`.
- The ban line appears once at the end of every Block.
- Uploaded `@角色参考图` is the sole appearance authority. Do not describe clothing in any Block. Use a separately uploaded neutral state asset such as `@角色名_状态02` when appearance state changes.
- Do not claim to inherit a previous Block tail frame unless that exact image is supplied as an asset.

## Lens Line

Use exactly:

```text
镜头 X 持续时间: Xs【取景主体景别 + 主运镜】
镜头角度：平视/俯拍/仰拍/侧面/过肩/主观/顶视
```

Inside `【】`, write the concrete framing subject joined directly to the shot size, then the main camera movement. Name `@角色` and the framed body part when relevant, every named role in a relationship shot, the exact prop in an insert, or the exact location in an environment shot. `【特写 + 固定镜头】` and every other subjectless shot size are invalid. Do not write function or intent words such as `爆点`, `爽点`, `钩子`, `反应落点`, `心动蓄力`, `命令起势`, or `情绪压迫`.

The declared framing subject must be the visual center of the following `画面描述`. Split the lens if the header claims a prop close-up while the description mainly depicts a character performance.

Every shot inherits the Block scene and must contain exactly one angle line and one concrete visual description. One shot carries one primary beat; use a short causal micro-action chain only when it serves that beat.

## Visual Description

Write filmable 3D action. Include:

- named subject or @asset
- position and orientation
- visible action
- expression, body reaction, or physiology
- other visible characters' reactions or background actions
- life action, small animation beat, material, prop, environment, or effect when useful
- entry/exit, turn, approach, retreat, gaze direction, or spatial relation if it changes

Do not write unfilmable psychology or summary. Avoid generic visual references such as `他`, `她`, `男人`, `女人`, `老人`, `小孩`, `众人`; use role names or @assets. Dialogue can remain natural.

Heavy dialogue must be anchored to a visible action, prop, expression, or relation beat.

## Dialogue And Voice

Dialogue:

```text
@角色名情绪/动作地对@对象说：“台词。”
```

Normal voice line:

```text
声线/语气：@角色名｜固定声线：[从人物索引复制，全剧保持一致，不得改音色]｜语速正常｜状态：[情绪/动作状态]｜语气：[具体说法]
```

Rules:

- Put one `声线/语气` line near each dialogue line.
- Allowed speed values: `语速正常`, `语速快`, `语速慢`.
- Do not write old fields such as `本句语速`, `本句状态`, `本句语气`.
- Do not change the same character's fixed voice between Blocks or episodes.
- If the user provides a simplified custom voice format, preserve it exactly and apply consistently.

## Q-Version Inner OS

Use only when the user has confirmed Q-version inner OS.

```text
画面描述：@角色名站在门口没有退，@角色名头侧半空弹出同3D风格@Q版角色名小人，抱着胳膊轻轻一哼，本体@角色名嘴巴不动，只是眼神更稳。
@角色名内心OS（主角头侧半空Q版小人口播，本体嘴巴不动）笃定地说：“……”
声线/语气：@角色名内心OS｜固定声线：同@角色名，音色描述｜语速慢｜状态：心里有底｜语气：笃定
```

Rules:

- The visible Q character subject must appear in `👤 出场` only in Blocks where it is visible, and it counts toward the Block subject budget.
- Q visual and Q-OS dialogue must be in the same lens.
- The visual line before the Q-OS dialogue must mention Q appearance/action and body mouth not moving.
- Default placement is head-side/shoulder-side 3D space, not corner sticker/subtitle.
- Do not write `实体Q版小人`.
- Keep Q-generation complexity and a handling strategy in the internal Block skeleton only. Do not render a risk label or fallback in the public Block.

## Internal Generation Complexity

Preserve necessary drama. Keep feasibility reasoning internal and never render it into the public Block.

Record `generationComplexity`, reasons, and a handling strategy in the internal Block skeleton. Common reasons include complex camera/contact, Q-version characters, animal speech, system UI, readable plot text, ensembles, dangerous action, precise prop handoff, and multi-subject occlusion. Use the result to refine staging, references, Block boundaries, model route, or review depth.

Do not output `生成风险`, `抽卡风险`, `Generation risk`, colored risk labels, fallback, or internal complexity fields.

## Light Cross-Scene Blocks

Allowed for short continuous actions such as entering/exiting, chasing to a doorway, moving from room to yard, or following someone nearby.

Do not merge two independent dramatic goals into one Block.

## Episode Ending

End every episode with:

```text
⏱ 本集总时长：约XXX秒

🧷 遗留信息：
  · 最后一帧画面：...
  · 未解决悬念：...
  · 人物状态：...
  · 集尾空间快照：逐角色姿态、位置锚点、持物、伤势/外观、离场去向；直续/跳跃
  · 关键道具/资产状态：...
  · 模块延续：...
  · OS表现设定：未确认，不自动启用 / 已确认，范围...
  · 下一集触发点：...

继续？（回复“继续”或给出修改意见）
```

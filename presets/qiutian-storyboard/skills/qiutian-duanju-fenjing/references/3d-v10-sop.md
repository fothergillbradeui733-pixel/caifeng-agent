# V10 Storyboard SOP Reference

This reference turns the V10 template into an executable internal process. Do not jump from source text directly to final prompts.

## Rule Mapping

Convert every template into constraints:

1. Pre-generation decisions: episode boundary, module selection, story purification, director logic, spatial ledger, Block skeleton.
2. Generation constraints: exact output structure, prompt transform, visual description, dialogue/voice, lens line.
3. Post-generation audit: deterministic checks plus a same-class scan across the full folder.

Per episode:

```text
source boundary -> project config -> module call -> plot purification -> director judgment -> spatial ledger -> Block skeleton -> adjacent-Block review -> final storyboard -> director contract + spatial gate + hard audit + semantic audit
```

## Episode Boundary

- Output one episode at a time unless the user explicitly asks for batch generation.
- If the source is a full novel, outline, or unsegmented plot, first create an episode planning table and wait for confirmation.
- If the user asks for a specific episode from a serial script, verify the episode boundary from the source body before writing.
- Cut episodes at plot-complete points: hook, escalation, payoff, reversal, closure, or next hook. Do not cut mechanically by seconds.
- After each episode, stop at the continue prompt. When the user says continue, anchor the rules before starting the next episode.

## Source Discipline

- Split only, do not invent.
- Preserve plot nodes, foreshadowing, key props, relationship changes, character motivations, and all weight-bearing lines.
- Preserve uncertain foreshadowing instead of deleting it.
- Allowed optimization: lens language, visible action, expression, environment, prop punctuation, transition, pacing, and colloquial polishing that does not change meaning.
- Keep generation complexity and handling strategy in the internal Block skeleton. Do not weaken necessary drama because it is complex, and do not render risk labels or fallback prose in the public Block.

## Story Purification

Before Block writing, internally process each beat in this order:

1. Original event sentence: restate what happens without adding plot.
2. Drama function: hook, setup, escalation, burst, payoff, reversal, closure, or next hook.
3. Audience emotion target: tension, comedy, pity, satisfaction, anger, curiosity, warmth, etc.
4. Viewing entry: face, action, reaction, prop, environment, or space.
5. Dialogue grading: mark every meaningful line as S/A/B/C.
6. Visual actionization: convert exposition into visible action, expression, physiology, prop, environment, or reaction.
7. Lens necessity test: each lens must add at least one of information, emotion, action, relationship, transition, or payoff.
8. 3D horizontal adaptation: readable poses, action paths, material details, multi-character staging, and horizontal screen geography.
9. Time compression: estimate by main time window, not by serially adding every reaction.
10. Light anchor restraint: keep the project tone exact; do not add extra mood/style drift in every Block.

## Spatial Ledger

Build the 空间台账 after director judgment and before the Block skeleton. Block 本身就是一个完整生成组; do not create G1/G2 or nest another generation group.

For every Block, record:

- source-supported location anchors and character starting postures
- the complete internal spatial ledger for every character still in the scene, plus the camera-visible subject subset for the current Block
- off-camera state for scene characters not selected as the current camera subjects
- held props, injuries/appearance, facing/eyeline only when supported
- movement as `从 A 到 B`, followed by the resulting end state
- the screen convention when left/right is necessary but absent from the source
- cross-Block inheritance in continuous scenes
- for 横向空间 action: left/center/right layers, 战斗轴线, 攻击方向, attacker/defender sides, and any motivated axis crossing

At episode end, save a spatial snapshot: each character's posture, anchor, held prop, injury/appearance, exit destination, unresolved spatial facts, and whether the next episode is 直续 or 跳跃.

## Dialogue Grading

- S-level: keep complete, bind to visible action or strong reaction.
- A-level: compress but do not delete the core information or emotional force.
- B-level: visualize through action, expression, physiological reaction, prop punctuation, environment change, or another character's reaction.
- C-level: delete only after checking the causal chain, relationship state, joke setup/payoff, and foreshadowing remain intact.

Treat dialect jokes, system-like banter, reaction-chain lines, and relationship-address lines as potentially weight-bearing. Do not classify them as filler merely because they are short or comedic.

## Director Judgment

Before writing a Block, decide:

- viewing entry: face, action, environment, prop, reaction, or space
- dramatic target
- desired audience feeling
- what is spoken, acted, silent, or shown through reactions
- lens strategy: fixed, push, pull, lateral move, over-shoulder, fast cut, close-up, prop insert
- 3D adaptation: action beat, pose readability, multi-person reactions, horizontal space, material/animation beat
- what information or feeling the viewer gains from each lens
- uploaded `@角色参考图` as the sole character-appearance authority; never describe clothing in a video prompt
- a separately uploaded neutral asset such as `@角色名_状态02` for any required appearance-state change

Each Block must form:

```text
entry / opening image -> main action -> reaction carry -> information or payoff -> landing / transition
```

Choose Block boundaries before reaching the 15-second limit. A boundary must land on a coherent completed state: completed action or line, reveal-to-reaction handoff, arrival at an established anchor, or a supported scene/time change. Never cut mechanically at 15 seconds or invent movement to repair a seam.

After deriving each internal end state, audit every adjacent pair for plot causality, position, posture, held prop, action phase, visible/off-camera state, screen direction, axis, and the relationship between the outgoing and incoming shots. For continuous scenes require `Block N internal end state = Block N+1 start state`. Apply the smooth-seam gate (see `seam-audit.md` in this skill): keep at least two visual bridge anchors and preserve the horizontal/combat axis and action phase. Without an actual supplied tail frame, use exactly one motivated change in shot size, viewpoint/composition, or movement; do not keep the whole setup identical across independent generations. Zero change requires a supplied tail frame or supported occlusion/insert mask. Multiple changes require a strong prop/reaction/reveal bridge or a real scene reset. If the seam fails, revise the boundary or camera plan.

## Block Skeleton

Build this skeleton before final prose:

```text
Block drama task:
Viewing entry:
Scene:
Starting spatial state:
Movement/end state:
Screen convention:
Camera-visible character subjects:
Off-camera continuity state:
Ensemble necessity (required for 6+ visible subjects):
Generation complexity/reasons/handling strategy (internal only):
Main action line:
Required S-level dialogue:
A-level core information:
B-level information to visualize:
Key reaction:
Transition/hook:
Estimated duration:
Expected lens count:
```

## Camera-Visible Subject Budget

- 3D 横屏优先 2–5 个镜头可见角色主体；这是生成稳定性的建议值，不是画面人数硬上限。
- `👤 出场` 与公开 `🧭 起始空间状态` 只列当前摄影机真正拍到的角色主体，不列普通/核心道具、屏幕、证物、伤口、地点、家具、特效或 UI。
- 内部空间台账继续跟踪场景内全部角色，包括画外角色的最后位置、持物、伤势与下一次可见入场路径。
- 剧情动作与横向构图需要的群像可以超过建议值；把 `群像必要性` 写入内部 Block skeleton，并在公开 `画面描述` 明确左/中/右、前/中/后与主要表演焦点，不因人数本身强制拆 Block。
- 只承担环境氛围的背景龙套、路人、宾客、士兵或背景人群不逐个写入 `👤 出场`；出现台词、关键动作、道具交互或推动剧情时才升级为主表演主体并进入空间台账。
- 是否拆 Block 由戏剧动作、摄影机焦点、时长与生成复杂度共同决定，并保持动作、轴线和跨 Block 空间连续性。

Duration target:

- Block must be <= 15s. There is no 16-18s exception for Seedance 2.0.
- 10-15s Blocks usually need 3-5 lenses.
- A one-lens Block is only acceptable for a very short, simple, continuous beat.

## Lens Density And Splitting

- Do not make one Block equal one shot by default.
- Important highlight can use one-to-three splitting: setup/action -> key detail or prop punctuation -> micro-expression/reaction.
- Ordinary reactions should usually be folded into the main shot, not all split into standalone reaction shots.
- A long information line over about 2.5s should use speaker/action, reaction, prop/detail, or back-cut instead of one static medium shot.
- A lens longer than 6s must have enough dialogue, continuous action, or visible emotional change.
- Avoid empty pull shots, repeated blank reaction stacks, and prop inserts that do not serve the drama.

## Timing Rules

Estimate internally using these baselines:

- normal dialogue: about 8 chars/s
- explanatory, pitch, recap: 8-8.5 chars/s
- argument or comedy quips: 9-10 chars/s
- sad, hesitant, heavy: 5-6 chars/s
- OS/VO: 5.5-6.5 chars/s
- Q-OS/comedy OS: 6-7 chars/s

Timing is by main timeline:

- Spoken lines and visible actions can happen simultaneously.
- Multi-character reactions in one frame share the same time window.
- Movement, camera, and reaction windows can overlap.
- Output only the final duration, but internally confirm dialogue can be spoken, actions can complete, camera can connect, and reactions can land.

## Visual Description Rules

Each `画面描述` must answer:

- Who is visible?
- Where is the subject?
- What visible action happens?
- Who or what does the character face, look at, or move toward?
- What expression, body reaction, or physiology is visible?
- What do other visible characters do?
- Is a prop, material, environment, or animation beat needed?

Do not use plot-summary words as the visual description: `分给`, `安排`, `负责`, `意味着`, `说明`, `证明`, `意识到`, `反应过来`, `明白`, `知道`, `判断`, `像是在`, `仿佛`, `心里`, `脑子里`, `盘算`, `觉得`, `以为`, `相信`, `怀疑`.

Allowed exception: a visible prop name such as `@离婚证明` is not an abstract "证明".

Use role names or @asset names in visual descriptions. Do not use generic references such as `他`, `她`, `男人`, `女人`, `老人`, `小孩`, or `众人` when a named asset is known. Dialogue itself may keep natural pronouns.

## Lens Line Rules

Lens line format:

```text
镜头 X 持续时间: Ys【取景主体景别 + 主运镜】
镜头角度：平视/俯拍/仰拍/侧面/过肩/主观/顶视
```

Inside `【】`, write concrete framing subject + shot size + camera movement. Name `@角色` and the framed body part when relevant, every named role in a relationship shot, the exact prop in an insert, or the exact location in an environment shot. Subjectless forms such as `【特写 + 固定镜头】` are invalid. The named subject must remain the visual center of `画面描述`; split competing visual centers into separate lenses. Do not write intent words such as `心动蓄力`, `爆点`, `命令起势`, `时间恢复`, `短钩`, `爽点`, `钩子`, `反应落点`, or `情绪压迫`.

Every shot inherits the Block scene and contains exactly one angle line and one concrete visual description. One shot carries one primary beat. Do not claim to inherit an unknown prior tail frame; use one only when the user supplies the actual image asset.

## Voice Rules

Normal form:

```text
声线/语气：@角色名｜固定声线：音色｜语速正常/语速快/语速慢｜状态：情绪/动作状态｜语气：具体说法
```

Simplified custom form is allowed only when the user explicitly gives it. Apply consistently.

Allowed voice changes: speed, state, tone. Do not change the same character's fixed voice across episodes.

## Q-Version Inner OS

- Q-version inner OS is opt-in. Ask before using it unless the user already confirmed the policy.
- Default without confirmation: normal OS/VO or visible expression/action.
- Candidate use: comedy inner calculation, light satire,爽点反讽. Avoid Q for heavy trauma, solemn exposition, or worldbuilding.
- If enabled, add the Q asset only to Blocks where it appears.
- Q visual and Q dialogue must be in the same lens.
- The visual line before the Q-OS dialogue must show the Q figure appearing, its action/expression, and the body mouth not moving.
- Default placement: beside the character's head or shoulder in 3D space. Do not default to a corner sticker/subtitle layer.
- Use same 3D style. Do not write `实体Q版小人`; prefer `同3D风格@Q版角色名小人` or `3D小分身`.
- Keep Q complexity and a workable handling strategy in the internal Block skeleton; do not output a public risk/fallback line.

## Same-Class Scan

When one issue is found:

- visual summary sentence -> scan all `画面描述`
- fixed voice pollution -> scan all `声线/语气` and voice indexes
- old dialogue format -> scan all dialogue lines
- prop/non-character asset in cast -> scan all `👤 出场`
- ensemble staging issue -> scan all `👤 出场`, matching `🧭 起始空间状态`, `群像必要性`, and foreground/middle/background priority; never fail on count alone
- lens intent in bracket -> scan all lens lines
- one-shot Block -> scan all Block lens counts and long-dialogue lenses
- missing dialogue -> scan S/A dialogue inventory or required-dialogue file
- Q OS mismatch -> scan all Q OS lines and the previous visual description

## Delivery

Before saving, ask the user to choose the location and save files to one named folder there. Never reuse a previous project's output root by default.

Use file names:

```text
剧名-第X集-分镜.txt
```

For future Manju storyboard deliverables, prefer folder naming:

```text
<start>-<end>集分镜-<剧名>
```

Also write or refresh:

- final audit report
- voice consistency map
- change records for major global changes

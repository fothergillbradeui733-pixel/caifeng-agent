---
name: qiutian-wangwen-manju-gaibian
description: 将长篇网络小说持续拆解并改编为16:9动态漫/漫画短剧剧本，使用目标长跑、原著四契约、分层最小上下文、权威机检、独立语义质检、作用域收据、可恢复Commit、增量视觉交接和性能遥测。Use for 小说转剧本、网文漫剧改编、原著保真改编、剧情拆解/分集、续写或重写EP剧本、视觉资产事实交接，或用户输入 ~start、~map、~write、~rewrite、~polish、~handoff、~status、~export、~next。只执行V6流程并兼容既有comic-adapt项目与Markdown布局。
---

# 秋天 网文漫剧改编 V6

把原著视为事实源、剧情地图视为改编中枢、项目台账视为跨集当前真值。缓存、brief、上下文包和遥测只服务执行，不得覆盖权威文件。

## 启动

1. 将本文件目录记为 `skill root`；脚本用绝对路径调用。先遵守项目内 `AGENTS.md`。
2. 新项目先让用户选择 `standard` 或 `fidelity-free`；既有项目从 `progress.md` 与policy恢复，缺失或非法时才询问。
3. 运行 [workflow.md](references/workflow.md) 的启动/恢复流程。脚本报载体缺失时才读取 [ledger-rules.md](references/ledger-rules.md)；建档才读 [progress-template.md](references/progress-template.md)。
4. 用户给出总目标后持续到目标位置。`goal-runner`对不少于6集的连续写作自动选 `long_run_batch`，短任务和回退使用 `classic`；普通未决登记后继续，只有真实阻塞才暂停。
5. `goal-runner`随 `Next/Advance`自动启停每集/批计时并在目标闭合时尝试结束总计时；默认目标完成后统一报告，不手工补造时长。长跑批次只在进入该档时读取 [long-run-batch.md](references/long-run-batch.md)。

## 按角色路由

同一角色不装载另一角色的规则；脚本输出的 `writer/checker/next-action brief` 优先于读取大包。

| 阶段/角色 | 必读 | 按需 |
|---|---|---|
| `~map` 主编 | [map-card.md](references/map-card.md) | 首批示例 [plot-map-example.md](references/plot-map-example.md)；保真模式 [fidelity-free-mode.md](references/fidelity-free-mode.md) |
| Map checker | quality Plan生成的checker brief | brief缺失时才读 [source-checker.md](references/source-checker.md) |
| `~write/~rewrite` 主编 | [write-card.md](references/write-card.md)＋本集writer brief＋目标原章 | 前2集按需读 [script-example.md](references/script-example.md)、[visual-style-ref.md](references/visual-style-ref.md) |
| 长跑批次主编 | [long-run-batch.md](references/long-run-batch.md)＋冻结批次契约 | 只按其路由读取单集write/checker卡 |
| Script checker | quality Plan生成的checker brief＋剧本＋其列明证据 | brief缺失时才读 [script-checker.md](references/script-checker.md) |
| `~polish` | [polish-card.md](references/polish-card.md) | 只按Plan触及的规则ID回读write/ledger/visual卡 |
| `~handoff` | [visual-handoff-card.md](references/visual-handoff-card.md) | 历史回填才读原著、剧本和完整台账 |
| `~status/~export/~next` | 直接运行workflow列明脚本并读取输出 | 只有报错修复才读对应规则卡 |

权威归属：写作语义=`write-card`；拆解语义=`map-card`；checker维度=`source/script-checker`；机器格式=`script-lint.ps1 -Rules`；台账=`ledger-rules`；视觉=`visual-handoff-card`；状态/作用域/失败路由=脚本生成的Plan与收据。

## 执行门

- `classic`逐集串行；`long_run_batch`的分批、冻结、staging、批审与批量Commit按 [long-run-batch.md](references/long-run-batch.md) 和`batch-runner Next`执行。
- `~map`：map-spec → map-preflight `FAIL=0` → quality Plan → 一个只读checker → PASS/UNRESOLVED → 提交。
- `~write`经典路径：只读预取 → 紧凑Write包与writer brief → 四契约门 `READY` → 单集正文 → PreReviewAuto → quality Plan与checker brief → 一个只读checker → Commit。
- checker严格执行Plan。输入hash变化记 `FAIL_INPUT` 并重建，不计语义失败；失败升级与PASS作用域只服从quality收据。
- 单集正文以 `【卡黑】` 结束。新写、重写、精修均不生成或读取下集预告；旧预告仅由兼容导出层剥离。

## 不可降低

- 原著事件、因果、行动主体、知识边界、揭晓顺序与明确相对时长不得错误。
- 相邻集地点、在场人物、人物/道具状态、末场完成态和未了动作不得断裂。
- 权威机检必须 `FAIL=0`；平台合规、基本可拍性和视觉事实完整性每集必查。
- 保真免费模式命中项必须检查；项目Markdown只由主编写，checker和原著只读。

## 完成

目标末统一报告：完成/PASS/UNRESOLVED范围；逐集/逐批拆与写用时；总时及主动、等待、checker、视觉、台账分项；机检、检查轮次、首次通过率、台账/视觉状态、缓存/brief体积和未决依赖。

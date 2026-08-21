# comic-adapt 主控流程 V6

本文件只负责启动、恢复、目标状态和查询。创作方法、checker维度、台账字段、视觉字段和长跑批次数据契约由各自权威卡负责。

## 项目布局

```text
project/
├── novel/                    # 只读事实源
├── plot-map.md
├── character-cards.md
├── scripts/EP-XX.md
├── progress.md
├── ledger-foreshadow.md
├── audit-log.md
├── visual-assets/{source-facts.md,episodes/,handoff.md}
├── .comic-adapt/             # policy、goal、quality、unresolved
└── .comic-adapt-cache/       # 可重建索引、包、brief、计划、事务、遥测
```

旧项目可继续使用既有Markdown布局；只补机器状态和缺失载体，不批量改写已有PASS正文。

## WF-START：启动与恢复

1. 只读检查 `progress.md`。新项目确认 `standard` 或 `fidelity-free`，把模式和生效范围写入progress；旧项目仅在模式缺失时询问。
2. 校验 `novel/`。EPUB先拆章；过短、占位、缺号章不得进入拆解。
3. 新项目按模板建载体并初始化视觉交接；旧项目只补机检报告的缺失项。
4. 初始化/规范化policy。新项目从EP-01禁预告并使用原著相对时间；旧项目以现有最大EP+1为新契约起点，旧预告和旧日历冻结保留。
5. 启动检查、旧PASS迁移和项目全检必须通过；失败时再读取对应规则卡修复。

```powershell
workflow-policy.ps1 -ProjectRoot . -Mode Init
script-lint.ps1 -Path . -Startup
quality-receipt.ps1 -ProjectRoot . -Mode MigrateLegacy
project-status.ps1 -ProjectRoot . -Full
```

## WF-GOAL：目标长跑

```powershell
goal-runner.ps1 -ProjectRoot . -Mode Init -Task write -Range 19-60
goal-runner.ps1 -ProjectRoot . -Mode Next
goal-runner.ps1 -ProjectRoot . -Mode Advance -UnitTarget EP-19 -State PREFETCHED
goal-runner.ps1 -ProjectRoot . -Mode Status
goal-runner.ps1 -ProjectRoot . -Mode Report
```

`Next`是下一动作权威：它同时输出准确命令和 `.comic-adapt-cache/next-action.json`，不得从文档手工推导或跳状态。连续写作不少于policy阈值时自动路由 `long_run_batch` 并由 `batch-runner Next`接管；详见 [long-run-batch.md](long-run-batch.md)。所有单元到 `COMPLETE` 或 `UNRESOLVED` 才算抵达目标位置。计时、闭合与`final_only`规则不因批次模式改变。

经典逐集状态机：

```text
PENDING → PREFETCHED → DRAFTED → MACHINE_PASS → REVIEWED
→ SEMANTIC_PASS | UNRESOLVED → COMMITTED → COMPLETE
```

`UNRESOLVED`保留问题与依赖并允许长跑继续，但不能描述成PASS或进入正式导出。共享权威文件始终单写者提交。

历史问题完成显式修复后，使用受限重审闭合，不能直接编辑收据或未决表：

```powershell
quality-receipt.ps1 -ProjectRoot . -Mode Revalidate -Target EP-XX -Kind Script
# 独立Full checker完成后，CheckedHash必须是其实际检查的当前文件SHA：
quality-receipt.ps1 -ProjectRoot . -Mode Revalidate -Target EP-XX -Kind Script -Result PASS -CheckerMode Full -CheckedDimensions 1,2,3,4,5,6,7,8,F -CheckedHash <sha256>
```

`batch-runner`与长跑批次卡唯一维护批次状态；每个批次状态仍同步推进上述逐集状态，确保旧项目、quality收据和性能报告兼容。

## WF-RUN：运行约束

- 主编只读本阶段权威卡和生成brief；checker只读checker brief及其列明材料。
- 经典路径checker等待期只做不可变预取。批次路径允许冻结接缝后并行生成staging候选稿；两者都不能把预取包当正式Review输入。
- PreReview先跑DraftGate；Commit只可机器闭合正文 `core_sha256` 未变的登记块/raw文件变化。视觉语义异文继续交checker。
- 旧绝对日历不进入新writer brief；旧预告不进入新正文或checker作用域。

## WF-STATUS：查询与导出

```powershell
project-status.ps1 -ProjectRoot . -Fast
project-status.ps1 -ProjectRoot . -Full
project-status.ps1 -ProjectRoot . -Full -SummaryOnly
project-status.ps1 -ProjectRoot . -Full -Json
quality-receipt.ps1 -ProjectRoot . -Mode Report
goal-runner.ps1 -ProjectRoot . -Mode Report
export-scripts.ps1 -ProjectRoot . -Range 1-60
```

- `~status`默认Fast；hash或状态异常时工具自行升级或提示Full。
- `~status --full`执行目录lint、progress、视觉全检与quality汇总。
- `-SummaryOnly/-Json`只改变展示；完整FAIL/WARN仍写入`.comic-adapt-cache/status-diagnostics.txt`，不降低任何判据。
- `~export`只导出有效PASS集，按policy剥离旧预告，不修改源文件。
- 目标末报告以goal/performance/quality工具输出为准，不重新扫描并人工汇总。

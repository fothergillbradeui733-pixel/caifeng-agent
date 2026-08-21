# 长跑批次执行卡 V6

只在 `goal-runner` 输出 `profile=long_run_batch` 时读取本卡。质量语义仍分别归 `write-card`、`script-checker`、`visual-handoff-card` 与 `ledger-rules`；本卡只定义批次编排和数据契约。

## 路由

始终执行 `goal-runner Next` 或 `batch-runner Next` 给出的准确命令。批次状态唯一顺序：

```text
PENDING → BATCH_PLANNED → SEAMS_FROZEN → CANDIDATES_READY
→ DRAFTS_LINT_PASS → BATCH_REVIEWED | REPAIRING → BATCH_COMMITTED
```

- 自动风险分批：高风险3集、中风险6集、低风险9集；最多3个writer worker，每个worker负责连续集。
- 先冻结整批契约，再生成正文。下一批最多预取一批，不得脱离上一批出口 `seam_sha256` 生成正式候选稿。
- worker不能修改 `scripts/`、progress、视觉事实或quality收据，只能写 `.comic-adapt-cache/staging/<BATCH>/worker-N/`。
- 主编逐集接收候选稿；批量checker可以共享读取材料，但每集必须独立PASS。

## 冻结契约

`batch-runner Plan`生成 `comic-adapt-batch-contract/1.0` 草案。主编完整读取列明原章后，为每集填写并冻结：

- `must_keep`
- `entry_state`
- `exit_state`
- `knowledge_delta`
- `source_time`：只写原著原话或“原著未明示”
- `entity_refs`
- `asset_transitions`
- `ledger_delta`

不得把绝对日历、下集预告、无据状态或后文信息写进契约。`Freeze`生成相邻 `seam_sha256`；冻结后需要改变首尾状态时，整条受影响接缝重新冻结并使相关候选稿失效。

## 候选稿与manifest

每集交付 `EP-XX.md` 和 `EP-XX.manifest.json`：

```json
{
  "schema_version": "comic-adapt-candidate-manifest/1.0",
  "episode": "EP-XX",
  "script_sha256": "64位小写哈希",
  "core_sha256": "64位小写哈希",
  "batch_contract_sha256": "64位小写哈希",
  "entry_state": "与冻结契约逐字一致",
  "exit_state": "与冻结契约逐字一致",
  "knowledge_delta": "与冻结契约逐字一致",
  "source_time": "与冻结契约逐字一致",
  "entity_refs": ["CHR-001", "SCN-001"],
  "asset_transitions": [],
  "ledger_delta": []
}
```

manifest只陈述本集结构化事实，不替代正文证据。`entity_refs / asset_transitions / ledger_delta`去空白、拒绝重复后必须与冻结episode contract精确同集合；实体必须使用显式ID，禁止只靠“阵石”“乾坤袋”等子串归并资产。`Freeze`输出契约文件SHA，worker和接收端必须使用同一值。

## 批量审核与修复

`PlanReview`生成一个批次checker brief。checker一次读取共享原章、冻结契约和连续剧本，返回 `comic-adapt-batch-checker-result/1.0`：

- `episodes`：每集独立 `PASS / FAIL / FAIL_INPUT`、raw/core hash、维度、问题四元组与 `exit_state_changed`。
- `seams`：每对相邻集独立 `PASS / FAIL`。

`RecordReview`仍为每集写独立quality receipt。普通失败只修失败集；出口状态改变或接缝失败时，把前后相邻集加入复查范围。核心事实影响由依赖关系传播，不全批重跑。第三次语义失败仍登记UNRESOLVED并继续目标；问题后来修复时只能运行`quality-receipt -Mode Revalidate`生成新的Full brief，并以当前hash的Full PASS闭合历史未决。

## 批量视觉、台账与Commit

- checker前视觉保持DRAFT；全批DraftGate全部通过后才允许视觉Sync、ledger Plan和后续包构建。带显式`PRP-*`的冻结`asset_transitions`必须在对应分集「道具出现」中覆盖。
- 整批/连续PASS前缀通过后统一执行台账收割、视觉Sync/READY/Validate、Index和Status。
- 每批只更新一次增量索引；每到第10集执行一次全量Index/Status检查。
- Commit验证 `core_sha256` 未变后，允许登记块引起的 `raw_sha256` 变化走机器闭合；人物、地点、道具或可见状态语义变化必须重新路由checker。
- Commit先在系统临时目录镜像演练`FixProgress`，演练FAIL不得改正式项目。journal记录每集输入`core_sha256`、每个完成步骤和事务态hash；恢复时输入核心变化立即要求语义重审，状态漂移则从门链起点重跑，任何情况下都不得跳过语义或视觉门。只提交从批首起的连续PASS前缀，其余保留在staging/REPAIRING。

## 上下文纪律

批次共享契约、稳定角色/视觉/台账事实只加载一次；单集writer只加载紧凑brief、冻结episode contract和目标原章。目标限额：writer brief不高于约2200 tokens，单集Write JSON不高于约5000 tokens。完整权威文件只在歧义、风险依赖或审计时定点回读。

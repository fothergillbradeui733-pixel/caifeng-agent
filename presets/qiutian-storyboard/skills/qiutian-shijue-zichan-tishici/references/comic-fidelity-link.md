# comic-adapt-fidelity 全季正式建库联动

本契约只处理用户在全季剧本完成后显式调用的一次性正式建库。不得自动从上游调用本技能。

## 输入与权威边界

固定入口为 `<项目>/visual-assets/handoff.md`。先由上游运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <comic-adapt-fidelity技能根目录>/scripts/visual-handoff.ps1 -ProjectRoot <项目> -Mode LibraryReady
```

只有输出 `ASSET-LIBRARY-READY` 才进入正式建库。随后运行：

```text
python <本技能根目录>/scripts/prepare_fidelity_library.py \
  <项目>/visual-assets/handoff.md \
  --style "<视觉风格>" \
  --pipeline "<下游管线>" \
  --output <项目>/.comic-adapt-fidelity-cache/qiutian-shijue-zichan-tishici/library-plan.json
```

`prepare_fidelity_library.py` 内部调用 `import_comic_handoff.py`。该导入器同时兼容：

- `comic-adapt-fidelity-visual-handoff/1.0`：本契约的严格联动模式。
- `comic-adapt-visual-handoff/1.0`：旧 `comic-adapt` 的兼容导入；不得据此让 fidelity skill 接管旧项目。

对 fidelity schema，标准 JSON 是唯一资产发现源：

- 正式卡集合严格等于全部 READY 分集里 `资产化决策=建卡` 的唯一 `建议状态@` 集合。
- `source-facts.md` 中未进入 READY 分集的实体不建卡。
- `逐镜内联` 与 `不资产化` 不建卡。
- 上游建卡决策为最终决策；不得以本技能门槛重新升降级。
- 不全量扫描剧本、剧情地图或原著发现新资产，也不运行会重新发现资产的全量源覆盖审计。
- 仅当标准 JSON 内部事实缺失、互相冲突，或缺少提示词必需的非审美事实时，按实体ID、剧本路径和证据场次定点回读。导入 FAIL 时停止并要求修复上游交接，不回退到全量发现。
- `原文未明示，交下游美术补足` 已授权纯审美设计，不属于事实缺失；按资产规格补足并在卡内说明标记为美术补足。

## 版本与幂等

默认输出目录固定为：

```text
<项目>/visual-assets/library/
├── {项目名}_视觉资产库_V1.md
└── {项目名}_资产索引_V1.md
```

严格服从建库计划的 `status`：

- `CREATE`：只创建计划给出的新版本和路径。
- `REUSE`：不改文件；重跑全部机检并报告复用。
- `REBUILD_INDEX`：资产库保持原文，只从库重建缺失索引。
- `BLOCKED`：现有库与当前交接指纹、视觉风格或生成契约不同；停止。只有用户明确要求“升版”时向计划命令加入 `--upgrade`，创建 V{N+1}，不得覆盖旧版。

禁止在计划之外自行选择版本、文件名或目录。

## 精确写卡

从计划 JSON 的 `candidate_cards` 建立闭合台账。每个对象含：

```json
{
  "asset_name": "@资产名",
  "entity_id": "CHR-001",
  "entity_type": "角色",
  "canonical_name": "规范名",
  "episodes": ["EP-01", "EP-02"]
}
```

每个候选恰好生成一张完整有效卡；不得多卡、漏卡或把基础卡额外加入状态族。卡内 `出现集` 必须精确等于 `episodes`，连续集压缩为区间，离散集逐项列出。人物、场景和道具的事实正文来自标准 JSON 中按同一 `entity_id` 过滤后的 `source_facts` 与逐集证据；仅为消歧或处理冲突时定点读取源文件。

完整库使用 `output-template.md`，并在 `## 风格设置` 后写：

```markdown
## 来源契约

生成契约版本：qiutian-shijue-zichan-tishici-fidelity-library/1.0
来源技能：{计划 source_skill}
来源交接schema：{计划 schema_version}
来源交接指纹：{计划 contract_fingerprint}
来源交接路径：{handoff.md 的绝对路径}
建库视觉风格：{计划 style}
建库下游管线：{计划 pipeline}
建库范围：{计划 coverage}
上游建卡数：{计划 candidate_card_count}
```

这些字段用于幂等判断，必须逐字复制计划值。

## 验收

新建或升版后依次运行：

```text
python <本技能根目录>/scripts/sync_asset_index.py <资产库> --output <计划 index_path>
python <本技能根目录>/scripts/validate_assets.py <资产库> --index <索引>
python <本技能根目录>/scripts/audit_handoff_suggestions.py <handoff.md> --library <资产库>
python <本技能根目录>/scripts/audit_fidelity_library.py <handoff.md> --library <资产库> --style "<计划 style>" --pipeline "<计划 pipeline>"
python <本技能根目录>/scripts/prepare_fidelity_library.py <handoff.md> --style "<计划 style>" --pipeline "<计划 pipeline>"
```

前四项必须零 FAIL；最后一次计划必须返回 `REUSE`。不运行 `audit_source_coverage.py`，因为本模式禁止二次资产发现。

交付报告至少包含：上游 `LibraryReady` 收据、schema、交接指纹、建卡数、库与索引路径、四项机检摘要、最终幂等状态。

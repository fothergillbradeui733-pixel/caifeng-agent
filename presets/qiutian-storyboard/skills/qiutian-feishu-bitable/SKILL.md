---
name: qiutian-feishu-bitable
version: 1.0.0
author: qiuyang
description: "Use when 用 lark-cli 操作飞书多维表格或建短剧资产表、上传视觉资产库到飞书、建角色/场景/道具/生物/群像五表、把资产卡写入飞书 Base。"
---

## When to Use
- 用户给飞书 `/base/` 链接、要"建资产表格"、"参考这个飞书表格"。
- 要建/改/读飞书多维表格（Base）的表、字段、记录。
- 为短剧建飞书资产表（角色/场景/道具/生物/群像 5 表）。

# 飞书多维表格（Base）操作 SOP

飞书多维表格（Base，旧名 Bitable）通过**飞书官方 CLI `lark-cli`**（`@larksuite/cli`）操作。本 skill 覆盖：定位与授权、读结构、建表建字段、写记录，以及**短剧资产表建表**的完整流程和坑。

## 1. lark-cli 定位与授权

**别人用自己的飞书。** 完整自助步骤见本预设根目录 [`SETUP-FEISHU.md`](../../SETUP-FEISHU.md)。不要复用作者本机路径、不要写死作者身份。

### 位置与配置
- 可执行文件：优先 `lark-cli`（`npm i -g @larksuite/cli` 装进 PATH）。作者本机历史路径 `~/.workbuddy/binaries/node/cli-connector-packages/bin/lark-cli` 仅本机有效，外发环境禁止写死。
- 配置：`~/.lark-cli/config.json`（对方自己的 appId；appSecret 进系统钥匙串 / 凭据库）
- 凭证缓存：本机 `lark-cli` 用户目录（macOS：`~/Library/Application Support/lark-cli/*.enc`），勿读明文、勿打包
- `--as user` = **当前 `lark-cli auth status` 登录的那个人**，不是作者

```bash
# 先确认在 PATH 里；没有再尝试本机已知路径
command -v lark-cli || export PATH="$HOME/.workbuddy/binaries/node/cli-connector-packages/bin:$PATH"
lark-cli --version
lark-cli auth status
```

### OAuth 设备码授权（缺 scope 时）
1. 发起（拿 device_code + verification_url）：
   ```bash
   lark-cli auth login --scope "<scope 空格分隔>" --no-wait --json
   ```
2. 生成二维码（**必须**，`--output` 只接受**当前目录内相对路径**，先 cd）：
   ```bash
   cd /tmp && lark-cli auth qrcode "<verification_url>" --output qr.png
   ```
3. 把 verification_url 和二维码图**都**展示给用户，用户扫码→同意授权（URL 里有配对码 user_code）。
4. 用户确认后，完成登录（会阻塞等授权，timeout≥600s）：
   ```bash
   lark-cli auth login --device-code "<device_code>"
   ```
- device_code 有效期约 10 分钟；不要缓存复用，每次重新发起。
- 常用 scope：读 `base:block:read base:table:read base:record:read bitable:app:readonly`；写 `base:app:create base:table:create base:field:create base:record:create base:table:update`；搜 Base `search:docs:read`。一次申请齐，避免反复授权。

## 2. 读结构（先拿 token）

```bash
# URL → base_token（用户给 /base/ 链接时）
lark-cli base +url-resolve --url "<url>" --as user
# 标题关键词 → base_token（需 search:docs:read）
lark-cli base +title-resolve --title "<短关键词≤30字>" --as user
# 列出 Base 内所有表/仪表盘
lark-cli base +base-block-list --base-token <bt> --as user
# 列出表字段（type/style/options/link_table）
lark-cli base +field-list --base-token <bt> --table-id <tid> --as user
# 列记录（--format 只有 markdown|json，无 ndjson）
lark-cli base +record-list --base-token <bt> --table-id <tid> --as user --format json --page-size N
```

## 3. 建 Base / 表 / 字段

### 字段 JSON 规范（SSOT）
| 类型 | 写法 |
|---|---|
| text | `{"type":"text","name":"X"}` |
| number | `{"type":"number","name":"X","style":{"type":"plain","precision":0,"percentage":false,"thousands_separator":false}}` |
| select | `{"type":"select","name":"X","multiple":false,"options":[{"name":"A","hue":"Green","lightness":"Light"}]}` |
| link | `{"type":"link","name":"X","link_table":"<表ID或表名>"}` |
| attachment | `{"type":"attachment","name":"X"}` |

- 字段数组**第一个是主字段**（primary field），通常放"资产名称"/"名称"。
- `select` 选项 `options[].name` 必填，写记录时值必须精确匹配选项名；hue/lightness 只是颜色。
- `--json` 传数组字符串，或 `@file`（**@file 必须是当前目录内相对路径**，否则报错）。

### 建 Base（含第一张表）
```bash
lark-cli base +base-create --name "<Base名>" --table-name "<表名>" --fields @fields.json --as user
```
- 若 `--fields` 里含**自引用 link 字段**会失败（见坑 4.1）——见下方 link 分步。
- 建表：
```bash
lark-cli base +table-create --base-token <bt> --name "<表名>" --fields @fields.json --as user
```

### 字段维护
```bash
lark-cli base +field-create --base-token <bt> --table-id <tid> --json @fields.json --as user   # 建（可数组）
lark-cli base +field-update --base-token <bt> --table-id <tid> --field-id <名或ID> --json '{"type":"text","name":"新名"}' --yes --as user  # 改名/PUT全量
lark-cli base +field-delete --base-token <bt> --table-id <tid> --field-id <名或ID> --yes --as user
lark-cli base +table-update --base-token <bt> --table-id <tid> --name "<新表名>" --as user   # 重命名表
```

## 4. 坑（务必读）

### 4.1 link 字段自引用不能在建表时声明
- `+base-create --fields` 里含 link 字段且 `link_table` 指向**正在创建的表本身**，报 `800030104 not_found`。
- 后果：Base 已创建（留下默认"数据表"），但 `--table-name`/`--fields` 未生效。
- **解法（分步）**：
  1. 先建表（`--fields` 不含 link 字段），拿到 table_id；
  2. 再 `+field-create` 补 link 字段，`link_table` 填真实 table_id。
- 复用已建的半成品 Base：用 `+title-resolve` 找到它的 base_token（需 search:docs:read），再 `+table-update` 把默认"数据表"改名、`+field-update` 把默认"文本"字段改为主字段名、`+field-delete` 删多余默认字段（单选/日期/附件），最后 `+field-create` 补字段。

### 4.2 默认新表的字段
飞书新建 Base 的默认"数据表"自带 4 字段：文本(text,主)、单选(select)、日期(datetime)、附件(attachment)。要干净结构就删掉后 3 个，把"文本"改名为你的主字段。

### 4.3 @file 相对路径
`--json @file` 的 file 必须是**当前目录内的相对路径**（`@./x.json` 或 `@x.json`），传绝对路径报 `invalid JSON file path`。先 `cd` 到文件目录。

### 4.4 record-list 无 ndjson
`+record-list --format` 只支持 `markdown`、`json`（报错提示里写的 `ndjson` 是文档旧描述，实际不接受）。

### 4.5 字段重排用 view-set-visible-fields，但有个 no-operation 坑
重排列顺序（字段本身的 field-id 顺序改不了，只能改**视图**的显示顺序）：
```bash
lark-cli base +view-set-visible-fields --base-token <bt> --table-id <tid> --view-id <grid视图ID> \
  --json '{"visible_fields":["资产名称","文生图提示词",...]}' --as user
```
- `visible_fields` 同时控制**可见性 + 顺序**；**必须包含所有要显示的字段**（漏了就隐藏）；主字段会被强制放第一。
- 视图 ID 用 `+view-list` 查（grid 视图即表格视图）。
- **坑**：某字段紧跟特定字段后面会触发 `800070003 no operation produced`（error 为空对象，无 message）。实测「设定性别」紧跟「音色行」后面失败，但放「音色行」前面或末尾就成功。这是飞书 view API 的排序稳定性 bug——报 no-operation 时换一下相邻位置即可，不要怀疑字段本身或反复重试同一顺序。

### 4.6 列宽是 UI-only，API 调不了
飞书多维表格的**列宽、行高、冻结列**都是纯界面属性，OpenAPI/CLI **不支持**设置（能力边界，不要探测未文档化参数或改走 raw API）。用户要调列宽，说明边界并给手动方法：鼠标移到列头右边界**双击**自动适应内容宽度，或手动拖拽。超长文本列（文生图提示词/说明）建议手动拖到固定宽度（300–400px）而非双击自适应，否则整列撑爆、其他列被挤。

## 5. 写记录

### CellValue 规范
| 类型 | 写入值 |
|---|---|
| text | 字符串 |
| number | JSON number |
| select | `["选项名"]`（单选也数组） |
| link | `[{"id":"<record_id>"}]`（**不是**标题） |
| attachment | 不能用普通写记录；用 `+record-upload-attachment` 专用命令 |

### 批量创建
```bash
lark-cli base +record-batch-create --base-token <bt> --table-id <tid> --json @batch.json --as user
```
`batch.json` 形状：
```json
{"create_records":[{"资产名称":"苏穗_日常","音色行":"...","排序":1}, ...]}
```
- 每个元素是 `字段名→CellValue` 映射，只写需要写的字段；单次最多 200 条。
- 返回 `record_id_list`（与输入顺序一致），用于后续 link 关联。

### 多状态父记录（先父后子）
1. 先 batch-create 所有父/单状态记录，拿 `record_id_list`；
2. 建 `名称→record_id` 映射；
3. 再 batch-create 子记录，`父记录` 字段填 `[{"id":"<父record_id>"}]`。

## 6. 短剧资产表建表（5 张表）

模板（参考用户已有 Base）5 张表 + 字段（第一个是主字段）：

| 表 | 字段（顺序） |
|---|---|
| 角色资产 | 资产名称、音色行、自动化(sel)、设定性别、分工(sel)、外观呈现、父记录(link自引用)、呈现性质、审核(sel)、排序(num)、说明、上传音频(att)、特殊标志、颜值定位、文生图提示词、类型、出现集、上传图片(att) |
| 场景资产 | 资产名称、说明、出现集、画幅比例、文生图提示词、分工(sel)、审核(sel)、上传图片(att) |
| 道具资产 | 资产名称、别名、说明、出现集、画幅比例、文生图提示词、审核(sel)、分工(sel)、上传图片(att) |
| 生物资产 | 资产名称、别名、说明、出现集、画幅比例、文生图提示词、音色行、审核(sel)、分工(sel)、上传图片(att) |
| 群像资产 | 资产名称、说明、出现集、画幅比例、文生图提示词、分工(sel)、审核(sel)、上传图片(att) |

select 选项（照模板）：审核=`通过pass/再优化/不通过/垃圾`；分工角色表=`邱国旗/邱睿/熊洋/李欣悦/毛佳佳`，场景/道具/群像加`学员2/学员3`，生物再加`QiuYang-自动化`；自动化=`Qiuyang-自动化`。

**数据源**：`成品/资产/…_视觉资产库_V1.md`（qiutian 资产库标准格式，`### @资产名` 卡片）。字段映射见 `scripts/` 里的解析脚本。脚本流程：`parse.py`（解析资产库→parsed.json）→ `build_data.py`（映射+生成 fields.json/records.json/parent_map.json）→ `write_records.py`（写飞书，先父后子）。

### 视图列顺序约定（用户拍板，重要字段靠前）
字段定义顺序（建表 `--fields` 数组）无所谓，**显示顺序由视图控制**（`+view-set-visible-fields`）。用户约定每张表的列顺序：

1. **资产名称**（主字段，飞书强制锁第一列）
2. **文生图提示词 → 说明 → 上传图片 → 分工 → 审核**（重要字段靠前；分工、审核紧贴上传图片后，对应「出图→上传→分工→审核」协作流）
3. 其余字段靠后（颜值定位、设定性别、音色行、外观呈现、呈现性质、特殊标志、类型、出现集、父记录、排序、上传音频、自动化、别名、画幅比例等按表取用）

写完后用 `+view-get-visible-fields` 回读核对顺序；建库后默认就用这套顺序，不必每部剧重排。

## 7. 参考脚本

- `scripts/parse.py`：解析资产库 V1 md → parsed.json（含文生图提示词/音色行的代码块正则，记得 `re.S|re.M`）
- `scripts/build_data.py`：字段定义 + 记录映射（场景别名并入说明；音色行 None 不写）
- `scripts/write_records.py`：subprocess 调 lark-cli 写记录（父记录先父后子）

## 8. 安全
- 任何 token/device_code/appSecret 一律不写进 memory、项目文件或 skill；device_code 是短时会话码，用完即弃。
- 写/删类命令（field-update/delete、record-batch-create）确认目标后执行；用户要"新增"必须用本轮 create 返回值确认，不能拿已有资源冒充。

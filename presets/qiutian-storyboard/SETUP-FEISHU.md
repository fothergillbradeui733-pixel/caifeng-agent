# 别人怎么接自己的飞书（才丰 / 秋天短剧制作）

飞书上传**不走作者账号**。每个人在自己电脑上登录自己的飞书，资产表建在自己的空间里。

本模式只会：读本地视觉资产库 Markdown → 调本机 `lark-cli` → 写进**当前登录用户**有权限的多维表格。

---

## 0. 你需要准备什么

- 一台能上网的电脑（macOS / Linux / Windows 均可）
- 自己的飞书账号（个人版或企业版都行）
- Node.js 18+（用来装官方 CLI）

作者不会、也不应该把飞书 appSecret / 登录态打包进安装包。

---

## 1. 安装飞书官方 CLI

任选一种：

```bash
# 推荐：单独装
npm i -g @larksuite/cli

# 装完确认
lark-cli --version
```

如果 `lark-cli` 不在 PATH，把安装目录加进 PATH，或用绝对路径调用。

> 作者本机历史路径 `~/.workbuddy/binaries/node/.../lark-cli` **只属于作者电脑**，别人不要抄这条。

---

## 2. 创建自己的飞书应用（只需一次）

1. 打开 [飞书开放平台](https://open.feishu.cn/app)
2. 创建企业自建应用（名字随意，例如「才丰资产上传」）
3. 记下 **App ID**、**App Secret**
4. 权限（开通后发布/创建版本，企业管理员审批一次）：

```text
base:app:create
base:table:create
base:field:create
base:table:update
base:record:create
base:block:read
base:table:read
base:record:read
bitable:app:readonly
search:docs:read
```

5. 安全设置里把重定向 / 设备码登录按 CLI 提示打开（`lark-cli auth login` 会告诉你缺什么）

把 App ID / Secret 配进本机 CLI（Secret 进系统钥匙串，不要写进项目文件）：

```bash
lark-cli config set --app-id "<你的 App ID>"
# appSecret 按 CLI 提示写入 keychain / 凭据库，不要明文提交 git
```

---

## 3. 登录你自己的飞书（每人一次，过期再登）

智能体缺权限时会走设备码。你也可以自己先登：

```bash
# 1) 发起登录，拿到 device_code + verification_url
lark-cli auth login --scope "base:app:create base:table:create base:field:create base:record:create base:table:read base:record:read base:block:read bitable:app:readonly search:docs:read" --no-wait --json

# 2) 生成二维码（必须先 cd 到当前目录，--output 不接受绝对路径）
cd /tmp && lark-cli auth qrcode "<上一步的 verification_url>" --output qr.png

# 3) 用飞书扫码，同意授权

# 4) 回到终端完成登录（最多等约 10 分钟）
lark-cli auth login --device-code "<上一步的 device_code>"

# 5) 确认身份是你自己，不是别人
lark-cli auth status
```

`device_code` 大约 10 分钟过期，不要复用。登录态缓存在本机（macOS：`~/Library/Application Support/lark-cli/`），**不要拷给别人、不要打进安装包**。

---

## 4. 在才丰里怎么用

1. 打开才丰智能Agent，**新开空白会话**
2. 模式选 **秋天短剧制作**
3. 先有一份本地资产库（`…_视觉资产库_V1.md`）
4. 直接说，例如：

```text
把这份资产库上传到飞书，建成角色/场景/道具/生物/群像五张表。
我还没有表格：请新建一个 Base。
```

或把已有表格丢过去：

```text
把资产库写入这个飞书表格：
https://xxx.feishu.cn/base/xxxxxxxxxx
```

智能体会：

- 检查本机 `lark-cli` 是否可用、是否已登录
- 没登录就按上面第 3 步给你 verification_url / 二维码
- 新建或解析你的 Base，按五表模板写记录

**不要**让别人用作者的飞书链接当默认表。每部剧、每个人自己的表。

---

## 5. 自检清单

| 检查 | 命令 / 现象 |
|---|---|
| CLI 在不在 | `lark-cli --version` 有版本号 |
| 登录的是不是你 | `lark-cli auth status` 显示你自己的名字 |
| 权限够不够 | 缺 scope 时重新跑第 3 步，一次申请齐 |
| 表格打得开 | 浏览器能打开该 `/base/` 链接，且当前账号是可编辑成员 |

---

## 6. 常见坑

- **抄作者的 PATH / ou_xxx 用户 ID**：一定会失败。那些是作者本机。
- **把 App Secret 写进 skill 或项目仓库**：禁止。
- **`--json @/绝对路径/file.json`**：CLI 只接受当前目录相对路径，先 `cd`。
- **建表时带自引用 link 字段**：先建表，再补 link（见 skill 正文坑 4.1）。
- **Windows**：钥匙串换成该系统凭据库；二维码步骤同样先 `cd` 再生成。

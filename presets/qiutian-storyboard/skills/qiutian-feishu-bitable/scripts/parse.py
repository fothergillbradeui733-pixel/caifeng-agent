#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""解析 qiutian 资产库 V1 md → parsed.json。
用法：改 SRC 指向「…_视觉资产库_V1.md」，OUT 为输出目录。
"""
import re, json, os

SRC = "/path/to/成品/资产/…_视觉资产库_V1.md"
OUT = "/tmp/dgc_assets"
os.makedirs(OUT, exist_ok=True)

text = open(SRC, encoding="utf-8").read()

# 章节定位（## 二级标题）
sec_pos = {m.group(1).strip(): m.start() for m in re.finditer(r'^## (.+)$', text, re.M)}
def section_of(pos):
    cur = None
    for name, p in sorted(sec_pos.items(), key=lambda x: x[1]):
        if p <= pos: cur = name
        else: break
    return cur

# 切卡（### @资产名）
cards = []
for m in re.finditer(r'^### (@.+)$', text, re.M):
    cards.append((m.group(1).strip(), m.start()))
cards.append(('__END__', len(text)))

def parse_card(body):
    """从卡 body 提取字段字典。"""
    fields = {}
    # 代码块字段：字段名：\n\n```text\n值\n```  （注意 re.S|re.M，否则 ^ 不匹配行首）
    for m in re.finditer(r'^(文生图提示词|音色行)[:：]\s*\n+```text\n(.*?)\n```', body, re.S | re.M):
        fields[m.group(1)] = m.group(2).strip()
    # 单行字段：字段名：值
    for m in re.finditer(r'^(类型|使用状态|替代资产|设定性别|外观呈现|呈现性质|颜值定位|特殊标志|别名|出现集|说明|画幅比例)[:：]\s*(.+)$', body, re.M):
        fields[m.group(1)] = m.group(2).strip()
    return fields

records = {"角色资产": [], "场景资产": [], "道具资产": [], "生物资产": [], "群像资产": []}

for i, (title, pos) in enumerate(cards[:-1]):
    body = text[pos:cards[i+1][1]]
    sec = section_of(pos)
    if sec not in records:
        continue
    f = parse_card(body)
    f['_名称'] = title.lstrip('@')
    f['_原标题'] = title
    records[sec].append(f)

for sec, lst in records.items():
    print(f"{sec}: {len(lst)} 张")

# 校验文生图提示词/音色行齐全
missing = []
for sec, lst in records.items():
    for f in lst:
        if not f.get('文生图提示词'): missing.append(f"{sec}/{f['_名称']} 缺文生图提示词")
        if sec == '角色资产' and not f.get('音色行'): missing.append(f"{sec}/{f['_名称']} 缺音色行")
print("缺失:", missing if missing else "无")

json.dump(records, open(os.path.join(OUT, "parsed.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("已保存", os.path.join(OUT, "parsed.json"))

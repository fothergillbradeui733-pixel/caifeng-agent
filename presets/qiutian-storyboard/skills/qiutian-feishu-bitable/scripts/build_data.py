#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""字段定义 + 记录映射 → fields.json / records.json / parent_map.json。
用法：先跑 parse.py 生成 parsed.json，再跑本脚本。
"""
import json, os

OUT = "/tmp/dgc_assets"
records = json.load(open(os.path.join(OUT, "parsed.json"), encoding="utf-8"))

# ============ select 选项（照模板，含颜色）============
AUDIT_OPTS = [
    {"name": "通过pass", "hue": "Green", "lightness": "Light"},
    {"name": "再优化", "hue": "Yellow", "lightness": "Light"},
    {"name": "不通过", "hue": "Orange", "lightness": "Light"},
    {"name": "垃圾", "hue": "Red", "lightness": "Light"},
]
FEN_GONG_5 = [
    {"name": "邱国旗", "hue": "Blue", "lightness": "Light"},
    {"name": "邱睿", "hue": "Green", "lightness": "Light"},
    {"name": "熊洋", "hue": "Orange", "lightness": "Light"},
    {"name": "李欣悦", "hue": "Purple", "lightness": "Light"},
    {"name": "毛佳佳", "hue": "Turquoise", "lightness": "Light"},
]
FEN_GONG_7 = FEN_GONG_5 + [
    {"name": "学员2", "hue": "Yellow", "lightness": "Light"},
    {"name": "学员3", "hue": "Red", "lightness": "Light"},
]
FEN_GONG_8 = FEN_GONG_7 + [{"name": "QiuYang-自动化", "hue": "Blue", "lightness": "Light"}]

def txt(n): return {"type": "text", "name": n}
def sel(n, o): return {"type": "select", "name": n, "multiple": False, "options": o}
def num(n): return {"type": "number", "name": n, "style": {"type": "plain", "precision": 0, "percentage": False, "thousands_separator": False}}
def att(n): return {"type": "attachment", "name": n}
def link(n, t): return {"type": "link", "name": n, "link_table": t}

# 字段定义（第一个是主字段）
fields = {
    "角色资产": [
        txt("资产名称"), txt("音色行"),
        sel("自动化", [{"name": "Qiuyang-自动化", "hue": "Carmine", "lightness": "Lighter"}]),
        txt("设定性别"), sel("分工", FEN_GONG_5), txt("外观呈现"),
        link("父记录", "角色资产"), txt("呈现性质"), sel("审核", AUDIT_OPTS),
        num("排序"), txt("说明"), att("上传音频"), txt("特殊标志"),
        txt("颜值定位"), txt("文生图提示词"), txt("类型"), txt("出现集"), att("上传图片"),
    ],
    "场景资产": [txt("资产名称"), txt("说明"), txt("出现集"), txt("画幅比例"),
        txt("文生图提示词"), sel("分工", FEN_GONG_7), sel("审核", AUDIT_OPTS), att("上传图片")],
    "道具资产": [txt("资产名称"), txt("别名"), txt("说明"), txt("出现集"), txt("画幅比例"),
        txt("文生图提示词"), sel("审核", AUDIT_OPTS), sel("分工", FEN_GONG_7), att("上传图片")],
    "生物资产": [txt("资产名称"), txt("别名"), txt("说明"), txt("出现集"), txt("画幅比例"),
        txt("文生图提示词"), txt("音色行"), sel("审核", AUDIT_OPTS), sel("分工", FEN_GONG_8), att("上传图片")],
    "群像资产": [txt("资产名称"), txt("说明"), txt("出现集"), txt("画幅比例"),
        txt("文生图提示词"), sel("分工", FEN_GONG_7), sel("审核", AUDIT_OPTS), att("上传图片")],
}

def merge_alias(sec, f):
    """场景表无别名字段，别名并入说明。"""
    if sec == "场景资产":
        a = f.get("别名")
        if a and a not in ("无",) and a != f["_名称"]:
            return (f.get("说明") or "") + f"（别名：{a}）"
    return f.get("说明")

def build_records():
    out = {}
    for sec, lst in records.items():
        rows = []
        for idx, f in enumerate(lst):
            r = {"资产名称": f["_名称"]}
            if sec == "角色资产":
                r.update({"音色行": f.get("音色行"), "设定性别": f.get("设定性别"),
                          "外观呈现": f.get("外观呈现"), "呈现性质": f.get("呈现性质"),
                          "排序": idx + 1, "说明": f.get("说明"), "特殊标志": f.get("特殊标志"),
                          "颜值定位": f.get("颜值定位"), "文生图提示词": f.get("文生图提示词"),
                          "类型": f.get("类型"), "出现集": f.get("出现集")})
            elif sec == "场景资产":
                r.update({"说明": merge_alias(sec, f), "出现集": f.get("出现集"),
                          "画幅比例": "16:9", "文生图提示词": f.get("文生图提示词")})
            elif sec == "道具资产":
                r.update({"别名": f.get("别名"), "说明": f.get("说明"), "出现集": f.get("出现集"),
                          "画幅比例": "16:9", "文生图提示词": f.get("文生图提示词")})
            elif sec == "生物资产":
                r.update({"别名": f.get("别名"), "说明": f.get("说明"), "出现集": f.get("出现集"),
                          "画幅比例": "16:9", "文生图提示词": f.get("文生图提示词"),
                          "音色行": f.get("音色行")})
            elif sec == "群像资产":
                r.update({"说明": f.get("说明"), "出现集": f.get("出现集"),
                          "画幅比例": "16:9", "文生图提示词": f.get("文生图提示词")})
            r = {k: v for k, v in r.items() if v is not None}  # 去掉 None 值
            r["_name"] = f["_名称"]; r["_sec"] = sec
            rows.append(r)
        out[sec] = rows
    return out

record_data = build_records()

# 多状态父记录映射（按实际多状态角色改）
PARENT_MAP = {"角色资产": {
    "苏穗_嫁衣": "苏穗_日常", "苏穗_孕相": "苏穗_日常",
    "林砚舟_婚服": "林砚舟_日常", "周秀兰_硬朗": "周秀兰_病弱",
}}

json.dump(fields, open(os.path.join(OUT, "fields.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)
json.dump(record_data, open(os.path.join(OUT, "records.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)
json.dump(PARENT_MAP, open(os.path.join(OUT, "parent_map.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)

for sec, rows in record_data.items():
    print(f"{sec}: {len(rows)} 条")
print("已生成 fields.json / records.json / parent_map.json")

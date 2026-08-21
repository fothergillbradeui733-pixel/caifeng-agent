#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""写飞书记录：角色资产先父后子（父记录 link），其余表直接批量。
用法：改 BT（base_token）和 TABLES（表名→table_id），先跑 parse.py + build_data.py。
"""
import json, os, subprocess, sys

OUT = "/tmp/dgc_assets"
LARK = os.path.expanduser("~/.workbuddy/binaries/node/cli-connector-packages/bin/lark-cli")
BT = "SpGJbY1mVaOPAzsNaaYcmJZRnGh"  # ← 改成目标 Base token
TABLES = {  # ← 改成目标表 ID（用 +base-block-list 查）
    "角色资产": "tblGVWfoMhGw1XBm",
    "场景资产": "tblsfKecto4fFDLM",
    "道具资产": "tblbBjo39s3arvkD",
    "生物资产": "tbl9jZm7HGCUVL60",
    "群像资产": "tbleOTX5CWvJ2OjP",
}
records = json.load(open(os.path.join(OUT, "records.json"), encoding="utf-8"))
parent_map = json.load(open(os.path.join(OUT, "parent_map.json"), encoding="utf-8"))["角色资产"]

env = dict(os.environ)
env["PATH"] = os.path.dirname(LARK) + ":" + env.get("PATH", "")

def run_lark(args, cwd=OUT):
    r = subprocess.run([LARK] + args, capture_output=True, text=True, env=env, cwd=cwd)
    try:
        return json.loads(r.stdout)
    except Exception:
        return {"_raw": r.stdout, "_err": r.stderr}

def batch_create(table_id, rows):
    payload = {"create_records": rows}
    fp = os.path.join(OUT, "_batch_tmp.json")
    json.dump(payload, open(fp, "w", encoding="utf-8"), ensure_ascii=False)
    d = run_lark(["base", "+record-batch-create", "--base-token", BT, "--table-id", table_id,
                  "--json", "@_batch_tmp.json", "--as", "user"])
    if d.get("ok"):
        return d.get("data", {}).get("record_id_list", [])
    print("ERR:", json.dumps(d.get("error", {}), ensure_ascii=False)[:400])
    return None

def clean_row(r):
    return {k: v for k, v in r.items() if not k.startswith("_")}

# 角色资产：先父后子
role_rows = records["角色资产"]
children = set(parent_map.keys())
parents = [r for r in role_rows if r["_name"] not in children]
child_rows = [r for r in role_rows if r["_name"] in children]

ids = batch_create(TABLES["角色资产"], [clean_row(r) for r in parents])
if ids is None: sys.exit(1)
print(f"父/单状态写入 {len(ids)} 条")

name2id = {parents[i]["_name"]: ids[i] for i in range(len(parents))}

child_payload = []
for r in child_rows:
    row = clean_row(r)
    pid = name2id.get(parent_map[r["_name"]])
    if pid is None:
        print("ERR: 找不到父记录", parent_map[r["_name"]]); sys.exit(1)
    row["父记录"] = [{"id": pid}]
    child_payload.append(row)
ids2 = batch_create(TABLES["角色资产"], child_payload)
if ids2 is None: sys.exit(1)
print(f"子记录写入 {len(ids2)} 条（已带父记录 link）")
print(f"角色资产共 {len(ids)+len(ids2)} 条 ✅")

for sec in ["场景资产", "道具资产", "生物资产", "群像资产"]:
    rows = [clean_row(r) for r in records[sec]]
    ids = batch_create(TABLES[sec], rows)
    if ids is None: sys.exit(1)
    print(f"{sec}: {len(ids)} 条 ✅")

print("\n全部记录写入完成")

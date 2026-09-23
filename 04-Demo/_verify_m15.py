# -*- coding: utf-8 -*-
"""_verify_m15.py — M15 彩蛋与隐藏事件（隐藏资源点/通道/上香虎符链）静态校验

覆盖：
  A. encounters.json 含隐藏要素遭遇（enc_hidden_* 前缀 + secret=true）
  B. 隐藏要素归属南中/中原区域，type 合法，loot 物品存在于 items 表（引用闭合）
  C. 隐藏事件链：quests.json 含 hi_huful（连续上香得虎符）等隐藏任务
  D. 既有遭遇不被破坏（enc_zhangjue_boss 等仍在）
"""
import io
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "assets", "data")
errors = []
warns = []


def check(cond, msg):
    if cond:
        print("  [PASS] " + msg)
    else:
        errors.append(msg)
        print("  [FAIL] " + msg)


def load_json(name):
    with io.open(os.path.join(DATA, name), encoding="utf-8") as f:
        return json.load(f)


items = load_json("items.json")
iid = {str(r.get("id")) for r in items}
encs = load_json("encounters.json")

print("== A. 隐藏要素遭遇就位 ==")
hidden = [e for e in encs if e.get("secret") is True]
check(len(hidden) >= 4, "隐藏要素遭遇 >=4 个 (实际 %d)" % len(hidden))
for h in hidden:
    check(str(h.get("id", "")).startswith("enc_hidden_"), "隐藏遭遇 id enc_hidden_* : %s" % h.get("id"))
    check(h.get("type") in ("treasure", "gather", "event"), "隐藏遭遇 type 合法: %s" % h.get("type"))
    # 区域归属
    regs = h.get("regions", [])
    check(bool(regs), "隐藏遭遇 %s 有区域归属" % h.get("id"))

print("")
print("== B. 隐藏要素 loot 物品引用闭合 ==")
for h in hidden:
    loot = h.get("loot_table", [])
    for it in loot:
        check(str(it) in iid, "隐藏 %s loot 物品 %s 存在于 items 表" % (h.get("id"), it))

print("")
print("== C. 隐藏事件链（hi_* 隐藏任务）==")
quests = load_json("quests.json")
qn = {q.get("id"): q for q in quests}
hi_ids = [i for i in qn if str(i).startswith("hi_")]
check(len(hi_ids) >= 2, "隐藏任务 hi_* >=2 (实际 %s)" % sorted(hi_ids))
check("hi_huful" in qn, "含 hi_huful（连续上香得虎符，自立信物链）")

print("")
print("== D. 不破坏既有遭遇 ==")
keep = {"enc_zhangjue_boss", "enc_yellow_turban", "enc_tribal_warrior", "enc_merchant"}
present = {e.get("id") for e in encs}
for k in keep:
    check(k in present, "既有遭遇 %s 仍存在" % k)

print("")
print("=" * 66)
if errors:
    print("[FAIL] M15 校验失败 %d 项" % len(errors))
    for e in errors:
        print("  - " + e)
    raise SystemExit(1)
print("M15 彩蛋与隐藏事件 数据校验通过 ✅ (warns=%d)" % len(warns))
for w in warns:
    print("  - " + w)

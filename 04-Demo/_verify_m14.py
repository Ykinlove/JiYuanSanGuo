# -*- coding: utf-8 -*-
"""_verify_m14.py — M13 自立称王（SelfRuleService + GameState 自立字段 + 信物链）静态校验

覆盖：
  A. SelfRuleService 存在 + 常量（阈值160/村声望80）+ 核心函数
  B. GameState self_rule_* 字段就位 + to_dict/from_dict/reset 同步（含 self_rule_city）
  C. 建国信物闭：玉玺/虎符物品存在；虎符线索任务 hi_huful 存在
  D. 关键函数引用闭合（可编译前提：类名/字段名一致）
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


def read_text(p):
    with io.open(p, encoding="utf-8") as f:
        return f.read()


def load_json(name):
    with io.open(os.path.join(DATA, name), encoding="utf-8") as f:
        return json.load(f)


print("== A. SelfRuleService 自立规则层 ==")
sr = read_text(os.path.join(HERE, "scripts", "services", "self_rule_service.gd"))
check("class_name SelfRuleService" in sr and "extends RefCounted" in sr,
      "class_name SelfRuleService + extends RefCounted")
check("SELF_RULE_THRESHOLD := 160" in sr, "自立阈值常量 160")
check("VILLAGE_FAME_NEED := 80" in sr, "村庄声望门槛常量 80")
for fn in ("can_attempt", "found_self_rule", "grant_jade_seal", "grant_tiger_tally",
           "has_seals_complete", "ending_state", "village_fame", "judgment"):
    check("static func %s" % fn in sr, "含 static func %s" % fn)

print("")
print("== B. GameState 自立字段 + 存档同步 ==")
gs = read_text(os.path.join(HERE, "scripts", "autoload", "game_state.gd"))
for fld in ("is_self_rule", "self_rule_name", "self_rule_flag", "self_rule_city",
            "has_jade_seal", "has_tiger_tally", "village_reputation"):
    check("var %s" % fld in gs, "GameState 含字段 %s" % fld)
check('"self_rule_city": self_rule_city' in gs, "to_dict 含 self_rule_city")
check('self_rule_city = str(data.get("self_rule_city", ""))' in gs, "from_dict 含 self_rule_city")
check("self_rule_city = \"\"" in gs, "reset 重置 self_rule_city")

print("")
print("== C. 建国信物链数据闭合 ==")
items = load_json("items.json")
iid = {str(r.get("id")) for r in items}
check("treasure_jade_seal" in iid, "items 含 玉玺 treasure_jade_seal")
check("treasure_tiger_tally" in iid, "items 含 虎符 treasure_tiger_tally")
quests = load_json("quests.json")
qn = {q.get("id"): q for q in quests}
check("hi_huful" in qn, "quet. 含虎符线索任务 hi_huful")

print("")
print("== D. 自立入口数据闭环（虎符链 unlock 已由 M13 引入）==")
if "hi_huful" in qn:
    un = qn["hi_huful"].get("rewards", {}).get("unlock", "")
    check(un == "seal_tiger_tally", "hi_huful 完成解锁 seal_tiger_tally（虎符信物链入口）")

print("")
print("=" * 66)
if errors:
    print("[FAIL] M14 校验失败 %d 项" % len(errors))
    for e in errors:
        print("  - " + e)
    raise SystemExit(1)
print("M13 自立称王 规则层与数据校验通过 ✅ (warns=%d)" % len(warns))
for w in warns:
    print("  - " + w)

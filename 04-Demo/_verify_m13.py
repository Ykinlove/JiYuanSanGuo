# -*- coding: utf-8 -*-
"""_verify_m13.py — 主线穿插支线 + 武将专属剧情 数据校验

覆盖：
  A. quests.json 新增支线(br_*)/势力(fa_*)/隐藏(hi_*)/专属(整数2001+)任务就位
  B. 新增任务 quest_type 枚举合法 + objectives type 合法 + chapter/faction 标注
  C. heroes6 历史武将 exclusive_quest_id 关联正确（7 位）
  D. 引用闭合：关联武将 id 在 heroes6 存在；未破坏既有任务（mj_hj/br_前缀不冲突）
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


VALID_QT = ("mainline", "branch", "faction", "hidden", "commission", "life")
VALID_OBJ = ("talk", "battle", "reach", "collect", "fish", "give_gold", "recruit_troop")
HERO_EXCLUSIVE = {167: 2001, 373: 2002, 351: 2003, 294: 2004, 537: 2005, 469: 2006, 268: 2007}

quests = load_json("quests.json")
qn = {q.get("id"): q for q in quests}

print("== A. 支线/势力/隐藏/专属任务就位 ==")
branch_prefix = [i for i in qn if str(i).startswith("br_")]
fa_prefix = [i for i in qn if str(i).startswith("fa_")]
hi_prefix = [i for i in qn if str(i).startswith("hi_")]
excl_ids = [i for i in qn if isinstance(i, int) and i >= 2000]
check(len(branch_prefix) >= 6, "支线任务 br_* >=6 个 (实际 %d: %s)" % (len(branch_prefix), sorted(branch_prefix)))
check(len(fa_prefix) >= 2, "势力任务 fa_* >=2 个 (实际 %d: %s)" % (len(fa_prefix), sorted(fa_prefix)))
check(len(hi_prefix) >= 2, "隐藏任务 hi_* >=2 个 (实际 %d: %s)" % (len(hi_prefix), sorted(hi_prefix)))
check(len(excl_ids) >= 7, "武将专属任务(整数id 2001+) >=7 个 (实际 %d: %s)" % (len(excl_ids), sorted(excl_ids)))

print("")
print("== B. 新增任务结构合法 ==")
new_ids = set(branch_prefix) | set(fa_prefix) | set(hi_prefix) | set(excl_ids)
for i in sorted(new_ids, key=lambda x: str(x)):
    q = qn[i]
    qt = q.get("quest_type", "")
    check(qt in VALID_QT, "  %s quest_type=%s 合法" % (i, qt))
    objs = q.get("objectives", [])
    check(bool(objs), "  %s 含 objectives" % i)
    for o in objs:
        check(o.get("type") in VALID_OBJ, "  %s objective type=%s 合法" % (i, o.get("type")))
# chapter 标注（支线）
for i in branch_prefix:
    q = qn[i]
    ch = q.get("chapter")
    check(ch is not None and 1 <= ch <= 7, "  %s chapter 标注 1-7 (实际 %r)" % (i, ch))

print("")
print("== C. heroes6 武将专属关联 ==")
heroes = load_json("heroes6.json")
hid = {h.get("id"): h for h in heroes}
for h, e in HERO_EXCLUSIVE.items():
    check(h in hid, "  heroes6 含武将 id=%d" % h)
    if h in hid:
        have = hid[h].get("exclusive_quest_id", 0)
        check(have == e, "  武将 id=%d exclusive_quest_id=%d (应为 %d)" % (h, have, e))
        check(e in qn, "  专属任务 id=%d 存在于 quests.json" % e)

print("")
print("== D. 引用闭合与不破坏既有 ==")
for i in ("mj_hj_01", "mj_hj_02", "mj_hj_03", "main_001", "main_002", "side_zhurong", "side_lunyu"):
    check(i in qn, "  既有任务 %s 仍存在" % i)
for i in sorted(excl_ids):
    q = qn[i]
    check("hero_id" in q, "  专属任务 %s 含 hero_id 关联" % i)

print("")
print("=" * 66)
if errors:
    print("[FAIL] M13 校验失败 %d 项" % len(errors))
    for e in errors:
        print("  - " + e)
    raise SystemExit(1)
print("M13 主线穿插支线+武将专属剧情 数据校验通过 ✅ (warns=%d)" % len(warns))
for w in warns:
    print("  - " + w)
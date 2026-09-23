# -*- coding: utf-8 -*-
"""_verify_m9.py — M9 策划文档与数据表标记字段校验

覆盖：
  A. 4 份 M9 策划文档存在 + 章节/小节结构完整
  B. 4 张数据表新字段就位 + 类型合法 + 枚举值合法
  C. 引用闭合：D-02 引用的城池/势力/武将 id 在数据表中存在
  D. 数据表加字段不破坏加载（JSON 仍可解析）
"""
import io
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "assets", "data")
DOC = os.path.normpath(os.path.join(HERE, "..", "02-策划文档"))

errors = []
warns = []


def check(cond, msg):
    if cond:
        print("  [PASS] " + msg)
    else:
        errors.append(msg)
        print("  [FAIL] " + msg)


def warn(msg):
    warns.append(msg)
    print("  [WARN] " + msg)


def read_text(p):
    with io.open(p, encoding="utf-8") as f:
        return f.read()


def load_json(name):
    p = os.path.join(DATA, name)
    with io.open(p, encoding="utf-8") as f:
        return json.load(f), p


print("== A. 4 份策划文档存在与结构 ==")
DOCS = [
    ("D-02-主线剧情剧本骨架.md", ["一、总览", "二、第一章", "十、三线结局汇总", "十三、版本与待确认"]),
    ("D-04-地图与关卡设计.md", ["一、总览", "二、区域详细布局", "三、关隘", "六、关卡设计原则"]),
    ("D-08-势力逻辑与外交设计.md", ["一、三成长路径", "二、势力 AI", "三、外交 7 手段", "六、待确认"]),
    ("D-09-自立与投靠机制设计.md", ["一、声望系统", "二、建国信物", "三、立业流程", "五、结局分支"]),
]
for name, sections in DOCS:
    p = os.path.join(DOC, name)
    check(os.path.exists(p), "文档存在: %s" % name)
    if not os.path.exists(p):
        continue
    txt = read_text(p)
    for sec in sections:
        check(sec in txt, "  %s 含章节: %s" % (name, sec))
    # 行数下限
    lines = txt.count("\n") + 1
    check(lines >= 80, "  %s 行数 ≥80 (实际 %d)" % (name, lines))

print("")
print("== B. 4 张数据表新字段就位 + 类型合法 ==")

# B1. cities.json mainline_chapter
cities, _ = load_json("cities.json")
check(len(cities) == 110, "cities.json 110 城 (实际 %d)" % len(cities))
chs = set()
for c in cities:
    check("mainline_chapter" in c, "  %s 有 mainline_chapter" % c.get("id"))
    if "mainline_chapter" in c:
        v = c["mainline_chapter"]
        check(isinstance(v, int) and 1 <= v <= 7,
              "  %s mainline_chapter 合法 1-7 (实际 %r)" % (c.get("id"), v))
        chs.add(v)
check(chs == {1, 2, 3, 4, 5, 6, 7} or chs >= {1, 5, 6},
      "  mainline_chapter 覆盖主要章节 (实际 %s)" % sorted(chs))

# B2. heroes6.json story_role + exclusive_quest_id
heroes, _ = load_json("heroes6.json")
check(len(heroes) == 825, "heroes6.json 825 武将 (实际 %d)" % len(heroes))
role_cnt = {"主角": 0, "历史主角": 0, "普通": 0, "专属剧情": 0}
protagonist_ids = set()
for h in heroes:
    check("story_role" in h, "  hero id=%s 有 story_role" % h.get("id"))
    if "story_role" in h:
        v = h["story_role"]
        check(v in role_cnt, "  hero id=%s story_role 枚举合法 (实际 %r)" % (h.get("id"), v))
        role_cnt[v] = role_cnt.get(v, 0) + 1
        if v == "主角":
            protagonist_ids.add(h.get("id"))
    check("exclusive_quest_id" in h, "  hero id=%s 有 exclusive_quest_id" % h.get("id"))
    if "exclusive_quest_id" in h:
        v = h["exclusive_quest_id"]
        check(isinstance(v, int) and v >= 0,
              "  hero id=%s exclusive_quest_id ≥0 整数 (实际 %r)" % (h.get("id"), v))
check({1, 517, 324, 337} == protagonist_ids,
      "  主角 id = {1, 517, 324, 337} (实际 %s)" % sorted(protagonist_ids))
print("  story_role 分布: %s" % role_cnt)

# B3. factions6.json storyline_tag + faction_line
factions, _ = load_json("factions6.json")
check(len(factions) == 46, "factions6.json 46 势力 (实际 %d)" % len(factions))
tag_cnt = {}
line_cnt = {}
for f in factions:
    check("storyline_tag" in f, "  faction id=%s 有 storyline_tag" % f.get("id"))
    if "storyline_tag" in f:
        v = f["storyline_tag"]
        check(v in ("主线", "支线"),
              "  faction id=%s storyline_tag 枚举合法 (实际 %r)" % (f.get("id"), v))
        tag_cnt[v] = tag_cnt.get(v, 0) + 1
    check("faction_line" in f, "  faction id=%s 有 faction_line" % f.get("id"))
    if "faction_line" in f:
        v = f["faction_line"]
        check(v in ("魏线", "蜀线", "吴线", "群雄线", "自立线"),
              "  faction id=%s faction_line 枚举合法 (实际 %r)" % (f.get("id"), v))
        line_cnt[v] = line_cnt.get(v, 0) + 1
check(line_cnt.get("魏线", 0) == 1 and line_cnt.get("蜀线", 0) == 1 and line_cnt.get("吴线", 0) == 1,
      "  魏蜀吴各 1 势力 (实际 %s)" % line_cnt)
print("  storyline_tag 分布: %s" % tag_cnt)
print("  faction_line 分布: %s" % line_cnt)

# B4. quests6.json quest_type
quests, _ = load_json("quests6.json")
check(len(quests) == 45, "quests6.json 45 任务 (实际 %d)" % len(quests))
type_cnt = {}
for q in quests:
    check("quest_type" in q, "  quest id=%s 有 quest_type" % q.get("id"))
    if "quest_type" in q:
        v = q["quest_type"]
        check(v in ("mainline", "branch", "faction", "hidden", "commission", "life"),
              "  quest id=%s quest_type 枚举合法 (实际 %r)" % (q.get("id"), v))
        type_cnt[v] = type_cnt.get(v, 0) + 1
check(type_cnt.get("commission", 0) > 0 and type_cnt.get("life", 0) > 0,
      "  commission + life 均非空 (实际 %s)" % type_cnt)
print("  quest_type 分布: %s" % type_cnt)

print("")
print("== C. D-02 引用闭合校验 ==")
d2 = read_text(os.path.join(DOC, "D-02-主线剧情剧本骨架.md"))

# C1. 城池引用 → cities.json
scene_refs = set(re.findall(r"\bscene_(\d+)\b", d2))
city_ids = {c["id"] for c in cities}
# scene_N 中 N 应能在 cities.json 找到（以 "scene_N" 形式）
missing_cities = []
for n in scene_refs:
    cid = "scene_%s" % n
    if cid not in city_ids:
        missing_cities.append(cid)
check(len(missing_cities) == 0,
      "  D-02 引用 %d 个 scene_N，全部存在于 cities.json (缺失 %d: %s)" % (
          len(scene_refs), len(missing_cities), missing_cities[:5]))

# C2. 势力引用 → factions6.json（从 §12.2 清单提取）
m = re.search(r"### 12\.2 势力 id.*?(?=## |$)", d2, re.S)
if m:
    fac_block = m.group(0)
    fac_refs = set(int(x) for x in re.findall(r"\b(\d+)\b", fac_block))
    # 去掉小节号 12.2 中的数字
    fac_refs -= {12, 2}
    fac_ids = {f["id"] for f in factions}
    missing_factions = [fid for fid in fac_refs if fid not in fac_ids]
    check(len(missing_factions) == 0,
          "  D-02 §12.2 引用 %d 个势力 id，全部存在于 factions6.json (缺失 %d: %s)" % (
              len(fac_refs), len(missing_factions), missing_factions[:5]))
else:
    check(False, "  D-02 §12.2 势力清单小节存在")

# C3. 武将引用 → heroes6.json（从 §12.3 清单提取）
m = re.search(r"### 12\.3 武将 id.*?(?=## |$)", d2, re.S)
if m:
    hero_block = m.group(0)
    hero_refs = set(int(x) for x in re.findall(r"\b(\d+)\b", hero_block))
    hero_refs -= {12, 3}  # 去掉小节号
    hero_ids = {h["id"] for h in heroes}
    missing_heroes = [hid for hid in hero_refs if hid not in hero_ids]
    check(len(missing_heroes) == 0,
          "  D-02 §12.3 引用 %d 个武将 id，全部存在于 heroes6.json (缺失 %d: %s)" % (
              len(hero_refs), len(missing_heroes), missing_heroes[:5]))
else:
    check(False, "  D-02 §12.3 武将清单小节存在")

print("")
print("== D. 数据表 JSON 可解析性 ==")
for name in ("cities.json", "heroes6.json", "factions6.json", "quests6.json"):
    try:
        load_json(name)
        check(True, "%s JSON 可解析" % name)
    except Exception as e:
        check(False, "%s JSON 解析失败: %s" % (name, e))

print("")
print("=" * 66)
if errors:
    print("[FAIL] M9 校验失败 %d 项" % len(errors))
    for e in errors:
        print("  - " + e)
    raise SystemExit(1)
print("M9 校验通过 ✅ (warns=%d)" % len(warns))
for w in warns:
    print("  - " + w)

# -*- coding: utf-8 -*-
"""_verify_m12.py — M12 势力线+投靠势力流程实装静态校验

覆盖：
  A. FactionService / DiplomacyService / AIService 存在 + class_name + 核心函数
  B. GameState 新增字段（feudal_cities / diplomacy / ai_state）存档同步 + advance_month 接 AI
  C. factions6 可投靠势力（刘备15/曹操16/孙策5，蜀线/魏线/吴线）
  D. D-08 专属兵种表有数据（service 内置 SPECIAL_TROOPS 含特色兵种）
  E. world_map 外交入口接入（diplo → 打开 DiplomacyPanel）
  F. 引用闭合（刘517/曹324/孙337 in heroes6；曹操16/刘备15/孙策5 in factions6）
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


print("== A. 三个 Service 服务层 ==")
fs = read_text(os.path.join(HERE, "scripts", "services", "faction_service.gd"))
ds = read_text(os.path.join(HERE, "scripts", "services", "diplomacy_service.gd"))
ais = read_text(os.path.join(HERE, "scripts", "services", "ai_service.gd"))
for name, text in (("faction_service", fs), ("diplomacy_service", ds), ("ai_service", ais)):
    cls = {"faction_service": "FactionService",
           "diplomacy_service": "DiplomacyService",
           "ai_service": "AIService"}[name]
    check("class_name %s" % cls in text, "%s class_name" % cls)
    check("extends RefCounted" in text, "%s extends RefCounted" % cls)

# FactionService 核心
for fn in ("available_affiliations", "join", "official_rank_name",
           "rank_requirements", "can_promote", "promote",
           "add_merit", "get_feudal_city", "special_troops", "resign"):
    check(("static func %s" % fn) in fs, "FactionService.%s" % fn)
# 官阶名
for rn in ("平民", "兵长", "校尉", "将军", "太守"):
    check(rn in fs, "FactionService 官阶名含「%s」" % rn)

# DiplomacyService 核心 + 7 手段
for fn in ("relation_status", "relational_status_name", "get_relation", "modify",
           "alliance", "trade", "war", "marriage", "alienate", "rumor", "sabotage",
           "monthly_relations"):
    check(("static func %s" % fn) in ds, "DiplomacyService.%s" % fn)
# AI 核心
for fn in ("monthly_tick", "recruit_probability", "war_probability", "alliance_probability"):
    check(("static func %s" % fn) in ais, "AIService.%s" % fn)

print("")
print("== B. GameState 新字段 + 存档同步 + AI 挂钩 ==")
gs = read_text(os.path.join(HERE, "scripts", "autoload", "game_state.gd"))
for field in ("feudal_cities", "diplomacy", "ai_state"):
    check("var %s" % field in gs, "GameState.%s 字段" % field)
    check('"%s": %s' % (field, field) in gs, "%s to_dict 序列化" % field)
    check('%s = data.get("%s"' % (field, field) in gs
          or '%s = _restore_int_keys(data.get("%s"' % (field, field) in gs,
          "%s from_dict 反序列化" % field)
    check('%s = []' % field in gs or '%s = {}' % field in gs, "%s reset 重置" % field)
# 既有投靠字段仍在
for fld in ("affiliation", "official_rank", "merit"):
    check("var %s" % fld in gs, "GameState.%s（既有）存在" % fld)
check("AIService.monthly_tick()" in gs, "advance_month 调用 AIService.monthly_tick")

print("")
print("== C. factions6 可投靠势力 ==")
factions = load_json("factions6.json")
by_id = {int(f.get("id", 0)): f for f in factions}
liu = by_id.get(15)
cao = by_id.get(16)
sun = by_id.get(5)
check(liu is not None and str(liu.get("faction_line", "")) == "蜀线", "factions6 刘备(15) 蜀线")
check(cao is not None and str(cao.get("faction_line", "")) == "魏线", "factions6 曹操(16) 魏线")
check(sun is not None and str(sun.get("faction_line", "")) == "吴线", "factions6 孙策(5) 吴线")
for ln in ("蜀线", "魏线", "吴线"):
    check(ln in fs, "FactionService 含可投靠线「%s」" % ln)

print("")
print("== D. D-08 专属兵种表有数据 ==")
for troop in ("青州兵", "虎豹骑", "龙枪兵", "连弩兵", "龙骑兵", "江东水军", "解烦兵"):
    check(troop in fs, "专属兵种表含「%s」" % troop)

print("")
print("== E. world_map 外交入口接入 ==")
wm = read_text(os.path.join(HERE, "scripts", "world", "world_map.gd"))
check("_diplomacy.open()" in wm, "world_map diplo → 打开外交面板")
check("DiplomacyPanel.new()" in wm, "world_map 实例化 DiplomacyPanel")
check('show_toast("外交（待实装）")' not in wm, "旧「外交（待实装）」占位已移除")

print("")
print("== F. 引用闭合 ==")
heroes = load_json("heroes6.json")
hid = {int(h.get("id", 0)) for h in heroes}
check(517 in hid, "heroes6 含 刘备 lord(刘) id=517")
check(324 in hid, "heroes6 含 曹操 id=324")
check(337 in hid, "heroes6 含 孙策 id=337")
check(int(by_id[15].get("lord_role_id", 0)) == 517, "factions6 刘备 lord_role_id=517")
check(int(by_id[16].get("lord_role_id", 0)) == 324, "factions6 曹操 lord_role_id=324")
check(int(by_id[5].get("lord_role_id", 0)) == 337, "factions6 孙策 lord_role_id=337")

print("")
print("=" * 66)
if errors:
    print("[FAIL] M12 校验失败 %d 项" % len(errors))
    for e in errors:
        print("  - " + e)
    raise SystemExit(1)
print("M12 势力线+投靠势力流程实装校验通过 ✅ (warns=%d)" % len(warns))
for w in warns:
    print("  - " + w)

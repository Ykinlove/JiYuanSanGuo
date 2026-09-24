# -*- coding: utf-8 -*-
"""_verify_m7.py — M7 内容扩充静态校验

覆盖：
  M7-A 村落委托：QuestService 事件接线（talk/battle/reach/collect/fish/give_gold/recruit_troop）、
                story_flags 存档、对话/大地图/战场/遭遇管理器接线、任务与对话/物品引用闭环
  M7-B 随机事件：WorldEventService + EventPopup + event 路由，4 个事件定义的 cost/effects 引用合法
  M7-C 铁匠强化：enhance 配置边界、EnhanceService、强化等级存档、属性生效点、铁匠铺 UI 接线
  M7-D 个人技单挑：duel 配置、DuelService、DuelPopup、个人技白名单/存档、战前决断接线、boss 引用
  通用：临时探针已清理、新规则层结构合规（extends RefCounted + class_name）
"""
import io
import json
import os
import re
import glob

HERE = os.path.dirname(os.path.abspath(__file__))


def read(p):
    return io.open(os.path.join(HERE, p), encoding="utf-8").read()


def read_json(p):
    return json.loads(read(p))


errors = []


def check(cond, msg):
    if cond:
        print("  [PASS] " + msg)
    else:
        errors.append(msg)
        print("  [FAIL] " + msg)


quests = read_json("assets/data/quests.json")
if isinstance(quests, dict):
    quests = quests.get("root", quests)
encs = read_json("assets/data/encounters.json")
items = read_json("assets/data/items.json")
items6 = read_json("assets/data/items6.json")
units = read_json("assets/data/units.json")
heroes6 = read_json("assets/data/heroes6.json")
talents6 = read_json("assets/data/talents6.json")
dialogues = read_json("assets/data/dialogues.json")
cities = read_json("assets/data/cities.json")
shop = read_json("assets/data/shop_goods.json")
combat = read_json("assets/data/combat.json")

item_ids = {str(r["id"]) for r in items}
unit_ids = {str(r["id"]) for r in units}
hero_ids = {str(r["id"]) for r in heroes6}
talent_ids = {int(r["id"]) for r in talents6}
enc_ids = {str(r["id"]) for r in encs}

qsvc = read("scripts/services/quest_service.gd")
wsvc = read("scripts/services/world_event_service.gd")
esvc = read("scripts/services/enhance_service.gd")
dsvc = read("scripts/services/duel_service.gd")
ssvc = read("scripts/services/skill_service.gd")
csvc = read("scripts/services/character_service.gd")
gs = read("scripts/autoload/game_state.gd")
dlg = read("scripts/ui/dialogue_ui.gd")
wm = read("scripts/world/world_map.gd")
em = read("scripts/world/encounter_manager.gd")
bs = read("scripts/battle/battle_scene.gd")
city = read("scripts/city/city_scene.gd")
epop = read("scripts/ui/event_popup.gd")
dpop = read("scripts/ui/duel_popup.gd")

# ================= 1. M7-A 委托引擎 =================
print("=" * 66)
print("[1] M7-A 村落委托：规则层与事件接线")
print("=" * 66)
for kw in ["class_name QuestService", "extends RefCounted",
           "static func accept", "static func record_event",
           "static func objective_progress", "static func turn_in",
           "func _canon"]:
    check(kw in qsvc, "QuestService 含 %s" % kw)
for ev in ["talk", "battle", "reach", "collect", "fish", "give_gold", "recruit_troop"]:
    check(('"%s"' % ev) in qsvc, "record_event 支持事件类型 %s" % ev)

for kw in ["var story_flags", '"story_flags": story_flags',
           "story_flags = data.get(", "story_flags = []"]:
    check(kw in gs, "GameState story_flags：%s" % kw)

check('var talker_id' in dlg and 'QuestService.record_event("talk"' in dlg,
      "对话 UI 注入 talker 并记 talk")
check('QuestService.accept(' in dlg, "对话 accept_quest 动作走 QuestService.accept")
check('record_event("give_gold"' in dlg, "give_gold 对话动作记给钱事件")
check('record_event("reach"' in wm and "talker_id" in wm,
      "大地图：进城记 reach / 对话注入 talker_id")
check('record_event("battle"' in bs and "quest_target" in bs,
      "战场胜利按 quest_target 记 battle")
check('record_event("collect"' in em and 'quest_event' in em
      and 'record_event(qev' in em,
      "遭遇管理器：采集记账 + quest_event 特殊事件（fish）")

# 任务目标类型都受支持
supported = {"talk", "battle", "reach", "collect", "fish", "give_gold", "recruit_troop"}
qids = set()
for q in quests:
    qid = str(q["id"])
    qids.add(qid)
    for o in q.get("objectives", []):
        t = str(o.get("type", ""))
        check(t in supported, "任务 %s 目标类型 %s 受支持" % (qid, t))
        if t in ("collect",):
            tid = str(o.get("target", ""))
            check(tid in item_ids, "任务 %s 收集物 %s 存在于 items 表" % (qid, tid))
    # 随机材料奖励在 material 分类内（由服务层随机，不做引用校验）

# 对话里的 accept_quest 都指向已有任务
accepted = set(re.findall(r'accept_quest:([A-Za-z0-9_]+)', read("assets/data/dialogues.json")))
check(len(accepted) > 0, "对话中存在 accept_quest 动作（%d 个任务）" % len(accepted))
for qid in accepted:
    check(qid in qids, "对话接取的任务 %s 在 quests.json 中" % qid)

# 关键遭遇/城市字段
bandit = next((e for e in encs if e["id"] == "enc_bandit"), {})
tribal = next((e for e in encs if e["id"] == "enc_tribal_warrior"), {})
check(str(bandit.get("quest_target")) == "bandit", "enc_bandit.quest_target=bandit")
check(str(tribal.get("type")) == "battle" and str(tribal.get("boss_hero_id", "")) != "",
      "enc_tribal_warrior 为带首领的战斗遭遇（boss_hero_id）")
fishing = next((e for e in encs if e.get("quest_event") == "fish"), None)
check(fishing is not None and str(fishing.get("gather_item")) == "material_fish",
      "钓鱼遭遇 enc_fishing 指向 material_fish")
check("material_fish" in item_ids, "items.json 含 material_fish")
jianning = next((c for c in cities if c.get("id") == "scene_40"), {})
check(str(jianning.get("visit_target")) == "city_jianning", "建宁 scene_40.visit_target=city_jianning")

# ================= 2. M7-B 随机事件 =================
print("=" * 66)
print("[2] M7-B 大地图随机事件：规则/弹窗/路由/数据")
print("=" * 66)
for kw in ["class_name WorldEventService", "static func can_pick",
           "static func resolve", "static func find_option"]:
    check(kw in wsvc, "WorldEventService 含 %s" % kw)
check("class_name EventPopup" in epop, "EventPopup 类存在")
check('"event"' in em and "_handle_event" in em, "遭遇管理器含 event 分支")
check('type == "event"' in wm and "_event_popup.open" in wm, "大地图路由 event → EventPopup")

event_encs = [e for e in encs if e.get("type") == "event"]
check(len(event_encs) >= 4, "至少 4 个随机事件（实际 %d）" % len(event_encs))
effect_keys = {"gold", "food", "wood", "iron", "fame", "infamy", "exp"}
for e in event_encs:
    eid = e["id"]
    opts = e.get("options", [])
    check(len(opts) >= 2, "事件 %s 至少 2 个选项" % eid)
    for o in opts:
        for c in o.get("cost", {}).keys():
            check(c in effect_keys, "事件 %s 选项 %s cost 字段 %s 合法" % (eid, o.get("id"), c))
        # effects 形态：{标量字段: n} 或 {"unit_add": {uid: n}} / {"item_add": {iid: n}}
        for kind, val in o.get("effects", {}).items():
            if kind in effect_keys:
                ok = isinstance(val, (int, float))
            elif kind in ("item_add", "unit_add"):
                ref_set = item_ids if kind == "item_add" else unit_ids
                ok = isinstance(val, dict) and all(str(k) in ref_set for k in val.keys())
            else:
                ok = False
            check(ok, "事件 %s 效果 %s 字段与引用合法" % (eid, kind))

# ================= 3. M7-C 铁匠铺强化 =================
print("=" * 66)
print("[3] M7-C 铁匠铺强化：配置/规则/生效/UI")
print("=" * 66)
enh = shop.get("enhance", {})
for kw in ["max_level", "stat_per_level", "gold_base", "gold_growth",
           "iron_costs", "success_rates", "fail_drops_level"]:
    check(kw in enh, "enhance 配置含 %s" % kw)
ml = int(enh.get("max_level", 0))
check(ml >= 1 and ml <= 10, "max_level 合理（%d）" % ml)
check(len(enh.get("iron_costs", [])) == ml, "iron_costs 长度 == max_level")
check(len(enh.get("success_rates", [])) == ml, "success_rates 长度 == max_level")
check(all(0.05 <= float(x) <= 0.35 for x in [enh.get("stat_per_level")]),
      "stat_per_level 在 5%%~35%%（%s）" % enh.get("stat_per_level"))
check(all(0.1 <= float(r) <= 1.0 for r in enh.get("success_rates", [])),
      "成功率全部在 10%%~100%%")
check(all(int(c) > 0 for c in enh.get("iron_costs", [])), "各级铁耗为正")
check(float(enh.get("gold_growth", 1)) >= 1.0, "金价成长 ≥ 1")

for kw in ["class_name EnhanceService", "static func terms",
           "static func can_enhance", "static func enhance",
           "static func level_of"]:
    check(kw in esvc, "EnhanceService 含 %s" % kw)
check("DataManager.get_record(\"shop_goods\", \"root\").get(\"enhance\"" in esvc,
      "强化成本读 shop_goods.json（数值 JSON 驱动）")

for kw in ["var equip_levels", '"equip_levels": equip_levels',
           "equip_levels = data.get(", "equip_levels = {}"]:
    check(kw in gs, "GameState equip_levels：%s" % kw)

check("enhance_lv: int = 0" in csvc, "item_combat_bonus 支持强化等级参数")
check("EnhanceService.stat_per_level()" in csvc, "属性增量取规则层")
check("with_levels: bool = false" in csvc, "equipment_bonuses 可选计入强化")
check("EnhanceService.level_of(wid)" in csvc, "主角武器攻击含强化等级")
check("_build_smith_enhance" in city and "EnhanceService.enhance" in city
      and "EnhanceService.terms" in city, "铁匠铺面板接强化区（成本/裁决走服务层）")
# UI 层不写强化公式
check("stat_per_level" not in city and "gold_growth" not in city,
      "UI 层不含强化数值公式")

# ================= 4. M7-D 个人技与单挑 =================
print("=" * 66)
print("[4] M7-D 个人技与单挑：配置/规则/弹窗/接线")
print("=" * 66)
duel = combat.get("duel", {})
for kw in ["max_rounds", "hp", "base_damage", "force_weight", "damage_variance",
           "counter_mult", "clash_mult", "win_enemy_count_scale", "win_start_rage",
           "lose_player_hp_scale", "win_fame", "enemy_bias"]:
    check(kw in duel, "duel 配置含 %s" % kw)
check(0.5 <= float(duel.get("win_enemy_count_scale", 0)) < 1.0,
      "胜利敌军缩编比例在 50%%~100%%（%s）" % duel.get("win_enemy_count_scale"))
check(0.3 <= float(duel.get("lose_player_hp_scale", 0)) < 1.0,
      "失败主角血量比例在 30%%~100%%")
for m in ["attack", "guard", "feint"]:
    check(m in duel.get("enemy_bias", {}), "敌方出招偏置含 %s" % m)

for kw in ["class_name DuelService", "MOVE_ATTACK", "MOVE_GUARD", "MOVE_FEINT",
           "static func start", "static func play_round",
           "static func champions", "static func enemy_of_encounter",
           "static func battle_effects"]:
    check(kw in dsvc, "DuelService 含 %s" % kw)
check("class_name DuelPopup" in dpop and "duel_finished" in dpop,
      "DuelPopup 类与结束信号存在")
check("DuelService.play_round" in dpop and "DuelService.start" in dpop,
      "单挑弹窗回合裁决全部走 DuelService")

for sid in [1, 2, 3, 4, 5, 6]:
    check(sid in talent_ids, "talents6 含个人技 id=%d" % sid)
for kw in ["PERSONAL_SKILLS", "static func personal_meta",
           "static func available_personal_skills",
           "static func hero_personal_skills"]:
    check(kw in ssvc, "SkillService 含 %s" % kw)
check("PERSONAL_COOLDOWN" in ssvc and "PERSONAL_POWER" in ssvc,
      "个人技冷却/效果数值集中在规则层")
for kw in ["var personal_skill: int = 1", '"personal_skill": personal_skill',
           "personal_skill = int(data.get(", "personal_skill = 1"]:
    check(kw in gs, "GameState personal_skill：%s" % kw)

for kw in ["_open_prepare()", "_begin_battle()", "DuelPopup.create()",
           "_on_duel_finished", "_build_talent_button", "_on_talent",
           "SkillService.personal_meta", "DuelService.battle_effects",
           "_apply_contact_damage"]:
    check(kw in bs, "battle_scene 接线：%s" % kw)
# 敌军必须在战前决断之后才布置（单挑缩兵才有效）
setup_pos = bs.find("func _setup_battle")
prepare_pos = bs.find("_open_prepare()", setup_pos)
deploy_pos = bs.find("_director.deploy_enemies", setup_pos)
check(setup_pos < prepare_pos and deploy_pos > prepare_pos,
      "deploy_enemies 在战前弹层之后执行")

# 带 boss 的遭遇其 boss 必须能在 heroes6 解析
boss_encs = [e for e in encs if str(e.get("boss_hero_id", "")) != ""]
check(len(boss_encs) >= 2, "至少 2 个带 boss 的遭遇（实际 %d）" % len(boss_encs))
for e in boss_encs:
    check(str(e["boss_hero_id"]) in hero_ids,
          "遭遇 %s 的 boss_hero_id=%s 在 heroes6 中" % (e["id"], e["boss_hero_id"]))

# ================= 5. 规则层结构与工程卫生 =================
print("=" * 66)
print("[5] 规则层结构与工程卫生")
print("=" * 66)
for f in [qsvc, wsvc, esvc, dsvc]:
    head = f[:400]
    check("extends RefCounted" in head and "class_name" in head,
          "规则层 %s 结构合规（RefCounted + class_name）"
          % re.search(r"class_name\s+(\w+)", head).group(1))

leftover = sorted(glob.glob(os.path.join(HERE, "_probe*")))
check(not leftover, "临时探针文件已清理（残留：%s）" % [os.path.basename(x) for x in leftover])
stray_out = [os.path.basename(x) for x in glob.glob(os.path.join(HERE, "_*out*.txt"))
             if os.path.basename(x) != "_all_out.txt"]
check(not stray_out, "临时输出文件已清理（%s）" % stray_out)

# ================= 汇总 =================
print("=" * 66)
if errors:
    print("[FAIL] M7 校验 %d 项失败：" % len(errors))
    for m in errors:
        print("  - " + m)
    raise SystemExit(1)
print("[OK] M7 全部校验通过 ✅")

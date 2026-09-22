# -*- coding: utf-8 -*-
"""_verify_m6.py — M6 手感打磨：中循环断点接线 + 战斗奖励规则 + 数值边界

镜像 BattleRewardService 常量，验证：
  1. combat.json battle_rewards 参数完备且有序
  2. 战斗结算走规则层（经验正确升级、击溃半额、材料入包、武将经验）
  3. 中循环断点：采集/宝箱入背包、商队开交易、采集点防连发与次日恢复
  4. 遭遇表引用的物品全部存在（材料/采集/宝箱）
  5. 起始资源一致性（gold=1500 三处）
  6. 数值边界：初期建军可承受、首场胜利有正收益、首将可在 ~10 场内招募
"""
import io
import json
import os
import re

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


combat = read_json("assets/data/combat.json")
br = combat["battle_rewards"]
encs = read_json("assets/data/encounters.json")
items = {str(r["id"]) for r in read_json("assets/data/items.json")}
barracks = read_json("assets/data/barracks.json")
recruit = read_json("assets/data/recruit_pool.json")
gs = read("scripts/autoload/game_state.gd")
bs = read("scripts/battle/battle_scene.gd")
em = read("scripts/world/encounter_manager.gd")
wm = read("scripts/world/world_map.gd")
svc = read("scripts/services/battle_reward_service.gd")

# ================= 1. battle_rewards 参数 =================
print("=" * 66)
print("[1] combat.json battle_rewards 参数")
print("=" * 66)
for k in ["exp_range", "gold_range", "exp_per_kill", "gold_per_kill",
          "exp_per_rout", "gold_per_rout", "hero_exp_share", "default_fame"]:
    check(k in br, "存在字段 %s" % k)
check(br["exp_range"][0] <= br["exp_range"][1], "经验区间有序")
check(br["gold_range"][0] <= br["gold_range"][1], "金钱区间有序")
check(br["gold_per_kill"] > br["gold_per_rout"] > 0, "歼灭缴获 > 击溃缴获 > 0（金）")
check(br["exp_per_kill"] > br["exp_per_rout"] > 0, "歼灭经验 > 击溃经验 > 0")
check(0.0 < br["hero_exp_share"] <= 1.0, "hero_exp_share 在 (0,1]，实际 %s" % br["hero_exp_share"])

# ================= 2. 规则层与结算接线 =================
print()
print("=" * 66)
print("[2] 战斗奖励规则层与 battle_scene 接线")
print("=" * 66)
check("class_name BattleRewardService" in svc, "BattleRewardService 已定义")
check(re.search(r"static func roll\(", svc) is not None, "roll() 纯计算")
check(re.search(r"static func apply\(", svc) is not None, "apply() 落账")
check("add_player_exp" in svc, "规则层走 add_player_exp（主角能升级）")
check("add_hero_exp" in svc, "规则层给统兵武将发经验")
check("add_fame" in svc and 'add_item' in svc, "规则层发名声与材料")
check('routs' in svc and "per_rout" in svc.lower() or "PER_ROUT" in svc,
      "击溃（routs）计入半额奖励")

check("BattleRewardService.apply(" in bs, "battle_scene 调用 BattleRewardService.apply")
check("GameState.player_exp +=" not in bs, "结算不再绕过 add_player_exp 直接加经验")
# 结算代码块中不再硬编码 randi_range 奖励
victory_block = bs.split("if win:")[1].split("else:")[0] if "if win:" in bs else ""
check("randi_range" not in victory_block, "胜利结算无硬编码随机奖励（数据驱动）")
check('int(summary["kills"])' in victory_block and 'int(summary["routs"])' in victory_block,
      "结算传入 kills 与 routs")

# ================= 3. 中循环断点 =================
print()
print("=" * 66)
print("[3] 中循环断点：采集/宝箱/商队")
print("=" * 66)
# 采集
gather_seg = em.split("func _handle_gather")[1].split("func _handle_treasure")[0]
check("GameState.add_item(" in gather_seg, "采集物入背包 GameState.add_item")
check("_triggered_ids[enc_id] = true" in gather_seg, "采集触发后防本帧连发")
# 宝箱
trea_seg = em.split("func _handle_treasure")[1].split("func _handle_merchant")[0]
check("GameState.add_item(" in trea_seg, "宝箱掉落入背包")
# 次日恢复采集
check('"gather"' in em and "_triggered_ids.erase(enc_id)" in em, "采集点次日恢复可交互")
# 商队
check("待实装" not in em.split("func _handle_merchant")[1].split("func _hide")[0],
      "商队不再提示待实装")
check('type == "merchant"' in wm and "_trade.open(" in wm, "world_map 商队遭遇打开交易面板")

# ================= 4. 物品引用完整性 =================
print()
print("=" * 66)
print("[4] 遭遇/掉落/采集物品引用完整性")
print("=" * 66)
referenced = set()
for e in encs:
    mats = e.get("rewards", {}).get("materials", [])
    referenced.update(str(m) for m in mats)
    if "gather_item" in e:
        referenced.add(str(e["gather_item"]))
    referenced.update(str(x) for x in e.get("loot_table", []))
missing = sorted(i for i in referenced if i not in items)
check(not missing, "全部被引用物品存在于 items.json（缺：%s）" % missing)
for mid in ["material_herb", "material_beast_hide"]:
    check(mid in items, "新增材料 %s 已入表" % mid)

# ================= 5. 起始资源一致性 =================
print()
print("=" * 66)
print("[5] 起始资源与 reset 一致性")
print("=" * 66)
check(gs.count("gold = 1500") >= 1 and 'data.get("gold", 1500)' in gs
      and "var gold: int = 1500" in gs, "起始金 1500（声明/reset/读档默认三处一致）")
check("current_encounter = {}" in gs, "reset() 清空 current_encounter")

# ================= 6. 数值边界（镜像规则复算） =================
print()
print("=" * 66)
print("[6] 经济与奖励数值边界（Python 镜像复算）")
print("=" * 66)

battle_encs = [e for e in encs if e.get("type") == "battle"]
exp_def = br["exp_range"]
gold_def = br["gold_range"]


def roll_bounds(e, kills, routs):
    rew = e.get("rewards", {})
    er = rew.get("exp", exp_def)
    gr = rew.get("gold", gold_def)
    emin = er[0] + kills * br["exp_per_kill"] + routs * br["exp_per_rout"]
    emax = er[1] + kills * br["exp_per_kill"] + routs * br["exp_per_rout"]
    gmin = gr[0] + kills * br["gold_per_kill"] + routs * br["gold_per_rout"]
    gmax = gr[1] + kills * br["gold_per_kill"] + routs * br["gold_per_rout"]
    return emin, emax, gmin, gmax


# 6.1 每场胜利都有正收益（kills/routs 至少其一，最坏取基础区间下限）
for e in battle_encs:
    emin, emax, gmin, gmax = roll_bounds(e, 1, 0)
    check(emin > 0 and gmin >= 0, "%s 歼 1 队：经验 %d~%d 金 %d~%d" % (
        e["name"], emin, emax, gmin, gmax))
# 6.2 纯击溃胜利也有收益（黄巾类溃而不歼的情形）
for e in battle_encs:
    emin, emax, gmin, gmax = roll_bounds(e, 0, 1)
    check(emin > 0 and gmin > 0, "%s 仅击溃 1 队仍有收益（exp≥%d gold≥%d）" % (
        e["name"], emin, gmin))

# 6.3 初期建军：200 刀盾成本 ≤ 起始资源
inf = next(u for u in barracks["units"] if u["unit_id"] == "infantry")
cost_g = inf["gold_per_10"] * 20
cost_f = inf["food_per_10"] * 20
check(cost_g <= 1500 and cost_f <= 2000,
      "初期 200 刀盾成本 金%d/粮%d ≤ 起始 1500/2000" % (cost_g, cost_f))
# 6.4 建军后余钱 + 10 场山贼最坏/平均收入足以招最便宜将
settings = recruit["settings"]
prices = sorted(
    settings["base_gold"] + int(e["difficulty"]) * settings["gold_per_difficulty"]
    + int(e.get("gold_extra", 0)) for e in recruit["pool"])
cheapest = prices[0]
bandit = next(e for e in encs if e["id"] == "enc_bandit")
_, _, gmin, gmax = roll_bounds(bandit, 1, 0)
_, _, rmin, rmax = roll_bounds(bandit, 0, 1)
worst10 = (1500 - cost_g) + 10 * gmin
mean10 = (1500 - cost_g) + 10 * (gmin + gmax) // 2
check(worst10 >= cheapest,
      "建军后打 10 场山贼（最坏掉落 %d/场）可招最便宜将 %d（余 %d）" % (
          gmin, cheapest, worst10))
check((1500 - cost_g) + 6 * (gmin + gmax) // 2 >= cheapest,
      "平均约 6 场山贼可招首将（剩余 %d ≥ %d）" % (
          (1500 - cost_g) + 6 * (gmin + gmax) // 2, cheapest))
# 6.5 最便宜将价格带合理（≤2000，避免新手墙）
check(cheapest <= 2000, "首将价格 %d ≤ 2000（新手可预期）" % cheapest)

# 6.6 月度义兵与月耗：200 兵、民心 60，5 个月粮草不枯竭（起始粮 2000 - 建军粮耗）
food_after = 2000 - cost_f
troops = 200
spent = 0
militia_per = 60 * barracks["settings"]["monthly_militia_morale_factor"]
for _ in range(5):
    spent += int(troops / 100.0 * 30.0)
    troops += militia_per
check(food_after - spent > 0,
      "200 兵+月义兵 5 个月累计耗粮 %d ≤ 余粮 %d（不枯竭）" % (spent, food_after))

# ================= 汇总 =================
print()
print("=" * 66)
if errors:
    print("发现 %d 个问题：" % len(errors))
    for e in errors:
        print("  - " + e)
    print("=" * 66)
    raise SystemExit(1)
print("M6 中循环与数值边界校验全部通过 ✅")
print("=" * 66)

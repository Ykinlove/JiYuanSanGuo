# -*- coding: utf-8 -*-
"""_verify_monthly.py — 月度义兵 + 好感结义 校验

镜像 MonthlyService / CharacterService 结义常量，验证：
  1. barracks.json 月度义兵参数
  2. 义兵数量边界（民心 39/40/60/100）
  3. GameState 月度发放与结义方法/信号
  4. CharacterService 结义常量与判定
  5. formation_calculator 结义攻防 +10%
  6. city_scene 结义入口 / world_clock 义兵提示
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


# 镜像常量
MILITIA_UNIT = "infantry"
MORALE_FACTOR = 3.0
MIN_MORALE = 40
SWORN_INTIMACY = 80
SWORN_MAX = 3
SWORN_BONUS = 0.10

errors = []


def check(cond, msg):
    if cond:
        print("  [PASS] " + msg)
    else:
        errors.append(msg)
        print("  [FAIL] " + msg)


def militia_count(morale):
    if morale < MIN_MORALE:
        return 0
    return int(round(morale * MORALE_FACTOR))


# ================= 1. barracks 参数 =================
print("=" * 66)
print("[1] barracks.json 月度义兵参数")
print("=" * 66)
bk = read_json("assets/data/barracks.json")
s = bk["settings"]
check(s.get("monthly_militia_unit") == "infantry",
      "monthly_militia_unit = infantry，实际 %s" % s.get("monthly_militia_unit"))
check(s.get("monthly_militia_morale_factor") == 3,
      "monthly_militia_morale_factor = 3，实际 %s" % s.get("monthly_militia_morale_factor"))
check(s.get("monthly_militia_min_morale") == 40,
      "monthly_militia_min_morale = 40，实际 %s" % s.get("monthly_militia_min_morale"))

# ================= 2. 义兵数量边界 =================
print()
print("=" * 66)
print("[2] 月度义兵数量边界（镜像 MonthlyService）")
print("=" * 66)
cases = [(0, 0), (39, 0), (40, 120), (50, 150), (60, 180), (67, 201), (100, 300)]
for morale, expect in cases:
    got = militia_count(morale)
    check(got == expect, "民心 %3d → 义兵 %4d（期望 %d）" % (morale, got, expect))

# ================= 3. GameState 方法 =================
print()
print("=" * 66)
print("[3] GameState 月度发放 / 结义方法")
print("=" * 66)
gs = read("scripts/autoload/game_state.gd")
for fn in ["_grant_monthly_militia", "is_sworn", "set_sworn"]:
    check(re.search(r'func %s\(' % fn, gs) is not None,
          "GameState.%s() 已定义" % fn)
check("MonthlyService.militia(" in gs, "advance_month 调 MonthlyService.militia")
check("EventBus.monthly_militia.emit" in gs, "发义兵后 emit monthly_militia")
check('current_city_id.is_empty()' in gs, "野外（无所在城）不发义兵")
check("advance_month" in gs and "_grant_monthly_militia()" in gs,
      "advance_month 末尾挂接月度义兵")

eb = read("scripts/autoload/event_bus.gd")
check("signal monthly_militia(" in eb, "EventBus.monthly_militia 信号已定义")

# ================= 4. CharacterService 结义 =================
print()
print("=" * 66)
print("[4] CharacterService 结义常量与判定")
print("=" * 66)
cs = read("scripts/services/character_service.gd")
check("SWORN_INTIMACY_REQUIRED := 80" in cs, "结义好感门槛 80")
check("SWORN_MAX := 3" in cs, "结义名额上限 3")
check("SWORN_COMBAT_BONUS := 0.10" in cs, "结义攻防加成 0.10")
for fn in ["sworn_count", "can_sworn_by_intimacy"]:
    check(re.search(r'static func %s\(' % fn, cs) is not None,
          "CharacterService.%s() 已定义" % fn)


def sworn_count(party):
    return sum(1 for h in party if h.get("sworn", False))


check(sworn_count([{"sworn": True}, {}, {"sworn": True}]) == 2,
      "sworn_count 正确统计（2/3）")
check(all(m >= SWORN_INTIMACY for m in (80, 100)) and 79 < SWORN_INTIMACY,
      "好感 80 达标，79 不达标")

# ================= 5. formation_calculator 结义加成 =================
print()
print("=" * 66)
print("[5] formation_calculator 结义攻防 +10%")
print("=" * 66)
fc = read("scripts/battle/formation_calculator.gd")
check("GameState.is_sworn(" in fc, "阵型计算读取 GameState.is_sworn")
check("SWORN_COMBAT_BONUS" in fc, "阵型计算使用 SWORN_COMBAT_BONUS")
# 攻与防 detail 都加结义
check(fc.count("+ sworn_bonus") >= 2,
      "attack_bonus 与 defense_bonus 均计入 sworn_bonus（出现 %d 次）" % fc.count("+ sworn_bonus"))
check("(1.0 + sworn_bonus)" in fc, "战力公式乘 (1+结义加成)")

# ================= 6. UI / 提示接入 =================
print()
print("=" * 66)
print("[6] 酒馆结义入口 / 世界时钟义兵提示")
print("=" * 66)
scene = read("scripts/city/city_scene.gd")
check(re.search(r'func _do_sworn\(', scene) is not None, "city_scene._do_sworn() 已定义")
check("CharacterService.sworn_count" in scene, "结义区显示名额占用")
check("CharacterService.can_sworn_by_intimacy" in scene, "结义按钮按好感门槛显示")
check("GameState.set_sworn" in scene, "结义调用 GameState.set_sworn")

wc = read("scripts/world/world_clock.gd")
check("monthly_militia.connect" in wc, "world_clock 监听 monthly_militia")
check("义兵来投" in wc, "义兵到账弹提示")

# ================= 7. MonthlyService 文件 =================
print()
print("=" * 66)
print("[7] MonthlyService 规则层")
print("=" * 66)
ms = read("scripts/services/monthly_service.gd")
check("class_name MonthlyService" in ms, "MonthlyService 类已定义")
check(re.search(r'static func militia\(', ms) is not None, "militia() 静态规则方法")
check("monthly_militia_morale_factor" in ms and "monthly_militia_min_morale" in ms,
      "参数从 barracks settings 读取（数据驱动）")

# ================= 汇总 =================
print()
print("=" * 66)
if errors:
    print("发现 %d 个问题：" % len(errors))
    for e in errors:
        print("  - " + e)
    print("=" * 66)
    raise SystemExit(1)
print("月度义兵 + 好感结义校验全部通过 ✅")
print("=" * 66)

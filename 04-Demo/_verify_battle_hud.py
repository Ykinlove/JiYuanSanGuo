# -*- coding: utf-8 -*-
"""
_verify_battle_hud.py — 战斗 HUD 平滑 / 连斩 / 按钮冷却 的接线静态复核
（2026-09-30 第二轮战斗优化：用户反馈「战斗页面太生硬死板」）

运行时探针（probe_runner 第 ⑨ 组）能验参数与算法，但**验不了接线**：
"血条到底有没有走平滑通道""连斩到底有没有被触发""残影条有没有被画在血条下面"
这些只有读源码才看得出来。本脚本补上这一层，防止后人改回直接写 value。

检查项：
  W1 血条不再被直接写死：_update_bars 只记目标值
  W2 _tick_bars/_tick_buttons/_tick_combo 都挂进了 _process
  W3 残影条画在血条下层（move_child 到 _hp_bar 之前）
  W4 残影条掉血时慢收、回血时立刻跟上（不能领先血条）
  W5 残血警示只在 <阈值 且 FIGHTING 时才可见
  W6 连斩在普攻命中后累加，且有中断清零
  W7 动作按钮冷却遮罩已接线（普攻/闪避）
  W8 数值不在场景层内联：平滑/警示/连斩参数一律走 CombatFeelService
  W9 combat.json 新增键齐全且区间自洽
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = HERE
SRC = os.path.join(ROOT, "scripts", "battle", "battle_scene.gd")
SERVICE = os.path.join(ROOT, "scripts", "services", "combat_feel_service.gd")
CFG_PATH = os.path.join(ROOT, "assets", "data", "combat.json")

results = []


def check(name, ok, detail):
    results.append((name, ok, detail))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def func_body(src, sig):
    """截取某个 func 的函数体（到下一个顶层 func / 顶层注释块为止）"""
    i = src.find(sig)
    if i < 0:
        return ""
    j = src.find("\nfunc ", i + 1)
    if j < 0:
        j = len(src)
    return src[i:j]


print("=" * 68)
print("战斗 HUD 平滑 / 连斩 / 按钮冷却 · 接线静态复核")
print("=" * 68)

src = read(SRC)
svc = read(SERVICE)
cfg = json.load(open(CFG_PATH, "r", encoding="utf-8"))
feel = cfg.get("feel", {})

# ---------- W1 血条不再被直接写死 ----------
print("\n[W1] 血条走平滑通道（只记目标值）")
ub = func_body(src, "func _update_bars()")
check("_update_bars 存在", bool(ub), "%d 字符" % len(ub))
direct = re.findall(r"_(?:hp|morale|rage|enemy_hp)_bar\.value\s*=", ub)
check("_update_bars 不直接写控件 value", not direct,
      "命中 %d 处：%s" % (len(direct), direct if direct else "无"))
for k in ("_target_hp", "_target_morale", "_target_rage", "_target_enemy"):
    check("_update_bars 记账 %s" % k, bool(re.search(re.escape(k) + r"\s*=", ub)), "已赋值")

rh = func_body(src, "func _refresh_hud()")
check("_refresh_hud 不再直写敌方血条", "_enemy_hp_bar.value =" not in rh,
      "改为记 _enemy_hp，由 _tick_bars 逼近")

# ---------- W2 每帧驱动挂进 _process ----------
print("\n[W2] 每帧驱动已挂进 _process")
proc = func_body(src, "func _process(delta")
for fn in ("_tick_bars", "_tick_buttons", "_tick_combo"):
    check("%s 在 _process 中调用" % fn, bool(re.search(re.escape(fn) + r"\(delta\)", proc)),
          "已接线")

# ---------- W3 残影条层级 ----------
print("\n[W3] 残影条画在血条下层")
bh = func_body(src, "func _build_hud_extras()")
check("_build_hud_extras 在 _ready 中调用", "_build_hud_extras()" in func_body(src, "func _ready()"),
      "已调用")
check("残影条与血条同位置（40/40 → 440/74）",
      all(x in bh for x in ("offset_left = 40.0", "offset_top = 40.0",
                            "offset_right = 440.0", "offset_bottom = 74.0")),
      "矩形一致")
check("残影条被排到血条之前（画在下层）",
      "move_child(_hp_ghost_bar, _hp_bar.get_index())" in bh,
      "move_child 到 _hp_bar 的索引位")
check("残影条不吞点击", "MOUSE_FILTER_IGNORE" in bh, "鼠标过滤已设")

# ---------- W4 残影条行为 ----------
print("\n[W4] 残影条：掉血慢收、回血立刻跟上")
gh = func_body(src, "func _tick_hp_ghost(delta")
check("掉血进入停留计时", "_ghost_hold += delta" in gh, "先停后收")
check("停留时长取自配置", "CombatFeelService.ghost_hold()" in gh, "不内联数值")
check("回血时残影立刻跟上（不会领先血条）",
      bool(re.search(r"_hp_ghost_bar\.value\s*=\s*_hp_bar\.value", gh)), "else 分支直接对齐")

# ---------- W5 残血警示 ----------
print("\n[W5] 残血警示")
lw = func_body(src, "func _tick_low_hp_warning(delta")
check("阈值取自配置", "CombatFeelService.low_hp_ratio()" in lw, "不内联 0.3")
check("仅在 FIGHTING 阶段可见", "_phase == Phase.FIGHTING" in lw, "结算/准备阶段不闪")
check("频率与透明度都取自配置",
      "CombatFeelService.low_hp_hz_min()" in lw and "CombatFeelService.low_hp_alpha_max()" in lw,
      "区间插值")

# ---------- W6 连斩 ----------
print("\n[W6] 连斩")
bump = func_body(src, "func _bump_combo()")
tick_c = func_body(src, "func _tick_combo(delta")
atk = func_body(src, "func _on_attack()")
check("_bump_combo 在普攻命中后调用", "_bump_combo()" in atk, "命中分支之后")
# 挥空分支在 _bump_combo 之前 return，才不会把空砍也算进连斩
i_ret = atk.find("show_toast(\"距离过远")
i_bump = atk.find("_bump_combo()")
check("挥空不计连斩（return 早于 _bump_combo）", i_ret >= 0 and i_ret < i_bump,
      "return 在第 %d 字符、bump 在第 %d 字符" % (i_ret, i_bump))
check("低于 combo_min 不显示", "CombatFeelService.combo_min()" in bump, "至少 2 连")
check("超窗口清零", "CombatFeelService.combo_window()" in tick_c, "中断即归零")
check("战斗结束收掉连斩", "_combo = 0" in func_body(src, "func _on_battle_finished"),
      "不会残留到结算面板")

# ---------- W7 按钮冷却遮罩 ----------
print("\n[W7] 动作按钮冷却遮罩")
btns = func_body(src, "func _tick_buttons(delta")
check("普攻遮罩已接线", "_apply_cd_veil(_btn_attack, _attack_cooldown, ATTACK_COOLDOWN)" in btns,
      "剩余比例 → 遮罩高度")
check("闪避遮罩已接线", "_apply_cd_veil(_btn_dodge, _dodge_cooldown, DODGE_COOLDOWN)" in btns,
      "同上")
check("大招按怒气灰化/发光", "RAGE_SKILL_COST" in btns and "_btn_skill.modulate" in btns,
      "怒气不足压暗、够了呼吸")
check("冷却总时长提为常量（不再散落字面量）",
      "const ATTACK_COOLDOWN" in src and "const RAGE_SKILL_COST" in src,
      "ATTACK_COOLDOWN / RAGE_SKILL_COST")

# ---------- W8 数值不内联在场景层 ----------
print("\n[W8] 数值一律走规则层")
tb = func_body(src, "func _tick_bars(delta")
calls = re.findall(r"CombatFeelService\.approach\([^)]*\)", tb, re.S)
check("_tick_bars 四条全部经 CombatFeelService.approach", len(calls) == 4,
      "命中 %d 条" % len(calls))
# 每个 approach 的速率参数必须是 CombatFeelService.bar_smooth(...)
rates = re.findall(r"CombatFeelService\.approach\((?:[^()]|\([^()]*\))*\)", tb, re.S)
ok_rate = all("CombatFeelService.bar_smooth(" in c for c in rates)
check("逼近速率全部来自配置（无裸数字）", ok_rate and len(rates) == 4,
      "4 条速率参数均为 bar_smooth()")
for fn in ("bar_smooth", "ghost_hold", "ghost_catchup", "low_hp_ratio",
           "low_hp_hz_min", "low_hp_hz_max", "low_hp_alpha_min",
           "low_hp_alpha_max", "combo_window", "combo_min", "combo_font",
           "combo_pop_scale", "approach"):
    check("CombatFeelService 暴露 %s()" % fn,
          bool(re.search(r"static func %s\(" % fn, svc)), "已定义")

# ---------- W9 配置键完整且区间自洽 ----------
print("\n[W9] combat.json feel 段新增键")
need = ["bar_smooth_hp", "bar_smooth_morale", "bar_smooth_rage", "bar_smooth_enemy",
        "ghost_hold", "ghost_catchup", "low_hp_ratio", "low_hp_hz_min", "low_hp_hz_max",
        "low_hp_alpha_min", "low_hp_alpha_max", "combo_window", "combo_min",
        "combo_font", "combo_pop_scale"]
missing = [k for k in need if k not in feel]
check("新增键齐全（%d 项）" % len(need), not missing, "缺失：%s" % (missing or "无"))
check("逼近速率均为正", all(float(feel.get(k, 0)) > 0 for k in need if k.startswith("bar_smooth")),
      "hp/morale/rage/enemy 均 > 0")
check("残血阈值在 (0,1)", 0.0 < float(feel.get("low_hp_ratio", 0)) < 1.0,
      "%.2f" % float(feel.get("low_hp_ratio", 0)))
check("频率区间自洽", float(feel.get("low_hp_hz_min", 9)) <= float(feel.get("low_hp_hz_max", 0)),
      "%.1f ~ %.1f Hz" % (float(feel.get("low_hp_hz_min", 0)), float(feel.get("low_hp_hz_max", 0))))
check("透明度区间自洽且足够淡",
      float(feel.get("low_hp_alpha_min", 9)) <= float(feel.get("low_hp_alpha_max", 0)) <= 0.35,
      "%.2f ~ %.2f" % (float(feel.get("low_hp_alpha_min", 0)), float(feel.get("low_hp_alpha_max", 0))))
check("连斩窗口为正、门槛 ≥ 2",
      float(feel.get("combo_window", 0)) > 0 and int(feel.get("combo_min", 0)) >= 2,
      "%.1f s / %d 连" % (float(feel.get("combo_window", 0)), int(feel.get("combo_min", 0))))

# ---------- 汇总 ----------
print("\n" + "=" * 68)
passed = sum(1 for _, ok, _ in results if ok)
print("复核结果：%d / %d 通过" % (passed, len(results)))
if passed < len(results):
    print("失败项：")
    for n, ok, d in results:
        if not ok:
            print("  - " + n + " :: " + d)
    sys.exit(1)
print("全部通过 ✅")
print("=" * 68)

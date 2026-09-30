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
  W10 转场：开场黑幕 / 开战横幅 / 结算慢镜
  W11 血条数值文本（绝对值 + 敌军队数 + 跟真实血量）
  W12 布局重排几何：左簇右缘对齐 524 / 士气怒气底行对齐 / 敌血条镜像 / 战况文字下移
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = HERE
SRC = os.path.join(ROOT, "scripts", "battle", "battle_scene.gd")
TSCN = os.path.join(ROOT, "scenes", "battle", "battle_scene.tscn")
SERVICE = os.path.join(ROOT, "scripts", "services", "combat_feel_service.gd")
CFG_PATH = os.path.join(ROOT, "assets", "data", "combat.json")

results = []


def check(name, ok, detail):
    results.append((name, ok, detail))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def tscn_rect(path, name):
    """从 tscn 里抠出某个 Control 节点的 offset_*（绝对布局坐标）"""
    txt = read(path)
    i = txt.find('[node name="%s"' % name)
    if i < 0:
        return {}
    j = txt.find("\n[node ", i + 1)
    if j < 0:
        j = len(txt)
    block = txt[i:j]
    out = {}
    for m in re.finditer(r"^(offset_\w+)\s*=\s*(-?[\d.]+)", block, re.M):
        out[m.group(1)] = float(m.group(2))
    return out


def code_rect(src, prefix):
    """从脚本里抠出 `prefix.offset_x = 12.0` 形式的矩形赋值"""
    out = {}
    for k in ("left", "top", "right", "bottom"):
        m = re.search(re.escape(prefix) + r"\.offset_%s\s*=\s*(-?[\d.]+)" % k, src)
        if m:
            out["offset_" + k] = float(m.group(1))
    return out


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
ghost_rect = code_rect(src, "_hp_ghost_bar")
hp_rect = tscn_rect(TSCN, "HPBar")
check("残影条矩形与 tscn 的 HPBar 完全相等（%s）" % ghost_rect,
      bool(ghost_rect) and ghost_rect == hp_rect,
      "代码 %s vs tscn %s" % (ghost_rect, hp_rect))
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

# ---------- W10 转场（开场黑幕 / 开战横幅 / 结算慢镜） ----------
print("\n[W10] 战斗转场")
ready = func_body(src, "func _ready()")
check("黑幕在 _ready 里构建", "_build_curtain()" in func_body(src, "func _build_hud_extras()"),
      "已调用")
check("黑幕在战场摆完后才拉开",
      ready.find("await _setup_battle()") < ready.find("_fade_from_black()"),
      "先 await 布置战场，再淡出")
check("黑幕不吞点击", "MOUSE_FILTER_IGNORE" in func_body(src, "func _build_curtain()"),
      "鼠标过滤已设")

ban = func_body(src, "func _banner(")
check("开战横幅在 _begin_battle 中调用",
      "_banner(" in func_body(src, "func _begin_battle()"), "已接线")
check("横幅以自身中心为缩放原点（否则会往右下抽）", "pivot_offset" in ban, "已设")
check("横幅用完自行回收", "queue_free" in ban, "淡出后 queue_free")
check("横幅不吞点击", "MOUSE_FILTER_IGNORE" in ban, "鼠标过滤已设")

fin = func_body(src, "func _play_finish_transition()")
obf = func_body(src, "func _on_battle_finished(win")
check("结算转场在战斗结束时调用", "_play_finish_transition()" in obf, "已接线")
check("慢镜前先清顿帧（否则被 _tick_hitstop 拉回 1）", "_hitstop_end_ms = 0" in fin,
      "顿帧与慢镜不打架")
check("慢镜会还原 time_scale", 'tween_property(Engine, "time_scale", 1.0' in fin,
      "0.35 → 1.0")
check("渐暗层压在 UI 最底层（不盖结算面板）", "move_child(veil, 0)" in fin, "index 0")
check("渐暗层不吞点击", "MOUSE_FILTER_IGNORE" in fin, "鼠标过滤已设")
check("结算面板改为慢镜一拍后再弹",
      src.count("_show_result_after_beat()") >= 3 and "_pop_result_panel()" in
      func_body(src, "func _show_result_after_beat()"),
      "主流程 + 演武场两条路径都走延迟弹出")
check("延迟计时不受慢镜影响", "ignore_time_scale" in src or "true, false, true" in src,
      "create_timer(..., true, false, true)")

# ---------- W11 血条数值文本 ----------
print("\n[W11] 血条数值文本")
bt = func_body(src, "func _build_bar_texts()")
check("血条关掉自带百分比", "_hp_bar.show_percentage = false" in bt, "改显绝对值")
check("敌血条关掉自带百分比", "_enemy_hp_bar.show_percentage = false" in bt, "同上")
check("数值文本每帧刷新", "_tick_bar_texts()" in func_body(src, "func _tick_bars(delta"),
      "挂进 _tick_bars")
tt = func_body(src, "func _tick_bar_texts()")
check("数值跟随真实血量而非动画值", "_player_hp" in tt and "_hp_bar.value" not in tt,
      "用 _player_hp，不用平滑后的控件值")
check("敌军队数已记账", "_enemy_alive_n" in func_body(src, "func _refresh_hud()"),
      "alive / total 同步记录")
check("数值文本不吞点击", "MOUSE_FILTER_IGNORE" in func_body(src, "func _make_bar_text("),
      "鼠标过滤已设")

# ---------- W12 布局重排（左上角状态条理顺、右簇镜像、战况文字下移） ----------
print("\n[W12] HUD 布局重排几何")
hp_r = tscn_rect(TSCN, "HPBar")
mo_r = tscn_rect(TSCN, "MoraleBar")
ra_r = tscn_rect(TSCN, "RageBar")
en_r = tscn_rect(TSCN, "EnemyHPBar")
si_r = tscn_rect(TSCN, "SituationLabel")
# 左簇：血条占满整行（44→524）；下方士气(左半 44→280)+怒气(右半 300→524)
# 并排，二者合起来也收口到 524。即：HP 右缘=524、怒气右缘=524、士气左缘=HP左缘。
check("左簇收口到右缘 524（HP 满宽、怒气右缘接上）",
      hp_r.get("offset_left") == 44.0 and hp_r.get("offset_right") == 524.0
      and mo_r.get("offset_left") == 44.0 and ra_r.get("offset_right") == 524.0,
      "HP %s→%s / Morale 左=%s / Rage 右=%s" % (
      hp_r.get("offset_left"), hp_r.get("offset_right"),
      mo_r.get("offset_left"), ra_r.get("offset_right")))
# 士气 / 怒气并排、底行对齐（top 同、bottom 同，二者合宽对齐到 524）
check("士气与怒气底行对齐（top/bottom 一致）",
      mo_r.get("offset_top") == ra_r.get("offset_top")
      and mo_r.get("offset_bottom") == ra_r.get("offset_bottom"),
      "Morale top=%s bottom=%s / Rage top=%s bottom=%s" % (
      mo_r.get("offset_top"), mo_r.get("offset_bottom"),
      ra_r.get("offset_top"), ra_r.get("offset_bottom")))
# 敌方血条是左簇的水平镜像（左缘 -524、右缘 -44，与 HP 的 44/524 镜像）
check("敌方血条为左簇镜像（左缘 -524 / 右缘 -44）",
      en_r.get("offset_left") == -524.0 and en_r.get("offset_right") == -44.0,
      "Enemy %s / %s" % (en_r.get("offset_left"), en_r.get("offset_right")))
# 战况文字下移到 140 行，与状态条错行自成一排（不再挤在前排）
check("战况文字下移（top=140，不与状态条重叠）",
      si_r.get("offset_top") == 140.0, "SituationLabel top=%s" % si_r.get("offset_top"))

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

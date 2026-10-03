# -*- coding: utf-8 -*-
"""战斗动作差异化演出（第二十三轮）· 接线静态复核

锁定「角色移动去僵 + 普攻/大招/个人技三类各有独立视觉签名」，
防止后人改回「贴地硬滑 / 放技能都一样」：

  A1 战斗移动平滑：_drive_player 用 move_toward 平滑速度（非瞬时常量速度）
  A2 立绘行走增强：WalkAnim 新增 bob_double / weave_amp，战斗与大地图立绘分支均调成 2.0 + weave
  B1 普攻：_on_attack 落月牙斩(_spawn_slash) 且走 KIND_LIGHT（轻）
  B2 大招：_on_skill 炸冲击波(_spawn_shockwave) + 全屏金闪 + KIND_ULTIMATE（最重）
  B3 个人技 damage：着色月牙斩 + 前冲；aoe 再叠着色冲击波
  B4 个人技 shield：_cast_shield_vfx（青色护盾环，明确"防御"）
  B5 个人技 heal：_cast_heal_vfx（绿色升腾光 + 回血飘字，明确"回血"）
  C1 VFX 助手齐备：_spawn_slash/_spawn_shockwave/_spawn_ring/_cast_shield_vfx/
                     _cast_heal_vfx/_flash_tinted/_pop_float/_skill_tint/_slash_polygon/_ring_polygon
  C2 前摇：_play_swing 含 windup 蓄力（朝反方向小幅拉弓）
  D1 feel 段新键 + CombatFeelService 暴露齐全
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = HERE
BS = os.path.join(ROOT, "scripts", "battle", "battle_scene.gd")
WA = os.path.join(ROOT, "scripts", "world", "walk_anim.gd")
PC = os.path.join(ROOT, "scripts", "world", "player_controller.gd")
SVC = os.path.join(ROOT, "scripts", "services", "combat_feel_service.gd")
CFG = os.path.join(ROOT, "assets", "data", "combat.json")

results = []


def check(name, ok, detail):
    results.append((name, ok, detail))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def func_body(src, name):
    """提取函数体：先按括号配平吃掉完整签名（**可跨行**），再按缩进定界取体。

    【参数两种历史形态都要支持】（本轮统一时踩过：只认裸名会让 9 个
     用「完整签名片段」调用的校验器集体返回 None → 假红）
      · 裸名：      "_process"
      · 带 func 前缀："func add_legs("
      · 带参数字面： "func _process(delta"
    统一规约为：去掉 "func " 前缀 → 取首个 "(" 之前的部分 → 即函数名。

    【血泪·五次踩坑的最终形态，勿再简化】
      1) 只按 {}/} 配对 → 遇 `var x: Dictionary = {}` 立刻 depth 归零 → 体被截成几十字符
      2) 加字符串跳过后被单引号 'Hint' 搞乱状态
      3) 正则只写 ^func → 匹配不到 `static func` → 判据集体假红
      4) 按「第一个换行」当签名结束 → 截到的是签名续行（缩进更深）→ 真体缩进更小 → 立即 break
      5) **基线缩进取错行**：拿「签名后第一行代码」当基线，而该行通常是 `if`（1 tab），
         体里同级的 `if`/`var`（也是 1 tab）会被判成「函数结束」→ 体被截断 → 判据假红。
         正解：基线 = **函数签名行自身的缩进**（顶层函数恒为 0）。
    """
    fname = name.strip()
    if fname.startswith("func "):
        fname = fname[5:]
    fname = fname.split("(")[0].strip()
    if not fname:
        return None
    m = re.search(r"^(?:static\s+)?func\s+%s\s*\(" % re.escape(fname), src, re.M)
    if not m:
        return None
    i = src.find("(", m.start())
    depth = 0
    j = i
    while j < len(src):
        if src[j] == "(":
            depth += 1
        elif src[j] == ")":
            depth -= 1
            if depth == 0:
                break
        j += 1
    sig_line_start = src.rfind("\n", 0, m.start()) + 1
    head = src[sig_line_start:m.start()]
    baseline = len(head) - len(head.lstrip("\t"))
    k = src.find("\n", j)
    lines = src[k + 1:].split("\n")
    out = []
    for ln in lines:
        s = ln.strip()
        if s == "":
            out.append(ln)
            continue
        ind = len(ln) - len(ln.lstrip("\t"))
        if ind <= baseline:
            break
        out.append(ln)
    return "\n".join(out)

print("=" * 68)
print("战斗动作差异化演出 · 接线静态复核")
print("=" * 68)

bs = read(BS)
wa = read(WA)
pc = read(PC)
svc = read(SVC)
cfg = json.load(open(CFG, "r", encoding="utf-8"))
feel = cfg.get("feel", {})

# ---------- A1 战斗移动平滑 ----------
print("\n[A1] 战斗主角移动平滑（加速度/惯性）")
dp = func_body(bs, "func _drive_player(")
check("用 move_toward 平滑速度（非瞬时常量速度）",
      "move_toward" in dp and "_player_vel" in dp, "加速/减速带惯性")
check("不再瞬移 position += 摇杆×速度",
      "_player.position += _player_vel * delta" in dp, "速度向量驱动")
check("_player_vel 成员已声明", "var _player_vel := Vector2.ZERO" in bs, "平滑速度载体")

# ---------- A2 立绘行走增强 ----------
print("\n[A2] 立绘行走增强（bob_double / weave_amp）")
check("WalkAnim 导出 bob_double", "@export var bob_double := 1.0" in wa, "双峰/步开关")
check("WalkAnim 导出 weave_amp", "@export var weave_amp := 0.0" in wa, "左右摆动开关")
check("bob 频率按 bob_double 倍率", "var bob_phase := _phase * bob_double" in func_body(wa, "func _process("),
      "立绘双峰、几何单峰")
check("weave 合成到本体 position.x", "Vector2(weave, bob_offset)" in func_body(wa, "func _process("),
      "左右轻晃")
def _positive_expr(rhs):
    """赋值右端是否为「正值表达式」。

    【为什么要放宽】旧判据用正则只认**字面数字**（如 `weave_amp = 3.0`）。
    第六十六轮把大地图立绘的振幅改成按身高比例取（`portrait_world_height * 0.012`），
    正则就匹配不上了 —— 那是判据过时，不是产品回归（行为上 weave_amp 仍 > 0）。
    放宽后仍保留捕获能力：赋 0、负数或删掉这行都会变红。
    """
    if rhs is None or rhs.strip() == "":
        return False
    nums = [float(x) for x in re.findall(r"\d*\.?\d+", rhs)]
    if not nums or any(n <= 0.0 for n in nums):
        return False
    # 出现减号（如 `-3.0` 或 `x - y`）一律不认：可能是负值或相减
    return "-" not in rhs


bpv = func_body(bs, "func _build_player_visual(")
check("战斗立绘分支 bob_double=2.0", "wa.bob_double = 2.0" in bpv, "双峰/步")
_m = re.search(r"wa\.weave_amp = ([^\n]+)", bpv)
check("战斗立绘分支 weave_amp>0", _positive_expr(_m.group(1) if _m else None),
      "左右摆动" + ("（%s）" % _m.group(1).strip() if _m else "（缺失）"))
tp = func_body(pc, "func _try_use_static_portrait(")
check("大地图立绘分支 bob_double=2.0", "_walk.bob_double = 2.0" in tp, "双峰/步")
_m2 = re.search(r"_walk\.weave_amp = ([^\n]+)", tp)
check("大地图立绘分支 weave_amp>0", _positive_expr(_m2.group(1) if _m2 else None),
      "左右摆动" + ("（%s）" % _m2.group(1).strip() if _m2 else "（缺失）"))

# ---------- B1 普攻 ----------
print("\n[B1] 普攻（轻·快）")
atk = func_body(bs, "func _on_attack()")
check("普攻落月牙斩 _spawn_slash", "_spawn_slash(" in atk, "命中处弧刃")
check("普攻走 KIND_LIGHT（比大招轻）", "KIND_LIGHT" in atk, "轻顿帧")
check("普攻保留前冲 _play_swing", "_play_swing(1.0)" in atk, "挥砍形")

# ---------- B2 大招 ----------
print("\n[B2] 大招（最重）")
sk = func_body(bs, "func _on_skill()")
check("大招炸冲击波 _spawn_shockwave", "_spawn_shockwave(" in sk, "金色扩散环")
check("大招全屏金闪 _flash_screen", "_flash_screen(Color(1.0, 0.86, 0.45)" in sk, "气势")
check("大招走 KIND_ULTIMATE", "KIND_ULTIMATE" in sk, "最重顿帧+震屏")

# ---------- B3 个人技 damage ----------
print("\n[B3] 个人技 damage（着色月牙斩 + 前冲；aoe 叠冲击波）")
tal = func_body(bs, "func _on_talent()")
dmg_block = tal[tal.find("PERSONAL_KIND_DAMAGE"):tal.find("PERSONAL_KIND_SHIELD")]
check("damage 分支调 _skill_tint 取色", "_skill_tint(" in dmg_block, "每技能招牌色")
check("damage 分支落着色月牙斩", "_spawn_slash(" in dmg_block, "区别于普攻白斩")
check("damage 分支前冲 _play_swing", "_play_swing(1.4)" in dmg_block, "挥砍形")
check("damage aoe 叠着色冲击波", "_spawn_shockwave(_player.position, tint)" in dmg_block
      and "aoe" in dmg_block, "群攻有扩散环")
check("damage 命中染色 _flash_tinted", "_flash_tinted(_player, tint)" in dmg_block, "主角染技能色")

# ---------- B4 个人技 shield ----------
print("\n[B4] 个人技 shield（护盾环）")
sh_block = tal[tal.find("PERSONAL_KIND_SHIELD"):tal.find("PERSONAL_KIND_HEAL")]
check("shield 分支调 _cast_shield_vfx", "_cast_shield_vfx()" in sh_block, "青色护盾泡")

# ---------- B5 个人技 heal ----------
print("\n[B5] 个人技 heal（回春光）")
check("heal 分支调 _cast_heal_vfx", "_cast_heal_vfx(" in tal, "绿色升腾光+回血飘字")

# ---------- C1 VFX 助手齐备 ----------
print("\n[C1] VFX 助手函数齐备")
for fn in ["_spawn_slash", "_spawn_shockwave", "_spawn_ring", "_cast_shield_vfx",
           "_cast_heal_vfx", "_flash_tinted", "_pop_float", "_skill_tint",
           "_slash_polygon", "_ring_polygon", "_nearest_enemy_pos"]:
    check("实现 %s()" % fn, bool(re.search(r"func %s\(" % fn, bs)), "已定义")

# ---------- C2 前摇 ----------
print("\n[C2] 挥砍前摇（蓄力）")
sw = func_body(bs, "func _play_swing(")
check("前摇：先朝反方向蓄力再递出", "-push * 0.35" in sw, "朝背向拉弓")
check("前摇时长取自配置", "CombatFeelService.attack_windup()" in sw, "不内联")

# ---------- D1 feel 配置 + 服务暴露 ----------
print("\n[D1] feel 段新键 + CombatFeelService 暴露")
need_keys = ["attack_windup", "slash_life", "slash_scale", "shockwave_life",
             "shockwave_speed", "shockwave_max_r", "shield_ring_life",
             "shield_bubble_life", "heal_glow_life", "heal_particle_life"]
missing = [k for k in need_keys if k not in feel]
check("feel 段动作演出键齐全（%d 项）" % len(need_keys), not missing, "缺失：%s" % (missing or "无"))
need_fns = ["attack_windup", "slash_life", "slash_scale", "shockwave_life",
            "shockwave_speed", "shockwave_max_r", "shield_ring_life",
            "shield_bubble_life", "heal_glow_life", "heal_particle_life"]
for fn in need_fns:
    check("CombatFeelService 暴露 %s()" % fn,
          bool(re.search(r"static func %s\(" % fn, svc)), "已定义")

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

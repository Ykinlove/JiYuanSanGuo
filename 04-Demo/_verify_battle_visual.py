# -*- coding: utf-8 -*-
"""战斗场景升级（第十七轮续）· 接线静态复核

锁定本轮「把战斗场景从几何六边形升级为阵营军旗大战场」的关键接线，
防止后人改回纯几何 / 改坏孤身战败修复：

  V1 单位视觉容器：BattleUnit 用 _art 容器承载「方阵底座 + 军旗 + 投影」
  V2 阵营分色：faction_color() 区分我方蓝 / 敌方绛红（非按兵种上色）
  V3 军旗：_build_banner / _build_emblem 已实现，缺贴图也有程序化徽记
  V4 闪红/视觉偏移走 _art（_refresh_flash 用 _art.modulate、_apply_impulse 写 _art.position）
  V5 战场布景：_build_battle_set / _spawn_standard 已实现，且 _ready 中始终调用
  V6 孤身战败修复：_apply_contact_damage 的战败分支走 force_end(false)，
     且仅当 ally_alive()>0 才挂彩后撤（不再用 not had_allies() 让孤身永生）
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
UNIT = os.path.join(HERE, "scripts", "battle", "battle_unit.gd")
SCENE = os.path.join(HERE, "scripts", "battle", "battle_scene.gd")

results = []


def check(name, ok, detail):
    results.append((name, ok, detail))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def func_body(src, sig):
    i = src.find(sig)
    if i < 0:
        return ""
    j = src.find("\nfunc ", i + 1)
    if j < 0:
        j = len(src)
    return src[i:j]


print("=" * 68)
print("战斗场景升级 · 接线静态复核")
print("=" * 68)

u = read(UNIT)
s = read(SCENE)

# ---------- V1 单位视觉容器 ----------
print("\n[V1] 单位视觉容器 _art")
check("_art 成员已声明", bool(re.search(r"var _art: Node2D", u)), "容器节点")
check("_build_visual 建立 _art 容器", "_art = Node2D.new()" in func_body(u, "func _build_visual("), "已建")
check("_art 含地面投影", "_shadow = Polygon2D.new()" in func_body(u, "func _build_visual("), "重心投影")

# ---------- V2 阵营分色 ----------
print("\n[V2] 阵营分色 faction_color()")
check("faction_color() 已实现", bool(re.search(r"func faction_color\(\)", u)), "已定义")
fac = func_body(u, "func faction_color()")
check("我方蓝 / 敌方绛红", "Color(0.30, 0.55, 0.95)" in fac and "Color(0.92, 0.30, 0.28)" in fac,
      "is_ally 二分支")
check("_build_visual 用阵营色而非兵种色", "faction_color()" in func_body(u, "func _build_visual(")
      and "var fac := faction_color()" in func_body(u, "func _build_visual("), "底座按阵营")

# ---------- V3 军旗 + 徽记 ----------
print("\n[V3] 军旗 / 兵种徽记")
check("_build_banner 已实现", bool(re.search(r"func _build_banner\(", u)), "已定义")
check("_build_emblem 已实现", bool(re.search(r"func _build_emblem\(", u)), "已定义")
check("_build_visual 接线军旗", "_build_banner(fac, accent, size)" in func_body(u, "func _build_visual("),
      "调用旗")
check("缺贴图走程序化徽记", "_build_emblem(accent, size)" in func_body(u, "func _build_visual("),
      "else 分支")
check("军旗绕顶端轻摆（tween loop）", "_banner_tween = create_tween()" in func_body(u, "func _build_banner(")
      and "set_loops(true)" in func_body(u, "func _build_banner("), "布料感")

# ---------- V4 闪红 / 偏移走 _art ----------
print("\n[V4] 闪红与视觉偏移接入 _art")
rf = func_body(u, "func _refresh_flash(")
check("_refresh_flash 用 _art.modulate", "_art.modulate" in rf and "_body.modulate" not in rf,
      "整体闪红")
ai = func_body(u, "func _apply_impulse(")
check("_apply_impulse 写 _art.position", "_art.position = _vis_off" in ai, "整组随偏移")
check("底座叠待机呼吸", "_body.position = bob" in ai or "sin(_bob)" in ai, "起伏")
check("_play_death 复位 _art 并停旗", "_art.modulate = Color.WHITE" in func_body(u, "func _play_death(")
      and "_banner_tween.kill()" in func_body(u, "func _play_death("), "收尾干净")
check("受击/阵亡粒子迸发", "_burst(" in func_body(u, "func take_damage(")
      and "_burst(" in func_body(u, "func _play_death("), "火星+尘土")

# ---------- V5 战场布景 ----------
print("\n[V5] 战场布景（大纛 / 营火 / 余烬）")
check("_build_battle_set 已实现", bool(re.search(r"func _build_battle_set\(", s)), "已定义")
check("_spawn_standard 已实现", bool(re.search(r"func _spawn_standard\(", s)), "已定义")
check("_ready 中始终调用 _build_battle_set", "_build_battle_set()" in func_body(s, "func _ready()"),
      "不依赖背景贴图")
bs = func_body(s, "func _build_battle_set(")
check("背线大纛双方各三面", "range(3)" in bs and "_spawn_standard(" in bs, "两军对阵")
check("营火烟柱 + 飘散余烬（CPU 粒子）",
      "CampSmoke" in bs and "Embers" in bs and "CPUParticles2D" in bs, "零新资源")
# 【第二十二轮更新】主角视觉拆成分支函数（立绘优先/几何兜底）后，
# 将旗挪进 _build_player_flag —— 断言改为「主函数确实调用它 + 旗件本体齐全」
fl = func_body(s, "func _build_player_flag(")
check("主角将旗（统帅感）",
      "_build_player_flag(" in func_body(s, "func _build_player_visual(")
      and "pflag" in fl and "pban" in fl, "主公焦点")

# ---------- V6 孤身战败修复 ----------
print("\n[V6] 孤身不战败修复")
cd = func_body(s, "func _apply_contact_damage(")
check("战败分支走 force_end(false)", "_director.force_end(false)" in cd, "真正判负")
check("仅 ally_alive()>0 才挂彩后撤", "if _director.ally_alive() > 0:" in cd, "有部曲才退")
check("已移除 not had_allies() 永生分支", "not _director.had_allies()" not in cd,
      "孤身不再无限复活")

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

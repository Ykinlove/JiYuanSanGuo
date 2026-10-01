# -*- coding: utf-8 -*-
"""角色行走动作·双腿与落地感（2026-10-01）· 接线静态复核

锁定「几何小人装真腿 + 单图立绘影子联动」两组接线，防止后人改回纸片滑动：

  L1 WalkAnim 双腿 rig：add_legs/_pose_leg 与踏步同相位（前摆抬脚/后蹬伸直）
  L2 影子联动：shadow_node 抬脚缩小变淡、落地恢复（立绘的"落地感"来源）
  L3 世界 NPC：两分支均挂 WalkAnim（此前完全没挂，纯滑动），几何装腿
  L4 城内 NPC：几何装腿、立绘接影子（has_portrait 分流）
  L5 战斗主角/世界主角：几何兜底装腿；立绘分支加投影并联动
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def read(p):
    with open(os.path.join(HERE, p), "r", encoding="utf-8") as f:
        return f.read()


def func_body(src, sig):
    i = src.find(sig)
    if i < 0:
        return ""
    j = src.find("\nfunc ", i + 1)
    if j < 0:
        j = len(src)
    return src[i:j]


results = []


def check(name, ok, detail):
    results.append((name, ok, detail))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


print("=" * 68)
print("角色行走动作 · 双腿与落地感 接线静态复核")
print("=" * 68)

wa = read("scripts/world/walk_anim.gd")
nm = read("scripts/world/npc_manager.gd")
cia = read("scripts/city/city_interior_art.gd")
cs = read("scripts/city/city_scene.gd")
bs = read("scripts/battle/battle_scene.gd")
pc = read("scripts/world/player_controller.gd")

# ---------- L1 双腿 rig ----------
print("\n[L1] WalkAnim 双腿 rig")
check("add_legs 已实现", bool(re.search(r"func add_legs\(", wa)), "已定义")
check("_pose_leg 已实现", bool(re.search(r"func _pose_leg\(", wa)), "已定义")
check("腿画在身体之下（move_child 到 0）", "parent.move_child(legs, 0)" in
      func_body(wa, "func add_legs("), "别盖住躯干")
check("双腿与踏步同相位", "_pose_leg(_leg_l, _phase" in wa and "_phase + PI" in wa,
      "左右腿反相交替")
check("前摆抬脚+小腿回收+后蹬伸直", "leg_swing_deg" in func_body(wa, "func _pose_leg(")
      and "shin" in func_body(wa, "func _pose_leg("), "摆动/抬腿/落地")
check("立绘不加腿有说明防呆", "立绘角色不要调用" in wa or "会变成四条腿" in wa,
      "注释明确约束")

# ---------- L2 影子联动 ----------
print("\n[L2] 影子联动")
check("shadow_node 导出", "@export var shadow_node: Node2D = null" in wa, "可选接入")
sh = func_body(wa, "func _process(")
check("影子随抬起缩小变淡", "shadow_node.scale = _shadow_base" in sh
      and "shadow_node.modulate.a = _shadow_alpha" in sh, "抬脚/落地呼吸")

# ---------- L3 世界 NPC ----------
print("\n[L3] 世界 NPC（此前无任何行走动画）")
check("两分支均挂 WalkAnim", nm.count("WalkAnim.attach(node, art)") == 2,
      "立绘/几何都接")
check("几何分支装腿", "wa.add_legs(art, 54.0, 30.0)" in nm, "真腿")
check("立绘分支接影子", "wa.shadow_node = shadow" in nm, "落地感")
check("本体装 Art 容器（投影/名牌在外）", 'art.name = "Art"' in nm, "不整块抖动")

# ---------- L4 城内 NPC ----------
print("\n[L4] 城内 NPC")
check("立绘/几何 meta 标记", 'set_meta("has_portrait"' in cia, "分流依据")
check("影子已命名", 'shadow.name = "Shadow"' in cia, "可被 get_node 取到")
check("几何装腿", 'wa.add_legs(art.get_node_or_null("Body") as Node2D, 22.0, 6.0)' in cs,
      "真腿")
check("立绘接影子", 'wa.shadow_node = art.get_node_or_null("Shadow") as Node2D' in cs,
      "落地感")

# ---------- L5 主角 ----------
print("\n[L5] 主角（战斗 / 大地图 / 城内）")
bpv = func_body(bs, "func _build_player_visual(")
check("战斗主角装腿", "wa.add_legs(body_root, 14.0, 8.0)" in bpv, "五边形也有腿")
ready = func_body(pc, "func _ready()")
check("几何兜底装腿（大地图/城内共用）", "_walk.add_legs(_visual, 14.0, 7.0)" in ready,
      "世界/城内几何小人")
tp = func_body(pc, "func _try_use_static_portrait(")
# 【三十三轮】影子半径随 portrait_world_height 联动（15.0*k），高度参数化后字面量带 k
check("立绘主角加脚下投影", "_ellipse_points(Vector2.ZERO, 15.0 * k, 6.0 * k, 14)" in tp,
      "此前无影子")
check("立绘主角接影子联动", "_walk.shadow_node = shadow" in tp, "落地感")

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

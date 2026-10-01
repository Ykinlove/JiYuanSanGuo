# -*- coding: utf-8 -*-
"""三十二轮 大地图官道商队 静态复核（数据同源/数量红锁/折线推进折返/绘制裁剪）"""
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(ROOT, "scripts", "world", "world_caravans.gd")
WMAP = os.path.join(ROOT, "scripts", "world", "world_map.gd")

passes, fails = [], []


def check(name, cond):
    if cond:
        passes.append(name)
    else:
        fails.append(name)


check("A1 商队脚本在位", os.path.exists(SCRIPT))
src = ""
if os.path.exists(SCRIPT):
    with open(SCRIPT, "r", encoding="utf-8") as f:
        src = f.read()
wmap = ""
if os.path.exists(WMAP):
    with open(WMAP, "r", encoding="utf-8") as f:
        wmap = f.read()

# ---- A. 接线 ----
check("A2 world_map 实例化 WorldCaravans", "WorldCaravans.new()" in wmap)
check("A3 注入相机（视口裁剪用）", "caravans.setup(_camera)" in wmap)
check("A4 class_name 已注册", "class_name WorldCaravans" in src)

# ---- B. 数据同源（商队走在画出来的官道上） ----
check("B1 数据源 terrain 表", 'DataManager.get_table("terrain")' in src)
check("B2 取 china 行 roads（与 minimap/地形官道同源）",
      '"china"' in src and 'row.get("roads", [])' in src)
check("B3 折线转 PackedVector2Array", "_to_polyline" in src)

# ---- C. 数量与性能红锁 ----
check("C1 商队上限 CARAVAN_MAX=3", "CARAVAN_MAX := 3" in src
      and "_caravans.size() >= CARAVAN_MAX" in src)
check("C2 短路不派队（MIN_ROAD_LEN）", "MIN_ROAD_LEN" in src)
check("C3 单节点批量 _draw（无子节点无粒子）",
      "func _draw" in src and src.count("CPUParticles2D") == 0)
check("C4 离屏绘制裁剪（CULL_GROW + has_point）",
      "CULL_GROW" in src and ".grow(" in src and "has_point" in src)
check("C5 无队时停 process", "set_process(false)" in src)

# ---- D. 行为 ----
check("D1 折线弧长采样（段插值+方向角）",
      "_sample" in src and "lerp" in src and "angle()" in src)
check("D2 端点折返（dir 翻转）",
      '"dir"] = -1' in src and '"dir"] = 1' in src)
check("D3 端点歇脚（进城感，REST 区间）",
      "REST_MIN" in src and "REST_MAX" in src and 'rest"] = randf_range' in src)
check("D4 行走摆腿相位推进", '"phase"] = float(cv["phase"]) + delta' in src
      and "sin(phase)" in src)
check("D5 货车随路向旋转（draw_set_transform）",
      "draw_set_transform" in src and "draw_rect" in src)

# ---- E. 探针 ----
check("E1 行为探针场景在位",
      os.path.exists(os.path.join(ROOT, "tests", "caravan_probe.tscn")))
diag = ""
_diag_path = os.path.join(ROOT, "tests", "terrain_diag_probe.gd")
if os.path.exists(_diag_path):
    with open(_diag_path, "r", encoding="utf-8") as f:
        diag = f.read()
check("E2 诊断探针可跟随商队截图（DIAG_AT_CARAVAN）",
      "DIAG_AT_CARAVAN" in diag and "WorldCaravans" in diag)

print("=" * 50)
print("大地图官道商队校验")
print("=" * 50)
for p in passes:
    print("  [PASS] %s" % p)
for f_ in fails:
    print("  [FAIL] %s" % f_)
print("-" * 50)
print("通过 %d / %d" % (len(passes), len(passes) + len(fails)))
sys.exit(1 if fails else 0)

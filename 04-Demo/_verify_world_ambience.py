# -*- coding: utf-8 -*-
"""第 38 项校验：大地图活物氛围层（2026-10-01 身临其境）

内容：WorldAmbience 三件套——云影掠地（CPU 烘焙无缝噪声 + 视口自适应
region 滚动）/ 城池炊烟（仅相机附近城市，上限 6 发射器）/ 飞鸟掠空
（程序化 V 翅，零贴图）。零新资源。
性能红锁：云影层数 ≤1（填充率）、巨图显式 LINEAR、炊烟近城裁剪。
"""
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
AMB = os.path.join(ROOT, "scripts", "world", "world_ambience.gd")
WMAP = os.path.join(ROOT, "scripts", "world", "world_map.gd")

fails = []
passes = []


def check(name, cond, detail=""):
    if cond:
        passes.append(name)
    else:
        fails.append("%s %s" % (name, detail))


with open(AMB, "r", encoding="utf-8") as f:
    src = f.read()
with open(WMAP, "r", encoding="utf-8") as f:
    wmap = f.read()

# ---- A. 接线 ----
check("A1 world_map 实例化 WorldAmbience", "WorldAmbience.new()" in wmap)
check("A2 注入相机引用 setup(_camera)", "ambience.setup(_camera)" in wmap)
check("A3 独立脚本文件在位", os.path.exists(AMB))

# ---- B. 云影 ----
check("B1 CPU 烘焙无缝噪声纹理", "_bake_cloud_texture" in src and "get_noise_3d" in src)
check("B2 环面参数化无缝平铺", "cos(u)" in src and "sin(v)" in src)
check("B3 视口自适应 region（不许巨型 quad）",
      "_update_clouds" in src and "get_screen_center_position" in src
      and "region_rect = Rect2" in src)
check("B4 云影显式 LINEAR 过滤（性能红锁）",
      "TEXTURE_FILTER_LINEAR" in src
      and "TEXTURE_FILTER_LINEAR_WITH_MIPMAPS" not in src)
check("B5 云影层数 ≤1（填充率红锁）",
      "CLOUD_LAYERS" in src
      and int(__import__("re").search(r"CLOUD_LAYERS\s*:=\s*(\d+)", src).group(1)) <= 1)

# ---- C. 炊烟（近城裁剪） ----
check("C1 炊烟发射器上限", "SMOKE_MAX" in src
      and int(__import__("re").search(r"SMOKE_MAX\s*:=\s*(\d+)", src).group(1)) <= 8)
check("C2 相机半径裁剪", "SMOKE_RANGE" in src and "distance_to(center)" in src)
check("C3 世界坐标粒子（烟随风飘）", "local_coords = false" in src)
check("C4 低频扫描", "SMOKE_SCAN_INTERVAL" in src)

# ---- D. 飞鸟 ----
check("D1 程序化 V 翅绘制", "_draw_flock" in src and "draw_line" in src)
check("D2 扇翅动画", "flap" in src and "queue_redraw" in src)
check("D3 出界回卷重生", "set_meta(\"vel\"" in src and "rotated" in src)
# 【红锁】draw 信号回调里的 draw_line 必须带 flock. 前缀：裸 draw_line 解析到
# WorldAmbience 自身、不在其 draw 上下文 → 全部被拒 + 每帧刷 ERROR 拖垮帧率。
# （第三十轮实锤：裸调用致飞鸟隐形 + FPS 28→14）
import re as _re
_draw_fn = ""
if "func _draw_flock" in src:
    _d0 = src.index("func _draw_flock")
    _d1 = src.find("\nfunc ", _d0 + 1)
    _draw_fn = src[_d0:_d1 if _d1 > 0 else len(src)]
check("D4 飞鸟 draw_line 必须 flock. 前缀（draw 上下文红锁）",
      bool(_draw_fn) and ".draw_line(" in _draw_fn
      and not _re.search(r"(?<![\w.])draw_line\(", _draw_fn))

# ---- E. 分层正确 ----
check("E1 氛围层 z 介于地形与标记之间", "z_index = 0" in src)

print("=" * 50)
print("大地图活物氛围层校验")
print("=" * 50)
for p in passes:
    print("  [PASS] %s" % p)
for f_ in fails:
    print("  [FAIL] %s" % f_)
print("-" * 50)
print("通过 %d / %d" % (len(passes), len(passes) + len(fails)))
sys.exit(1 if fails else 0)

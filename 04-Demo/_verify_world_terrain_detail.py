# -*- coding: utf-8 -*-
"""第 37 项校验：大地图地貌细节层（2026-10-01 修复主视图纯绿）

背景：近景细节层原先叠 world_static.png（程序化噪声烘焙图），没有山川水系，
α=1.0 全开把底下 AI 写实图整个盖平 → 主视图纯绿。修复后：
  底图：china_geo_2048（与 minimap 同源）→ china_geo(1024) → world_static → 程序化
  细节层：china_geo_4096（AI 图 lanczos+USM 锐化烘焙）α=zoom 渐入
          → world_static 低透明度（NEAR_STATIC_ALPHA）回退
          → 256 噪声 tile 地表颗粒
本脚本静态复核接线 + 产物存在性 + 烘焙管线在位。
"""
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
PAINTER = os.path.join(ROOT, "scripts", "world", "terrain_painter.gd")
BAKE = os.path.join(ROOT, "..", "03-美术资源", "tools", "_china_geo_4096_bake.py")
GEO_4096 = os.path.join(ROOT, "assets", "sprites", "terrain", "china_geo_4096.png")

fails = []
passes = []


def check(name, cond, detail=""):
    if cond:
        passes.append(name)
    else:
        fails.append("%s %s" % (name, detail))


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    w, h = struct.unpack(">II", head[16:24])
    return w, h


with open(PAINTER, "r", encoding="utf-8") as f:
    src = f.read()

# ---- A. 底图链：2048 优先，1024 兜底 ----
draw_body = src[src.index("func _draw()"):] if "func _draw()" in src else ""
check("A1 底图优先 china_geo_2048", "_get_art_geo_2048_tex()" in draw_body)
check("A2 底图回退 china_geo(1024)", "_get_art_geo_tex()" in draw_body)
check("A3 底图回退 world_static", "_get_static_tex_lazy()" in draw_body)
check("A4 底图终兜底程序化远景", "_get_lowres_world_tex()" in draw_body)
# 2048 必须在 1024 之前赋给 art（优先级锁）
idx2048 = draw_body.find("_get_art_geo_2048_tex()")
idx1024 = draw_body.find("_get_art_geo_tex()")
check("A5 2048 优先级先于 1024", 0 <= idx2048 < idx1024)

# ---- B. 近景细节层：4096 锐化图 + 回退链 ----
check("B1 细节层 getter _get_near_detail_tex", "func _get_near_detail_tex" in src)
check("B2 细节层引用 china_geo_4096", "china_geo_4096.png" in src)
check("B3 _draw 渐入绘制 hi_near",
      "hi_near" in draw_body and "_near_detail_factor()" in draw_body)
check("B4 world_static 降级回退存在", "NEAR_STATIC_ALPHA" in src)
check("B5 回退透明度 <0.5（不再盖平底图）",
      bool(re.search(r"NEAR_STATIC_ALPHA\s*:=\s*0\.\d+", src))
      and float(re.search(r"NEAR_STATIC_ALPHA\s*:=\s*(0\.\d+)", src).group(1)) < 0.5)
check("B6 地表颗粒 tile 保留", '"plain", 256' in draw_body)
check("B7 细节层懒加载（_near_tex_checked）", "_near_tex_checked" in src)

# ---- C. 产物与管线 ----
check("C1 china_geo_4096.png 已烘焙", os.path.exists(GEO_4096))
if os.path.exists(GEO_4096):
    size = png_size(GEO_4096)
    check("C2 尺寸 4096 级", size is not None and size[0] >= 4096 and size[1] >= 4096,
          "实际 %s" % (size,))
    check("C3 文件合理（4~60MB）",
          4 * 1048576 <= os.path.getsize(GEO_4096) <= 60 * 1048576)
check("C4 烘焙管线脚本在位", os.path.exists(BAKE))
if os.path.exists(BAKE):
    with open(BAKE, "r", encoding="utf-8") as f:
        bake_src = f.read()
    check("C5 烘焙用 UnsharpMask 锐化", "UnsharpMask" in bake_src)
    check("C6 烘焙 lanczos 放大", "LANCZOS" in bake_src)

# ---- D. 小地图同源（视觉一致性不回退） ----
check("D1 minimap 注入仍走 _get_minimap_tex", "_get_minimap_tex" in src)
minimap_fn = ""
if "func _get_minimap_tex" in src:
    m_start = src.index("func _get_minimap_tex")
    m_next = src.find("\nfunc ", m_start + 1)
    minimap_fn = src[m_start:m_next if m_next > 0 else len(src)]
check("D2 minimap 优先 2048 版", "_get_art_geo_2048_tex()" in minimap_fn)

# ---- 汇总 ----
print("=" * 50)
print("大地图地貌细节层校验")
print("=" * 50)
for p in passes:
    print("  [PASS] %s" % p)
for f_ in fails:
    print("  [FAIL] %s" % f_)
print("-" * 50)
print("通过 %d / %d" % (len(passes), len(passes) + len(fails)))
sys.exit(1 if fails else 0)

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
check("B6 地表颗粒 tile 改用 detail 512 RGBA", '"detail", 512' in draw_body)
check("B7 细节层懒加载（_near_tex_checked）", "_near_tex_checked" in src)

# ---- B2. 抗糊约束（第二十六轮 2026-10-01） ----
m = re.search(r'"detail", 512\)\n\s*draw_texture_rect\(grain, [^\n]*Color\(1, 1, 1, (0\.\d+) \* near\)', src)
check("B8 噪点层 α ≤0.2（脏糊锁）", m is not None and float(m.group(1)) <= 0.2,
      "实际 %s" % (m.group(1) if m else "未找到"))
imp = os.path.join(ROOT, "assets", "sprites", "terrain", "china_geo_4096.png.import")
check("B9 4096 禁开 mipmap 生成（性能红锁：省 33%% 显存）",
      os.path.exists(imp) and "mipmaps/generate=false" in open(imp, encoding="utf-8").read())
check("B10 巨图过滤性能红锁：首帧后延迟设 LINEAR（_apply_linear_filter_later）",
      "_apply_linear_filter_later" in src
      and "TEXTURE_FILTER_LINEAR" in src
      and "TEXTURE_FILTER_LINEAR_WITH_MIPMAPS" not in src)
check("B11 底图=细节图时不再二次绘制（hi_near != art 守卫）",
      "hi_near != art" in draw_body)

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
    check("C7 烘焙走频段交换（低频原图+高频HD）",
          "频段交换" in bake_src and "DETAIL_GAIN" in bake_src)
STITCH = os.path.join(ROOT, "..", "03-美术资源", "tools", "_china_geo_hd_stitch.py")
check("C8 HD 四象限拼接管线在位", os.path.exists(STITCH))
HD_2048 = os.path.join(ROOT, "..", "03-美术资源", "AI源图", "terrain", "china_geo_hd_2048.png")
check("C9 HD 2048 原生源图在位（本地归档）", os.path.exists(HD_2048))

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

# -*- coding: utf-8 -*-
""" china_geo_4096 烘焙：AI 写实全景图 → 近景细节整图（lanczos 4x + USM 锐化）

背景：大地图近景细节层原先叠 world_static.png（程序化噪声烘焙图），
它没有山川水系，α=1.0 时把底下 china_geo AI 图的雪山大河整个盖平
（主视图纯绿的元凶）。本脚本从同一张 AI 图派生高清近景层：
  1024 原生 → lanczos 放大 4096 → UnsharpMask 锐化恢复边缘
与底图（china_geo_2048）同源同色，近景等于「把同一张画拉近看」，
山脊/河谷走向清晰，城池点位对齐不变（同一张图）。

用法（工程外一次性烘焙，产物落 04-Demo/assets/sprites/terrain/）：
    python _china_geo_4096_bake.py
"""
import os
import sys
from PIL import Image, ImageEnhance, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "AI源图", "..", "AI源图", "terrain", "china_geo_src.png"))
# 源图不在归档时，直接用工程内的 china_geo.png（1024 原生）
FALLBACK = os.path.normpath(os.path.join(HERE, "..", "..", "04-Demo", "assets", "sprites", "terrain", "china_geo.png"))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "04-Demo", "assets", "sprites", "terrain", "china_geo_4096.png"))

SIZE = 4096
USM_RADIUS = 2.6      ## 锐化半径（像素，4096 尺度）
USM_PERCENT = 120     ## 锐化强度
USM_THRESHOLD = 2     ## 阈值：只锐化真边缘，避免放大噪声

# ——【第二弯 2026-10-01 提质】用户反馈近景仍糊：源图原生 1024，游戏里线性过滤
# 放大 5~10 倍天生偏软。单次 USM 不够，改多尺度锐化链：
#   ① DETAIL 卷积（全域细节增强，各向同性）
#   ② 细尺度 USM（r=1.2 强度 160）：恢复纹理边缘
#   ③ 粗尺度 USM（r=6 强度 70）：局部对比（山体立体感）
#   ④ 饱和度 1.15 + 对比 1.06：对冲游戏内叠层洗色
USM_FINE_RADIUS = 1.2
USM_FINE_PERCENT = 160
USM_COARSE_RADIUS = 6.0
USM_COARSE_PERCENT = 70
SATURATION = 1.15
CONTRAST = 1.06


def main() -> None:
    src = SRC if os.path.exists(SRC) else FALLBACK
    if not os.path.exists(src):
        print("[FAIL] 找不到源图：", src)
        sys.exit(1)
    im = Image.open(src).convert("RGB")
    print("[INFO] 源图：", src, im.size)

    im = im.resize((SIZE, SIZE), Image.LANCZOS)
    im = im.filter(ImageFilter.DETAIL)
    im = im.filter(ImageFilter.UnsharpMask(
        radius=USM_FINE_RADIUS, percent=USM_FINE_PERCENT, threshold=1))
    im = im.filter(ImageFilter.UnsharpMask(
        radius=USM_COARSE_RADIUS, percent=USM_COARSE_PERCENT, threshold=2))
    im = ImageEnhance.Color(im).enhance(SATURATION)
    im = ImageEnhance.Contrast(im).enhance(CONTRAST)
    im.save(OUT, optimize=True)
    print("[OK] 已烘焙：", OUT, "（%d×%d，%.1f MB）"
          % (SIZE, SIZE, os.path.getsize(OUT) / 1048576.0))


if __name__ == "__main__":
    main()

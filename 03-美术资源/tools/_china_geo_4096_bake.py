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
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "AI源图", "..", "AI源图", "terrain", "china_geo_src.png"))
# 源图不在归档时，直接用工程内的 china_geo.png（1024 原生）
FALLBACK = os.path.normpath(os.path.join(HERE, "..", "..", "04-Demo", "assets", "sprites", "terrain", "china_geo.png"))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "04-Demo", "assets", "sprites", "terrain", "china_geo_4096.png"))

SIZE = 4096
USM_RADIUS = 2.6      ## 锐化半径（像素，4096 尺度）
USM_PERCENT = 120     ## 锐化强度
USM_THRESHOLD = 2     ## 阈值：只锐化真边缘，避免放大噪声


def main() -> None:
    src = SRC if os.path.exists(SRC) else FALLBACK
    if not os.path.exists(src):
        print("[FAIL] 找不到源图：", src)
        sys.exit(1)
    im = Image.open(src).convert("RGB")
    print("[INFO] 源图：", src, im.size)

    im = im.resize((SIZE, SIZE), Image.LANCZOS)
    im = im.filter(ImageFilter.UnsharpMask(
        radius=USM_RADIUS, percent=USM_PERCENT, threshold=USM_THRESHOLD))
    im.save(OUT, optimize=True)
    print("[OK] 已烘焙：", OUT, "（%d×%d，%.1f MB）"
          % (SIZE, SIZE, os.path.getsize(OUT) / 1048576.0))


if __name__ == "__main__":
    main()

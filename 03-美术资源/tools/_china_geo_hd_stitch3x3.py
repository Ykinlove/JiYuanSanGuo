# -*- coding: utf-8 -*-
""" 3×3 九宫格 i2i 增强图 → 拼接 3072 原生超清全图（china_geo_hd_3072.png）

在 2×2 版（_china_geo_hd_stitch.py → hd_2048）基础上二次增强：
hd_2048 切 3×3 块 768²（重叠 128px）→ ImageGen 逐块增强至 1024² →
拼成 3072² 原生图 → 供 _china_geo_4096_bake.py 作源（近景纹素密度再 ×2.25）。

拼接：1024 → 1152（=768×1.5，对齐 3072 网格，位置 0/960/1920，
重叠 192px 线性羽化）；每块右下角「AI生成」水印用源块同区域羽化覆盖。

用法：
    python _china_geo_hd_stitch3x3.py
"""
import os
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
QDIR = os.path.normpath(os.path.join(HERE, "..", "AI源图", "terrain", "tiles3x3"))
OUT = os.path.normpath(os.path.join(HERE, "..", "AI源图", "terrain", "china_geo_hd_3072.png"))

TILE_IN = 768          ## 输入块边长（hd_2048 上的裁剪尺寸）
POS = [0, 640, 1280]   ## 块在 hd_2048 上的偏移
GRID = 3072            ## 拼接画布（hd_2048 的 1.5 倍）
SCALE = 1.5            ## hd_2048 → 画布倍率
TILE_OUT = int(TILE_IN * SCALE)   ## 1152
STEP = int(POS[1] * SCALE)        ## 960
FEATHER = 192          ## 拼接羽化宽度（画布像素）
WM_BOX = (824, 924, 1024, 1024)   ## 水印区（输出 1024 坐标）
WM_FEATHER = 48


def kill_watermark(tile_img: Image.Image, quad_src: Image.Image) -> Image.Image:
    """用源块（放大到 1024 对位）同区域羽化覆盖水印。"""
    src_up = quad_src.resize((1024, 1024), Image.LANCZOS)
    x0, y0, x1, y1 = WM_BOX
    patch = src_up.crop(WM_BOX)
    w, h = patch.size
    yy, xx = np.mgrid[0:h, 0:w]
    fx = np.minimum(1.0, (xx + 1) / float(WM_FEATHER))
    fy = np.minimum(1.0, (yy + 1) / float(WM_FEATHER))
    mask = (fx * fy * 255).astype(np.uint8)
    tile_img.paste(patch, (x0, y0), Image.fromarray(mask))
    return tile_img


def tile_weight(inner_l, inner_t, inner_r, inner_b) -> np.ndarray:
    w = np.ones((TILE_OUT, TILE_OUT), dtype=np.float32)
    ramp = np.linspace(0.0, 1.0, FEATHER, dtype=np.float32)
    if inner_l:
        w[:, :FEATHER] *= ramp[None, :]
    if inner_t:
        w[:FEATHER, :] *= ramp[:, None]
    if inner_r:
        w[:, -FEATHER:] *= ramp[::-1][None, :]
    if inner_b:
        w[-FEATHER:, :] *= ramp[::-1][:, None]
    return w


def main() -> None:
    acc = np.zeros((GRID, GRID, 3), dtype=np.float64)
    wsum = np.zeros((GRID, GRID), dtype=np.float64)

    for ry in range(3):
        for rx in range(3):
            idx = ry * 3 + rx + 1
            tile_path = os.path.join(QDIR, "out_t%02d.png" % idx)
            tile = Image.open(tile_path).convert("RGB")
            src_quad = Image.open(os.path.join(QDIR, "t%02d.png" % idx)).convert("RGB")
            tile = kill_watermark(tile, src_quad)
            tile = tile.resize((TILE_OUT, TILE_OUT), Image.LANCZOS)
            arr = np.asarray(tile).astype(np.float64)
            wt = tile_weight(rx > 0, ry > 0, rx < 2, ry < 2)
            cx, cy = rx * STEP, ry * STEP
            acc[cy:cy + TILE_OUT, cx:cx + TILE_OUT] += arr * wt[..., None]
            wsum[cy:cy + TILE_OUT, cx:cx + TILE_OUT] += wt
            print("[INFO] t%02d 已合成" % idx)

    canvas = np.clip(acc / np.maximum(wsum, 1e-9)[..., None], 0, 255).astype(np.uint8)
    img = Image.fromarray(canvas)
    img.save(OUT, optimize=True)
    print("[OK] 已拼接：", OUT, "（%d×%d，%.1f MB）"
          % (GRID, GRID, os.path.getsize(OUT) / 1048576.0))


if __name__ == "__main__":
    main()

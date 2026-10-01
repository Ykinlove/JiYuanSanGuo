# -*- coding: utf-8 -*-
""" 四象限 i2i 增强图 → 拼接 2048 原生高清全图（china_geo_hd_2048.png）

管线：ImageGen 图生图 4 象限（576² 输入含 128px 重叠 → 1024² 输出）
  ① 水印处理：每张输出右下角「AI生成」水印，用原象限同区域（放大对位）
     羽化融合覆盖 —— 构图已对齐，补丁在地图尺度不可见
  ② 每张 1024 → 1152（=576×2，对齐 2048 网格）
  ③ 重叠区 256px 线性羽化加权拼接（内缘 ramp，核心区权重 1）

产物：03-美术资源/AI源图/terrain/china_geo_hd_2048.png（2048 原生细节，
      供 _china_geo_4096_bake.py 作源图 → 只需 2x lanczos 即可烘焙 4096）

用法：
    python _china_geo_hd_stitch.py
"""
import os
import glob
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
QDIR = os.path.normpath(os.path.join(HERE, "..", "AI源图", "terrain", "quads"))
OUT = os.path.normpath(os.path.join(HERE, "..", "AI源图", "terrain", "china_geo_hd_2048.png"))

TILE_IN = 576          ## 输入象限边长（源 1024 图上的裁剪尺寸）
TILE_POS = 448         ## 象限在源图上的偏移（0/448）
GRID = 2048            ## 拼接画布（源 1024 的 2 倍）
SCALE = 2              ## 源图 → 画布倍率
FEATHER = 256          ## 拼接羽化宽度（画布像素）
WM_BOX = (824, 924, 1024, 1024)  ## 水印区（输出 1024 坐标）
WM_FEATHER = 48        ## 水印补丁羽化


def find_output(quad_idx: int) -> str:
    """按生成时间序取第 quad_idx 张增强图（1..4）。
    目录里有 4 张 Enhance_*（生成顺序=quad1..4，见本轮时间戳）。"""
    files = sorted(glob.glob(os.path.join(QDIR, "Enhance_*.png")))
    assert len(files) >= 4, "增强图不足 4 张：%d" % len(files)
    return files[quad_idx - 1]


def kill_watermark(tile_img: Image.Image, quad_src: Image.Image) -> Image.Image:
    """用原象限（放大到 1024 对位）同区域羽化覆盖水印。"""
    src_up = quad_src.resize((1024, 1024), Image.LANCZOS)
    x0, y0, x1, y1 = WM_BOX
    patch = src_up.crop(WM_BOX)
    w, h = patch.size
    # 羽化 mask：左/上边缘 0→1 ramp，右/下到 1（补丁边界藏进渐变）
    yy, xx = np.mgrid[0:h, 0:w]
    fx = np.minimum(1.0, (xx + 1) / float(WM_FEATHER))
    fy = np.minimum(1.0, (yy + 1) / float(WM_FEATHER))
    mask = (fx * fy * 255).astype(np.uint8)
    tile_img.paste(patch, (x0, y0), Image.fromarray(mask))
    return tile_img


def tile_weight(size: int, inner_left: bool, inner_top: bool,
                inner_right: bool, inner_bottom: bool) -> np.ndarray:
    """tile 权重：内缘方向 FEATHER 宽 0→1 线性 ramp，其余为 1。"""
    w = np.ones((size, size), dtype=np.float32)
    ramp = np.linspace(0.0, 1.0, FEATHER, dtype=np.float32)
    if inner_left:
        w[:, :FEATHER] *= ramp[None, :]
    if inner_top:
        w[:FEATHER, :] *= ramp[:, None]
    if inner_right:
        w[:, -FEATHER:] *= ramp[::-1][None, :]
    if inner_bottom:
        w[-FEATHER:, :] *= ramp[::-1][:, None]
    return w


def main() -> None:
    # 象限定义：(画布位置, 内缘方向)
    quads = [
        (1, 0, 0, False, False, True, True),      # 左上：右/下内缘
        (2, TILE_POS * SCALE, 0, True, False, False, True),   # 右上
        (3, 0, TILE_POS * SCALE, False, True, True, False),   # 左下
        (4, TILE_POS * SCALE, TILE_POS * SCALE, True, True, False, False),  # 右下
    ]
    acc = np.zeros((GRID, GRID, 3), dtype=np.float64)
    wsum = np.zeros((GRID, GRID), dtype=np.float64)

    for idx, cx, cy, il, it, ir, ib in quads:
        out_path = find_output(idx)
        tile = Image.open(out_path).convert("RGB")
        src_quad = Image.open(os.path.join(QDIR, "quad%d.png" % idx)).convert("RGB")
        tile = kill_watermark(tile, src_quad)
        tile = tile.resize((TILE_IN * SCALE, TILE_IN * SCALE), Image.LANCZOS)  # 1152
        arr = np.asarray(tile).astype(np.float64)
        wt = tile_weight(TILE_IN * SCALE, il, it, ir, ib)
        acc[cy:cy + TILE_IN * SCALE, cx:cx + TILE_IN * SCALE] += arr * wt[..., None]
        wsum[cy:cy + TILE_IN * SCALE, cx:cx + TILE_IN * SCALE] += wt
        print("[INFO] quad%d 已合成（%s）" % (idx, os.path.basename(out_path)))

    canvas = np.clip(acc / np.maximum(wsum, 1e-9)[..., None], 0, 255).astype(np.uint8)
    img = Image.fromarray(canvas)
    img.save(OUT, optimize=True)
    print("[OK] 已拼接：", OUT, "（%d×%d，%.1f MB）"
          % (GRID, GRID, os.path.getsize(OUT) / 1048576.0))


if __name__ == "__main__":
    main()

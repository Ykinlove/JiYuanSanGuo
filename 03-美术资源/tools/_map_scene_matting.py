# -*- coding: utf-8 -*-
"""城池贴图边缘泛洪抠底（2026-09-27）。

背景：AI 生成的 12 张 1024x1024 城池贴图（scene_53~108）全部带白色纸底、
无 alpha，画到大地图上就是「城池旁边一片白」。项目约定：抠底必须用
「从边缘泛洪」，不能按颜色全图替换（会误删主体内部的高光白，如瀑布/云雾）。

算法：
  1. 候选集 = 与白色(250,250,250)最大通道差 <= tol 的像素；
  2. 从图像四边出发做连通泛洪（numpy 迭代膨胀），只吃与边缘连通的白底；
     主体内部被山体包住的白色云雾/瀑布不与边缘连通，得以保留；
  3. alpha 用 MinFilter(3) 收 1px 边，去掉白色残留描边；
  4. 原图已备份到 03-美术资源/AI源图/map_raw_backup/。
"""
import os
import sys
import numpy as np
from PIL import Image, ImageFilter

SRC_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "04-Demo", "assets", "sprites", "map")
TOL = 30          ## 与参考白的最大通道差容差（水彩纸底约 5~15，浅雾 20~40）
REF = np.array([250.0, 250.0, 250.0])
MIN_KEEP_RATIO = 0.30   ## 主体保留率低于此值视为抠穿（容差过大），拒绝写回


def matting(path: str) -> None:
    im = Image.open(path).convert("RGBA")
    arr = np.asarray(im).astype(np.float32)
    rgb, alpha = arr[..., :3], arr[..., 3]
    if alpha.min() < 250:
        print("  [SKIP] 已有透明通道，跳过")
        return
    cand = np.abs(rgb - REF).max(axis=2) <= TOL

    visited = np.zeros_like(cand)
    visited[0, :] = cand[0, :]
    visited[-1, :] = cand[-1, :]
    visited[:, 0] |= cand[:, 0]
    visited[:, -1] |= cand[:, -1]
    if not visited.any():
        print("  [WARN] 边缘无白底候选，检查 REF/TOL")
        return
    while True:
        grown = visited.copy()
        grown[1:, :] |= visited[:-1, :]
        grown[:-1, :] |= visited[1:, :]
        grown[:, 1:] |= visited[:, :-1]
        grown[:, :-1] |= visited[:, 1:]
        new = grown & cand & ~visited
        if not new.any():
            break
        visited |= new

    keep = 1.0 - visited.mean()
    if keep < MIN_KEEP_RATIO:
        print("  [ABORT] 主体保留率 %.1f%% < %d%%，疑似抠穿，拒绝写回" % (keep * 100, MIN_KEEP_RATIO * 100))
        return

    out = np.where(visited, 0, 255).astype(np.uint8)
    a_img = Image.fromarray(out, "L").filter(ImageFilter.MinFilter(3))  # 收 1px 白边
    arr[..., 3] = np.asarray(a_img)
    Image.fromarray(arr.astype(np.uint8), "RGBA").save(path)
    print("  [OK] 抠底完成，主体保留 %.1f%%，透明区 %.1f%%" % (keep * 100, visited.mean() * 100))


def main() -> None:
    targets = sys.argv[1:]
    files = sorted(f for f in os.listdir(SRC_DIR)
                   if f.endswith(".png") and (not targets or f in targets))
    for f in files:
        p = os.path.join(SRC_DIR, f)
        print(f)
        matting(p)


if __name__ == "__main__":
    main()

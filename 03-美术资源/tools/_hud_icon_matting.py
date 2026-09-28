#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""顶栏资源图标抠底（边缘泛洪法，工程惯例：不按色整体替换）。

【2026-09-28 用户反馈】金钱/粮草/木材/兵力四个 HUD 图标带 AI 源的近白底
（四角取样 RGB≈225），在墨色顶栏上是四块白疙瘩。
方法：从图像四边向内 BFS 泛洪，把与背景色连续（含抗锯齿过渡带）的像素置透明；
主体内部即使有相近浅色也不受影响（不连通即不抠）。
原图先备份到 03-美术资源/AI源图/ui_icons_raw/。
"""
import os
import shutil
from collections import deque
from PIL import Image

SRC = r"E:/Work buddy/2026-09-21-17-49-04/纪元三国/04-Demo/assets/sprites/ui/icons"
BACKUP = r"E:/Work buddy/2026-09-21-17-49-04/纪元三国/03-美术资源/AI源图/ui_icons_raw"
ICONS = ["icon_gold.png", "icon_food.png", "icon_wood.png", "icon_troop.png"]

TOL = 34          ## 与背景色的最大色距（含抗锯齿过渡带）
FEATHER_LUM = 205 ## 泛洪边界上更亮的邻接像素做半透明羽化


def dist2(c1, c2):
    return sum((a - b) ** 2 for a, b in zip(c1[:3], c2[:3]))


def matte(path):
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    px = im.load()

    # 背景基准色 = 四边像素均值
    edge = []
    for x in range(w):
        edge.append(px[x, 0]); edge.append(px[x, h - 1])
    for y in range(h):
        edge.append(px[0, y]); edge.append(px[w - 1, y])
    bg = tuple(sum(c[i] for c in edge) / len(edge) for i in range(3))

    # 边缘泛洪：与背景连续的浅色区域 → 透明
    seen = [[False] * w for _ in range(h)]
    q = deque()
    for x in range(w):
        q.append((x, 0)); q.append((x, h - 1))
    for y in range(h):
        q.append((0, y)); q.append((w - 1, y))
    for x, y in q:
        seen[y][x] = True

    boundary = []   ## 泛洪边界（用于羽化）
    while q:
        x, y = q.popleft()
        for nx, ny in ((x+1,y),(x-1,y),(x,y+1),(x,y-1)):
            if nx < 0 or ny < 0 or nx >= w or ny >= h or seen[ny][nx]:
                continue
            c = px[nx, ny]
            if dist2(c, bg) <= TOL * TOL * 3:
                seen[ny][nx] = True
                q.append((nx, ny))
            elif sum(c[:3]) / 3.0 >= FEATHER_LUM:
                # 亮色但超出容差 → 边界抗锯齿像素，半透明
                seen[ny][nx] = True
                boundary.append((nx, ny))

    for y in range(h):
        for x in range(w):
            if seen[y][x]:
                r, g, b, a = px[x, y]
                if (x, y) in set(boundary):
                    px[x, y] = (r, g, b, 110)
                else:
                    px[x, y] = (r, g, b, 0)

    out = path  # 原位覆盖（原图已备份）
    im.save(out)
    # 统计透明率供验收
    alpha = [px[x, y][3] for y in range(h) for x in range(w)]
    cleared = sum(1 for a in alpha if a == 0) / len(alpha)
    print(f"[OK] {os.path.basename(path)} 透明占比 {cleared:.0%}")


def main():
    os.makedirs(BACKUP, exist_ok=True)
    for name in ICONS:
        src = os.path.join(SRC, name)
        bak = os.path.join(BACKUP, name)
        if not os.path.exists(bak):
            shutil.copy2(src, bak)
        matte(src)
    print(f"\n原图备份：{BACKUP}")


if __name__ == "__main__":
    main()

# -*- coding: utf-8 -*-
"""通用市民立绘入库（2026-10-01）：6 张按身份复用的城内/世界 NPC 立绘 → civ_<type>.png
管线与 _npc_batch2_process.py 一致（边缘泛洪抠底，防误删白衣）。"""
import os
import shutil
from collections import deque

from PIL import Image

GEN = r"E:\Work buddy\2026-09-21-17-49-04\generated-images"
DEST = r"E:\Work buddy\2026-09-21-17-49-04\纪元三国\04-Demo\assets\sprites\npcs"
RAW_ARCHIVE = r"E:\Work buddy\2026-09-21-17-49-04\纪元三国\03-美术资源\AI源图\NPC立绘二批"

P = "二次元国风_2D_游戏角色立绘_全身站姿_"
MAPPING = [
    ("civ_resident",   P + "东汉末年普通城中居_2026-10-01T03-02-55.png"),
    ("civ_elder",      P + "东汉末年城中老者__2026-10-01T03-02-56.png"),
    ("civ_youth",      P + "东汉末年城中后生青_2026-10-01T03-03-08.png"),
    ("civ_hero",       P + "东汉末年路过的游侠_2026-10-01T03-03-08.png"),
    ("civ_merchant",   P + "东汉末年市集商人掌_2026-10-01T03-03-34.png"),
    ("civ_blacksmith", P + "东汉末年铁匠_赤褐_2026-10-01T03-03-35.png"),
]

THRESH = 45
DESPILL = 228
MARGIN_RATIO = 0.05
TARGET_H = 768


def flood_bg(im):
    w, h = im.size
    px = im.load()
    visited = bytearray(w * h)
    q = deque()

    def is_bg(x, y):
        r, g, b, a = px[x, y]
        return a > 0 and r >= 255 - THRESH and g >= 255 - THRESH and b >= 255 - THRESH

    for x in range(w):
        for y in (0, h - 1):
            i = y * w + x
            if not visited[i] and is_bg(x, y):
                visited[i] = 1
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            i = y * w + x
            if not visited[i] and is_bg(x, y):
                visited[i] = 1
                q.append((x, y))
    while q:
        x, y = q.popleft()
        px[x, y] = (0, 0, 0, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h:
                i = ny * w + nx
                if not visited[i] and is_bg(nx, ny):
                    visited[i] = 1
                    q.append((nx, ny))


def despill(im):
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if 0 < a < 255 and r >= DESPILL and g >= DESPILL and b >= DESPILL:
                px[x, y] = (r, g, b, 0)


def main():
    os.makedirs(RAW_ARCHIVE, exist_ok=True)
    for npc_id, src in MAPPING:
        sp = os.path.join(GEN, src)
        if not os.path.exists(sp):
            print("  [FAIL] %s :: 源图缺失 %s" % (npc_id, src))
            continue
        im = Image.open(sp).convert("RGBA")
        flood_bg(im)
        despill(im)
        bbox = im.getbbox()
        if bbox:
            l, t, r, b = bbox
            mw = int((r - l) * MARGIN_RATIO)
            mh = int((b - t) * MARGIN_RATIO)
            im = im.crop((max(0, l - mw), max(0, t - mh),
                          min(im.width, r + mw), min(im.height, b + mh)))
        if im.height > TARGET_H:
            s = TARGET_H / im.height
            im = im.resize((max(1, int(im.width * s)), TARGET_H), Image.LANCZOS)
        im.save(os.path.join(DEST, npc_id + ".png"))
        shutil.copy2(sp, os.path.join(RAW_ARCHIVE, npc_id + "_raw.png"))
        print("  [OK] %-16s -> %s" % (npc_id, im.size))


if __name__ == "__main__":
    main()

# -*- coding: utf-8 -*-
"""立绘处理：浅灰/白渐变底抠除 -> 裁剪 -> 统一高度 -> 按 id 命名。
一次性脚本，完成后可删。"""
import glob
import os
import shutil
from collections import deque

from PIL import Image

D = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国\04-Demo\assets\sprites\npcs'
RAW = os.path.join(D, '_raw')
SRC_BANK = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国\03-美术资源\AI源图\npcs'
os.makedirs(RAW, exist_ok=True)
os.makedirs(SRC_BANK, exist_ok=True)

PROC_W, PROC_H = 512, 768
OUT_H = 768
LIGHT_MIN = 198      # 背景亮度下限（近中性浅色）
SAT_MAX = 30         # 背景饱和度上限（max-min）
DESPILL = 205

# 文件名关键字 -> 输出名列表（同一张可对应多个 id，如既是 NPC 又是武将）
MAPPING = [
    ('寨中长者', ['npc_elder']),
    ('武士向导', ['npc_meng_qian']),
    ('少年随从', ['npc_a_hei']),
    ('壮年铁匠', ['npc_blacksmith']),
    ('行脚商人', ['npc_traveler']),
    ('南蛮女将', ['npc_zhurong', '268']),
    ('南蛮王', ['npc_meng_huo', '469']),
    ('巫者将领', ['100']),
    ('藤甲兵将领', ['205']),
    ('巨汉战士', ['243']),
    ('部落首领', ['346']),
    ('步卒首领', ['419']),
    ('年轻蛮将', ['471']),
]


def outputs_for(name):
    for kw, outs in MAPPING:
        if kw in name:
            return outs
    return None


def is_bg_px(px, x, y):
    r, g, b, a = px[x, y]
    if a == 0:
        return False
    mn = min(r, g, b)
    if mn < LIGHT_MIN:
        return False
    return (max(r, g, b) - mn) <= SAT_MAX


def flood_bg(im):
    w, h = im.size
    px = im.load()
    visited = bytearray(w * h)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            i = y * w + x
            if not visited[i] and is_bg_px(px, x, y):
                visited[i] = 1
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            i = y * w + x
            if not visited[i] and is_bg_px(px, x, y):
                visited[i] = 1
                q.append((x, y))
    while q:
        x, y = q.popleft()
        px[x, y] = (0, 0, 0, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h:
                i = ny * w + nx
                if not visited[i] and is_bg_px(px, nx, ny):
                    visited[i] = 1
                    q.append((nx, ny))


def despill(im):
    w, h = im.size
    px = im.load()
    clear = []
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            if min(r, g, b) >= DESPILL and (max(r, g, b) - min(r, g, b)) <= SAT_MAX:
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and px[nx, ny][3] == 0:
                        clear.append((x, y))
                        break
    for x, y in clear:
        px[x, y] = (0, 0, 0, 0)


def main():
    src_dir = RAW if glob.glob(os.path.join(RAW, '*.png')) else D
    files = [f for f in sorted(glob.glob(os.path.join(src_dir, '*.png')))
             if not os.path.basename(f).startswith('_')]
    print('来源 %s 共 %d 张' % (os.path.basename(src_dir), len(files)))
    for f in files:
        base = os.path.basename(f)
        outs = outputs_for(base)
        if not outs:
            print('  未匹配:', base[:40])
            continue
        im = Image.open(f).convert('RGBA').resize((PROC_W, PROC_H), Image.LANCZOS)
        flood_bg(im)
        despill(im)
        bbox = im.getbbox()
        if bbox is None:
            print('  空:', base[:30])
            continue
        crop = im.crop(bbox)
        cw, ch = crop.size
        scale = OUT_H / float(ch)
        nw = max(8, int(round(cw * scale)))
        final = crop.resize((nw, OUT_H), Image.LANCZOS)
        for o in outs:
            final.save(os.path.join(D, o + '.png'))
        # 源图归档到美术资源库
        shutil.move(f, os.path.join(SRC_BANK, base))
        print('  OK %-28s -> %s  (%dx%d)' % (base[:26], ','.join(outs), nw, OUT_H))


if __name__ == '__main__':
    main()

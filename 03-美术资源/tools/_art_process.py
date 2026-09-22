# -*- coding: utf-8 -*-
"""把 AI 生成的近白底图处理成透明底游戏图标：泛洪抠底 -> 去白边 -> 裁剪 -> 留白 -> 缩放。
一次性脚本，处理完可删。来源优先 _raw/（原图归档目录）。"""
import glob
import os
import shutil
from collections import deque

from PIL import Image

D = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国\04-Demo\assets\sprites\city_icons'
RAW = os.path.join(D, '_raw')
os.makedirs(RAW, exist_ok=True)

MAPPING = [
    ('城池', 'city', 128),
    ('村落', 'village', 128),
    ('关隘', 'pass', 128),
    ('遗迹', 'ruin', 128),
    ('名胜', 'landmark', 128),
]
WORK = 512
THRESH = 45
DESPILL = 228
MARGIN_RATIO = 0.06


def key_of(name):
    for cn, en, sz in MAPPING:
        if cn in name:
            return en, sz
    return None, None


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
            idx = y * w + x
            if not visited[idx] and is_bg(x, y):
                visited[idx] = 1
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            idx = y * w + x
            if not visited[idx] and is_bg(x, y):
                visited[idx] = 1
                q.append((x, y))
    while q:
        x, y = q.popleft()
        px[x, y] = (0, 0, 0, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h:
                idx = ny * w + nx
                if not visited[idx] and is_bg(nx, ny):
                    visited[idx] = 1
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
            if r >= DESPILL and g >= DESPILL and b >= DESPILL:
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
    print('来源目录：%s  待处理 %d 张' % (os.path.basename(src_dir), len(files)))
    for f in files:
        base = os.path.basename(f)
        en, sz = key_of(base)
        if en is None:
            print('  跳过:', base)
            continue
        im = Image.open(f).convert('RGBA').resize((WORK, WORK), Image.LANCZOS)
        flood_bg(im)
        despill(im)
        bbox = im.getbbox()
        if bbox is None:
            print('  空图:', base)
            continue
        crop = im.crop(bbox)
        cw, ch = crop.size
        side = max(cw, ch)
        square = Image.new('RGBA', (side, side), (0, 0, 0, 0))
        square.paste(crop, ((side - cw) // 2, (side - ch) // 2), crop)
        # 留白按「目标尺寸」计算
        margin = max(1, int(sz * MARGIN_RATIO))
        content = sz - 2 * margin
        scaled = square.resize((content, content), Image.LANCZOS)
        final = Image.new('RGBA', (sz, sz), (0, 0, 0, 0))
        final.paste(scaled, (margin, margin), scaled)
        final.save(os.path.join(D, en + '.png'))
        if src_dir == D:
            shutil.move(f, os.path.join(RAW, base))
        print('  OK %-14s %dx%d  content=%d' % (en + '.png', sz, sz, content))


if __name__ == '__main__':
    main()

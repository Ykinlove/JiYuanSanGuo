# -*- coding: utf-8 -*-
"""主菜单六子项美术图标后处理（复用 _encounter_art_process.py 管线）。

  03-美术资源/AI源图/menu_icons/_raw/<action>/ 唯一原图
    -> 泛洪抠白底 -> despill 去白边 -> 裁剪内容 -> 正方化 -> 128×128 透明底
    -> 04-Demo/assets/sprites/menu_icons/<action>.png

原图归档 _done/<action>/。
"""
import glob
import os
import shutil
from collections import deque

from PIL import Image

ROOT = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国\03-美术资源\AI源图\menu_icons'
RAW = os.path.join(ROOT, '_raw')
DONE = os.path.join(ROOT, '_done')
OUT = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国\04-Demo\assets\sprites\menu_icons'

IDS = ['quest', 'heroes', 'player', 'achieve', 'diplo', 'system']

WORK = 512
THRESH = 45
DESPILL = 228
SIZE = 128
MARGIN_RATIO = 0.04


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


def _unique_png(folder):
    for ext in ('*.png', '*.webp', '*.jpg', '*.jpeg'):
        files = [f for f in sorted(glob.glob(os.path.join(folder, ext)))
                 if not os.path.basename(f).startswith('.')]
        if files:
            return files[0]
    return None


def process(action):
    src_dir = os.path.join(RAW, action)
    src = _unique_png(src_dir)
    if src is None:
        src = _unique_png(os.path.join(DONE, action))
    if src is None:
        print('  缺图: %s' % action)
        return False

    im = Image.open(src).convert('RGBA').resize((WORK, WORK), Image.LANCZOS)
    flood_bg(im)
    despill(im)
    bbox = im.getbbox()
    if bbox is None:
        print('  抠图后为空: %s' % action)
        return False
    crop = im.crop(bbox)
    cw, ch = crop.size
    side = max(cw, ch)
    square = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    square.paste(crop, ((side - cw) // 2, (side - ch) // 2), crop)

    margin = max(1, int(SIZE * MARGIN_RATIO))
    content = SIZE - 2 * margin
    scaled = square.resize((content, content), Image.LANCZOS)
    final = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    final.paste(scaled, (margin, margin), scaled)

    os.makedirs(OUT, exist_ok=True)
    final.save(os.path.join(OUT, action + '.png'))

    if os.path.dirname(src) == src_dir:
        dst_dir = os.path.join(DONE, action)
        os.makedirs(dst_dir, exist_ok=True)
        shutil.move(src, os.path.join(dst_dir, os.path.basename(src)))
    print('  OK %-12s %dx%d' % (action + '.png', SIZE, SIZE))
    return True


def main():
    print('输出目录：%s' % OUT)
    ok = 0
    for action in IDS:
        if process(action):
            ok += 1
    print('完成 %d / %d' % (ok, len(IDS)))


if __name__ == '__main__':
    main()

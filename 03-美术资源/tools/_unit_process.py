# -*- coding: utf-8 -*-
"""兵种图标处理：泛洪抠底 -> 去白边 -> 裁剪 -> 留白 -> 128x128 -> 按 id 命名。"""
import glob
import os
import shutil
from collections import deque

from PIL import Image

D = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国\04-Demo\assets\sprites\units'
RAW = os.path.join(D, '_raw')
SRC_BANK = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国\03-美术资源\AI源图\units'
os.makedirs(RAW, exist_ok=True)
os.makedirs(SRC_BANK, exist_ok=True)

WORK = 512
THRESH = 45
DESPILL = 228
SZ = 128
MARGIN_RATIO = 0.06

MAPPING = [
    ('盾牌与短剑', 'infantry'),
    ('红缨长枪', 'spearman'),
    ('马头侧面轮廓', 'cavalry'),
    ('马头侧面与一张', 'qiang_archer'),
    ('弯弓与一壶箭矢', 'archer'),
    ('弩机与弩矢', 'crossbow'),
    ('披着重甲的冲锋', 'heavy_cavalry'),
    ('一匹披着重甲', 'heavy_cavalry'),
    ('战象头部', 'elephant'),
    ('藤编护甲', 'rattan'),
    ('船桨', 'navy'),
    ('猛虎头', 'tiger_cavalry'),
    ('白色神骏马头', 'white_horse'),
    ('马头侧面与一张弯弓', 'qiang_archer'),
    ('古代战戟', 'great_halberd'),
    ('盘龙长枪', 'dragon_spear'),
]


def key_of(name):
    for kw, out in MAPPING:
        if kw in name:
            return out
    return None


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
    w, h = im.size
    px = im.load()
    clear = []
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            if min(r, g, b) >= DESPILL and (max(r, g, b) - min(r, g, b)) <= 30:
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
    done = []
    for f in files:
        base = os.path.basename(f)
        en = key_of(base)
        if not en:
            print('  未匹配:', base[:40])
            continue
        im = Image.open(f).convert('RGBA').resize((WORK, WORK), Image.LANCZOS)
        flood_bg(im)
        despill(im)
        bbox = im.getbbox()
        if bbox is None:
            print('  空:', base[:30])
            continue
        crop = im.crop(bbox)
        cw, ch = crop.size
        side = max(cw, ch)
        sq = Image.new('RGBA', (side, side), (0, 0, 0, 0))
        sq.paste(crop, ((side - cw) // 2, (side - ch) // 2), crop)
        margin = max(1, int(SZ * MARGIN_RATIO))
        content = SZ - 2 * margin
        sc = sq.resize((content, content), Image.LANCZOS)
        final = Image.new('RGBA', (SZ, SZ), (0, 0, 0, 0))
        final.paste(sc, (margin, margin), sc)
        final.save(os.path.join(D, en + '.png'))
        shutil.move(f, os.path.join(SRC_BANK, base))
        done.append(en)
        print('  OK %-14s' % (en + '.png'))
    print('共生成 %d 个兵种图标' % len(done))


if __name__ == '__main__':
    main()

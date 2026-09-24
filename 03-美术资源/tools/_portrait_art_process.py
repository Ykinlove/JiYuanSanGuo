# -*- coding: utf-8 -*-
"""P3-4 主角/创角立绘后处理。

流程：复用 encounters 管线的 flood_bg/despill，把 03-美术资源/AI源图/portraits/_raw/<id>/
里的唯一 png 处理成 256×256 透明底，输出到 04-Demo/assets/sprites/player/<id>.png。
"""
import glob
import os
import shutil
from collections import deque

from PIL import Image

ROOT = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国\03-美术资源\AI源图\portraits'
RAW = os.path.join(ROOT, '_raw')
DONE = os.path.join(ROOT, '_done')
OUT = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国\04-Demo\assets\sprites\player'

IDS = [
    'portrait_male_01', 'portrait_male_02', 'portrait_male_03',
    'portrait_male_04', 'portrait_male_05',
    'portrait_female_01', 'portrait_female_02', 'portrait_female_03',
    'portrait_female_04', 'portrait_female_05',
]

WORK = 512
THRESH = 45      # 泛洪抠底容差
DESPILL = 228    # 去白边阈值
SIZE = 256       # 最终透明底尺寸（大地图 token 和创角预览通用）
MARGIN_RATIO = 0.06


def flood_bg(im):
    """从四边泛洪，把连通的近白区域变透明"""
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
    """抹掉紧贴透明区的发白像素，去掉抠图后的一圈白边"""
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


def _unique_png(folder: str):
    """取目录里唯一一张图片"""
    for ext in ('*.png', '*.webp', '*.jpg', '*.jpeg'):
        files = [f for f in sorted(glob.glob(os.path.join(folder, ext)))
                 if not os.path.basename(f).startswith('.')]
        if files:
            return files[0]
    return None


def process(pid: str) -> bool:
    src_dir = os.path.join(RAW, pid)
    src = _unique_png(src_dir)
    if src is None:
        src = _unique_png(os.path.join(DONE, pid))
    if src is None:
        print('  缺图: %s' % pid)
        return False

    im = Image.open(src).convert('RGBA').resize((WORK, WORK), Image.LANCZOS)
    flood_bg(im)
    despill(im)
    bbox = im.getbbox()
    if bbox is None:
        print('  抠图后为空: %s' % pid)
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
    final.save(os.path.join(OUT, pid + '.png'))

    if os.path.dirname(src) == src_dir:
        dst_dir = os.path.join(DONE, pid)
        os.makedirs(dst_dir, exist_ok=True)
        shutil.move(src, os.path.join(dst_dir, os.path.basename(src)))
    print('  OK %-26s %dx%d' % (pid + '.png', SIZE, SIZE))
    return True


def main():
    print('输出目录：%s' % OUT)
    ok = 0
    for pid in IDS:
        if process(pid):
            ok += 1
    print('完成 %d / %d' % (ok, len(IDS)))


if __name__ == '__main__':
    main()

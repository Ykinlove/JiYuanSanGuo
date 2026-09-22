# -*- coding: utf-8 -*-
"""批次二素材处理：城内建筑贴图 + 都城专属地图贴图。

相对批次一的增强：抠底后增加【最大连通域过滤】，只保留主体，
清掉 AI 图右侧残留的浅色水印与零散杂点。

- 建筑：res://assets/sprites/city/<key>.png   512x512，主体底边对齐、水平居中
- 都城：res://assets/sprites/map/<city_id>.png 256x256，主体居中带留白
"""
import glob
import os
import sys
from collections import deque

from PIL import Image

ROOT = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国'
DEMO = os.path.join(ROOT, '04-Demo')
BANK = os.path.join(ROOT, '03-美术资源', 'AI源图')

# 建筑：文件名关键字 -> 输出 id
# 说明：scenes6 每城的 buildings dict 共 12 个 key。
#   已有贴图 5：hall/tavern/barracks/market(shop)/smith。
#   本表补齐 7 个新 key：inn/house/shrine/stable/riceshop/dojo/clinic。
#   注意 riceshop 是连写（非 rice_shop）。
BUILDING_MAP = [
    ('官府', 'hall', 512),
    ('衙门', 'hall', 512),
    ('酒馆', 'tavern', 512),   # tavern=酒馆（与 inn 客栈区分）
    ('客栈', 'inn', 512),
    ('旅店', 'inn', 512),
    ('民居', 'house', 512),
    ('民宅', 'house', 512),
    ('农舍', 'house', 512),
    ('祠堂', 'shrine', 512),
    ('马厩', 'stable', 512),
    ('粮铺', 'riceshop', 512),
    ('米店', 'riceshop', 512),
    ('粮店', 'riceshop', 512),
    ('武馆', 'dojo', 512),
    ('练功', 'dojo', 512),
    ('医馆', 'clinic', 512),
    ('药铺', 'clinic', 512),
    ('兵营', 'barracks', 512),
    ('营地', 'barracks', 512),
    ('市集', 'market', 512),
    ('集市', 'market', 512),
    ('铁匠', 'smith', 512),
]
# 都城：文件名关键字 -> 输出 city_id（cities.json 的 id）
CITY_MAP = [
    ('长安', 'scene_17', 256),
    ('洛阳', 'scene_19', 256),
    ('许昌', 'scene_21', 256),
    ('成都', 'scene_27', 256),
    ('建业', 'scene_37', 256),
    ('下邳', 'scene_38', 256),
]

WORK = 1024
WHITE_KEEP = 236      # 三通道均 >= 此值视为背景白
DESPILL = 232         # 与透明区相邻的接近白像素一并清除（去白边）
MIN_BLOB_RATIO = 0.02  # 连通域小于主体面积的此比例则丢弃


def _is_bg(px, x, y):
    r, g, b, a = px[x, y]
    return a > 0 and r >= WHITE_KEEP and g >= WHITE_KEEP and b >= WHITE_KEEP


def flood_bg(im):
    """从四边泛洪抠除连通的白色背景（保留主体内部的白色高光）。"""
    w, h = im.size
    px = im.load()
    visited = bytearray(w * h)
    q = deque()

    def push(x, y):
        i = y * w + x
        if not visited[i] and _is_bg(px, x, y):
            visited[i] = 1
            q.append((x, y))

    for x in range(w):
        push(x, 0)
        push(x, h - 1)
    for y in range(h):
        push(0, y)
        push(w - 1, y)

    while q:
        x, y = q.popleft()
        px[x, y] = (0, 0, 0, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h:
                push(nx, ny)


def despill(im):
    """清除紧贴透明区的近白像素，消除抠底残留的白边。"""
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


def keep_main_blob(im):
    """只保留面积最大的不透明连通域，丢弃水印与零散碎块。"""
    w, h = im.size
    px = im.load()
    label = [-1] * (w * h)
    blobs = []
    for sy in range(h):
        for sx in range(w):
            i = sy * w + sx
            if label[i] != -1 or px[sx, sy][3] == 0:
                continue
            bid = len(blobs)
            q = deque([(sx, sy)])
            label[i] = bid
            cells = []
            while q:
                x, y = q.popleft()
                cells.append((x, y))
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h:
                        j = ny * w + nx
                        if label[j] == -1 and px[nx, ny][3] > 0:
                            label[j] = bid
                            q.append((nx, ny))
            blobs.append(cells)

    if not blobs:
        return 0
    main = max(range(len(blobs)), key=lambda k: len(blobs[k]))
    keep_size = len(blobs[main])
    dropped = 0
    for k, cells in enumerate(blobs):
        if k == main or len(cells) >= keep_size * MIN_BLOB_RATIO:
            continue
        for x, y in cells:
            px[x, y] = (0, 0, 0, 0)
        dropped += 1
    return dropped


def load_clean(path):
    im = Image.open(path).convert('RGBA').resize((WORK, WORK), Image.LANCZOS)
    flood_bg(im)
    despill(im)
    dropped = keep_main_blob(im)
    bbox = im.getbbox()
    if bbox is None:
        return None, dropped
    return im.crop(bbox), dropped


def place_building(crop, size):
    """缩放到目标宽度，高度按比例，画布【紧贴内容】不留透明边。

    紧贴很关键：调用方按「贴图宽度 → 世界宽度」等比换算后，
    贴图高度就等于建筑的实际世界高度，牌匾才能贴着屋顶摆放。
    若留正方形空白，会把空白也算进高度，牌匾被抬到空中。
    """
    cw, ch = crop.size
    nw = size
    nh = max(1, int(round(ch * float(size) / float(cw))))
    cap = int(size * 1.8)          # 极端细高图的保护上限
    if nh > cap:
        nh = cap
        nw = max(1, int(round(cw * float(cap) / float(ch))))
    return crop.resize((nw, nh), Image.LANCZOS)


def place_icon(crop, size):
    """正方形化 + 居中留白。"""
    cw, ch = crop.size
    side = max(cw, ch)
    square = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    square.paste(crop, ((side - cw) // 2, (side - ch) // 2), crop)
    margin = max(1, int(size * 0.06))
    content = size - 2 * margin
    scaled = square.resize((content, content), Image.LANCZOS)
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    canvas.paste(scaled, (margin, margin), scaled)
    return canvas


def match(name, table):
    for kw, out, size in table:
        if kw in name:
            return out, size
    return None, None


def run(kind, table, out_dir_rel):
    src_dir = os.path.join(BANK, kind)
    out_dir = os.path.join(DEMO, out_dir_rel)
    os.makedirs(out_dir, exist_ok=True)
    files = [f for f in sorted(glob.glob(os.path.join(src_dir, '*.png')))
             if not os.path.basename(f).startswith('_')]
    print('=== [%s] 源 %d 张 -> %s ===' % (kind, len(files), out_dir_rel))
    ok = 0
    for f in files:
        base = os.path.basename(f)
        out, size = match(base, table)
        if out is None:
            print('  未匹配，跳过:', base[:44])
            continue
        crop, dropped = load_clean(f)
        if crop is None:
            print('  空图:', base[:44])
            continue
        final = (place_building if kind == 'city' else place_icon)(crop, size)
        dst = os.path.join(out_dir, out + '.png')
        final.save(dst)
        ok += 1
        print('  OK %-16s %dx%d  源裁剪 %dx%d  丢弃碎块 %d'
              % (out + '.png', final.size[0], final.size[1],
                 crop.size[0], crop.size[1], dropped))
    print('  --> 产出 %d 张\n' % ok)
    return ok


def main():
    n1 = run('city', BUILDING_MAP, os.path.join('assets', 'sprites', 'city'))
    n2 = run('map', CITY_MAP, os.path.join('assets', 'sprites', 'map'))
    print('合计 %d 张' % (n1 + n2))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    main()

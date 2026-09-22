# -*- coding: utf-8 -*-
"""全量武将立绘批量处理管线（升级版 _portrait_process.py）。
用法：AI 出图时把每张源图存到 `AI源图/npcs/<id>_<名字>.png`，
运行本脚本：自动对所有待处理源图做
  边缘泛洪抠底 -> 去边 -> 裁剪 -> 统一 768 高 -> 按数字 id 命名
  存入 `04-Demo/assets/sprites/npcs/<id>.png`，并归档源图到 `AI源图/npcs/_done/`。
支持 男/女 输出规模一致；同名已存在跳过（幂等）。
"""
import glob
import json
import os
import re
import shutil
import sys
from collections import deque

from PIL import Image

sys.stdout.reconfigure(encoding='utf-8')

ROOT = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国'
DEMO = os.path.join(ROOT, '04-Demo')
SPR = os.path.join(DEMO, 'assets', 'sprites', 'npcs')
RAW = os.path.join(ROOT, '03-美术资源', 'AI源图', 'npcs')
DONE = os.path.join(RAW, '_done')
os.makedirs(RAW, exist_ok=True)
os.makedirs(DONE, exist_ok=True)

PROC_W, PROC_H = 512, 768   # 处理画布
OUT_H = 768                 # 输出统一高度
LIGHT_MIN = 195             # 白底背景亮度下限
SAT_MAX = 30                # 白底背景饱和度上限
GRAY_MIN = 95               # 灰底渐变亮度下限
GRAY_SAT = 14               # 灰底饱和度上限
DARK_MAX = 26               # 黑底亮度上限
DARK_SAT = 12               # 黑底饱和度上限
DESPILL = 205


def hsv_qual(r, g, b):
    return max(r, g, b), max(r, g, b) - min(r, g, b)


def detect_bg_mode(px, w, h):
    """按四角+边中采样判定背景：dark / gray / light。"""
    pts = [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3),
           (w // 2, 2), (w // 2, h - 3), (2, h // 2), (w - 3, h // 2)]
    vals = sorted(max(px[x, y][:3]) for x, y in pts)
    v = vals[len(vals) // 2]
    if v <= 45:
        return 'dark'
    if v < 185:
        return 'gray'
    return 'light'

# 别名：某些 id 与 NPC 字符串 id 对应同一人（与批一 MAPPING 保持一致的补充）
# key=源图文件名关键字 -> 数字 id 列表（同一图可命中多个 id，如祝融=268+npcs/npc_zhurong）
ALIAS = {
    '祝融': ['268'],
    '孟获': ['469'],
}


def extract_id(fname):
    """从文件名提取数字 id。优先匹配纯数字前缀，其次找 _gen_list 里的名字。"""
    m = re.match(r'^(\d+)', os.path.splitext(fname)[0])
    if m:
        return m.group(1)
    return None


def bg_pred(mode, r, g, b):
    v, s = max(r, g, b), max(r, g, b) - min(r, g, b)
    if mode == 'dark':
        return v <= DARK_MAX and s <= DARK_SAT
    if mode == 'gray':
        return v >= GRAY_MIN and s <= GRAY_SAT
    return min(r, g, b) >= LIGHT_MIN and s <= SAT_MAX


def flood_bg(im, mode):
    w, h = im.size
    px = im.load()
    visited = bytearray(w * h)
    q = deque()

    def seed(x, y):
        i = y * w + x
        if not visited[i]:
            r, g, b, a = px[x, y]
            if a != 0 and bg_pred(mode, r, g, b):
                visited[i] = 1
                q.append((x, y))

    for x in range(w):
        seed(x, 0)
        seed(x, h - 1)
    for y in range(h):
        seed(0, y)
        seed(w - 1, y)
    while q:
        x, y = q.popleft()
        px[x, y] = (0, 0, 0, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h:
                i = ny * w + nx
                if not visited[i]:
                    r, g, b, a = px[nx, ny]
                    if a != 0 and bg_pred(mode, r, g, b):
                        visited[i] = 1
                        q.append((nx, ny))


def remove_glow(im):
    """黑底专用：删脚下白色光晕（整团位于下半部的扁平亮部连通域）。"""
    w, h = im.size

    def flat_white(r, g, b):
        v, s = max(r, g, b), max(r, g, b) - min(r, g, b)
        return v >= 200 and s <= 12

    px = im.load()
    visited = bytearray(w * h)
    for sy in range(int(h * 0.5), h):
        for sx in range(w):
            i0 = sy * w + sx
            if visited[i0]:
                continue
            r, g, b, a = px[sx, sy]
            if a == 0 or not flat_white(r, g, b):
                continue
            comp = [(sx, sy)]
            visited[i0] = 1
            q = deque(comp)
            min_y = sy
            while q:
                x, y = q.popleft()
                if y < min_y:
                    min_y = y
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h:
                        i = ny * w + nx
                        if not visited[i]:
                            r2, g2, b2, a2 = px[nx, ny]
                            if a2 != 0 and flat_white(r2, g2, b2):
                                visited[i] = 1
                                q.append((nx, ny))
                                comp.append((nx, ny))
            if min_y > int(h * 0.55) and len(comp) > 300:
                for x, y in comp:
                    px[x, y] = (0, 0, 0, 0)

    # 白色光晕删完后常剩一圈中性色墨圈：全图连通域标记，
    # 只删"整个连通域位于下半部"的孤立中性色块（人物毛发/靴甲均向上连通身体，不受影响）
    def neutral(r, g, b):
        v, s = max(r, g, b), max(r, g, b) - min(r, g, b)
        return v <= 200 and s <= 22

    visited = bytearray(w * h)
    for sy in range(h):
        for sx in range(w):
            i0 = sy * w + sx
            if visited[i0]:
                continue
            r, g, b, a = px[sx, sy]
            if a == 0 or not neutral(r, g, b):
                continue
            comp = [(sx, sy)]
            visited[i0] = 1
            q = deque(comp)
            min_y = sy
            while q:
                x, y = q.popleft()
                if y < min_y:
                    min_y = y
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h:
                        i = ny * w + nx
                        if not visited[i]:
                            r2, g2, b2, a2 = px[nx, ny]
                            if a2 != 0 and neutral(r2, g2, b2):
                                visited[i] = 1
                                q.append((nx, ny))
                                comp.append((nx, ny))
            if int(h * 0.55) < min_y and 50 <= len(comp) <= 30000:
                for x, y in comp:
                    px[x, y] = (0, 0, 0, 0)


def remove_corner_debris(im):
    """删除边缘带内的小孤立块（AI 签名/小印章），大物体（刀枪/手脚）保留。"""
    w, h = im.size
    px = im.load()
    band = int(min(w, h) * 0.09)
    visited = bytearray(w * h)
    edge_seeds = set()
    for x in range(w):
        edge_seeds.add((x, 0)); edge_seeds.add((x, band))
        edge_seeds.add((x, h - 1)); edge_seeds.add((x, h - 1 - band))
    for y in range(h):
        edge_seeds.add((0, y)); edge_seeds.add((band, y))
        edge_seeds.add((w - 1, y)); edge_seeds.add((w - 1 - band, y))
    for sx, sy in edge_seeds:
        i0 = sy * w + sx
        if visited[i0]:
            continue
        r, g, b, a = px[sx, sy]
        if a == 0:
            continue
        comp = [(sx, sy)]
        visited[i0] = 1
        q = deque(comp)
        while q:
            x, y = q.popleft()
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h:
                    i = ny * w + nx
                    if not visited[i]:
                        r2, g2, b2, a2 = px[nx, ny]
                        in_band = (nx < band or nx >= w - band or ny < band or ny >= h - band)
                        if a2 != 0 and in_band:
                            visited[i] = 1
                            q.append((nx, ny))
                            comp.append((nx, ny))
        if len(comp) <= 60:
            for x, y in comp:
                px[x, y] = (0, 0, 0, 0)


def despill(im, mode='light'):
    w, h = im.size
    px = im.load()
    clear = []
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            v, s = max(r, g, b), max(r, g, b) - min(r, g, b)
            light_fringe = min(r, g, b) >= DESPILL and s <= SAT_MAX
            dark_fringe = mode == 'dark' and v <= 42 and s <= 16
            if light_fringe or dark_fringe:
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and px[nx, ny][3] == 0:
                        clear.append((x, y))
                        break
    for x, y in clear:
        px[x, y] = (0, 0, 0, 0)


def main():
    files = [f for f in sorted(glob.glob(os.path.join(RAW, '*.png')))
             if not os.path.basename(f).startswith('_')]
    if not files:
        print('AI源图/npcs/ 下无待处理源图。')
        return
    print('待处理源图 %d 张' % len(files))
    ok = skip = fail = 0
    for f in files:
        base = os.path.basename(f)
        rid = extract_id(base)
        if not rid:
            # 尝试别名
            match = [k for k in ALIAS if k in base]
            if not match:
                print('  未识别id:', base[:40])
                fail += 1
                continue
            rid = ALIAS[match[0]]
        else:
            rid = [rid]
        # 幂等：所有目标 id 已存在则跳过
        if all(os.path.exists(os.path.join(SPR, r + '.png')) for r in rid):
            print('  已存在跳过:', base[:40])
            shutil.move(f, os.path.join(DONE, base))
            skip += 1
            continue
        im = Image.open(f).convert('RGBA').resize((PROC_W, PROC_H), Image.LANCZOS)
        mode = detect_bg_mode(im.load(), PROC_W, PROC_H)
        flood_bg(im, mode)
        if mode == 'dark':
            remove_glow(im)
        remove_corner_debris(im)
        despill(im, mode)
        bbox = im.getbbox()
        if bbox is None:
            print('  空图:', base[:30])
            fail += 1
            continue
        crop = im.crop(bbox)
        cw, ch = crop.size
        scale = OUT_H / float(ch)
        nw = max(8, int(round(cw * scale)))
        final = crop.resize((nw, OUT_H), Image.LANCZOS)
        for r in rid:
            final.save(os.path.join(SPR, r + '.png'))
            ok += 1
        shutil.move(f, os.path.join(DONE, base))
        print('  OK %-26s -> %s  (%dx%d)' % (base[:26], ','.join(rid), nw, OUT_H))
    print('完成: 入库 %d 文件, 跳过已存在 %d, 未识别/空 %d' % (ok, skip, fail))


if __name__ == '__main__':
    main()

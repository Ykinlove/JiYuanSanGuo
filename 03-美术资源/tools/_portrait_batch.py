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
LIGHT_MIN = 198             # 背景亮度下限（近中性浅色）
SAT_MAX = 30                # 背景饱和度上限
DESPILL = 205

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
        flood_bg(im)
        despill(im)
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

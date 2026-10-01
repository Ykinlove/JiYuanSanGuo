# -*- coding: utf-8 -*-
"""第二批剧情 NPC 立绘入库（2026-10-01）：29 张 AI 源图 → 泛洪抠底 → 768 高 → npcs/<id>.png

流程沿用 _art_process.py 的成熟管线（边缘泛洪抠底，不按色抠，防误删白衣/白发），
源图归档到 03-美术资源/AI源图/，不进工程。
"""
import os
import shutil
from collections import deque

from PIL import Image

GEN = r"E:\Work buddy\2026-09-21-17-49-04\generated-images"
DEST = r"E:\Work buddy\2026-09-21-17-49-04\纪元三国\04-Demo\assets\sprites\npcs"
RAW_ARCHIVE = r"E:\Work buddy\2026-09-21-17-49-04\纪元三国\03-美术资源\AI源图\NPC立绘二批"

P = "二次元国风_2D_游戏角色立绘_全身站姿_"
MAPPING = [
    # (npc_id, 源文件名)
    ("npc_zhugeliang",     P + "东汉末年蜀汉丞相诸_2026-10-01T02-13-55.png"),
    ("npc_liubei",         P + "东汉末年三国时期蜀_2026-10-01T02-18-05.png"),
    ("npc_caocao",         P + "东汉末年三国时期魏_2026-10-01T02-18-08.png"),
    ("npc_sunquan",        P + "东汉末年三国时期东_2026-10-01T02-18-08.png"),
    ("npc_zhou_yu",        P + "东汉末年三国时期江_2026-10-01T02-18-06.png"),
    ("npc_zhao_yu",        P + "东汉末年三国时期常_2026-10-01T02-18-35.png"),
    ("npc_dianwei",        P + "东汉末年三国时期虎_2026-10-01T02-18-28.png"),
    ("npc_caiwenji",       P + "东汉末年三国时期才_2026-10-01T02-18-36.png"),
    ("npc_lusu",           P + "东汉末年三国时期东_2026-10-01T02-18-37.png"),
    ("npc_fazheng",        P + "东汉末年三国时期蜀_2026-10-01T02-19-11.png"),
    ("npc_jianggan",       P + "东汉末年三国时期文_2026-10-01T02-19-09.png"),
    ("npc_wu_tu_gu",       P + "东汉末年三国时期南_2026-10-01T02-19-16.png"),
    ("npc_zhu_lao_dawang", P + "东汉末年三国时期南_2026-10-01T02-19-17.png"),
    ("npc_jin_huan_san_jie", P + "东汉末年三国时期南_2026-10-01T02-19-43.png"),
    ("npc_han_envoy",      P + "东汉末年朝廷使者__2026-10-01T02-19-47.png"),
    ("npc_strategist",     P + "东汉末年军中谋士__2026-10-01T02-19-43.png"),
    ("npc_historian",      P + "东汉末年史官_褐色_2026-10-01T02-19-44.png"),
    ("npc_baimen_warden",  P + "东汉末年守城武将白_2026-10-01T02-20-13.png"),
    ("npc_yushi",          P + "东汉末年朝廷御史__2026-10-01T02-20-13.png"),
    ("npc_jing_shizhong",  P + "东汉末年荆州州府从_2026-10-01T02-20-14.png"),
    ("npc_temple_elder",   P + "东汉末年南中祠堂守_2026-10-01T02-20-13.png"),
    ("npc_scout_zhuge",    P + "东汉末年少年书僮__2026-10-01T02-20-39.png"),
    ("npc_yicheng",        P + "东汉末年蜀道老驿丞_2026-10-01T02-20-43.png"),
    ("npc_shuishou",       P + "东汉末年蒙难义士__2026-10-01T02-20-38.png"),
    ("npc_ahei_luoyang",   P + "东汉末年酒肆跑堂小_2026-10-01T02-20-38.png"),
    ("npc_dianmu",         P + "东汉末年寻子的白发_2026-10-01T02-21-18.png"),
    ("mentor_yangleipeng", P + "东汉末年游方老名士_2026-10-01T02-21-18.png"),
    ("mentor_yangzixuan",  P + "东汉末年年轻白衣谋_2026-10-01T02-21-20.png"),
    ("mentor_liming",      P + "东汉末年须眉皆白的_2026-10-01T02-21-23.png"),
]

THRESH = 45      # 近白判定容差
DESPILL = 228    # 半透明边缘去白
MARGIN_RATIO = 0.05
TARGET_H = 768   # npc 立绘规范高度（与现有 7 张一致）


def flood_bg(im):
    """边缘泛洪抠底：从四边向内漫延，只清与边缘连通的近白像素。
    白衣/白发在轮廓内部、不与背景连通，不会被误删。"""
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
    """半透明边缘去白晕：把接近纯白的半透明像素 alpha 压零。"""
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if 0 < a < 255 and r >= DESPILL and g >= DESPILL and b >= DESPILL:
                px[x, y] = (r, g, b, 0)


def crop_with_margin(im):
    bbox = im.getbbox()
    if not bbox:
        return im
    l, t, r, b = bbox
    mw = int((r - l) * MARGIN_RATIO)
    mh = int((b - t) * MARGIN_RATIO)
    l = max(0, l - mw)
    t = max(0, t - mh)
    r = min(im.width, r + mw)
    b = min(im.height, b + mh)
    return im.crop((l, t, r, b))


def main():
    os.makedirs(RAW_ARCHIVE, exist_ok=True)
    ok, fail = [], []
    for npc_id, src in MAPPING:
        sp = os.path.join(GEN, src)
        if not os.path.exists(sp):
            fail.append((npc_id, "源图缺失 " + src))
            continue
        im = Image.open(sp).convert("RGBA")
        flood_bg(im)
        despill(im)
        im = crop_with_margin(im)
        # 规范高度 768，宽按比例；不足不放大（只缩不放，避免糊）
        if im.height > TARGET_H:
            s = TARGET_H / im.height
            im = im.resize((max(1, int(im.width * s)), TARGET_H), Image.LANCZOS)
        out = os.path.join(DEST, npc_id + ".png")
        im.save(out)
        # 源图归档（不进工程）
        shutil.copy2(sp, os.path.join(RAW_ARCHIVE, npc_id + "_raw.png"))
        ok.append((npc_id, im.size))
        print("  [OK] %-24s -> %s" % (npc_id, im.size))
    print("")
    print("入库 %d 张，失败 %d 张" % (len(ok), len(fail)))
    for npc_id, why in fail:
        print("  [FAIL] %s :: %s" % (npc_id, why))


if __name__ == "__main__":
    main()

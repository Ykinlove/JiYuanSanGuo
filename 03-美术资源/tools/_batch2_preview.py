# -*- coding: utf-8 -*-
"""批次二（地标贴图）总览预览图：游戏内真实尺度。
缩放系数直接抄 GDScript，保证预览 = 游戏内观感：
  CityInteriorArt.BUILDING_WORLD_WIDTH = 400 -> 城内建筑
  CityMarkerArt（0.80 类型 / ×1.14 专属 / ×1.18 都城）-> 大地图地标
"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国'
DEMO = os.path.join(ROOT, '04-Demo')
SPR = os.path.join(DEMO, 'assets', 'sprites')
OUT = os.path.join(ROOT, '03-美术资源', '批次二_地标贴图总览.png')

BUILDING_WORLD_WIDTH = 400.0      # CityInteriorArt
BUILDING_MULT = 1.4               # 预览放大
CITY_ICON_SCALE = 0.80
UNIQUE_BOOST = 1.14
CAPITAL_MULT = 1.18
CITY_MULT = 2.6                   # 预览放大

BUILDINGS = [
    ("hall", "官府"),
    ("tavern", "酒馆"),
    ("barracks", "兵营"),
    ("market", "市集"),
    ("smith", "铁匠铺"),
]
CAPITALS = [
    ("scene_17", "长安"),
    ("scene_19", "洛阳"),
    ("scene_21", "许昌"),
    ("scene_27", "成都"),
    ("scene_37", "建业"),
    ("scene_38", "下邳"),
]
CAP_FLAG = {"scene_17": True, "scene_19": True, "scene_37": True}


def font(sz, bold=False):
    for c in ([r'C:\Windows\Fonts\msyhbd.ttc'] if bold else []) + \
             [r'C:\Windows\Fonts\msyh.ttc', r'C:\Windows\Fonts\simhei.ttf']:
        if os.path.exists(c):
            try:
                return ImageFont.truetype(c, sz)
            except Exception:
                pass
    return ImageFont.load_default()


F_B = font(30, True)
F_L = font(21)
F_S = font(16)


def load(p):
    return Image.open(p).convert('RGBA')


def text_c(d, cx, y, s, f, fill):
    d.text((cx - d.textlength(s, font=f) / 2.0, y), s, font=f, fill=fill)


W, M = 1500, 40
HEAD = 48
A_H, B_H = 300, 320
CANVAS_H = M + HEAD + A_H + M + HEAD + B_H + M + 40
canvas = Image.new('RGBA', (W, CANVAS_H), (252, 249, 242, 255))
dr = ImageDraw.Draw(canvas)
y = M


def city_cell(band, bd, im, cx, bottom, label, sub, is_cap):
    """绘制一个地标 + 投影 + 名称"""
    sc = CITY_ICON_SCALE * UNIQUE_BOOST * (CAPITAL_MULT if is_cap else 1.0) * CITY_MULT
    im = im.resize((max(1, int(im.width * sc)), max(1, int(im.height * sc))), Image.LANCZOS)
    sw, sh = im.width * 0.55, im.height * 0.12
    sh_im = Image.new('RGBA', (int(sw), int(sh)), (0, 0, 0, 0))
    ImageDraw.Draw(sh_im).ellipse([0, 0, int(sw) - 1, int(sh) - 1], fill=(0, 0, 0, 55))
    x = int(round(cx - im.width / 2.0))
    band.alpha_composite(sh_im, (int(round(cx - sw / 2.0)), int(bottom - sh * 0.4)))
    band.alpha_composite(im, (x, int(bottom - im.height)))
    text_c(bd, cx, bottom + 4, label, F_L, (70, 58, 42))
    text_c(bd, cx, bottom + 30, sub, F_S, (150, 132, 104))


# ============ ① 城内建筑 ============
dr.text((M, y + 8), "① 城内 · 建筑贴图    世界宽 %d px  /  实际尺寸 ×%g"
        % (int(BUILDING_WORLD_WIDTH), BUILDING_MULT), font=F_B, fill=(122, 92, 52))
y += HEAD
band = Image.new('RGBA', (W - M * 2, A_H), (228, 219, 200, 255))
bd = ImageDraw.Draw(band)
for gx in range(0, band.width, 64):
    bd.line([(gx, 0), (gx, A_H)], fill=(220, 210, 190, 255))
for gy in range(0, A_H, 64):
    bd.line([(0, gy), (band.width, gy)], fill=(220, 210, 190, 255))
cw = band.width / float(len(BUILDINGS))
for i, (key, name) in enumerate(BUILDINGS):
    im = load(os.path.join(SPR, 'city', key + '.png'))
    sc = BUILDING_WORLD_WIDTH / float(im.width) * BUILDING_MULT
    im = im.resize((max(1, int(im.width * sc)), max(1, int(im.height * sc))), Image.LANCZOS)
    cx = cw * (i + 0.5)
    bottom = A_H - 40
    sw, sh = im.width * 0.7, im.height * 0.09
    sh_im = Image.new('RGBA', (int(sw), int(sh)), (0, 0, 0, 0))
    ImageDraw.Draw(sh_im).ellipse([0, 0, int(sw) - 1, int(sh) - 1], fill=(0, 0, 0, 55))
    band.alpha_composite(sh_im, (int(round(cx - sw / 2.0)), int(bottom - sh * 0.4)))
    band.alpha_composite(im, (int(round(cx - im.width / 2.0)), int(bottom - im.height)))
    text_c(bd, cx, bottom + 4, name, F_L, (70, 58, 42))
    text_c(bd, cx, bottom + 32, "%s.png  %d×%d" % (key, im.width, im.height), F_S, (150, 132, 104))
canvas.alpha_composite(band, (M, y))
y += A_H + M

# ============ ② 大地图地标 ============
dr.text((M, y + 8), "② 大地图 · 都城专属地标    专属 ×1.14，都城再 ×1.18  /  实际尺寸 ×%g"
        % CITY_MULT, font=F_B, fill=(122, 92, 52))
y += HEAD
band = Image.new('RGBA', (W - M * 2, B_H), (236, 227, 206, 255))
bd = ImageDraw.Draw(band)
for gx in range(0, band.width, 56):
    bd.line([(gx, 0), (gx, B_H)], fill=(228, 218, 197, 255))
for gy in range(0, B_H, 56):
    bd.line([(0, gy), (band.width, gy)], fill=(228, 218, 197, 255))
cw = band.width / float(len(CAPITALS))
for i, (cid, name) in enumerate(CAPITALS):
    im = load(os.path.join(SPR, 'map', cid + '.png'))
    city_cell(band, bd, im, cw * (i + 0.5), B_H - 52, name,
              "%s  ×%g" % (cid, 1.18 if CAP_FLAG.get(cid) else 1.0),
              CAP_FLAG.get(cid, False))
canvas.alpha_composite(band, (M, y))
y += B_H + M

dr.text((M, y + 8), "说明：建筑贴图宽度固定为世界 400px（与城内地基一致），高度按内容自动换算，牌匾随屋顶定位。地标贴图按「目标世界宽度 ÷ 素材宽度」反算缩放，换成任意分辨率都不走样。",
        font=F_S, fill=(130, 110, 84))

canvas.convert('RGB').save(OUT, quality=93)
print("saved:", OUT)
print("size :", canvas.size)

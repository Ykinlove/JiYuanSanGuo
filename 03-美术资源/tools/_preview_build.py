# -*- coding: utf-8 -*-
"""生成《纪元三国》美术资源「游戏内真实尺度」效果预览图。

所有缩放系数直接抄自 GDScript，保证预览 = 游戏内实际观感：
  CityMarkerArt.TYPE_ICON_SCALE   -> 大地图城池标记
  BattleUnit.unit_size()/icon.scale -> 战场兵种徽章
  CityInteriorArt.NPC_WORLD_HEIGHT = 56 -> 城内 NPC 立绘
"""
import os, json, math
from PIL import Image, ImageDraw, ImageFont

ROOT = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国'
DEMO = os.path.join(ROOT, '04-Demo')
SPR = os.path.join(DEMO, 'assets', 'sprites')
DATA = os.path.join(DEMO, 'assets', 'data')
OUT = os.path.join(ROOT, '03-美术资源', '游戏内效果预览_v1.png')

# ---------- 字体 ----------
def font(sz, bold=False):
    for c in ([r'C:\Windows\Fonts\msyhbd.ttc'] if bold else []) + \
             [r'C:\Windows\Fonts\msyh.ttc', r'C:\Windows\Fonts\simhei.ttf']:
        if os.path.exists(c):
            try:
                return ImageFont.truetype(c, sz)
            except Exception:
                pass
    return ImageFont.load_default()

F_L  = font(24)
F_S  = font(19)
F_B  = font(30, True)

# ---------- GDScript 常量（务必与代码一致） ----------
TYPE_ICON_SCALE = {"city": 0.80, "village": 0.66, "pass": 0.68, "ruin": 0.60, "landmark": 0.70}
CAPITAL_MULT = 1.18
NPC_WORLD_HEIGHT = 56.0

CAT_COLOR = {
    "infantry": (102, 184, 128), "cavalry": (191, 173, 89), "archer": (115, 158, 217),
    "beast": (158, 115, 184), "elite": (217, 153, 77), "special": (140, 184, 140),
    "navy": (97, 153, 191),
}

def load(p):
    return Image.open(p).convert('RGBA')

def put(canvas, im, cx, bottom=None, cy=None):
    x = int(round(cx - im.width / 2.0))
    y = int(round(bottom - im.height)) if bottom is not None else int(round(cy - im.height / 2.0))
    canvas.alpha_composite(im, (x, y))

def text_c(draw, cx, y, s, f, fill):
    w = draw.textlength(s, font=f)
    draw.text((cx - w / 2.0, y), s, font=f, fill=fill)

# ---------- 数据 ----------
units = json.load(open(os.path.join(DATA, 'units.json'), encoding='utf-8'))
if isinstance(units, dict):
    units = list(units.values())
UNIT_ORDER = ["infantry", "spearman", "cavalry", "heavy_cavalry", "archer", "crossbow",
              "elephant", "rattan", "navy", "tiger_cavalry", "white_horse", "qiang_archer",
              "great_halberd", "dragon_spear"]
UMAP = {str(e.get("id")): e for e in units}

PORTRAITS = [
    ("npc_elder", "寨中长者"), ("npc_meng_qian", "孟迁"), ("npc_a_hei", "阿黑"),
    ("npc_blacksmith", "铁匠老陈"), ("npc_traveler", "行脚商人"), ("npc_zhurong", "祝融夫人"),
    ("npc_meng_huo", "孟获"), ("100", "阿会喃"), ("205", "金环三结"), ("243", "兀突骨"),
    ("346", "带来洞主"), ("419", "董荼那"), ("471", "孟优"),
]

CITY_TYPES = [
    ("city", "城池", False), ("city", "都城", True), ("village", "村庄", False),
    ("pass", "关隘", False), ("ruin", "遗迹", False), ("landmark", "名胜", False),
]

# ---------- 画布尺寸 ----------
W, M = 1620, 40
A_MULT, B_MULT, C_MULT = 2, 2.4, 5
A_H, B_H, C_H = 300, 470, 750
HEAD = 52
canvas_h = M + HEAD + A_H + M + HEAD + B_H + M + HEAD + C_H + M
canvas = Image.new('RGBA', (W, canvas_h), (250, 248, 243, 255))
dr = ImageDraw.Draw(canvas)

y = M

# ============================================================
# ① 大地图城池标记
# ============================================================
dr.text((M, y + 8), "① 大地图 · 城池类型标记    羊皮纸底  /  实际尺寸 ×%d" % A_MULT,
        font=F_B, fill=(122, 92, 52))
y += HEAD
band = Image.new('RGBA', (W - M * 2, A_H), (233, 224, 203, 255))
bd = ImageDraw.Draw(band)
for gx in range(0, band.width, 60):        # 淡格纹，模拟地图
    bd.line([(gx, 0), (gx, A_H)], fill=(224, 214, 191, 255), width=1)
for gy in range(0, A_H, 60):
    bd.line([(0, gy), (band.width, gy)], fill=(224, 214, 191, 255), width=1)

cell = band.width / float(len(CITY_TYPES))
for i, (t, name, cap) in enumerate(CITY_TYPES):
    sc = TYPE_ICON_SCALE.get(t, 0.8) * (CAPITAL_MULT if cap else 1.0) * A_MULT
    im = load(os.path.join(SPR, 'city_icons', t + '.png'))
    im = im.resize((max(1, int(im.width * sc)), max(1, int(im.height * sc))), Image.LANCZOS)
    cx = cell * (i + 0.5)
    # 脚下投影
    sw, sh = im.width * 0.62, im.height * 0.16
    sh_im = Image.new('RGBA', (int(sw), int(sh)), (0, 0, 0, 0))
    ImageDraw.Draw(sh_im).ellipse([0, 0, int(sw) - 1, int(sh) - 1], fill=(0, 0, 0, 60))
    put(band, sh_im, cx, cy=A_H - 62)
    put(band, im, cx, bottom=A_H - 70)
    label = name + ("（都城 ×1.18）" if cap else "")
    text_c(bd, cx, A_H - 52, label, F_L, (78, 62, 42))
    text_c(bd, cx, A_H - 22, "%d×%d px" % (im.width, im.height), F_S, (140, 122, 92))
canvas.alpha_composite(band, (M, y))
y += A_H + M

# ============================================================
# ② 战场兵种徽章
# ============================================================
dr.text((M, y + 8), "② 战场 · 兵种徽章叠六边形    实际尺寸 ×%s" % ("%g" % B_MULT),
        font=F_B, fill=(122, 92, 52))
y += HEAD
band = Image.new('RGBA', (W - M * 2, B_H), (241, 238, 228, 255))
bd = ImageDraw.Draw(band)
COLS = 7
cw = band.width / float(COLS)
row_h = B_H / 2.0
for i, uid in enumerate(UNIT_ORDER):
    e = UMAP.get(uid, {})
    cat = str(e.get("category", ""))
    # --- GDScript: size = 26 + clamp(count/12, 0, 20) ---
    size = 26.0 + min(max(100 / 12.0, 0.0), 20.0)
    r = size * B_MULT
    cx = cw * (i % COLS + 0.5)
    cy = row_h * (i // COLS) + 88
    pts = [(cx + r * math.cos(math.radians(60 * k - 90)),
            cy + r * math.sin(math.radians(60 * k - 90))) for k in range(6)]
    col = CAT_COLOR.get(cat, (153, 153, 153))
    bd.polygon(pts, fill=col + (255,), outline=(60, 48, 36, 255), width=3)
    # --- GDScript: isc = (size * 1.7) / texture_width ---
    im = load(os.path.join(SPR, 'units', uid + '.png'))
    tgt_w = int(size * 1.7 * B_MULT)
    im = im.resize((tgt_w, max(1, int(im.height * tgt_w / float(im.width)))), Image.LANCZOS)
    put(band, im, cx, cy=cy)
    text_c(bd, cx, cy + r + 14, str(e.get("name", uid)), F_L, (70, 58, 42))
canvas.alpha_composite(band, (M, y))
y += B_H + M

# ============================================================
# ③ 城内 NPC 立绘
# ============================================================
dr.text((M, y + 8), "③ 城内 · NPC 立绘    实际高度 %d px  /  实际尺寸 ×%d" % (int(NPC_WORLD_HEIGHT), C_MULT),
        font=F_B, fill=(122, 92, 52))
y += HEAD
band = Image.new('RGBA', (W - M * 2, C_H), (216, 202, 176, 255))
bd = ImageDraw.Draw(band)
for gx in range(0, band.width, 72):        # 地砖
    bd.line([(gx, 0), (gx, C_H)], fill=(206, 191, 165, 255), width=1)
for gy in range(0, C_H, 72):
    bd.line([(0, gy), (band.width, gy)], fill=(206, 191, 165, 255), width=1)

COLS = 7
cw = band.width / float(COLS)
row_h = C_H / 2.0
GH = NPC_WORLD_HEIGHT * C_MULT          # 立绘/小人共同世界高度（预览像素）
for i, (fid, name) in enumerate(PORTRAITS):
    cx = cw * (i % COLS + 0.5)
    gy = row_h * (i // COLS + 1) - 46   # 地面线

    # 脚下投影
    sw, sh = GH * 0.34, GH * 0.09
    sh_im = Image.new('RGBA', (int(sw), int(sh)), (0, 0, 0, 0))
    ImageDraw.Draw(sh_im).ellipse([0, 0, int(sw) - 1, int(sh) - 1], fill=(0, 0, 0, 62))
    put(band, sh_im, cx, cy=gy + sh * 0.3)

    # 立绘：等比缩放到 NPC_WORLD_HEIGHT
    im = load(os.path.join(SPR, 'npcs', fid + '.png'))
    sc = GH / float(im.height)
    im = im.resize((max(1, int(im.width * sc)), int(GH)), Image.LANCZOS)
    put(band, im, cx, bottom=gy)

    text_c(bd, cx, gy + 8, name, F_L, (66, 54, 38))
    text_c(bd, cx, gy + 32, "%s.png" % fid, F_S, (140, 124, 98))

# 对照：几何小人（无立绘时的回退外观）
# 世界坐标 → 预览像素：y=26 为地面线（与立绘脚底一致），56 世界单位高
px = cw * 6.5
gy = row_h * 2 - 46
sw, sh = GH * 0.34, GH * 0.09
sh_im = Image.new('RGBA', (int(sw), int(sh)), (0, 0, 0, 0))
ImageDraw.Draw(sh_im).ellipse([0, 0, int(sw) - 1, int(sh) - 1], fill=(0, 0, 0, 62))
put(band, sh_im, px, cy=gy + sh * 0.3)
u = GH / 56.0                            # 世界单位 -> 预览像素
wy = lambda v: gy + (v - 26.0) * u       # 世界 y -> 画布 y
# CityInteriorArt.build_npc 的几何体（原样搬过来，仅换算坐标）
bd.polygon([(px - 10 * u, wy(-8)), (px + 10 * u, wy(-8)),
            (px + 8 * u, wy(26)), (px - 8 * u, wy(26))],
           fill=(77, 66, 56, 255), outline=(48, 40, 32, 255))
bd.polygon([(px, wy(-30)), (px + 8 * u, wy(-22)),
            (px, wy(-14)), (px - 8 * u, wy(-22))],
           fill=(217, 184, 148, 255), outline=(48, 40, 32, 255))
text_c(bd, px, gy + 8, "（回退形态）", F_L, (110, 96, 76))
text_c(bd, px, gy + 32, "几何小人", F_S, (140, 124, 98))

canvas.alpha_composite(band, (M, y))
canvas.convert('RGB').save(OUT, quality=93)
print("saved:", OUT)
print("size :", canvas.size)

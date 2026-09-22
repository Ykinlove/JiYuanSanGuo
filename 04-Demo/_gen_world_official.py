# -*- coding: utf-8 -*-
"""
《纪元三国》大地图生成器 V2 —— 基于《三国大时代6》官方场景坐标
替代 _gen_world.py 的自编布局，彻底解决两个用户痛点：
  1. 城市命名：改用官方真实历史地名（武威/长安/洛阳/成都/建邺/会稽…）
  2. 地理排版：直接用官方坐标，100% 符合中国历史地理方位

数据源：scenes.json（官方场景表）+ factions.json（势力）
坐标变换：官方(X向东增, Y向北增) → Godot(X向东增, Y向南增)，故 Y 翻转。
"""
import json
import math
import os

ROOT = r"E:\Users\27904\Desktop\JiyuanSanGuo\json"
OUT = r"E:\Work buddy\2026-09-21-17-49-04\纪元三国\04-Demo\assets\data"

SCALE = 3.2        # 放大系数：城池最近邻 394 → 1261px ≈ 步行 5.0 秒 @250px/s
MARGIN = 700.0     # 地图留白

# ---------------------------------------------------------------- 载入
scenes = json.load(open(os.path.join(ROOT, "scenes.json"), encoding="utf-8"))["data"]
factions_doc = json.load(open(os.path.join(ROOT, "factions.json"), encoding="utf-8"))
faction_name = {f["id"]: f["name"] for f in factions_doc["data"]}

# 排除"世界地图"(category 99)占位
places = [s for s in scenes if s["category"] in (1, 2)]

src_xs = [s["src_x"] for s in places]
src_ys = [s["src_y"] for s in places]
MINX, MAXX = min(src_xs), max(src_xs)
MINY, MAXY = min(src_ys), max(src_ys)
W = round((MAXX - MINX) * SCALE + MARGIN * 2)
H = round((MAXY - MINY) * SCALE + MARGIN * 2)


def T(x, y):
    """官方坐标 → Godot 世界坐标（Y 翻转）。"""
    return [round((x - MINX) * SCALE + MARGIN), round((MAXY - y) * SCALE + MARGIN)]


# ---------------------------------------------------------------- 州域归属
# 以各州代表性都城为种子，地点按「最近的州种子」归属，保证地域连续
REGION_SEEDS = [
    ("reg_you", "幽州", 5085, 7416), ("reg_ji", "冀州", 3618, 6341),
    ("reg_bing", "并州", 3424, 6782), ("reg_liang", "凉州", 298, 7675),
    ("reg_sili", "司隶", 2672, 5621), ("reg_yan", "兖州", 4212, 5874),
    ("reg_yu", "豫州", 3741, 5154), ("reg_xu", "徐州", 5786, 5087),
    ("reg_yang", "扬州", 5306, 3904), ("reg_jing", "荆州", 3049, 4275),
    ("reg_yi", "益州", 445, 4521), ("reg_jiao", "交州", 1401, 2126),
    ("reg_nanzhong", "南中", 573, 2608),
]


def region_of(sx, sy):
    best, bd = None, 1e18
    for rid, rname, x, y in REGION_SEEDS:
        d = math.hypot(sx - x, sy - y)
        if d < bd:
            bd, best = d, (rid, rname)
    return best


# ---------------------------------------------------------------- 城池
def level_of(s):
    """综合 城防/人口/军事 定等级 1~5。"""
    score = s["defense"] * 1.4 + s["military"] * 0.7 + s["population"] / 12000.0
    if score >= 165:
        return 5
    if score >= 130:
        return 4
    if score >= 100:
        return 3
    if score >= 70:
        return 2
    return 1


BUILDING_MAP = {          # 源表建筑 → 通用 building key
    "hall": "hall", "tavern": "tavern", "shop": "market", "smith": "smith",
    "clinic": "clinic", "dojo": "dojo", "inn": "inn", "barracks": "barracks",
    "house": "house", "riceshop": "rice_shop", "stable": "stable", "shrine": "shrine",
}
BUILDING_CN = {
    "hall": "衙门", "tavern": "酒馆", "market": "商铺", "smith": "铁匠铺",
    "clinic": "医馆", "dojo": "武馆", "inn": "旅馆", "barracks": "兵营",
    "house": "民宅", "rice_shop": "米铺", "stable": "马房", "shrine": "祠堂",
}

cities = []
for s in places:
    rid, rname = region_of(s["src_x"], s["src_y"])
    is_city = s["category"] == 1
    fac_id = s["faction_id"]
    fac_key = "f%d" % fac_id if fac_id else "neutral"
    fac_cn = faction_name.get(fac_id, "无") if fac_id else "中立"

    blist = [BUILDING_MAP[k] for k, v in s["buildings"].items() if v == 1 and k in BUILDING_MAP]
    lv = level_of(s) if is_city else max(1, int(s["defense"]) - 2)

    spec = "军屯" if s["military"] >= max(s["commerce"], s["agriculture"]) else (
        "商埠" if s["commerce"] >= s["agriculture"] else "粮仓")

    tags = [fac_key]
    if fac_id == 0:
        tags.append("neutral")
    else:
        tags.append("foreign")

    cities.append({
        "id": "scene_%d" % s["id"],
        "scene_id": s["id"],
        "name": s["name"],
        "title": "%s · %s" % (rname, "城池" if is_city else "据点"),
        "type": "city" if is_city else "village",
        "level": lv,
        "region": rid,
        "region_name": rname,
        "faction": fac_key,
        "faction_id": fac_id,
        "faction_name": fac_cn,
        "map_x": T(s["src_x"], s["src_y"])[0],
        "map_y": T(s["src_x"], s["src_y"])[1],
        "src_x": s["src_x"],
        "src_y": s["src_y"],
        "defense": s["defense"],
        "population": s["population"],
        "morale": s["security"],
        "garrison": s["military"] * 40,
        "commerce": s["commerce"],
        "agriculture": s["agriculture"],
        "military": s["military"],
        "specialty": spec,
        "buildings": blist,
        "buildings_cn": [BUILDING_CN[b] for b in blist],
        "tags": tags,
        "is_capital": is_city and s["defense"] >= 60,
        "description": "%s治下%s，人口%d，城防%d。" % (
            fac_cn if fac_id else "无主之地", s["name"], s["population"], s["defense"]),
    })

by_name = {c["name"]: c for c in cities}
city_only = [c for c in cities if c["type"] == "city"]

# ---------------------------------------------------------------- 道路（Gabriel 图，城际主干）
def gabriel_edges(pts, max_len):
    """Gabriel 图：边 pq 存在 iff 以 pq 为直径的圆内无其他点。生成的路网最自然。"""
    edges = []
    n = len(pts)
    for i in range(n):
        for j in range(i + 1, n):
            ax, ay = pts[i]["src_x"], pts[i]["src_y"]
            bx, by = pts[j]["src_x"], pts[j]["src_y"]
            if math.hypot(bx - ax, by - ay) > max_len:
                continue
            mx, my = (ax + bx) / 2.0, (ay + by) / 2.0
            rr = math.hypot(bx - ax, by - ay) / 2.0
            ok = True
            for k in range(n):
                if k == i or k == j:
                    continue
                cx, cy = pts[k]["src_x"], pts[k]["src_y"]
                if math.hypot(cx - mx, cy - my) < rr - 1e-9:
                    ok = False
                    break
            if ok:
                edges.append((i, j))
    return edges


city_pts = [{"src_x": c["src_x"], "src_y": c["src_y"], "name": c["name"]} for c in city_only]
edges = gabriel_edges(city_pts, max_len=1600.0)

roads = []
for i, j in edges:
    a, b = city_pts[i], city_pts[j]
    roads.append({"name": "%s道" % a["name"], "points": [
        T(a["src_x"], a["src_y"]), T(b["src_x"], b["src_y"])]})

# 据点接入：每个据点连到最近的一座城池
villages = [c for c in cities if c["type"] == "village"]
for v in villages:
    best, bd = None, 1e18
    for c in city_only:
        d = math.hypot(v["src_x"] - c["src_x"], v["src_y"] - c["src_y"])
        if d < bd:
            bd, best = d, c
    if best is not None:
        roads.append({"name": "%s支路" % v["name"], "points": [
            T(v["src_x"], v["src_y"]), T(best["src_x"], best["src_y"])]})

# ---------------------------------------------------------------- 河流（史实走向 + 渡口）
RIVERS = [
    {"name": "黄河", "src": [
        (300, 6950), (1200, 7300), (2000, 7450), (3000, 7450), (3678, 7400),
        (4000, 7050), (4100, 6750), (3950, 6450), (3600, 6150), (3200, 5960),
        (2800, 5830), (3100, 5730), (3600, 5840), (4300, 6010), (4900, 6130),
        (5500, 6260), (6000, 6360)],
     "ford_src": [(2800, 5830), (3600, 5840), (4300, 6010)]},
    {"name": "长江", "src": [
        (400, 4400), (900, 3700), (1500, 3230), (2260, 3345), (2920, 3560),
        (3230, 3480), (3900, 3650), (4442, 3750), (5000, 3830), (5306, 3860),
        (5700, 3850), (6100, 3830)],
     "ford_src": [(2920, 3560), (3230, 3480), (4442, 3750), (5306, 3860)]},
    {"name": "汉水", "src": [
        (1701, 5240), (2000, 4800), (2400, 4450), (2800, 4250), (3049, 4220),
        (3600, 4000), (4000, 3820), (4442, 3750)],
     "ford_src": [(3049, 4220)]},
    {"name": "淮河", "src": [
        (3900, 4850), (4400, 4900), (4800, 4850), (5200, 4780), (5515, 4760),
        (5800, 4700), (6044, 4650)],
     "ford_src": [(5515, 4760)]},
    {"name": "泸水", "src": [
        (200, 2450), (400, 2080), (600, 2400), (720, 2800)],
     "ford_src": [(600, 2400)]},
]

rivers = []
for rv in RIVERS:
    rivers.append({
        "name": rv["name"],
        "points": [T(x, y) for x, y in rv["src"]],
        "fords": [T(x, y) for x, y in rv["ford_src"]],
    })

# ---------------------------------------------------------------- 州域矩形
regions = []
for rid, rname, _sx, _sy in REGION_SEEDS:
    pts = [c for c in cities if c["region"] == rid]
    if not pts:
        continue
    xs = [c["map_x"] for c in pts]
    ys = [c["map_y"] for c in pts]
    pad = 420
    x0, y0 = max(0, min(xs) - pad), max(0, min(ys) - pad)
    x1, y1 = min(W, max(xs) + pad), min(H, max(ys) + pad)
    regions.append({"id": rid, "name": rname, "rect": [x0, y0, x1 - x0, y1 - y0],
                    "terrain": "plain"})

# ---------------------------------------------------------------- 落地
json.dump(cities, open(os.path.join(OUT, "cities.json"), "w", encoding="utf-8"),
          ensure_ascii=False, indent=2)
terrain = [{
    "id": "china", "name": "天下", "width": W, "height": H,
    "base_terrain": "grass", "default_bgm": "res://assets/audio/bgm/world_map.ogg",
    "description": "汉室倾颓，群雄并起。自辽东至交趾，自敦煌至会稽，九州尽入乱世。",
    "regions": regions, "roads": roads, "rivers": rivers,
}]
json.dump(terrain, open(os.path.join(OUT, "terrain.json"), "w", encoding="utf-8"),
          ensure_ascii=False, indent=2)

spawn = T(573, 2608)      # 建宁附近（南中，沿用 Demo 起始区）
json.dump({"spawn": spawn, "width": W, "height": H, "scale": SCALE, "margin": MARGIN},
          open(os.path.join(OUT, "_layout_meta.json"), "w", encoding="utf-8"),
          ensure_ascii=False, indent=2)

# ---------------------------------------------------------------- 报告
print("地图尺寸: %d x %d   (SCALE=%.1f)" % (W, H, SCALE))
print("地点 %d 个（城池 %d / 据点 %d）" % (len(cities), len(city_only), len(villages)))
print("道路 %d 条 / 河流 %d 条 / 州域 %d 个" % (len(roads), len(rivers), len(regions)))
print("出生点: %s" % spawn)
caps = [c["name"] for c in cities if c["is_capital"]]
print("都城（城防>=60）:", "、".join(caps))
import collections
rc = collections.Counter(c["region_name"] for c in cities)
print("州域分布:", dict(rc))

d = []
for a in city_only:
    b = min((c for c in city_only if c is not a),
            key=lambda c: math.hypot(c["map_x"] - a["map_x"], c["map_y"] - a["map_y"]))
    d.append(math.hypot(b["map_x"] - a["map_x"], b["map_y"] - a["map_y"]))
d.sort()
print("城池最近邻: min=%.0fpx(%.1fs)  中位=%.0fpx(%.1fs)" % (
    d[0], d[0] / 250, d[len(d) // 2], d[len(d) // 2] / 250))

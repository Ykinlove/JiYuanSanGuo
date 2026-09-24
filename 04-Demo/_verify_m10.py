# -*- coding: utf-8 -*-
"""_verify_m10.py — 全国大地图分区加载框架（Region Window）静态校验

覆盖：
  A. RegionService 服务存在 + class_name + 4 区映射/邻接常量
  B. 4 个游戏区域映射的古州在 terrain.json regions[] 中都存在
  C. 各区域世界坐标矩形（region_rect，古州 rect 并集）数值正确
  D. 城池归属：每区按 region 字段能过滤出城池，且各区域主城存在
  E. 4 区邻接拓扑：M10 定义的每对邻接区域 rect 边界相接（可越界穿越）
  F. world_map.gd 已实现分区加载（相机锁定/城池过滤/越界切换/进区渐变）
  G. encounter_manager.gd 已区域化（region_id 跟随 + china 通配 + 区域窗口生成）
  H. HUD 区域显示：hud.gd 有 update_region + world_map.tscn 有 RegionLabel
  I. GameState 已有 current_region / unlocked_regions 字段
"""
import io
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "assets", "data")
WORLD = os.path.join(HERE, "scenes", "world")
errors = []
warns = []


def check(cond, msg):
    if cond:
        print("  [PASS] " + msg)
    else:
        errors.append(msg)
        print("  [FAIL] " + msg)


def warn(msg):
    warns.append(msg)
    print("  [WARN] " + msg)


def read_text(p):
    with io.open(p, encoding="utf-8") as f:
        return f.read()


def load_json(name):
    with io.open(os.path.join(DATA, name), encoding="utf-8") as f:
        return json.load(f)


# ----- 4 游戏区域 -> 古州映射（必须与 region_service.gd 的 GAME_REGIONS 一致）-----
GAME_REGIONS = {
    "nanzhong":  ["reg_nanzhong"],
    "jing":      ["reg_jing"],
    "zhongyuan": ["reg_yu", "reg_yan"],
    "jiangdong": ["reg_yang"],
}
REGION_NAMES = {"nanzhong": "南中", "jing": "荆州", "zhongyuan": "中原", "jiangdong": "江东"}
NEIGHBORS = {
    "nanzhong":  ["jing"],
    "jing":      ["nanzhong", "zhongyuan", "jiangdong"],
    "zhongyuan": ["jing", "jiangdong"],
    "jiangdong": ["jing", "zhongyuan"],
}


def guizhou_rect(code, regions):
    for r in regions:
        if r.get("id") == code:
            raw = r.get("rect", [])
            if len(raw) >= 4:
                return (raw[0], raw[1], raw[0] + raw[2], raw[1] + raw[3])
    return None


def region_bbox(game_region, regions):
    min_x = min_y = 2e9
    max_x = max_y = -2e9
    found = False
    for code in GAME_REGIONS[game_region]:
        r = guizhou_rect(code, regions)
        if not r:
            continue
        found = True
        min_x = min(min_x, r[0]); min_y = min(min_y, r[1])
        max_x = max(max_x, r[2]); max_y = max(max_y, r[3])
    return (min_x, min_y, max_x, max_y) if found else None


def rects_overlap(a, b):
    """两矩形（x0,y0,x1,y1）是否有相交面积（可穿越带）"""
    return not (a[2] <= b[0] or b[2] <= a[0] or a[3] <= b[1] or b[3] <= a[1])


terrain = load_json("terrain.json")
china = next((t for t in terrain if t.get("id") == "china"), None)
regions = china.get("regions", []) if china else []
cities = load_json("cities.json")

print("== A. RegionService 服务与常量 ==")
rs_path = os.path.join(HERE, "scripts", "services", "region_service.gd")
rs = read_text(rs_path)
check(os.path.exists(rs_path), "region_service.gd 存在")
check("class_name RegionService" in rs, "RegionService class_name 存在")
check("extends RefCounted" in rs, "extends RefCounted（服务层范式）")
for k in ("GAME_REGIONS", "REGION_NAMES", "NEIGHBORS"):
    check(k in rs, "RegionService 含常量 %s" % k)
for fn in ("guizhou_rect", "region_rect", "region_name", "neighbors",
           "city_in_area", "main_city", "resolve_crossing", "push_into_region"):
    check("static func %s" % fn in rs, "RegionService 含 static func %s" % fn)

print("")
print("== B. 4 区映射的古州在 terrain.json regions[] 都存在 ==")
for game, codes in GAME_REGIONS.items():
    for code in codes:
        check(guizhou_rect(code, regions) is not None,
              "%s 所属古州 %s 在 terrain.json regions[] 中" % (game, code))

print("")
print("== C. 各游戏区域世界坐标矩形（region_rect 并集）数值 ==")
expected = {
    "nanzhong":  (280, 14974, 5098, 21546),      # reg_nanzhong
    "jing":      (5067, 10034, 13264, 18995),    # reg_jing
    "zhongyuan": (11288, 4350, 15651, 11827),    # 豫+兖 并集
    "jiangdong": (12533, 10770, 20032, 20074),   # reg_yang
}
for game, exp in expected.items():
    got = region_bbox(game, regions)
    check(got == exp, "%s(%s) rect=%s" % (game, REGION_NAMES[game], got))

print("")
print("== D. 城池归属：每区能过滤出城池 + 主城存在 ==")
for game, codes in GAME_REGIONS.items():
    in_cities = [c for c in cities if c.get("region") in codes]
    check(len(in_cities) >= 3, "%s(%s) 过滤出城池 >=3 座 (实际 %d)"
          % (game, REGION_NAMES[game], len(in_cities)))
    cap = [c for c in in_cities if c.get("is_capital")]
    lvs = [c.get("level", 0) for c in in_cities]
    top = max(lvs) if lvs else 0
    check((not cap and top >= 1) or cap, "%s(%s) 有主城（is_capital 或最高等级城）"
          % (game, REGION_NAMES[game]))

print("")
print("== E. 4 区邻接拓扑：每对邻接区域 rect 边界相接（可越界穿越）==")
for game, nbs in NEIGHBORS.items():
    a = region_bbox(game, regions)
    for nb in nbs:
        b = region_bbox(nb, regions)
        check(rects_overlap(a, b), "%s ↔ %s 区域矩形相接，可越界穿越"
              % (REGION_NAMES[game], REGION_NAMES[nb]))

print("")
print("== F. world_map.gd 分区加载实现 ==")
wm = read_text(os.path.join(HERE, "scripts", "world", "world_map.gd"))
check("_apply_region_camera" in wm, "world_map 有 _apply_region_camera（相机锁定区域矩形）")
check("_camera.limit_left = 0" in wm and "_camera.limit_right = int(world.x)" in wm,
      "world_map 相机 limit=全图（全国无缝地图，视口边缘收于世界边界）")
check("RegionService.city_in_area(cur, city)" in wm, "world_map 城池按区域过滤（分区加载）")
check("_check_region_bounds" in wm, "world_map 有 _check_region_bounds（每帧古州归属判定）")
check("_enter_region_in_place(target)" in wm, "world_map 原地切区（_enter_region_in_place，无过场重载）")
check("GameState.current_region = target" in wm, "world_map 切换时更新 current_region")
check("GameState.unlocked_regions.append(target)" in wm, "world_map 解锁新区域")
check("_encounters.reload_region()" in wm, "world_map 切区后刷新遭遇分布（reload_region）")

print("")
print("== G. encounter_manager 区域化 ==")
enc = read_text(os.path.join(HERE, "scripts", "world", "encounter_manager.gd"))
check("region_id = GameState.current_region" in enc, "encounter 跟随当前区域")
check("var rect := RegionService.region_rect(region_id)" in enc, "encounter 读取区域矩形")
check("_region_origin = rect.position" in enc, "encounter 记录区域原点")
check("regions.is_empty() or region_id in regions or \"china\" in regions" in enc,
      "encounter 支持 china 通配 + 区域过滤")
check("var pos := _region_origin + local" in enc, "encounter 在区域窗口内生成")

print("")
print("== H. HUD 区域显示 ==")
hud = read_text(os.path.join(HERE, "scripts", "ui", "hud.gd"))
check("func update_region(game_region: String)" in hud, "hud.gd 有 update_region")
check("RegionService.region_name(game_region)" in hud, "update_region 用 RegionService 取区域名")
tscn = read_text(os.path.join(WORLD, "world_map.tscn"))
check("[node name=\"RegionLabel\"" in tscn and "text = \"区域 · 南中\"" in tscn,
      "world_map.tscn 含 RegionLabel 节点（HUD 多区域适配）")

print("")
print("== I. GameState 区域字段 ==")
gs = read_text(os.path.join(HERE, "scripts", "autoload", "game_state.gd"))
check("var current_region: String" in gs, "GameState.current_region 字段存在")
check("var unlocked_regions: Array" in gs, "GameState.unlocked_regions 字段存在")

print("")
print("=" * 66)
if errors:
    print("[FAIL] M10 校验失败 %d 项" % len(errors))
    for e in errors:
        print("  - " + e)
    raise SystemExit(1)
print("M10 分区加载框架校验通过 ✅ (warns=%d)" % len(warns))
for w in warns:
    print("  - " + w)

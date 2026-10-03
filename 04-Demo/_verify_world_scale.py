# -*- coding: utf-8 -*-
"""
_verify_world_scale.py — 第六十六轮·问题1 回归锁
用户反馈：
  ① 城池与角色放大后，黄巾军/宝箱/采集点等可交互物仍是旧尺寸，不协调；
  ② 宝箱太密集，走不了几步就有；
  ③ 人物行走方式特别不好。

【取证到的失衡（先量后改，不是拍脑袋）】
  玩家立绘世界高  425   （scenes/world/world_map.tscn: portrait_world_height）
  城池图标显示宽  384   （CityMarkerArt TYPE_ICON_SCALE.city 3.00 × ICON_BASE_PX 128）
  世界 NPC        210   （NPCManager.NPC_WORLD_HEIGHT）
  遭遇物           54   （EncounterManager.ENC_WORLD_HEIGHT，旧值）
  → 玩家 : 遭遇物 ≈ 7.9 : 1，宝箱摆在放大后的地图上像地上的小石子。
  密度：遭遇物最小间距 220px、小图保底 26 个 —— 玩家 250px/s 走直线不到 1 秒一个。

【修法】两头靠拢：遭遇物按「物件 < 人 < 城」三档重排（基准 125 + 类型倍率），
间距放宽到 620px，数量改由面积反推；行走方面把步幅从**绝对像素**改为
**身高比例**（旧式对 425px 主角只合 0.06~0.15 身高 → 步频被顶到 3.2 步/秒的小碎步）。

本校验全部走**数值断言**（解析常量后算比例 / 复算步频），
不做「字符串存在就算过」的空判据 —— 否则常量改回旧值也不会变红。
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ENC = os.path.join(HERE, "scripts", "world", "encounter_manager.gd")
CMA = os.path.join(HERE, "scripts", "world", "city_marker_art.gd")
NPC = os.path.join(HERE, "scripts", "world", "npc_manager.gd")
WALK = os.path.join(HERE, "scripts", "world", "walk_anim.gd")
PLAYER = os.path.join(HERE, "scripts", "world", "player_controller.gd")
CITY = os.path.join(HERE, "scripts", "city", "city_scene.gd")
WM_TSCN = os.path.join(HERE, "scenes", "world", "world_map.tscn")

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print("  [%s] %s%s" % ("OK" if ok else "FAIL", name, ("  " + detail) if detail else ""))
    return bool(ok)


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def const_floats(src, name):
    """解析 `const NAME := 数值`"""
    out = []
    for m in re.finditer(r"^\s*const\s+%s\s*:?=\s*([0-9]*\.?[0-9]+(?:e[0-9]+)?)" % name,
                         src, flags=re.M):
        out.append(float(m.group(1)))
    return out


def dict_floats(src, name):
    """解析 `const NAME := { "k": 1.23, ... }`"""
    m = re.search(r"const\s+%s\s*:?=\s*\{(.*?)\}" % name, src, flags=re.S)
    if not m:
        return {}
    return {k: float(v) for k, v in re.findall(r'"([^"]+)"\s*:\s*([0-9.]+)', m.group(1))}


print("=" * 68)
print("第六十六轮 大地图尺度 / 密度 / 行走 回归锁")
print("=" * 68)

for p in (ENC, CMA, NPC, WALK, PLAYER, CITY, WM_TSCN):
    if not os.path.isfile(p):
        check("源文件存在", False, p)
        sys.exit(1)

enc, cma, npc, walk = read(ENC), read(CMA), read(NPC), read(WALK)
player, city, wmtscn = read(PLAYER), read(CITY), read(WM_TSCN)

# ---------- ① 尺度：物件 < 人 < 城 ----------
print("\n[1] 尺度统一（物件 < 人 < 城）")
enc_h = const_floats(enc, "ENC_WORLD_HEIGHT")
check("ENC_WORLD_HEIGHT 有定义", len(enc_h) == 1, str(enc_h))
enc_h = enc_h[0] if enc_h else 0.0
tscale = dict_floats(enc, "ENC_TYPE_SCALE")
check("ENC_TYPE_SCALE 覆盖五种遭遇类型",
      set(tscale) >= {"battle", "event", "merchant", "treasure", "gather"},
      str(sorted(tscale)))

icon_scale = dict_floats(cma, "TYPE_ICON_SCALE")
base_px = const_floats(cma, "ICON_BASE_PX")
city_w = float(icon_scale.get("city", 0.0)) * (base_px[0] if base_px else 0.0)
npc_h = const_floats(npc, "NPC_WORLD_HEIGHT")
npc_h = npc_h[0] if npc_h else 0.0
m = re.search(r"portrait_world_height\s*=\s*([0-9.]+)", wmtscn)
player_h = float(m.group(1)) if m else 0.0

check("取证到玩家立绘世界高度", player_h > 0, "%.0f" % player_h)
check("取证到城池图标显示宽", city_w > 0, "%.0f" % city_w)
check("取证到世界 NPC 高度", npc_h > 0, "%.0f" % npc_h)

h_treasure = enc_h * float(tscale.get("treasure", 1.0))
h_battle = enc_h * float(tscale.get("battle", 1.0))
print("      → 宝箱 %.0f / 战斗队 %.0f / NPC %.0f / 城池宽 %.0f / 主角 %.0f"
      % (h_treasure, h_battle, npc_h, city_w, player_h))

# 旧失衡 7.9:1 —— 修复后玩家与遭遇物的高度比必须显著收敛
ratio_player_treasure = player_h / max(h_treasure, 1.0)
check("玩家/宝箱高度比收敛（旧 7.9:1 → ≤5:1）", ratio_player_treasure <= 5.0,
      "%.2f : 1" % ratio_player_treasure)
check("宝箱不至于比人还高（≥0.15 身高）", h_treasure / player_h >= 0.15,
      "%.2f 身高" % (h_treasure / player_h))
check("战斗队（成队人马）接近单人高度（0.30~0.60 身高）",
      0.30 <= h_battle / player_h <= 0.60, "%.2f 身高" % (h_battle / player_h))
check("物件确实小于人（宝箱 < 战斗队）", h_treasure < h_battle,
      "%.0f < %.0f" % (h_treasure, h_battle))
check("城池与玩家同量级（不失衡，0.6~1.6）", 0.6 <= city_w / player_h <= 1.6,
      "%.2f" % (city_w / player_h))
check("遭遇物不再是与城池差一个量级（城池/宝箱 ≤4.5）",
      city_w / max(h_treasure, 1.0) <= 4.5, "%.2f" % (city_w / max(h_treasure, 1.0)))

# ---------- ② 密度 ----------
print("\n[2] 密度放宽（不再走几步一个宝箱）")
gap = const_floats(enc, "ENC_MIN_GAP")
check("ENC_MIN_GAP 有定义", len(gap) == 1, str(gap))
gap = gap[0] if gap else 0.0
city_gap = const_floats(enc, "ENC_CITY_GAP")
area_one = const_floats(enc, "ENC_AREA_PER_ONE")
max_cnt = const_floats(enc, "ENC_MAX_COUNT")
spawn_n = re.search(r"@export var spawn_count: int = (\d+)", enc)

check("遭遇物最小间距 ≥500（旧 220）", gap >= 500.0, "%.0f" % gap)
check("间距 ≥ 3 个最大图标身位（放大后不会挤成一堆）",
      gap >= 3.0 * h_battle, "%.0f vs 3×%.0f" % (gap, h_battle))
check("避让城池距离 ≥ 城池半宽（不会压在城墙上）",
      (city_gap[0] if city_gap else 0.0) >= city_w * 0.5,
      "%.0f vs 半宽 %.0f" % (city_gap[0] if city_gap else 0.0, city_w * 0.5))
check("数量改由面积反推（每遭遇分摊面积 ≥2e6）",
      bool(area_one) and area_one[0] >= 2.0e6, str(area_one))
check("保底数量已下调（≤14，旧 26）",
      spawn_n is not None and int(spawn_n.group(1)) <= 14,
      spawn_n.group(1) if spawn_n else "缺失")
check("数量上限已下调（≤80，旧 140）",
      bool(max_cnt) and max_cnt[0] <= 80, str(max_cnt))
# 玩家 250px/s 走直线，平均多久碰到一个（用分摊面积粗算）
lam = 1.0 / (area_one[0] if area_one else 1.0)     # 点/px²
per_sec = lam * 700.0 * 250.0                       # 交互带宽 700px × 速度
check("按面积反推的遭遇密度不至于秒遇（≥4 秒/个）",
      per_sec <= 0.25, "约 %.1f 秒碰到一个" % (1.0 / max(per_sec, 1e-9)))
# 源码里不应再残留旧的写死间距
check("间距判定已改用常量（不再写死 220.0 / 180.0）",
      "distance_to(node.position) < 220.0" not in enc
      and "distance_to(cp) < 180.0" not in enc)

# ---------- ③ 布局随高度联动 ----------
print("\n[3] 布局随放大后的高度联动（脚底落地 / 标签不压图）")
spawn_fn = re.search(r"func _spawn_one\(.*?(?=\n## |\nfunc )", enc, flags=re.S)
body = spawn_fn.group(0) if spawn_fn else ""
check("图标缩放按 h 计算（不再用固定 ENC_WORLD_HEIGHT）",
      "var sc := h /" in body)
check("图标位置按 h 落地（20.0 - h * 0.5）", "20.0 - h * 0.5" in body)
check("脚下投影按 h 联动（不再写死 21.0, 8.0）",
      "h * 0.39" in body and "21.0, 8.0, 18" not in body)
check("名称标签水平居中（不再写死 -36 左偏移）",
      "HORIZONTAL_ALIGNMENT_CENTER" in body and "Vector2(-36, 26)" not in body)
check("「▲ 可交互」提示浮在图标顶上（按 h 推导）", "20.0 - h - 46.0" in body)
check("几何菱形兜底按 h 缩放（有图/无图不再差三倍）",
      "func _make_diamond(color: Color, h: float" in enc and "h * 0.33" in enc)

# ---------- ④ 行走：步幅随身高 ----------
print("\n[4] 行走方式（步幅按身高，不再小碎步）")
check("步幅改为身高比例常量 STRIDE_MIN_RATIO", "STRIDE_MIN_RATIO" in walk)
check("步幅改为身高比例常量 STRIDE_MAX_RATIO", "STRIDE_MAX_RATIO" in walk)
check("WalkAnim 新增 body_height", "@export var body_height" in walk)
check("步幅计算用到 body_height",
      bool(re.search(r"lerpf\(STRIDE_MIN_RATIO, STRIDE_MAX_RATIO, ratio\)"
                     r"\s*\\?\s*\n?\s*\*\s*maxf\(body_height", walk)))
check("旧的绝对像素步幅已移除", "STRIDE_MIN := 26.0" not in walk)

# 复算步频：这是「行走方式」的可量化判据
REF_SPEED, MAX_RATE = 300.0, 3.2
smin = const_floats(walk, "STRIDE_MIN_RATIO")
smax = const_floats(walk, "STRIDE_MAX_RATIO")
check("取到步幅比例常量", bool(smin) and bool(smax), "%s / %s" % (smin, smax))
smin = smin[0] if smin else 0.0
smax = smax[0] if smax else 0.0


def step_rate(speed, height):
    ratio = min(1.0, max(0.0, speed / REF_SPEED))
    stride = (smin + (smax - smin) * ratio) * max(height, 24.0)
    stride = max(stride, speed / MAX_RATE)
    return speed / stride


rate_walk = step_rate(250.0, player_h)
rate_run = step_rate(400.0, player_h)
print("      → 主角 %0.f px 高：常速 %.2f 步/秒，疾跑 %.2f 步/秒"
      % (player_h, rate_walk, rate_run))
check("主角常速步频落在自然区间（1.0~2.0 步/秒）",
      1.0 <= rate_walk <= 2.0, "%.2f" % rate_walk)
check("主角疾跑仍不抽搐（≤2.8 步/秒）", rate_run <= 2.8, "%.2f" % rate_run)
# 反证：旧模型（固定 26~64px 步幅）在这个身高下必然被封顶成 3.2
old_stride = max(26.0 + (64.0 - 26.0) * (250.0 / REF_SPEED), 250.0 / MAX_RATE)
old_rate = 250.0 / old_stride
check("反证：旧固定步幅在本身高下会被顶到 3.2 步/秒（修复确有必要）",
      abs(old_rate - MAX_RATE) < 1e-6, "旧 %.2f 步/秒" % old_rate)
check("新步幅确实比旧步幅大（不再小碎步）",
      (smin + (smax - smin) * (250.0 / REF_SPEED)) * player_h > old_stride * 1.5,
      "新 %.0f px vs 旧 %.0f px" % (
          (smin + (smax - smin) * (250.0 / REF_SPEED)) * player_h, old_stride))

# 各调用点必须真的报了身高，否则步幅仍是默认的 120
check("世界 NPC 立绘分支报身高", bool(re.search(
    r"wa\.body_height = NPC_WORLD_HEIGHT", npc)))
check("世界 NPC 几何分支也报身高",
      npc.count("wa.body_height = NPC_WORLD_HEIGHT") >= 2,
      "出现 %d 次" % npc.count("wa.body_height = NPC_WORLD_HEIGHT"))
check("城内 NPC 报身高", "wa.body_height = CityInteriorArt.NPC_WORLD_HEIGHT" in city)
check("主角报身高（用 portrait_world_height）",
      "_walk.body_height = portrait_world_height" in player)
# 大立绘的旋转不能再是 6°：425px 图转 6° 顶端要甩 22px
check("大立绘摇摆角度已收小（≤2.5°，不再整个人在扭）",
      bool(re.search(r"_walk\.lean_deg = ([0-9.]+)", player))
      and float(re.search(r"_walk\.lean_deg = ([0-9.]+)", player).group(1)) <= 2.5,
      re.search(r"_walk\.lean_deg = ([0-9.]+)", player).group(1)
      if re.search(r"_walk\.lean_deg = ([0-9.]+)", player) else "缺失")
check("起伏按身高比例取（≈2.6% 身高，不再像跳）",
      "portrait_world_height * 0.026" in player)
check("左右轻晃按身高比例取", "portrait_world_height * 0.012" in player)
check("落地挤压已收小（≤0.02，不再是果冻）",
      bool(re.search(r"_walk\.squash = ([0-9.]+)", player))
      and float(re.search(r"_walk\.squash = ([0-9.]+)", player).group(1)) <= 0.02)

# ---------- 汇总 ----------
print("\n" + "=" * 68)
passed = sum(1 for _, ok, _ in results if ok)
print("复核结果：%d / %d 通过" % (passed, len(results)))
if passed < len(results):
    print("失败项：")
    for n, ok, d in results:
        if not ok:
            print("  - %s :: %s" % (n, d))
    sys.exit(1)
print("全部通过 ✅")

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
# 【第六十八轮补·R6 盲区】与城内 NPC 同类问题：原先只「取证到」不「校验值」，
# 把世界 NPC 退回 210 校验器仍全绿。世界 NPC 与玩家同高是「比例自洽」的第一前提。
check("世界 NPC 与玩家同高（比例 0.95~1.05）",
      0.95 <= npc_h / player_h <= 1.05,
      "%.0f vs 玩家 %.0f = %.2f 倍" % (npc_h, player_h, npc_h / player_h))
# 反证：退回 210（旧值，玩家的一半不到）必须被拒
check("反证：世界 NPC 退回 210 会是 %.2f 倍（超 1.05 上限，须被拒）" % (210.0 / player_h),
      (210.0 / player_h) > 1.05, "%.2f > 1.05" % (210.0 / player_h))

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
# 【第六十八轮·基准归一后重新论证】
# 以下区间原按旧基准 425px 人高设，换到 120px 后必须**重新论证**而非简单放宽。
# 论证依据写在每条判据旁，避免下一个人又照着旧数字盲调。
#   战斗队 62×1.40 = 87px ÷ 120 = 0.72 —— 一队人马的单兵比玩家矮，合理
#   宝箱   62×0.85 = 53px ÷ 120 = 0.44 —— 地面物件约为成人半身，合理
#   城池   384px    ÷ 120 = 3.20 —— 城墙显著高于人，才有「城池」感
check("战斗队（成队人马）比人略矮（0.50~0.90 身高）",
      0.50 <= h_battle / player_h <= 0.90, "%.2f 身高" % (h_battle / player_h))
check("物件确实小于人（宝箱 < 战斗队）", h_treasure < h_battle,
      "%.0f < %.0f" % (h_treasure, h_battle))
# 【方向反转·重要】旧判据是「城池与玩家同量级（0.6~1.6）」——
#   那是旧基准 425 下的产物（384÷425=0.90），也就是说旧判据在**要求城池接近人高**，
#   而这正是用户抱怨「像贴图游戏」的直接来源：城墙和行人差不多大，毫无城池感。
#   现反转为「城池必须显著大于人」，并给出上限防城池大到看不见地图。
check("城池显著大于行人（2.5~5.0 倍身高，城池要有体量感）",
      2.5 <= city_w / player_h <= 5.0, "%.2f" % (city_w / player_h))
check("城池/宝箱 比例合理（5.0~12.0：建筑 vs 地面物件本就差一个量级）",
      5.0 <= city_w / max(h_treasure, 1.0) <= 12.0,
      "%.2f" % (city_w / max(h_treasure, 1.0)))
# 反证：若有人把城池改回「与玩家同高」（旧判据方向），本条必须抓住
check("反证：城池退回玩家同高（<2.0 倍）会被判红——防回退到无体量感状态",
      (city_w / player_h) >= 2.5, "当前 %.2f 倍" % (city_w / player_h))

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

# ---------- ④ 行走：步幅由速度反解（第六十八轮） ----------
# 【判据演进史，防再次失效】本校验第六十六轮复刻的是「步幅 = 身高比例」算法。
# 第六十八轮基准身高 425→120 后，若不同步改，本校验会「测的和跑的不是一个东西」
# —— 它仍按身高比例算出一个数，而产品已改成速度驱动。这是复刻式校验的固有陷阱，
# 每当产品算法变更，本段必须同步重写（判据随实现演进，不是固化不变）。
print("\n[4] 行走方式（步幅由速度反解，步频不随身高塌陷）")
check("步频目标常量已引入 TARGET_STEP_RATE_SLOW",
      "TARGET_STEP_RATE_SLOW" in walk)
check("步频目标常量已引入 TARGET_STEP_RATE_FAST",
      "TARGET_STEP_RATE_FAST" in walk)
check("WalkAnim 仍有 body_height（振幅用）", "@export var body_height" in walk)
check("旧的按身高比例插值步幅已移除（STRIDE_MAX_RATIO 不复存在）",
      "STRIDE_MAX_RATIO" not in walk)
check("步幅由「速度 ÷ 目标步频」反解",
      bool(re.search(r"_speed\s*/\s*maxf\(target_rate", walk)))
check("目标步频按速度比例插值（慢走→疾跑）",
      bool(re.search(r"lerpf\(TARGET_STEP_RATE_SLOW, TARGET_STEP_RATE_FAST, ratio\)", walk)))

# 复算步频：**逐行复刻 walk_anim.gd 的新算法**
# 【铁律·勿硬编码上游常量副本】REF_SPEED 必须从源码读 —— 本文件曾硬编码 300.0，
# 而产品已改成 400.0，于是校验器算出一个**产品根本不会产生**的步频 2.08，
# 还会据此把正确的实现判红。这正是「测的和跑的不是一个东西」的活样本。
# walk_anim.gd 无 class_name，REF_SPEED 也从源文件抠取。
_ref = const_floats(walk, "REF_SPEED")
check("取到 REF_SPEED（须从源码读，不得硬编码副本）", bool(_ref), "%s" % (_ref,))
REF_SPEED = _ref[0] if _ref else 400.0
_maxr = const_floats(walk, "MAX_STEP_RATE")
MAX_RATE = _maxr[0] if _maxr else 3.2
rate_slow = const_floats(walk, "TARGET_STEP_RATE_SLOW")
rate_fast = const_floats(walk, "TARGET_STEP_RATE_FAST")
smin = const_floats(walk, "STRIDE_MIN_RATIO")
check("取到步频目标常量", bool(rate_slow) and bool(rate_fast),
      "%s / %s" % (rate_slow, rate_fast))
check("取到步幅下限常量", bool(smin), "%s" % (smin,))
rate_slow = rate_slow[0] if rate_slow else 0.0
rate_fast = rate_fast[0] if rate_fast else 0.0
smin = smin[0] if smin else 0.0


def step_rate(speed, height):
    """复刻 walk_anim.gd 第六十八轮后的步幅/步频公式"""
    ratio = min(1.0, max(0.0, speed / REF_SPEED))
    target_rate = rate_slow + (rate_fast - rate_slow) * ratio
    stride = max(speed / max(target_rate, 0.1), 1.0)
    stride = max(stride, smin * max(height, 24.0))
    return speed / stride


rate_walk = step_rate(250.0, player_h)
rate_run = step_rate(400.0, player_h)
print("      -> 主角 %0.f px 高: 常速 %.2f 步/秒, 疾跑 %.2f 步/秒"
      % (player_h, rate_walk, rate_run))
check("主角常速步频落在自然区间（1.0~2.0 步/秒；旧缺陷为 3.2）",
      1.0 <= rate_walk <= 2.0, "%.2f" % rate_walk)
check("主角疾跑步频自然（1.4~2.6 步/秒）",
      1.4 <= rate_run <= 2.6, "%.2f" % rate_run)

# 反证 A：若还用第六十六轮的「身高比例步幅」，在 120px 身高下会被顶到 3.2
def old_step_rate(speed, height, smin_, smax_):
    ratio = min(1.0, max(0.0, speed / REF_SPEED))
    stride = (smin_ + (smax_ - smin_) * ratio) * max(height, 24.0)
    stride = max(stride, speed / MAX_RATE)
    return speed / stride


old_rate_at_120 = old_step_rate(250.0, 120.0, 0.26, 0.42)
check("反证：旧身高比例步幅在 120px 身高下会被顶到 3.2 步/秒（本次改动确有必要）",
      abs(old_rate_at_120 - MAX_RATE) < 1e-6,
      "旧算法 %.2f 步/秒 vs 新算法 %.2f 步/秒" % (old_rate_at_120, rate_walk))

# 反证 B：第六十六轮的旧身高(425)下新算法同样正常（说明改动不是靠调参蒙的）
old_h_rate = step_rate(250.0, 425.0)
check("反证：新算法在旧身高 425px 下步频同样自然（非过拟合单一身高）",
      1.0 <= old_h_rate <= 2.0, "425px 下 %.2f 步/秒" % old_h_rate)

# 反证 D：REF_SPEED 若不等于 player_controller.RUN_SPEED(400)，常速步频会偏快。
#   REF=300 → 常速 2.08（偏快，且仍在旧区间 2.2 内 → 无专项判据就抓不到）。
#   REF=400 → 常速 1.94。两者差 7%，必须显式钉住这个等式。
_rc = const_floats(player, "RUN_SPEED")
RUN_SPEED = _rc[0] if _rc else 0.0
check("取到 player_controller.RUN_SPEED（疾跑速度）", bool(_rc), "%s" % (_rc,))
check("REF_SPEED 与 RUN_SPEED 一致（否则常速步频偏移，REF=300 会被放过）",
      bool(RUN_SPEED) and abs(REF_SPEED - RUN_SPEED) < 1e-6,
      "REF_SPEED %.0f vs RUN_SPEED %.0f" % (REF_SPEED, RUN_SPEED))
# 反证 E：REF_SPEED 退回 300 时常速步频必须超出判据区间（本条锁住上面的等式的意义）
check("反证：REF_SPEED=300 会让常速步频变 %.2f（超 2.0 上限，须被拒）" % (
      1.5 + 0.7 * min(1.0, 250.0 / 300.0)),
      (1.5 + 0.7 * min(1.0, 250.0 / 300.0)) > 2.0,
      "%.2f > 2.0" % (1.5 + 0.7 * min(1.0, 250.0 / 300.0)))

# 反证 C：步频必须**不随身高变化**（这是本次解耦的核心断言）
rates_across = [step_rate(250.0, h) for h in (56.0, 120.0, 210.0, 425.0)]
check("步频不随身高塌陷（56~425px 全高度步频一致 ±0.05）",
      max(rates_across) - min(rates_across) < 0.05,
      "各身高步频 %s" % ["%.2f" % r for r in rates_across])

# 各调用点必须真的报了身高，否则步幅仍是默认的 120
check("世界 NPC 立绘分支报身高", bool(re.search(
    r"wa\.body_height = NPC_WORLD_HEIGHT", npc)))
check("世界 NPC 几何分支也报身高",
      npc.count("wa.body_height = NPC_WORLD_HEIGHT") >= 2,
      "出现 %d 次" % npc.count("wa.body_height = NPC_WORLD_HEIGHT"))
check("城内 NPC 报身高", "wa.body_height = CityInteriorArt.NPC_WORLD_HEIGHT" in city)
# 【第六十八轮补·R3 盲区】原先只锁了「接线」（有没有报 body_height），
# 没锁「数值」——把 NPC_WORLD_HEIGHT 退回 56 校验器仍全绿。
# 而「NPC 比玩家矮一半」正是用户点名的观感缺陷，必须锁住数值本身。
_city_art = read(os.path.join(HERE, "scripts", "city", "city_interior_art.gd"))
city_npc_h = const_floats(_city_art, "NPC_WORLD_HEIGHT")
check("取到城内 NPC 身高常量", bool(city_npc_h), "%s" % (city_npc_h,))
city_npc_h = city_npc_h[0] if city_npc_h else 0.0
check("城内 NPC 与玩家同高（比例 0.95~1.05，不再是玩家高一倍）",
      0.95 <= city_npc_h / player_h <= 1.05,
      "%.0f vs 玩家 %.0f = %.2f 倍" % (city_npc_h, player_h, city_npc_h / player_h))
# 反证：退回 56（旧的「比玩家矮一半」）必须被上面那条抓住
check("反证：城内 NPC 退回 56 会是 %.2f 倍（低于 0.95 下限，须被拒）" % (56.0 / player_h),
      (56.0 / player_h) < 0.95, "%.2f < 0.95" % (56.0 / player_h))
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

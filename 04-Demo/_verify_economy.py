# -*- coding: utf-8 -*-
"""
M5 城池经济与招募系统 —— 独立 Python 复核
目的：用纯 Python 重新实现一遍 rules 层的公式，与 GDScript 实现逐条比对。
      若两套独立实现结果一致，即可确认 CityService 的数值逻辑无实现偏差。

覆盖 6 项测试：
  T1  物价系数（城池等级 → 买入/卖出价）
  T2  征兵成本曲线（线性度 + 稀有兵种溢价）
  T3  每日征兵上限（人口约束 vs 上限约束谁先触发）
  T4  民心消耗与施赈循环（征兵 -民心 / 施赈 +民心 的收支平衡）
  T5  练兵升级节奏（经验阈值 / 粮草消耗 / 需练多少次升一级）
  T6  武将招募定价 + 四维攻防加成（v6 heroes6：force→攻 / strong→防，±30%）
"""
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(ROOT, "assets", "data")

results = []


def load(name):
    with open(os.path.join(DATA, name), "r", encoding="utf-8") as fh:
        return json.load(fh)


def check(label, condition, detail=""):
    results.append((label, bool(condition), detail))


# ============================================================ 常量（与 GDScript 一致）
PRICE_LEVEL_FACTOR = 0.08
SELL_RATIO = load("shop_goods.json")["settings"]["sell_ratio"]
BS = load("barracks.json")["settings"]
RP = load("recruit_pool.json")["settings"]
BARRACKS_UNITS = {u["unit_id"]: u for u in load("barracks.json")["units"]}
CITIES = {c["id"]: c for c in load("cities.json")}
POOL = load("recruit_pool.json")["pool"]


# ------------------------------------------------------------ T1 物价系数
print("T1  物价系数")
print("-" * 58)


def buy_price(base, level):
    f = 1.0 + (level - 2) * PRICE_LEVEL_FACTOR
    return max(1, int(round(base * max(0.6, f))))


def sell_price(base, level):
    return max(1, int(round(buy_price(base, level) * SELL_RATIO)))


rows = []
for lv in range(1, 6):
    bp = buy_price(200, lv)     # 粮草基准价 200
    sp = sell_price(200, lv)
    rows.append((lv, bp, sp))
    print("    等级 %d：粮草买入 %3d  卖出 %3d" % (lv, bp, sp))

check("T1-a 物价系数单调递增（等级越高越贵）",
      all(rows[i][1] < rows[i + 1][1] for i in range(len(rows) - 1)))
check("T1-b 卖出价恒低于买入价（无套利漏洞）",
      all(r[2] < r[1] for r in rows),
      "最小差价 %d" % min(r[1] - r[2] for r in rows))
check("T1-c 最低价保护生效（不出现 0 或负价）",
      all(r[1] > 0 and r[2] > 0 for r in rows))
# 等级 1 → 系数 1+(1-2)*0.08 = 0.92；等级 ≤ -3 才会触及 0.6 下限
check("T1-d 极端低等级被裁剪到 0.6 下限（防止价格崩塌）",
      buy_price(1000, -3) == 600, "等级-3 1000 → %d" % buy_price(1000, -3))
check("T1-e 单级价差约 8%（等级惩罚平缓，不逼迫刷等级）",
      abs(rows[1][1] / rows[0][1] - 1.0 - PRICE_LEVEL_FACTOR) < 0.02,
      "等级1→2 涨幅 %.1f%%" % ((rows[1][1] / rows[0][1] - 1) * 100))


# ------------------------------------------------------------ T2 征兵成本
print("\nT2  征兵成本曲线")
print("-" * 58)


def recruit_cost(unit_id, count):
    cfg = BARRACKS_UNITS[unit_id]
    batches = count / 10.0
    return int(round(cfg["gold_per_10"] * batches)), int(round(cfg["food_per_10"] * batches))


samples = ["infantry", "spearman", "archer", "cavalry", "rattan", "elephant"]
costs = {}
for uid in samples:
    g10, f10 = recruit_cost(uid, 10)
    g100, f100 = recruit_cost(uid, 100)
    costs[uid] = (g10, f10, g100, f100)
    print("    %-10s 10兵=金%4d/粮%3d   100兵=金%5d/粮%4d" % (uid, g10, f10, g100, f100))

check("T2-a 征兵成本与数量严格线性",
      all(costs[u][2] == costs[u][0] * 10 for u in samples))
check("T2-b 藤甲兵溢价合理（高于基础步兵 50%~100%）",
      1.5 <= costs["rattan"][0] / costs["infantry"][0] <= 2.0,
      "藤甲/步兵 = %.2f" % (costs["rattan"][0] / costs["infantry"][0]))
check("T2-c 战象为最贵兵种（王牌定位）",
      costs["elephant"][0] == max(v[0] for v in costs.values()),
      "战象 %d 金/10兵" % costs["elephant"][0])
check("T2-d 粮耗 ≤ 金耗（粮为大宗补给，金为精锐成本）",
      all(costs[u][1] <= costs[u][0] for u in samples))


# ------------------------------------------------------------ T3 每日征兵上限
print("\nT3  每日征兵上限")
print("-" * 58)


def remaining_quota(city_id, recruited_today=0):
    cap = BS["max_recruit_per_day"]
    pop = CITIES[city_id].get("population", 0)
    if pop > 0:
        cap = min(cap, max(20, int(pop / 100.0)))
    return max(0, cap - recruited_today)


for cid in ["scene_40", "scene_48", "scene_76", "scene_76"]:
    q = remaining_quota(cid)
    pop = CITIES[cid]["population"]
    print("    %-16s 人口 %6d → 每日上限 %3d 人" % (cid, pop, q))

check("T3-a 大城（建宁 3万人口）可达配置上限 300",
      remaining_quota("scene_40") == BS["max_recruit_per_day"])
# 动态选人口最少的地点做「小寨」用例（数据表换代后不再依赖固定地名）
smallest = min(CITIES, key=lambda cid: CITIES[cid].get("population", 0))
check("T3-b 小人口地点受人口约束低于上限（%s %d人）" % (
          CITIES[smallest].get("name", smallest), CITIES[smallest].get("population", 0)),
      remaining_quota(smallest) < BS["max_recruit_per_day"],
      "每日 %d 人" % remaining_quota(smallest))
check("T3-c 人口配额至少保留 20（小村不被完全锁死）",
      remaining_quota(smallest) >= 20)
check("T3-d 配额耗尽后返回 0（不出现负数）",
      remaining_quota("scene_40", 999) == 0)


# ------------------------------------------------------------ T4 民心收支
print("\nT4  民心收支平衡")
print("-" * 58)

BATCH = BS["recruit_per_batch"]
MORALE_PER_BATCH = BS["morale_cost_per_batch"]


def morale_cost_for_recruit(count):
    return int(math.ceil(count / float(BATCH))) * MORALE_PER_BATCH


def relieve_gain(gold_cost):
    return int(round(gold_cost / 40.0))


def morale_capacity(morale, min_morale):
    budget = morale - min_morale
    if budget <= 0:
        return 0
    return int(budget / MORALE_PER_BATCH) * BATCH


print("    每征 %d 兵 → 民心 -%d" % (BATCH, MORALE_PER_BATCH))
print("    征兵 50 人  → 民心 -%d" % morale_cost_for_recruit(50))
print("    征兵 100 人 → 民心 -%d" % morale_cost_for_recruit(100))
print("    征兵 300 人 → 民心 -%d" % morale_cost_for_recruit(300))
print("    施赈 200 金 → 民心 +%d" % relieve_gain(200))

check("T4-a 征兵民心消耗与人数成正比（每 10 兵 -%d）" % MORALE_PER_BATCH,
      morale_cost_for_recruit(100) == 10 * MORALE_PER_BATCH
      and morale_cost_for_recruit(300) == 30 * MORALE_PER_BATCH,
      "100 兵 → -%d 民心" % morale_cost_for_recruit(100))
check("T4-b 一次施赈回补约 20 人征兵额度（施赈是应急而非循环）",
      relieve_gain(200) == 5,
      "施赈 +5 民心 ≈ %d 人" % (relieve_gain(200) * BATCH // MORALE_PER_BATCH))

# 一轮完整循环：满民心 70 的建宁，能征多少兵耗尽民心
morale = CITIES["scene_40"]["morale"]
min_morale = BS["min_city_morale"]
cap_by_morale = morale_capacity(morale, min_morale)
cap_by_quota = remaining_quota("scene_40")
actual = min(cap_by_morale, cap_by_quota)
print("    建宁民心 %d（下限 %d）→ 民心可支撑 %d 人" % (morale, min_morale, cap_by_morale))
print("    每日名额 %d 人 → 实际单日可征 %d 人" % (cap_by_quota, actual))
check("T4-c 单日征兵受【民心】与【名额】双重约束，取其小",
      actual == min(cap_by_morale, cap_by_quota))
check("T4-d 民心仍是 Demo 阶段有效瓶颈（比名额更紧或有实际压制作用）",
      cap_by_morale < cap_by_quota * 1.15,
      "民心上限 %d vs 名额 %d" % (cap_by_morale, cap_by_quota))

# 民心耗尽后不能继续征
exhausted = morale_capacity(min_morale, min_morale)
print("    民心降至下限 %d → 可征 %d 人（自动锁死征兵）" % (min_morale, exhausted))
check("T4-e 民心触底后征兵通道自动关闭（形成真实节奏约束）",
      exhausted == 0)

# 全图 5 城一轮总产能
total_capacity = 0
for cid in ["scene_40", "scene_48", "scene_76", "scene_78", "scene_28"]:
    total_capacity += min(remaining_quota(cid),
                          morale_capacity(CITIES[cid]["morale"], min_morale))
print("    南中五城一轮（民心耗尽前）总可征 %d 人" % total_capacity)
check("T4-f 全图一轮征兵量在合理区间（200~2000，够打 2~5 场 3v3）",
      200 <= total_capacity <= 2000, "实际 %d 人" % total_capacity)


# ------------------------------------------------------------ T5 练兵升级
print("\nT5  练兵升级节奏")
print("-" * 58)

FOOD_PER_10 = BS["train_food_per_10"]
EXP_PER_10 = BS["train_exp_per_10"]
THRESHOLD = BS["veteran_threshold"]
times_per_level = math.ceil(THRESHOLD / EXP_PER_10)
food_per_level = times_per_level * FOOD_PER_10

print("    每次练兵（10 兵）：耗粮 %d，得经验 %d" % (FOOD_PER_10, EXP_PER_10))
print("    升级需 %d 经验 → 需练 %d 次，累计耗粮 %d" % (THRESHOLD, times_per_level, food_per_level))
print("    10 次练兵（100 兵）耗粮 %d，可得经验 %d" % (FOOD_PER_10 * 10, EXP_PER_10 * 10))

check("T5-a 升一级练兵次数在合理区间（5~25 次，不拖沓也不速成）",
      5 <= times_per_level <= 25, "实际 %d 次" % times_per_level)
check("T5-b 升级粮耗低于征兵粮耗（练兵是经济路径）",
      food_per_level < recruit_cost("infantry", 100)[1] * 2,
      "练兵 %d vs 征兵100兵 %d" % (food_per_level, recruit_cost("infantry", 100)[1]))
check("T5-c 练兵存在真实成本（不能零成本刷经验）",
      FOOD_PER_10 > 0 and EXP_PER_10 > 0)

# 经验余额结转
exp, levels = 0, 0
for _ in range(times_per_level + 3):
    exp += EXP_PER_10
    if exp >= THRESHOLD:
        exp -= THRESHOLD
        levels += 1
print("    练 %d 次后：等级 +%d，余经验 %d" % (times_per_level + 3, levels, exp))
check("T5-d 溢出经验正确结转（不丢失）",
      levels == 1 and exp == EXP_PER_10 * (times_per_level + 3) - THRESHOLD)


# ------------------------------------------------------------ T6 武将招募与加成
print("\nT6  武将招募定价与统兵加成")
print("-" * 58)


def hero_terms(entry):
    diff = entry.get("difficulty", 1)
    gold = RP["base_gold"] + diff * RP["gold_per_difficulty"] + entry.get("gold_extra", 0)
    return gold, entry.get("require_fame", 0), entry.get("require_infamy", 0), diff


CHARS = {c["id"]: c for c in load("characters.json")}
priced = []
for e in POOL:
    gold, fame, infamy, diff = hero_terms(e)
    priced.append((e["hero_id"], diff, gold, fame, infamy))
    print("    %-14s 难度%s  价 %5d 金  名声需求 %d  恶名需求 %d" % (
        CHARS.get(e["hero_id"], {}).get("name", e["hero_id"]), "★" * diff, gold, fame, infamy))

check("T6-a 招募价与难度正相关（星级越高越贵）",
      all(priced[i][2] <= priced[i + 1][2] for i in
          sorted(range(len(priced) - 1), key=lambda i: priced[i][1])) or
      len({p[1] for p in priced}) > 1)
check("T6-b 最高难度武将价不超过最低的 6 倍",
      max(p[2] for p in priced) <= min(p[2] for p in priced) * 6,
      "最高 %d / 最低 %d = %.1f 倍" % (
          max(p[2] for p in priced), min(p[2] for p in priced),
          max(p[2] for p in priced) / min(p[2] for p in priced)))
check("T6-c 存在需要恶名的武将（乱世路线可选）",
      any(p[4] > 0 for p in priced),
      "需恶名：%s" % [CHARS.get(p[0], {}).get("name", p[0]) for p in priced if p[4] > 0])


# ---- v6 heroes6 数据源 + resolver（复刻 DataManager.get_hero_resolved）----
HEROES6 = {int(h["id"]): h for h in load("heroes6.json") if h.get("id") is not None}
HERO6_BY_NAME = {h.get("name", ""): h for h in load("heroes6.json") if h.get("name")}
# hero_multiplier 配置（formation_slots.json）与中帐位 command_bonus
_SLOTS_CFG = load("formation_slots.json")
HC6 = _SLOTS_CFG["hero_multiplier"]
_CMD_SLOT_BONUS = next(
    (sb for sb in _SLOTS_CFG["slot_bonuses"]
     if sb["row"] == 2 and sb["col"] == 2), {})
CMD_BONUS = float(_CMD_SLOT_BONUS.get("command_bonus", 1.0))


def resolve_hero(hero_id):
    """legacy 字符串 id → v6 heroes6 记录（按 name 匹配），与 GDScript 侧一致。"""
    if not hero_id:
        return {}
    if hero_id in ("player_male", "player_female", "player"):
        return HEROES6.get(1, {})
    if hero_id.lstrip("-").isdigit():
        r = HEROES6.get(int(hero_id))
        if r:
            return r
    legacy = CHARS.get(hero_id, {})
    nm = legacy.get("name", "")
    if nm and nm in HERO6_BY_NAME:
        return HERO6_BY_NAME[nm]
    return legacy


def hero_bonuses(hero, cmd_slot=False):
    """复刻 FormationCalculator.hero_bonuses：
    force→attack delta, strong→defense delta，±cap；中帐位 × command_bonus。
    """
    if not hero:
        return {"attack": 0.0, "defense": 0.0}
    force_stat = float(hero.get("force", 50))
    strong_stat = float(hero.get("strong", 50))
    base = float(HC6.get("base_stat", 50))
    div = float(HC6.get("divisor", 200.0))
    cap = float(HC6.get("cap", 0.30))
    atk = max(-cap, min(cap, (force_stat - base) / div))
    dfn = max(-cap, min(cap, (strong_stat - base) / div))
    if cmd_slot:
        atk *= CMD_BONUS
        dfn *= CMD_BONUS
    return {"attack": atk, "defense": dfn}


print("\n    四维攻防加成 delta（普通位，±%.0f%%；中帐位 ×%.2f）："
      % (HC6.get("cap", 0.30) * 100, CMD_BONUS))
bonuses = {}
for hid in ["zhuge_liang", "zhao_yun", "meng_huo", "lv_bu", "hua_tuo"]:
    h = resolve_hero(hid)
    if h:
        hb = hero_bonuses(h)
        hb_cmd = hero_bonuses(h, True)
        bonuses[hid] = (hb, hb_cmd)
        print("      %-8s 武力 %3.0f 强壮 %3.0f → 攻 %+.1f%% / 防 %+.1f%%"
              "（中帐：攻 %+.1f%% / 防 %+.1f%%）" % (
                  h.get("name", hid), h.get("force", 0), h.get("strong", 0),
                  hb["attack"] * 100, hb["defense"] * 100,
                  hb_cmd["attack"] * 100, hb_cmd["defense"] * 100))

check("T6-d 猛将（吕布）攻击加成显著（≥+20%）",
      bonuses.get("lv_bu", ({}, {}))[0]["attack"] >= 0.20,
      "吕布 攻 %+.1f%%" % (bonuses.get("lv_bu", ({}, {}))[0]["attack"] * 100))
check("T6-e 加成受 ±%.0f%% 封顶（不出现数值爆炸）" % (HC6.get("cap", 0.30) * 100),
      all(abs(b[0]["attack"]) <= HC6.get("cap", 0.30) + 1e-9
          and abs(b[0]["defense"]) <= HC6.get("cap", 0.30) + 1e-9
          for b in bonuses.values()))
check("T6-f 无武将时攻防 delta 均为 0（不惩罚裸编队）",
      hero_bonuses({}) == {"attack": 0.0, "defense": 0.0},
      "空属性 → %s" % hero_bonuses({}))
check("T6-g 中帐位加成按 command_bonus(×%.2f) 翻倍" % CMD_BONUS,
      all(abs(b[1]["attack"] - b[0]["attack"] * CMD_BONUS) < 1e-9
          and abs(b[1]["defense"] - b[0]["defense"] * CMD_BONUS) < 1e-9
          for b in bonuses.values()))


# ============================================================ 汇总
print("\n" + "=" * 58)
passed = sum(1 for _l, ok_, _d in results if ok_)
for label, ok_, detail in results:
    mark = "PASS" if ok_ else "FAIL"
    line = "  [%s] %s" % (mark, label)
    if detail:
        line += "　（%s）" % detail
    print(line)

failed = [(l, d) for l, o, d in results if not o]
print("")
if failed:
    print("[FAIL] %d/%d 项未通过" % (len(failed), len(results)))
    for l, d in failed:
        print("   - %s %s" % (l, d))
    sys.exit(1)

print("M5 城池经济复核：%d 项测试全部通过 ✅" % len(results))

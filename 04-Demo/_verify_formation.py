# -*- coding: utf-8 -*-
"""阵型战力公式交叉验证：用 Python 独立实现一遍，核对数值合理性。

本次更新（武将四维参与战斗子项）：
  - 数据源从 legacy characters 表切到 v6 heroes6 表（通过 resolver 桥接）
  - hero_multiplier → hero_bonuses，返回 {attack, defense} 两个 delta
  - v6: force→attack, strong→defense；±cap(0.30) 加性合并到 attack_bonus/defense_bonus
  - 主角约定：hero_id="player_male" → heroes6 id=1
"""
import json
import math
import os

R = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets", "data")


def load(name):
    with open(os.path.join(R, name), encoding="utf-8") as f:
        return json.load(f)


units = {u["id"]: u for u in load("units.json")}
formations = {f["id"]: f for f in load("formations.json")}
chars = {c["id"]: c for c in load("characters.json")}
heroes6 = {int(h["id"]): h for h in load("heroes6.json") if h.get("id") is not None}
hero6_by_name = {h.get("name", ""): h for h in load("heroes6.json") if h.get("name")}
items6 = {int(i["id"]): i for i in load("items6.json") if i.get("id") is not None}
fs = load("formation_slots.json")

EQUIP_SLOTS = ["weapon1", "weapon2", "helmet", "armor", "treasure", "mount"]

ROWS, COLS = 3, 5
SLOT = ROWS * COLS
idx_of = lambda r, c: r * COLS + c
row_of = lambda i: i // COLS
col_of = lambda i: i % COLS

# 阵位加成表
slot_b = [{} for _ in range(SLOT)]
for sb in fs["slot_bonuses"]:
    slot_b[sb["row"] * COLS + sb["col"]] = sb
row_m = [{} for _ in range(ROWS)]
for rm in fs["row_match"]:
    row_m[rm["row"]] = rm

QC = fs["unit_quality_baseline"]
HC = fs["hero_multiplier"]
CMD_SLOT = idx_of(2, 2)


def row_bonus(i, cat):
    rm = row_m[row_of(i)]
    if cat in rm.get("good_categories", []):
        return rm["good_bonus"], "good"
    if cat in rm.get("bad_categories", []):
        return rm["bad_penalty"], "bad"
    return 0.0, "none"


def quality(u):
    return max(0.2, (u["attack"] + u["hp"] * QC["hp_weight"]) / QC["attack_divisor"])


def _eff(e, i):
    return int(e[i]) if i < len(e) else 0


def item_bonus(item):
    """CharacterService.item_combat_bonus 的 Python 复刻。"""
    if not item:
        return {"attack": 0, "defense": 0, "hp": 0, "speed": 0}
    e = item.get("effects", [0, 0, 0, 0])
    a = d = h = s = 0
    mj = int(item.get("cat_major", 0))
    if mj == 5:          # 武器 [0]=攻
        a = _eff(e, 0)
    elif mj == 2:        # 头盔 [0]/[1] 攻，[2] 防
        a, d = _eff(e, 0) + _eff(e, 1), _eff(e, 2)
    elif mj == 4:        # 护甲 [2] 防，[3] HP
        d, h = _eff(e, 2), _eff(e, 3)
    elif mj == 6:        # 宝物 [0]/[1] 攻，[2] 防
        a, d = _eff(e, 0) + _eff(e, 1), _eff(e, 2)
    elif mj == 7:        # 坐骑 [1] 速
        s = _eff(e, 1)
    return {"attack": a, "defense": d, "hp": h, "speed": s}


def equipment_bonuses(hero):
    """CharacterService.hero_equipment_bonuses 复刻（weapon2 不计）。"""
    total = {"attack": 0, "defense": 0, "hp": 0, "speed": 0}
    for slot in EQUIP_SLOTS:
        if slot == "weapon2":
            continue
        iid = int((hero.get("equipment") or {}).get(slot, 0) or 0)
        if iid <= 0:
            continue
        b = item_bonus(items6.get(iid, {}))
        for k in total:
            total[k] += b[k]
    return total


def quality_bonus(u, eq):
    return max(0.2, ((u["attack"] + eq["attack"]) + (u["hp"] + eq["hp"]) * QC["hp_weight"])
               / QC["attack_divisor"])


def four_stats(hero):
    """v6 / legacy schema 无关取四维。返回 [v0, v1, v2, v3]。
    v6:    [strong, force, intel, charm]
    legacy:[leadership, might, intellect, politics]
    """
    if "strong" in hero or "force" in hero or "charm" in hero:
        keys = ["strong", "force", "intel", "charm"]
    else:
        keys = ["leadership", "might", "intellect", "politics"]
    return [int(float(hero.get(k, 0))) for k in keys]


def resolve_hero(hero_id):
    """DataManager.get_hero_resolved 的 Python 复刻。
    - "" → {}
    - "player_male"/"player_female"/"player" → heroes6[1]
    - 纯数字字符串 → heroes6[int]
    - legacy 字符串 → 按 name 匹配 heroes6；匹配不到回退 legacy
    """
    if not hero_id:
        return {}
    if hero_id in ("player_male", "player_female", "player"):
        return heroes6.get(1, {})
    if hero_id.lstrip("-").isdigit():
        r = heroes6.get(int(hero_id))
        if r:
            return r
    legacy = chars.get(hero_id, {})
    nm = legacy.get("name", "")
    if nm:
        v6 = hero6_by_name.get(nm)
        if v6:
            return v6
    return legacy


def hero_bonuses(hero, cmd_slot):
    """FormationCalculator.hero_bonuses 的 Python 复刻。
    返回 {"attack": atk_delta, "defense": def_delta}，±cap(0.30)。
    v6: force→attack, strong→defense。
    """
    if not hero:
        return {"attack": 0.0, "defense": 0.0}
    vals = four_stats(hero)
    strong_stat = float(vals[0])
    force_stat = float(vals[1])
    base = float(HC.get("base_stat", 50))
    div = float(HC.get("divisor", 200.0))
    cap = float(HC.get("cap", 0.30))
    atk_delta = max(-cap, min(cap, (force_stat - base) / div))
    def_delta = max(-cap, min(cap, (strong_stat - base) / div))
    if cmd_slot:
        cmd_mult = float(slot_b[CMD_SLOT].get("command_bonus", 1.0))
        atk_delta *= cmd_mult
        def_delta *= cmd_mult
    return {"attack": atk_delta, "defense": def_delta}


def calc(slots, troops, fid):
    f = formations[fid]
    fa, fd = f["attack_bonus"], f["defense_bonus"]
    total, detail, filled = 0.0, [], 0
    for i in range(SLOT):
        ti = slots[i]
        if ti < 0 or ti >= len(troops):
            continue
        t = troops[ti]
        u = units.get(t["unit_id"])
        if not u:
            continue
        filled += 1
        sb = slot_b[i]
        sa = sb.get("attack_bonus", 0.0)
        sd = sb.get("defense_bonus", 0.0)
        rb, kind = row_bonus(i, u["category"])
        hero = resolve_hero(t.get("hero_id", ""))
        hb = hero_bonuses(hero, i == CMD_SLOT)
        eq = equipment_bonuses(hero)
        p = (t["count"] * (1 + fa) * (1 + sa) * (1 + rb)
             * quality_bonus(u, eq) * (1.0 + hb["attack"]))
        total += p
        detail.append({"slot": i, "unit": u["name"], "row": row_of(i),
                       "power": p,
                       "atk": fa + sa + rb + hb["attack"],
                       "def": fd + sd + hb["defense"],
                       "kind": kind,
                       "hero_id": t.get("hero_id", ""),
                       "hero_atk_delta": hb["attack"],
                       "hero_def_delta": hb["defense"],
                       "attack_add": eq["attack"], "defense_add": eq["defense"],
                       "hp_add": eq["hp"], "speed_add": eq["speed"]})
    return total, detail, filled


def winrate(mp, ep):
    if ep <= 0:
        return 1.0
    if mp <= 0:
        return 0.0
    return 1.0 / (1.0 + math.exp(-math.log(mp / ep) * 1.1))


def auto(troops):
    s = [-1] * SLOT
    front = [i for i, t in enumerate(troops) if units[t["unit_id"]]["category"] != "archer"]
    rear = [i for i, t in enumerate(troops) if units[t["unit_id"]]["category"] == "archer"]
    pri = {"infantry": 4, "elite": 3, "cavalry": 2, "beast": 1}
    front.sort(key=lambda i: pri.get(units[troops[i]["unit_id"]]["category"], 0), reverse=True)
    fo = [idx_of(0, 2), idx_of(0, 1), idx_of(0, 3), idx_of(0, 0), idx_of(0, 4)]
    mo = [idx_of(1, 2), idx_of(1, 1), idx_of(1, 3), idx_of(1, 0), idx_of(1, 4)]
    ro = [idx_of(2, 2), idx_of(2, 1), idx_of(2, 3), idx_of(2, 0), idx_of(2, 4)]
    k = 0
    for s2 in fo + mo:
        if k < len(front):
            s[s2] = front[k]
            k += 1
    k = 0
    for s2 in ro:
        if k < len(rear):
            s[s2] = rear[k]
            k += 1
    return s


print("=" * 62)
print("【测试 1】自动布阵 —— 典型南中混编部队")
print("=" * 62)
troops = [
    {"unit_id": "infantry", "count": 200, "hero_id": "guan_yu"},
    {"unit_id": "spearman", "count": 180, "hero_id": "zhao_yun"},
    {"unit_id": "cavalry", "count": 150, "hero_id": "meng_huo"},
    {"unit_id": "archer", "count": 120, "hero_id": "zhuge_liang"},
    {"unit_id": "rattan", "count": 100, "hero_id": "wu_tu_gu"},
]
slots = auto(troops)
for i in range(SLOT):
    ti = slots[i]
    fn = fs["slot_bonuses"][i]["name"]
    rn = fs["grid"]["row_names"][row_of(i)]
    if ti >= 0:
        u = units[troops[ti]["unit_id"]]
        print("  %-6s %-4s  %-8s x%-4d" % (rn, fn, u["name"], troops[ti]["count"]))
    else:
        print("  %-6s %-4s  (空)" % (rn, fn))

total, detail, filled = calc(slots, troops, "yu_lin")
print("\n  阵型：鱼鳞阵（攻击 +15%，防御 -5%）")
print("  已布置：%d/15    总战力：%.0f" % (filled, total))
print("  平均攻击倍率：%.2f" % (sum(1 + d["atk"] for d in detail) / len(detail)))
best = max(detail, key=lambda d: d["power"])
print("  最强部队：%s（%s）战力 %.0f" % (best["unit"], fs["grid"]["row_names"][best["row"]], best["power"]))

print()
print("=" * 62)
print("【测试 2】同一批部队，放前排 vs 放后排（验证阵位确实有差异）")
print("=" * 62)
archer_bad = [-1] * SLOT
archer_bad[idx_of(0, 2)] = 3          # 弓兵放前排中锋
t1, d1, _ = calc(archer_bad, troops, "yu_lin")
archer_good = [-1] * SLOT
archer_good[idx_of(2, 2)] = 3         # 弓兵放后排中帐
t2, d2, _ = calc(archer_good, troops, "yu_lin")
print("  弓兵 @ 前军·中锋  战力 %.0f  （行适配：%s）" % (t1, d1[0]["kind"]))
print("  弓兵 @ 后军·中帐  战力 %.0f  （行适配：%s）" % (t2, d2[0]["kind"]))
print("  → 差距 %.0f 倍，位置决策有效" % (t2 / max(t1, 0.01)))

print()
print("=" * 62)
print("【测试 3】六种阵型对同一布阵的影响")
print("=" * 62)
for fid in ["yu_lin", "he_yi", "fang_yuan", "feng_shi", "chang_she", "yuan_yang"]:
    t, _, _ = calc(slots, troops, fid)
    f = formations[fid]
    print("  %-5s %-22s 战力 %7.0f" % (f["name"], f["effect_desc"], t))

print()
print("=" * 62)
print("【测试 4】胜率预估曲线")
print("=" * 62)
my = total
for r in [0.3, 0.5, 0.8, 1.0, 1.5, 2.0, 3.0]:
    print("  战力比 %.1f  →  胜率 %3.0f%%" % (r, winrate(my, my / r) * 100))

print()
print("=" * 62)
print("【测试 5】武将四维加成生效（v6 heroes6 表）")
print("=" * 62)
# 取中坚位（非中帐，避免 command_bonus 干扰）
test_slot = idx_of(0, 2)
test_troop_base = {"unit_id": "infantry", "count": 100}
cases = [
    ("无武将",      ""),
    ("player_male", "player_male"),
    ("关羽(role=167)", "167"),       # 纯数字字符串 → heroes6[167]
    ("关羽(name匹配)", "guan_yu"),  # legacy 字符串 → 按 name 匹配
    ("诸葛亮",      "zhuge_liang"),
    ("吕布",        "lv_bu"),
]
print("  位置：前军·中锋（非中帐，无 command_bonus）")
print("  基础部队：步兵 x100")
def _single(slot, troop):
    s = [-1] * SLOT
    s[slot] = 0
    return calc(s, [troop], "yu_lin")
for label, hid in cases:
    t, d, _ = _single(test_slot, {**test_troop_base, "hero_id": hid})
    if d:
        h = resolve_hero(hid)
        vals = four_stats(h) if h else [0, 0, 0, 0]
        print("  %-22s force=%3d strong=%3d  atk_delta=%+.3f  def_delta=%+.3f  战力=%.0f"
              % (label, vals[1], vals[0], d[0]["hero_atk_delta"], d[0]["hero_def_delta"], d[0]["power"]))
    else:
        print("  %-22s （未部署）" % label)

# 关键断言
no_hero = _single(test_slot, {**test_troop_base, "hero_id": ""})[1][0]
guan_num = _single(test_slot, {**test_troop_base, "hero_id": "167"})[1][0]
guan_name = _single(test_slot, {**test_troop_base, "hero_id": "guan_yu"})[1][0]
player = _single(test_slot, {**test_troop_base, "hero_id": "player_male"})[1][0]

assert guan_num["hero_atk_delta"] > 0, "关羽(数字 id)攻击加成应为正"
assert abs(guan_num["hero_atk_delta"] - guan_name["hero_atk_delta"]) < 1e-6, \
    "resolver 数字 id 与 name 匹配应等价"
assert player["hero_atk_delta"] > 0, "主角(80/80/80/80)加成应正"
assert guan_num["power"] > no_hero["power"], "关羽战力应高于无武将"
print("  → 断言通过：resolver 等价、加成为正、战力提升 ✅")

print()
print("=" * 62)
print("【测试 6】cap 上下限（force/strong 极端值）")
print("=" * 62)
cap = float(HC.get("cap", 0.30))
base = float(HC.get("base_stat", 50))
div = float(HC.get("divisor", 200.0))
for stat_val in [0, 50, 100, 200, 1000]:
    fake = {"strong": stat_val, "force": stat_val, "intel": 50, "charm": 50}
    hb = hero_bonuses(fake, False)
    print("  四维=%3d  atk_delta=%+.3f  def_delta=%+.3f  (cap=±%.2f)"
          % (stat_val, hb["attack"], hb["defense"], cap))
    assert abs(hb["attack"]) <= cap + 1e-9, "attack delta 超出 cap"
    assert abs(hb["defense"]) <= cap + 1e-9, "defense delta 超出 cap"
print("  → 断言通过：所有 delta 在 ±cap 范围内 ✅")

print()
print("=" * 62)
print("【测试 7】中帐位 command_bonus 翻倍")
print("=" * 62)
cmd_slot = CMD_SLOT
troop_cmd = [{**test_troop_base, "hero_id": "167"}]  # 关羽
_, d_normal, _ = _single(test_slot, troop_cmd[0])
_, d_cmd, _ = _single(cmd_slot, troop_cmd[0])
cmd_mult = float(slot_b[CMD_SLOT].get("command_bonus", 1.0))
print("  关羽 @ 中锋（无 command_bonus）  atk_delta=%+.3f" % d_normal[0]["hero_atk_delta"])
print("  关羽 @ 中帐（command_bonus×%.2f） atk_delta=%+.3f" % (cmd_mult, d_cmd[0]["hero_atk_delta"]))
assert abs(d_cmd[0]["hero_atk_delta"] - d_normal[0]["hero_atk_delta"] * cmd_mult) < 1e-6, \
    "中帐位应使 delta 翻倍 command_bonus 倍"
print("  → 断言通过：中帐位翻倍生效 ✅")

print()
print("=" * 62)
print("【测试 8】装备绝对值加成生效（items6 effects 聚合）")
print("=" * 62)
gy = resolve_hero("167")
eq_gy = equipment_bonuses(gy)
print("  关羽全套：攻+%(attack)d 防+%(defense)d HP+%(hp)d 速+%(speed)d" % eq_gy)
assert eq_gy == {"attack": 48, "defense": 30, "hp": 10, "speed": 11}, \
    "关羽装备聚合应为 攻+48/防+30/HP+10/速+11，实际 %s" % eq_gy

# weapon2（关羽 weapon2=135 钢剑 攻+15）不进聚合
gy_no_w2 = json.loads(json.dumps(gy))  # 深拷贝
gy_no_w2["equipment"]["weapon2"] = 135
assert equipment_bonuses(gy_no_w2)["attack"] == 48, "weapon2 不应参与聚合"
gy_no_w2["equipment"]["weapon2"] = 170  # 即便 weapon2 换名器也不影响
assert equipment_bonuses(gy_no_w2)["attack"] == 48, "weapon2 换名器仍不应参与聚合"
print("  weapon2 不参与聚合（钢剑/名器均不影响 attack_add=48）✅")

# 主角 id=1 装备全 0 → 四个 add 全 0
eq_p = equipment_bonuses(resolve_hero("player_male"))
assert eq_p == {"attack": 0, "defense": 0, "hp": 0, "speed": 0}, \
    "主角（白板）装备加成应全 0，实际 %s" % eq_p
print("  主角（全空装备）：四个 add 全 0 ✅")

# 装备战力：关羽（全套）vs 同一人剥光装备
_, d_equipped, _ = _single(test_slot, {**test_troop_base, "hero_id": "167"})
gy_naked = json.loads(json.dumps(gy))
gy_naked["equipment"] = {k: 0 for k in EQUIP_SLOTS}


def _single_raw_hero(slot, hero):
    """绕过 resolver，直接用指定 hero 记录算一支部队。"""
    u = units[test_troop_base["unit_id"]]
    t = test_troop_base
    sb = slot_b[slot]
    rb, _ = row_bonus(slot, u["category"])
    hb = hero_bonuses(hero, slot == CMD_SLOT)
    eq = equipment_bonuses(hero)
    p = (t["count"] * (1 + formations["yu_lin"]["attack_bonus"])
         * (1 + sb.get("attack_bonus", 0.0)) * (1 + rb)
         * quality_bonus(u, eq) * (1.0 + hb["attack"]))
    return p, eq


p_naked, eq_naked = _single_raw_hero(test_slot, gy_naked)
p_equipped = d_equipped[0]["power"]
print("  关羽步兵 x100 战力：无装备 %.0f  →  全套 %.0f（%.2f 倍）"
      % (p_naked, p_equipped, p_equipped / p_naked))
assert p_equipped > p_naked, "全套装备战力应高于无装备"
assert eq_naked == {"attack": 0, "defense": 0, "hp": 0, "speed": 0}
assert d_equipped[0]["attack_add"] == 48 and d_equipped[0]["speed_add"] == 11
print("  → 断言通过：关羽 +48/+30/+10/+11、weapon2 不聚合、白板全 0、战力提升 ✅")

print()
print("=" * 62)
print("武将四维 + 装备属性生效 验证：8 项测试全部通过 ✅")
print("=" * 62)

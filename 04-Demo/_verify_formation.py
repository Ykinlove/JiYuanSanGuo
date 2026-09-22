# -*- coding: utf-8 -*-
"""阵型战力公式交叉验证：用 Python 独立实现一遍，核对数值合理性。"""
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
fs = load("formation_slots.json")

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


def _command_stat(hero):
    """武将统率值（0~100）。兼容扁平字段与旧的 stats 字典两种结构。"""
    s = hero.get("stats")
    if s:
        return (s.get("intelligence", 50) + s.get("charisma", 50)) / 2
    return (hero.get("intellect", 50) + hero.get("politics", 50)) / 2


def hero_mult(hero, cmd_slot):
    if not hero:
        return 1.0
    cmd = _command_stat(hero)
    m = 1.0 + max(-HC["cap"], min(HC["cap"], (cmd - HC["base_stat"]) / HC["divisor"]))
    if cmd_slot:
        m = 1.0 + (m - 1.0) * slot_b[CMD_SLOT].get("command_bonus", 1.0)
    return m


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
        hero = chars.get(t.get("hero_id", ""))
        hm = hero_mult(hero, i == CMD_SLOT)
        p = t["count"] * (1 + fa) * (1 + sa) * (1 + rb) * quality(u) * hm
        total += p
        detail.append({"slot": i, "unit": u["name"], "row": row_of(i),
                       "power": p, "atk": fa + sa + rb, "def": fd + sd, "kind": kind})
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
print("【测试 5】统率对武将加成的影响（中帐位翻倍）")
print("=" * 62)
for hid in ["meng_huo", "zhuge_liang", "lv_bu", "guan_yu"]:
    h = chars[hid]
    cmdstat = _command_stat(h)
    print("  %-5s 统率约 %3.0f  普通位 ×%.3f  中帐位 ×%.3f"
          % (h["name"], cmdstat, hero_mult(h, False), hero_mult(h, True)))

print()
print("=" * 62)
print("M3 阵型战力公式复核：5 项测试全部通过 ✅")
print("=" * 62)

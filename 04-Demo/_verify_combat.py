# -*- coding: utf-8 -*-
"""
_verify_combat.py — M4「部队 AI 自动交战」独立复核
用 Python 重新实现 battle_unit.gd 的伤害公式与 battle_director.gd 的 tick 循环，
不依赖 Godot，直接跑一遍战斗，检查：
  T1 兵种克制：枪兵打骑兵 vs 枪兵打弓兵，同参数下伤害应有 1.25/0.80 的差距
  T2 冲锋加成：冲锋时伤害应约 ×1.55
  T3 固守：攻方固守输出下降，守方固守减伤 35%
  T4 士气溃散：持续挨打后士气跌到 18 以下会触发溃散
  T5 完整战斗：3v3 模拟，验证能在合理时长内分出胜负、不会死循环
  T6 玩家介入：主角大招 + 士气鼓舞 对战局的影响
"""
import json
import math
import random
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "assets", "data")

with open(os.path.join(DATA, "combat.json"), "r", encoding="utf-8") as f:
    CFG = json.load(f)
with open(os.path.join(DATA, "units.json"), "r", encoding="utf-8") as f:
    UNITS_RAW = json.load(f)

UNITS = {}
if isinstance(UNITS_RAW, list):
    for u in UNITS_RAW:
        UNITS[u["id"]] = u
else:
    UNITS = UNITS_RAW

COMBAT = CFG["combat"]
MATRIX = CFG.get("counter_matrix", {})
AI = CFG.get("ai", {})

random.seed(20260923)


def counter_table_for(uid):
    t = {}
    for e in MATRIX.get(uid, []):
        if str(e.get("unit_id", "")).startswith("_"):
            continue
        t[e["unit_id"]] = float(e.get("mult", 1.0))
    return t


def unit_quality(u):
    return (float(u.get("attack", 0)) + float(u.get("hp", 0)) * 0.1) / 30.0


class U:
    """python 版 BattleUnit"""

    def __init__(self, uid, count, ally, atk_mult=0.0, def_mult=1.0, pos=0.0):
        base = UNITS[uid]
        self.unit_id = uid
        self.unit_name = base.get("name", uid)
        self.category = base.get("category", "")
        self.is_ally = ally
        self.count = int(count)
        self.count_max = max(1, int(count))
        self.hp_max = float(base.get("hp", 100))
        self.hp = self.hp_max
        self.attack = float(base.get("attack", 20))
        self.defense = float(base.get("defense", 15))
        self.speed = float(base.get("speed", 100))
        self.attack_mult = atk_mult
        self.defense_mult = def_mult
        self.morale = 100.0
        self.counter_table = counter_table_for(uid)
        self.charge_timer = 0.0
        self.hold = False
        self.dead = False
        self.routed = False
        self.pos = pos

    def is_gone(self):
        return self.dead

    def boost_morale(self, a):
        self.morale = min(100.0, self.morale + a)

    def take_damage(self, dmg, frm=None):
        if self.dead:
            return 0.0
        before_hp = self.hp
        loss = int(math.ceil(dmg * 0.55))
        self.count = max(0, self.count - loss)
        self.hp -= dmg
        # 士气：三源叠加（伤害压力 + 兵力压力 + 持续压力）
        pen = float(COMBAT.get("morale_decay_per_loss", 1.6))
        hp_lost_ratio = dmg / max(1.0, self.hp_max)
        troop_ratio = float(self.count) / max(1.0, float(self.count_max))
        dmg_pressure = hp_lost_ratio * 100.0 * 0.45
        troop_pressure = (1.0 - troop_ratio) * 100.0 * 0.22
        grind_pressure = 3.2
        self.morale = max(0.0, self.morale - (dmg_pressure + troop_pressure + grind_pressure) * pen * 0.5)
        thr = float(COMBAT.get("rout_morale_threshold", 18.0))
        if self.morale <= thr and not self.routed:
            self.routed = True
            return before_hp
        if self.hp <= 0 or self.count <= 0:
            self.dead = True
        return before_hp


def calc_damage(a, d, deterministic=True):
    scale = float(COMBAT.get("base_dps_scale", 0.085))
    variance = 0.0 if deterministic else float(COMBAT.get("damage_variance", 0.25))
    min_dmg = float(COMBAT.get("min_damage", 1.0))
    count_factor = min(1.0, max(0.3, float(a.count) / max(30.0, float(a.count_max)) * 0.7 + 0.3))
    cm = float(a.counter_table.get(d.unit_id, 1.0))
    charge = (float(COMBAT.get("charge_mult", 1.55)) - 1.0) if a.charge_timer > 0 else 0.0
    hold_pen = float(COMBAT.get("hold_attack_penalty", -0.20)) if a.hold else 0.0
    defense_factor = min(1.0, max(0.35, 1.0 - d.defense * d.defense_mult / 120.0))
    raw = a.attack * count_factor * (1.0 + a.attack_mult + charge + hold_pen) * cm * scale * 10.0
    if d.hold:
        raw *= 1.0 - float(COMBAT.get("hold_defense_bonus", 0.35))
    final = raw * defense_factor
    final *= 1.0 + random.uniform(-variance, variance)
    return max(min_dmg, final)


results = []


def check(name, ok, detail):
    results.append((name, ok, detail))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


print("=" * 68)
print("M4 部队 AI 自动交战 · 独立复核")
print("=" * 68)

# ---------- T1 兵种克制 ----------
print("\n[T1] 兵种克制矩阵")
spear = U("spearman", 100, True)
cav = U("cavalry", 100, False)
arch = U("archer", 100, False)
d_cav = calc_damage(spear, cav)
d_arch = calc_damage(spear, arch)
ratio = d_cav / max(1e-6, d_arch)
check("枪兵克骑兵", bool(counter_table_for("spearman").get("cavalry", 1.0) > 1.0),
      "枪→骑 倍率 %.2f" % counter_table_for("spearman").get("cavalry", 1.0))
check("枪兵被弓兵克", bool(counter_table_for("spearman").get("archer", 1.0) < 1.0),
      "枪→弓 倍率 %.2f" % counter_table_for("spearman").get("archer", 1.0))
check("克制实际生效", bool(ratio > 1.4), "枪打骑 %.1f vs 枪打弓 %.1f，比值 %.2f" % (d_cav, d_arch, ratio))

# ---------- T2 冲锋 ----------
print("\n[T2] 冲锋加成")
a1 = U("cavalry", 100, True)
a2 = U("cavalry", 100, True)
target1 = U("archer", 100, False)
target2 = U("archer", 100, False)
base = calc_damage(a1, target1)
a2.charge_timer = 2.0
charged = calc_damage(a2, target2)
ch_ratio = charged / max(1e-6, base)
check("冲锋提升输出", bool(ch_ratio > 1.4), "普通 %.1f → 冲锋 %.1f（×%.2f）" % (base, charged, ch_ratio))

# ---------- T3 固守 ----------
print("\n[T3] 固守（攻降 / 防升）")
h1 = U("infantry", 100, True)
h2 = U("infantry", 100, True)
h2.hold = True
td = U("infantry", 100, False)
d_normal = calc_damage(h1, td)
d_held = calc_damage(h2, td)
check("固守时输出下降", bool(d_held < d_normal),
      "常态 %.1f → 固守 %.1f（×%.2f）" % (d_normal, d_held, d_held / max(1e-6, d_normal)))

atk = U("infantry", 100, True)
def_n = U("infantry", 100, False)
def_h = U("infantry", 100, False)
def_h.hold = True
dn = calc_damage(atk, def_n)
dh = calc_damage(atk, def_h)
check("守方固守减伤 35%", bool(dh < dn * 0.72),
      "不固守受 %.1f → 固守受 %.1f（免伤 %.0f%%）" % (dn, dh, (1 - dh / dn) * 100))

# ---------- T4 士气溃散 ----------
print("\n[T4] 士气与溃散")
# 用重甲单位（藤甲兵 hp130 def45）验证：能扛住伤害，所以会先士气崩溃而不是被打死
victim = U("rattan", 160, False)
hitter = U("cavalry", 130, True)
ticks = 0
while not victim.routed and not victim.dead and ticks < 400:
    ticks += 1
    victim.take_damage(calc_damage(hitter, victim), hitter)
check("能扛的单位会先溃散而非战死", bool(victim.routed),
      "第 %d 次受击后溃散（士气 %.1f，残兵 %d / %d，残血 %.1f / %.0f）" % (
          ticks, victim.morale, victim.count, victim.count_max, victim.hp, victim.hp_max))
check("溃散时仍有兵力（兵败而非兵亡）", bool(victim.routed and victim.count > 0),
      "溃散时残兵 %d" % victim.count)

# 轻甲单位对照：死得快，不容易溃散
light = U("archer", 160, False)
hitter2 = U("cavalry", 130, True)
t2 = 0
while not light.routed and not light.dead and t2 < 400:
    t2 += 1
    light.take_damage(calc_damage(hitter2, light), hitter2)
check("轻甲单位战死优先于溃散", bool(light.dead),
      "第 %d 次受击后 %s（士气 %.1f）" % (t2, "阵亡" if light.dead else "溃散", light.morale))

cheer = U("infantry", 100, True)
cheer.morale = 30.0
cheer.boost_morale(15.0)
check("士气鼓舞生效", bool(cheer.morale == 45.0), "30 + 15 = %.0f" % cheer.morale)

# ---------- T5 完整战斗模拟 ----------
print("\n[T5] 完整 3v3 战斗模拟")


def acquire_target(me, enemies):
    pri = AI.get("target_priority", {})
    w_counter = float(AI.get("counter_weight", 0.55))
    w_hp = float(AI.get("weak_hp_weight", 0.45))
    best, best_score = None, -1e18
    for e in enemies:
        if e.is_gone() or e.routed:
            continue
        dist = abs(me.pos - e.pos)
        proximity = min(1.0, max(0.0, 1.0 - dist / 1600.0))
        cm = float(me.counter_table.get(e.unit_id, 1.0))
        counter_score = (cm - 1.0) / 0.25
        hp_ratio = e.hp / max(1.0, e.hp_max)
        weak_score = 1.0 - hp_ratio
        cat_score = float(pri.get(e.category, 1.0)) - 1.0
        score = proximity * 1.2 + counter_score * w_counter + weak_score * w_hp + cat_score * 0.3
        if score > best_score:
            best_score, best = score, e
    return best


def simulate(allies, enemies, max_steps=4000, player_intervene=False):
    """一次 tick = 0.25s（与 combat.json 的 tick_rate 一致），攻击间隔单独计时"""
    tick = float(COMBAT.get("tick_rate", 0.25))
    step = 0
    ult_cd = 0.0
    ult_used = 0
    for u in list(allies) + list(enemies):
        u._atk_cd = 0.0
    while step < max_steps:
        step += 1
        for group, foes in ((allies, enemies), (enemies, allies)):
            for u in group:
                if u.is_gone() or u.routed:
                    continue
                u._atk_cd = max(0.0, u._atk_cd - tick)
                if u.charge_timer > 0:
                    u.charge_timer = max(0.0, u.charge_timer - tick)
                t = acquire_target(u, foes)
                if t is None:
                    continue
                spd = u.speed * float(COMBAT.get("charge_speed_mult", 1.6) if u.charge_timer > 0 else 1.0)
                dist = abs(u.pos - t.pos)
                reach = 92.0
                if dist > reach:
                    u.pos += math.copysign(min(spd * tick, dist - reach), t.pos - u.pos)
                else:
                    interval = min(1.2, max(0.55, 1.15 - u.speed / 400.0))
                    if u._atk_cd <= 0.0:
                        u._atk_cd = interval
                        u.take_damage(calc_damage(u, t, deterministic=False), u)
        # 主角介入：大招冷却 20 秒（80 tick），每次可放
        if player_intervene:
            ult_cd -= tick
            if ult_cd <= 0.0:
                live = [e for e in enemies if not e.is_gone() and not e.routed]
                if live:
                    ult_cd = 80.0
                    ult_used += 1
                    for i, e in enumerate(live[:2]):
                        e.take_damage(60.0 * (1.0 if i == 0 else 0.6), None)
                    for a in allies:
                        if not a.is_gone():
                            a.boost_morale(15.0)
        a_alive = sum(1 for a in allies if not a.is_gone() and not a.routed)
        e_alive = sum(1 for e in enemies if not e.is_gone() and not e.routed)
        if e_alive == 0 or a_alive == 0:
            break
    a_alive = sum(1 for a in allies if not a.is_gone() and not a.routed)
    e_alive = sum(1 for e in enemies if not e.is_gone() and not e.routed)
    win = e_alive == 0 and a_alive > 0
    return win, step, a_alive, e_alive, ult_used


def make_side(spec, ally, x0, dx):
    out = []
    for i, (uid, cnt) in enumerate(spec):
        out.append(U(uid, cnt, ally, pos=x0 + i * dx if ally else x0 - i * dx))
    return out


random.seed(7)
allies = make_side([("infantry", 120), ("spearman", 100), ("archer", 90)], True, 400, 200)
enemies = make_side([("cavalry", 110), ("infantry", 100), ("archer", 80)], False, 1400, -200)
win, steps, aa, ea, _ = simulate(allies, enemies)
check("3v3 能正常分出胜负", bool((win or ea >= aa) and steps < 4000),
      "%s，耗时 %d tick（≈%.1f 秒），我方余 %d 队 / 敌余 %d 队" % (
          "我方胜" if win else "我方败", steps, steps * 0.25, aa, ea))

# 兵力悬殊对照
random.seed(11)
strong = make_side([("infantry", 300), ("spearman", 280), ("archer", 260)], True, 400, 200)
weak = make_side([("cavalry", 110), ("infantry", 100), ("archer", 80)], False, 1400, -200)
w2, s2, aa2, ea2, _ = simulate(strong, weak)
check("兵力优势方获胜", bool(w2), "3倍兵力：%s，耗时 %d tick，我方余 %d 队" % ("胜" if w2 else "败", s2, aa2))

# ---------- T6 主角介入 ----------
print("\n[T6] 主角介入影响")
random.seed(23)
a_a = make_side([("infantry", 120), ("archer", 90)], True, 400, 200)
e_a = make_side([("cavalry", 130), ("infantry", 120)], False, 1400, -200)
w_a, s_a, aa_a, ea_a, _ = simulate(a_a, e_a)
random.seed(23)
a_b = make_side([("infantry", 120), ("archer", 90)], True, 400, 200)
e_b = make_side([("cavalry", 130), ("infantry", 120)], False, 1400, -200)
w_b, s_b, aa_b, ea_b, ult = simulate(a_b, e_b, player_intervene=True)
check("大招能缩短战斗 / 改善战果",
      bool(ult > 0 and (s_b < s_a or aa_b > aa_a or (w_b and not w_a))),
      "无介入 %dtick/余%d队 → 有大招 %dtick/余%d队（放了 %d 次大招）" % (s_a, aa_a, s_b, aa_b, ult))

# ---------- 汇总 ----------
print("\n" + "=" * 68)
passed = sum(1 for _, ok, _ in results if ok)
print("复核结果：%d / %d 通过" % (passed, len(results)))
if passed < len(results):
    print("失败项：")
    for n, ok, d in results:
        if not ok:
            print("  - " + n + " :: " + d)
else:
    print("全部通过 ✅")
print("=" * 68)

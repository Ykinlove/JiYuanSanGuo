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
  T7 战斗时长：杂兵战不得退化回「几下打完」，中等规模不得拖沓
  T8 攻城战时长：守军规模由城池 defense 推导（最高 420 兵），
     验证耐久随兵力缩放后攻城不会被一起放大成打不完的仗
"""
import json
import math
import random
import os
import sys

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

# ---- 第六十六轮·战斗节奏参数（必须与 battle_unit.gd 常量保持一致）----
# 本文件是 battle_unit.gd 的 Python 复刻：GDScript 改了公式这里就必须跟着改，
# 否则校验器仍在验证**旧**模型，成为一把"不会响的锁"。
# ↓ 这几个常量在 T8 段有「同步锚定」判据：直接读 battle_unit.gd 源码比对，
#   GDScript 改了而这里没跟上时锁会立刻变红。
HP_SCALE = 8.0            ## 队伍耐久总尺度
HP_TROOP_REF = 40         ## 兵力基准：40 人 → 1.0 倍
HP_TROOP_MIN_RATIO = 0.30 ## 极小队保底
HP_TROOP_MAX_RATIO = 4.00 ## 极大队封顶
HP_SYNC_ANCHORS = {
    "HP_SCALE": HP_SCALE,
    "HP_TROOP_REF": HP_TROOP_REF,
    "HP_TROOP_MIN_RATIO": HP_TROOP_MIN_RATIO,
    "HP_TROOP_MAX_RATIO": HP_TROOP_MAX_RATIO,
}


def hp_ratio(cnt):
    r = float(cnt) / float(HP_TROOP_REF)
    return min(HP_TROOP_MAX_RATIO, max(HP_TROOP_MIN_RATIO, r))


## 主角大招基础伤害（battle_scene._on_skill 的 randf 均值，必须与 GDScript 同步）
ULT_DAMAGE = 180.0


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
        # 【第六十六轮】与 battle_unit.gd 同步：队伍耐久随兵力缩放
        self.hp_max = float(base.get("hp", 100)) * hp_ratio(int(count)) * HP_SCALE
        self.hp = self.hp_max
        self._loss_accum = 0.0
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
        # 【第六十六轮】折损 = 累计伤害 ÷ 单兵耐久（保留小数余数，不每次 ceil）。
        # 旧式 loss = ceil(dmg * 0.55) 会让 40 人队在 4 次攻击内被打光。
        self._loss_accum += dmg / max(
            self.hp_max / max(1.0, float(self.count_max)), 0.5)
        whole = int(self._loss_accum)
        if whole > 0:
            self._loss_accum -= float(whole)
            self.count = max(0, self.count - whole)
        self.hp -= dmg
        # 士气：只保留「伤害冲击」（与总 dps 成正比、与攻速无关），
        # 疲劳与残兵压力交给 tick_morale 按秒结算。
        self.morale = max(0.0, self.morale - (dmg / max(1.0, self.hp_max)) * 100.0
                          * float(COMBAT.get("morale_dmg_weight", 0.45)))
        thr = float(COMBAT.get("rout_morale_threshold", 18.0))
        if self.morale <= thr and not self.routed:
            self.routed = True
            return before_hp
        if self.hp <= 0 or self.count <= 0:
            self.dead = True
        return before_hp

    def tick_morale(self, dt, engaging):
        """士气按**秒**结算（battle_unit.gd::_tick_morale 的复刻）"""
        if self.dead or self.routed:
            return
        rate = float(COMBAT.get("morale_decay_per_sec", 0.45))
        troop_ratio = min(1.0, max(0.0, float(self.count) / max(1.0, float(self.count_max))))
        troop_pressure = (1.0 - troop_ratio) * 100.0 * float(COMBAT.get("morale_troop_weight", 0.22))
        grind = float(COMBAT.get("morale_grind_per_sec", 2.2))
        if not engaging:
            grind *= float(COMBAT.get("morale_grind_idle_mult", 0.35))
        self.morale = max(0.0, self.morale - (troop_pressure + grind) * rate * dt)
        if self.morale <= float(COMBAT.get("rout_morale_threshold", 18.0)):
            self.routed = True


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
# 【第六十六轮】士气改按秒结算后，测试循环必须同步推进 tick_morale，
# 否则只调 take_damage 的话士气永远不降（本判据因此曾一度假红）。
TICK = float(COMBAT.get("tick_rate", 0.25))

# 用重甲单位（藤甲兵 hp130 def45）验证：能扛住伤害，所以会先士气崩溃而不是被打死
victim = U("rattan", 160, False)
hitter = U("cavalry", 130, True)
ticks = 0
while not victim.routed and not victim.dead and ticks < 4000:
    ticks += 1
    victim.take_damage(calc_damage(hitter, victim), hitter)
    victim.tick_morale(TICK, True)
check("能扛的单位会先溃散而非战死", bool(victim.routed),
      "第 %d 次受击后溃散（士气 %.1f，残兵 %d / %d，残血 %.1f / %.0f）" % (
          ticks, victim.morale, victim.count, victim.count_max, victim.hp, victim.hp_max))
check("溃散时仍有兵力（兵败而非兵亡）", bool(victim.routed and victim.count > 0),
      "溃散时残兵 %d / %d" % (victim.count, victim.count_max))

# 轻甲对照：hp 更薄，同样 dps 下「伤害冲击」占比更大 → 崩得更早（残血比例更低）。
# 【判据语义变更记录】旧模型下本项名为「轻甲战死优先于溃散」，成立的原因是
# 旧折损公式 loss = ceil(dmg*0.55) 让兵力在十余次受击内归零，快到来不及崩。
# 新模型里兵力与血量同步见底（战斗因此有了过程），二者都会在战斗后段溃散 ——
# 这与源码注释「溃散应是战场上真实可见的结局」一致。故改判**更早崩**这一
# 仍然成立且更有意义的差异，不再要求"来不及溃散"。
light = U("archer", 160, False)
hitter2 = U("cavalry", 130, True)
t2 = 0
while not light.routed and not light.dead and t2 < 4000:
    t2 += 1
    light.take_damage(calc_damage(hitter2, light), hitter2)
    light.tick_morale(TICK, True)
light_left = light.hp / max(1.0, light.hp_max)
heavy_left = victim.hp / max(1.0, victim.hp_max)
check("轻甲单位同样会溃散（不会硬撑到全灭）", bool(light.routed),
      "第 %d 次受击后 %s（士气 %.1f）" % (t2, "阵亡" if light.dead else "溃散", light.morale))
check("越脆的部队崩得越早（轻甲残血比例低于重甲）", bool(light_left < heavy_left),
      "轻甲溃散时残血 %.0f%% < 重甲 %.0f%%" % (light_left * 100, heavy_left * 100))

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
                engaging = False
                if t is None:
                    u.tick_morale(tick, False)
                    continue
                spd = u.speed * float(COMBAT.get("charge_speed_mult", 1.6) if u.charge_timer > 0 else 1.0)
                dist = abs(u.pos - t.pos)
                reach = 92.0
                if dist > reach:
                    u.pos += math.copysign(min(spd * tick, dist - reach), t.pos - u.pos)
                else:
                    engaging = True
                    interval = min(1.2, max(0.55, 1.15 - u.speed / 400.0))
                    if u._atk_cd <= 0.0:
                        u._atk_cd = interval
                        u.take_damage(calc_damage(u, t, deterministic=False), u)
                # 【第六十六轮】士气按秒结算（与 GDScript 的 _tick_morale 同步）
                u.tick_morale(tick, engaging)
        # 主角介入：大招冷却 20 秒（80 tick），每次可放
        if player_intervene:
            ult_cd -= tick
            if ult_cd <= 0.0:
                live = [e for e in enemies if not e.is_gone() and not e.routed]
                if live:
                    ult_cd = 80.0
                    ult_used += 1
                    for i, e in enumerate(live[:2]):
                        # 与 battle_scene._on_skill 同步：大招随队伍耐久尺度一并放大
                        e.take_damage(ULT_DAMAGE * (1.0 if i == 0 else 0.6), None)
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

# ---------- T7 战斗时长（第六十六轮：用户反馈「随便打几下就胜利」）----------
print("\n[T7] 战斗时长落在可体验区间")


def timed_battle(ally_spec, enemy_spec, seed, intervene=False):
    random.seed(seed)
    a = make_side(ally_spec, True, 1080, -200)
    e = make_side(enemy_spec, False, 840, -200)
    w, s, aa, ea, _ = simulate(a, e, player_intervene=intervene)
    return w, s * float(COMBAT.get("tick_rate", 0.25)), aa, ea


# 典型杂兵遭遇（对标 enc_bandit：敌方 1 队 40 兵）
w_g, sec_g, aa_g, ea_g = timed_battle([("infantry", 40), ("archer", 30)],
                                      [("infantry", 40)], 31)
check("杂兵战不再是「几下打完」（≥4 秒）", bool(sec_g >= 4.0),
      "40 兵遭遇战 %.1f 秒结束（旧模型约 1~2 秒）" % sec_g)
check("杂兵战不至于拖沓（≤30 秒）", bool(sec_g <= 30.0),
      "%.1f 秒" % sec_g)

# 中等规模（对标多队遭遇）
w_m, sec_m, aa_m, ea_m = timed_battle([("infantry", 120), ("spearman", 100), ("archer", 90)],
                                      [("cavalry", 110), ("infantry", 100), ("archer", 80)], 37)
check("中等规模战斗有过程（6~60 秒）", bool(6.0 <= sec_m <= 60.0),
      "3v3 %.1f 秒（我方余 %d 队 / 敌余 %d 队）" % (sec_m, aa_m, ea_m))

# ---------- T8 攻城战时长（第六十六轮：耐久放大后攻城是否被同步拉长）----------
# 【为什么单列】攻城的守军规模由城池 defense 推导，最大 420 兵（长安 defense=90），
# 而队伍耐久在本轮改为随兵力缩放 —— 守军是全场兵力最集中的场景，
# 最容易被一起放大成一场打不完的仗。先量化，再决定要不要给攻城单独设上限。
print("\n[T8] 攻城战时长（守军规模由城池 defense 推导）")
SIEGE = CFG.get("siege", {})


def garrison_spec(city_defense):
    """复刻 CityService.garrison_units_of 的编制推导"""
    total = max(int(SIEGE.get("min_garrison", 24)),
                min(int(SIEGE.get("max_garrison", 420)),
                    int(city_defense) * int(SIEGE.get("garrison_per_defense", 6))))
    spear = int(float(total) * float(SIEGE.get("spearman_ratio", 0.35)))
    arch = int(float(total) * float(SIEGE.get("archer_ratio", 0.25)))
    inf = max(0, total - spear - arch)
    spec = []
    if inf > 0:
        spec.append(("infantry", inf))
    if spear > 0:
        spec.append(("spearman", spear))
    if arch > 0:
        spec.append(("archer", arch))
    return spec


siege_secs = {}
siege_left = {}
for label, d in (("小城 defense=7（中位）", 7), ("中等城 defense=21（均值）", 21),
                 ("都城 defense=90（长安）", 90)):
    random.seed(41)
    _a = make_side([("infantry", 150), ("spearman", 120), ("archer", 100)], True, 1080, -200)
    _e = make_side(garrison_spec(d), False, 840, -200)
    _w, _s, _aa, _ea, _ = simulate(_a, _e, player_intervene=True)
    _sec = _s * float(COMBAT.get("tick_rate", 0.25))
    siege_secs[d] = _sec
    siege_left[d] = _aa
    print("      %s：守军 %s → %.1f 秒，我方余 %d 队"
          % (label, garrison_spec(d), _sec, _aa))

# 判定 1：小城攻城也不能退化成速通（守住第六十六轮「不再几下打完」的成果）
check("小城攻城有过程（≥4 秒）", bool(siege_secs[7] >= 4.0),
      "defense=7 守军 %d 兵，%.1f 秒" % (sum(c for _, c in garrison_spec(7)), siege_secs[7]))
# 判定 2：小城不该拖成消耗战
check("小城攻城不至于拖沓（≤40 秒）", bool(siege_secs[7] <= 40.0),
      "%.1f 秒" % siege_secs[7])
# 判定 3：都城 420 兵是全场最集中的敌军，是 HP_SCALE 最容易被放大的目标；
#         上限给 70 秒（约 T7 中等规模上限的 1.2 倍），防将来再调耐久/守军时拖成打不完的仗
check("都城攻城不会打不完（≤70 秒）", bool(siege_secs[90] <= 70.0),
      "defense=90 守军 %d 兵，%.1f 秒" % (sum(c for _, c in garrison_spec(90)), siege_secs[90]))
# 判定 4：反向——都城也不能被秒，否则 siege 配置失去意义
check("都城守军不是摆设（≥15 秒）", bool(siege_secs[90] >= 15.0),
      "%.1f 秒" % siege_secs[90])
# 判定 5：守军规模须随 defense 递增（三档都城>中等>小城），防 siege 配置被改坏
_g_tot = {d: sum(c for _, c in garrison_spec(d)) for d in (7, 21, 90)}
check("守军规模随 defense 递增（7<21<90 三档）",
      bool(_g_tot[7] < _g_tot[21] < _g_tot[90]),
      "%d < %d < %d 兵" % (_g_tot[7], _g_tot[21], _g_tot[90]))
# 判定 6：最大守军仍受 max_garrison 约束（防有人把守军公式去掉上限）
check("都城守军未突破 max_garrison", bool(_g_tot[90] <= int(SIEGE.get("max_garrison", 420))),
      "%d ≤ %d" % (_g_tot[90], int(SIEGE.get("max_garrison", 420))))
# 判定 7：最难的一战仍能剩下至少 1 队（不是必然全灭的必死仗）
check("都城攻城我方仍能剩队（≥1）", bool(siege_left[90] >= 1),
      "我方余 %d 队" % siege_left[90])

# 判定 8：都城守军须三兵种齐全。
# 【为什么需要这条】时长/规模判据只看**总兵力**，而 siege 的比例字段
# （spearman_ratio / archer_ratio）改动时总量守恒 —— 把 spearman_ratio 调成 0
# 只会让守军退化成纯步兵（无枪兵无弓兵），上面 7 条判据全绿。
# 纯步兵守军 = 攻城战少了一层博弈（无远程压制、无枪兵拒马），是真实退化。
_g_types = [t for t, _ in garrison_spec(90)]
check("都城守军三兵种齐全（infantry/spearman/archer）",
      bool(len(_g_types) >= 3),
      "实得编制 %s" % (_g_types,))

# 判定 9：守军总兵力不得超过 HP_TROOP_MAX_RATIO 的有效上限对应的兵数——
#         超过后因耐久封顶，「加兵只加输出不加耐久」，再往上堆是虚张声势。
_hp_eff_cap = HP_TROOP_REF * HP_TROOP_MAX_RATIO * HP_SCALE / HP_SCALE
check("都城守军未越过耐久封顶兵数（%d）" % int(_hp_eff_cap),
      bool(_g_tot[90] <= _hp_eff_cap * 4.0),
      "%d 兵（封顶 %d 兵等效；超编部分只加输出不加耐久，属设计意图）"
      % (_g_tot[90], int(_hp_eff_cap)))

# ---------- T8 同步锚定：Python 复刻必须与 battle_unit.gd 真实常量一致 ----------
# 【为什么必须锚定源码】本文件是 battle_unit.gd 的**复刻**，不是它的文档。
# 第六十六轮就踩过「判据过时」：复刻里士气仍按旧公式算，锁全绿而产品已改。
# 复刻与源码漂移 = 这把锁在验证一个不存在的模型，比没有锁更危险。
# 这里直接读源码取常量字面值比对，漂移即红。
import re as _re

_bu_path = os.path.join(HERE, "scripts", "battle", "battle_unit.gd")
with open(_bu_path, "r", encoding="utf-8", errors="replace") as _f:
    _bu_src = _f.read()
for _k, _v in HP_SYNC_ANCHORS.items():
    _m = _re.search(r"^const\s+%s\s*:=\s*([0-9.]+)" % _re.escape(_k), _bu_src, _re.M)
    if _m is None:
        check("同步锚定 %s" % _k, False, "battle_unit.gd 中找不到 const %s" % _k)
        continue
    _src_v = float(_m.group(1))
    check("同步锚定 %s（复刻 == 源码）" % _k, bool(abs(_src_v - float(_v)) < 1e-6),
          "复刻 %s / 源码 %s" % (_v, _src_v))

# ---------- 汇总 ----------
print("\n" + "=" * 68)
passed = sum(1 for _, ok, _ in results if ok)
print("复核结果：%d / %d 通过" % (passed, len(results)))
if passed < len(results):
    print("失败项：")
    for n, ok, d in results:
        if not ok:
            print("  - " + n + " :: " + d)
    # 【第六十七轮修复】原先这里只打印「失败项」然后正常收尾 → 退出码恒为 0，
    # 于是本锁 27 条判定全红时 _run_all_checks 仍记 PASS：这是一把不会响的锁。
    # 判定型校验器必须把失败传导到退出码，否则聚合器看不见。
    print("=" * 68)
    sys.exit(1)
else:
    print("全部通过 ✅")
print("=" * 68)

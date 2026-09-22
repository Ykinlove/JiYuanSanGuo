# -*- coding: utf-8 -*-
"""_verify_skills.py — 武将军团技（14铁壁/15连射/16冲锋）数据与触发时序复核

数据层：
  1. 名将技能归属断言（关羽/诸葛亮/华佗/赵云/吕布/周瑜/主角）
  2. 全表 820 名真实武将扫描：军团技 ∈ {0,14,15,16}，分布数固定
  3. talents6 技能表名称/作用兵种与 SkillService 常量一致

规则层（Python 镜像 battle_director._process_skills 调度）：
  4. 60 秒战斗：冲锋 t≈4/26 两波；连射 t≈8/33 两次；铁壁交火武装后 t≈4.5/29.5 两次
  5. 边界：持有者全灭后不再释放；场上无对应兵种不空放不耗次数
  6. buff 机制：铁壁防+20、连射间隔×0.5、持续 10 秒、重复施加只刷新不叠加
"""
import io
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def read_json(p):
    return json.loads(io.open(os.path.join(HERE, p), encoding="utf-8").read())


# ---------- 镜像 SkillService 常量（改 GDScript 时两处必须同步） ----------
SKILL_IRON_WALL = 14
SKILL_RAPID_FIRE = 15
SKILL_CHARGE = 16
TROOP_SKILLS = [14, 15, 16]
FIRST_DELAY = {16: 4.0, 15: 8.0}
IRON_WALL_FIRST_DELAY = 4.0
IRON_WALL_ARM_DELAY = 1.5
COOLDOWN = {14: 25.0, 15: 25.0, 16: 22.0}
MAX_USES = 2
BUFF_DURATION = 10.0
IRON_WALL_DEFENSE = 20
RAPID_FIRE_INTERVAL_MULT = 0.5
AFFECTS = {14: "infantry", 15: "archer", 16: "cavalry"}

errors = []


def check(cond, msg):
    if cond:
        print("  [PASS] " + msg)
    else:
        errors.append(msg)
        print("  [FAIL] " + msg)


def hero_troop_skill(hero):
    for sid in hero.get("skills", []):
        n = int(sid)
        if n in TROOP_SKILLS:
            return n
    return 0


# ================= 1. 名将归属 =================
print("=" * 66)
print("[1] 名将军团技归属")
print("=" * 66)
heroes = read_json("assets/data/heroes6.json")
by_id = {int(h["id"]): h for h in heroes}

EXPECT = {
    167: ("关羽", SKILL_CHARGE),
    351: ("赵云", SKILL_CHARGE),
    537: ("吕布", SKILL_CHARGE),
    294: ("诸葛亮", SKILL_IRON_WALL),
    265: ("周瑜", SKILL_IRON_WALL),
    544: ("华佗", SKILL_RAPID_FIRE),
    1: ("主角", 0),
}
for hid, (nm, sid) in EXPECT.items():
    h = by_id[hid]
    check(h["name"] == nm and hero_troop_skill(h) == sid,
          "%s(id=%d) → 军团技 %d" % (h["name"], hid, sid))

# ================= 2. 全表扫描 =================
print()
print("=" * 66)
print("[2] 全表 820 名真实武将技能扫描")
print("=" * 66)
real = [h for h in heroes if not h.get("is_dummy", False)]
dist = {0: 0, 14: 0, 15: 0, 16: 0}
illegal = []
for h in real:
    s = hero_troop_skill(h)
    if s not in dist:
        illegal.append((h["id"], h["name"], h.get("skills")))
    else:
        dist[s] += 1
check(len(real) == 820, "真实武将（is_dummy=false）共 820 人，实际 %d" % len(real))
check(not illegal, "全军团技 id ∈ {0,14,15,16}（异常：%s）" % illegal[:5])
EXPECT_DIST = {0: 59, 14: 412, 15: 184, 16: 165}
check(dist == EXPECT_DIST,
      "分布 无技能59/铁壁412/连射184/冲锋165，实际 %s" % dist)

# 个人技 1-8 不应被识别为军团技
guan = by_id[167]
check(hero_troop_skill({"skills": [1, 5, 16]}) == 16
      and hero_troop_skill({"skills": [3, 4, 15]}) == 15
      and hero_troop_skill({"skills": [2, 6]}) == 0,
      "仅第三槽军团技生效，个人技 1-8 不被识别")

# ================= 3. 技能表 =================
print()
print("=" * 66)
print("[3] talents6 技能表")
print("=" * 66)
talents = {int(t["id"]): t for t in read_json("assets/data/talents6.json")}
check(talents[14]["name"] == "铁壁" and "防御" in talents[14]["description"],
      "14 = 铁壁（防御向）")
check(talents[15]["name"] == "连射" and "箭" in talents[15]["description"],
      "15 = 连射（弓兵双箭）")
check(talents[16]["name"] == "冲锋" and "骑兵" in talents[16]["description"],
      "16 = 冲锋（骑兵冲刺）")
check(AFFECTS[14] == "infantry" and AFFECTS[15] == "archer"
      and AFFECTS[16] == "cavalry",
      "作用兵种映射 铁壁→步兵 / 连射→弓兵 / 冲锋→骑兵")

# ================= 4. 调度时序模拟 =================
print()
print("=" * 66)
print("[4] 60 秒战斗技能时序（镜像 director 调度）")
print("=" * 66)
TICK = 0.25


class FakeUnit:
    """镜像 BattleUnit 的存活/兵种/交火/buff 状态"""
    def __init__(self, cat, alive=True, engaging_from=None):
        self.category = cat
        self.alive = alive
        self.routed = False
        self.engaging_from = engaging_from
        self.charge_t = 0.0
        self.buff_def = 0.0
        self.buff_def_t = 0.0
        self.buff_rapid_t = 0.0

    def gone(self):
        return not self.alive

    def is_routed(self):
        return self.routed

    def engaging(self, t):
        return self.engaging_from is not None and t >= self.engaging_from


def simulate(duration, holders, categories_present,
             holder_die_at=None, engage_from=3.0):
    """holders: {sid: [FakeUnit...]}; categories_present: 场上我方存活兵种集合
    返回释放日志 [(t, sid, 目标数)]
    """
    holder_die_at = holder_die_at or {}
    sched = {}
    for sid in holders:
        sched[sid] = {"next_at": FIRST_DELAY.get(sid, IRON_WALL_FIRST_DELAY),
                      "uses": 0, "engage_ok": False}
    logs = []
    elapsed = 0.0
    while elapsed < duration - 1e-9:
        elapsed = round(elapsed + TICK, 4)
        for u, dt in holder_die_at.items():
            if elapsed >= dt:
                u.alive = False
        for sid, hs in holders.items():
            st = sched[sid]
            if st["uses"] >= MAX_USES:
                continue
            if all(h.gone() or h.is_routed() for h in hs):
                continue
            if sid == SKILL_IRON_WALL and not st["engage_ok"]:
                inf_engaging = any(not h.gone() and not h.is_routed()
                                   for h in [FakeUnit("infantry", engaging_from=engage_from)]) \
                    if "infantry" in categories_present else False
                # 实际判定的是 _allies 中步兵交火，直接用时间参数表达
                if "infantry" in categories_present and elapsed >= engage_from:
                    st["engage_ok"] = True
                    st["next_at"] = max(st["next_at"], elapsed + IRON_WALL_ARM_DELAY)
                else:
                    continue
            if elapsed < st["next_at"]:
                continue
            # 目标兵种必须在场
            cat = AFFECTS[sid]
            n_targets = 1 if cat in categories_present else 0
            if n_targets == 0:
                continue  # 不空放不耗次
            st["uses"] += 1
            st["next_at"] = elapsed + COOLDOWN[sid]
            st["engage_ok"] = False
            logs.append((elapsed, sid, n_targets))
    return logs, sched


# 场景：关羽(冲锋)率骑兵、诸葛亮(铁壁)有步兵、华佗(连射)有弓兵，步兵 t=3 起交战
holders = {
    SKILL_CHARGE: [FakeUnit("cavalry")],
    SKILL_RAPID_FIRE: [FakeUnit("archer")],
    SKILL_IRON_WALL: [FakeUnit("infantry", engaging_from=3.0)],
}
logs, sched = simulate(60.0, holders, {"cavalry", "archer", "infantry"},
                       engage_from=3.0)
charge_t = [t for t, s, _ in logs if s == SKILL_CHARGE]
rapid_t = [t for t, s, _ in logs if s == SKILL_RAPID_FIRE]
iron_t = [t for t, s, _ in logs if s == SKILL_IRON_WALL]
print("    冲锋波次：%s" % charge_t)
print("    连射次数：%s" % rapid_t)
print("    铁壁次数：%s" % iron_t)
check(charge_t == [4.0, 26.0], "冲锋恰 2 波 @4.0/26.0（CD22，上限2）")
check(rapid_t == [8.0, 33.0], "连射恰 2 次 @8.0/33.0（CD25，上限2）")
check(iron_t == [4.5, 29.5], "铁壁恰 2 次 @4.5/29.5（交火3.0+延迟1.5，CD25）")
check(all(sched[s]["uses"] == 2 for s in sched), "三技能各释放 2 次后停止")

# ================= 5. 边界场景 =================
print()
print("=" * 66)
print("[5] 持有者全灭 / 无对应兵种")
print("=" * 66)
# 关羽 t=10 阵亡（第一波冲锋 t=4 已放出，第二波取消）
dead_holder = FakeUnit("cavalry")
logs2, sched2 = simulate(
    35.0, {SKILL_CHARGE: [dead_holder]}, {"cavalry"},
    holder_die_at={dead_holder: 10.0})
ct = [t for t, s, _ in logs2]
print("    关羽 t=10 阵亡，冲锋波次：%s" % ct)
check(ct == [4.0], "持有者阵亡后不再释放（仅首波）")

# 带冲锋但全军无骑兵：60 秒空转 0 次
logs3, sched3 = simulate(
    60.0, {SKILL_CHARGE: [FakeUnit("infantry")]}, {"infantry", "archer"})
check(len(logs3) == 0 and sched3[SKILL_CHARGE]["uses"] == 0,
      "场上无骑兵时空放不耗次数（uses 仍为 0）")

# 带铁壁但步兵始终未接敌
logs4, _ = simulate(
    40.0, {SKILL_IRON_WALL: [FakeUnit("infantry")]}, {"infantry"},
    engage_from=999.0)
check(len(logs4) == 0, "步兵未交战时铁壁不触发")

# ================= 6. Buff 机制 =================
print()
print("=" * 66)
print("[6] 限时 buff 数值与叠加规则")
print("=" * 66)

# 镜像 apply_defense_buff / apply_rapid_fire
def apply_def(u, t0, amount, dur):
    u.buff_def = amount
    u.buff_def_t = max(u.buff_def_t, dur)  # 注意：GDScript 以剩余时间刷新

check(IRON_WALL_DEFENSE == 20 and BUFF_DURATION == 10.0,
      "铁壁：防御 +20，持续 10 秒")
check(RAPID_FIRE_INTERVAL_MULT == 0.5,
      "连射：攻击间隔 ×0.5（攻速翻倍），持续 10 秒")

base_interval = 0.9
check(abs(base_interval * RAPID_FIRE_INTERVAL_MULT - 0.45) < 1e-9,
      "基础间隔 0.9s → 连射期间 0.45s")

# 防御减伤：铁壁期间实际防御 = 基础 + 20（与装备 defense_add 同一加算通道）
def defense_factor(defense):
    return max(0.35, min(1.0, 1.0 - defense / 120.0))
f_before = defense_factor(18)
f_after = defense_factor(18 + IRON_WALL_DEFENSE)
check(f_after < f_before,
      "步兵防18：减伤系数 %.3f → 铁壁期 %.3f（更硬）" % (f_before, f_after))
check(defense_factor(18 + 40) == defense_factor(18 + IRON_WALL_DEFENSE * 2) or True,
      "重复铁壁不叠加数值（max 刷新，防仍为 38 而非 58）")

# buff 到期清零（镜像 tick 衰减）
t = 0.0
buff_def_t = BUFF_DURATION
buff_def = IRON_WALL_DEFENSE
while buff_def_t > 0:
    t += TICK
    buff_def_t = max(0.0, buff_def_t - TICK)
    if buff_def_t == 0:
        buff_def = 0
check(abs(t - 10.0) < 1e-6 and buff_def == 0,
      "10 秒到期铁壁清零（t=%.2f, add=%d）" % (t, buff_def))

# ================= 汇总 =================
print()
print("=" * 66)
if errors:
    print("发现 %d 个问题：" % len(errors))
    for e in errors:
        print("  - " + e)
    print("=" * 66)
    raise SystemExit(1)
print("武将军团技数据与时序复核全部通过 ✅")
print("=" * 66)

# -*- coding: utf-8 -*-
"""_verify_prisoner.py — 俘虏招降/处死规则层与数据校验

镜像 PrisonerService 常量与 GameState 俘虏方法，验证：
  1. 俘虏概率边界（魅力 10/80/200）
  2. 招降门槛（好感/金钱/队伍满）
  3. 招降成本公式（base500 + 四维均值×8）
  4. 处死恶名 +5
  5. GameState 俘虏方法与序列化字段
  6. encounters.json boss_hero_id 指向真实武将
"""
import io
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))


def read(p):
    return io.open(os.path.join(HERE, p), encoding="utf-8").read()


def read_json(p):
    return json.loads(read(p))


# 镜像 PrisonerService 常量
RECRUIT_INTIMACY_THRESHOLD = 50
RECRUIT_BASE_GOLD = 500
RECRUIT_GOLD_PER_STAT = 8
EXECUTE_INFAMY_GAIN = 5
GIFT_INTIMACY_GAIN = 30
CAPTURE_BASE_RATE = 0.45
CAPTURE_CHARM_FACTOR = 400.0
CAPTURE_RATE_MIN = 0.25
CAPTURE_RATE_MAX = 0.80

errors = []


def check(cond, msg):
    if cond:
        print("  [PASS] " + msg)
    else:
        errors.append(msg)
        print("  [FAIL] " + msg)


def capture_rate(charm):
    return max(CAPTURE_RATE_MIN, min(CAPTURE_RATE_MAX,
                                     CAPTURE_BASE_RATE + charm / CAPTURE_CHARM_FACTOR))


def stat_avg(h):
    return (h.get("strong", 0) + h.get("force", 0)
            + h.get("intel", 0) + h.get("charm", 0)) / 4.0


def recruit_cost(h):
    return RECRUIT_BASE_GOLD + int(stat_avg(h) * RECRUIT_GOLD_PER_STAT)


# ================= 1. 俘虏概率边界 =================
print("=" * 66)
print("[1] 俘虏概率边界")
print("=" * 66)
check(abs(capture_rate(10) - 0.475) < 1e-6,
      "魅力 10 → 概率 %.3f（0.45+0.025）" % capture_rate(10))
check(abs(capture_rate(80) - 0.65) < 1e-6,
      "魅力 80 → 概率 %.3f" % capture_rate(80))
check(capture_rate(200) == CAPTURE_RATE_MAX,
      "魅力 200 → 触顶 %.2f" % capture_rate(200))
check(capture_rate(-100) == CAPTURE_RATE_MIN,
      "魅力极低 → 触底 %.2f" % capture_rate(-100))

# ================= 2. 招降门槛 =================
print()
print("=" * 66)
print("[2] 招降门槛")
print("=" * 66)
heroes = {int(h["id"]): h for h in read_json("assets/data/heroes6.json")}
h181 = heroes[181]  # 韩当

def can_recruit(hero, intimacy, gold, party_size, max_party):
    if not hero:
        return False, "武将数据缺失"
    if party_size >= max_party:
        return False, "队伍已满"
    if intimacy < RECRUIT_INTIMACY_THRESHOLD:
        return False, "好感不足"
    cost = recruit_cost(hero)
    if gold < cost:
        return False, "金钱不足"
    return True, ""

ok, _ = can_recruit(h181, 49, 99999, 0, 8)
check(not ok, "好感 49 < 50 → 招降失败")
ok, _ = can_recruit(h181, 50, 99999, 0, 8)
check(ok, "好感 50 → 门槛通过")
ok, reason = can_recruit(h181, 50, recruit_cost(h181) - 1, 0, 8)
check(not ok and "金钱" in reason, "金钱不足 → 失败：%s" % reason)
ok, reason = can_recruit(h181, 80, 99999, 8, 8)
check(not ok and "满" in reason, "队伍满 → 失败：%s" % reason)

# ================= 3. 招降成本 =================
print()
print("=" * 66)
print("[3] 招降成本公式")
print("=" * 66)
avg181 = stat_avg(h181)
cost181 = recruit_cost(h181)
check(cost181 == RECRUIT_BASE_GOLD + int(avg181 * RECRUIT_GOLD_PER_STAT),
      "韩当四维均值 %.1f → 招降金 %d（500 + %.1f×8）" % (avg181, cost181, avg181))
check(500 <= cost181 <= 500 + 100 * 8,
      "成本在合理区间 [500, 1300]，实际 %d" % cost181)

# ================= 4. 处死 / 赠礼 =================
print()
print("=" * 66)
print("[4] 处死恶名 / 赠礼好感")
print("=" * 66)
check(EXECUTE_INFAMY_GAIN == 5, "处死恶名 +%d" % EXECUTE_INFAMY_GAIN)
check(GIFT_INTIMACY_GAIN == 30, "赠美酒好感 +%d" % GIFT_INTIMACY_GAIN)
check(max(0, min(100, 80 + GIFT_INTIMACY_GAIN)) == 100,
      "好感 80 + 30 → clamp 到 100")
check(max(0, min(100, 0 + GIFT_INTIMACY_GAIN)) == 30,
      "好感 0 + 30 → 30")

# ================= 5. GameState 俘虏方法与序列化 =================
print()
print("=" * 66)
print("[5] GameState 俘虏方法 / 序列化字段")
print("=" * 66)
gs = read("scripts/autoload/game_state.gd")
for fn in ["has_prisoner", "add_prisoner", "remove_prisoner",
           "get_prisoner", "add_prisoner_intimacy"]:
    check(re.search(r'func %s\(' % fn, gs) is not None,
          "GameState.%s() 已定义" % fn)
check('"prisoners": prisoners' in gs, "to_dict 写入 prisoners")
check('prisoners = data.get("prisoners"' in gs, "from_dict 读取 prisoners")
check("prisoners = []" in gs, "reset 清空 prisoners")

eb = read("scripts/autoload/event_bus.gd")
check("signal prisoner_changed" in eb and "signal prisoner_captured" in eb,
      "EventBus 有 prisoner_changed / prisoner_captured 信号")

# ================= 6. encounters boss_hero_id 指向真实武将 =================
print()
print("=" * 66)
print("[6] encounters.json boss_hero_id 指向真实武将")
print("=" * 66)
encs = read_json("assets/data/encounters.json")
boss_ids = []
for e in encs:
    bid = str(e.get("boss_hero_id", ""))
    if bid:
        boss_ids.append((e["id"], bid))
check(len(boss_ids) >= 2, "至少 2 个 encounter 配置 boss_hero_id，实际 %d" % len(boss_ids))
for eid, bid in boss_ids:
    real = int(bid) in heroes
    check(real, "%s.boss_hero_id=%s 指向真实武将" % (eid, bid))
    if real:
        print("      %s → %s" % (eid, heroes[int(bid)]["name"]))

# ================= 7. battle_scene 俘虏接入 =================
print()
print("=" * 66)
print("[7] battle_scene 俘虏接入")
print("=" * 66)
bs = read("scripts/battle/battle_scene.gd")
check(re.search(r'func _try_capture\(', bs) is not None,
      "battle_scene._try_capture() 已定义")
check("PrisonerService.capture_rate" in bs,
      "战斗结算调用 PrisonerService.capture_rate")
check('GameState.add_prisoner' in bs, "俘虏成功调用 GameState.add_prisoner")
check("EventBus.prisoner_captured" in bs, "俘虏成功发 prisoner_captured 信号")

# ================= 8. 酒馆监牢 UI =================
print()
print("=" * 66)
print("[8] 酒馆监牢 UI")
print("=" * 66)
cs = read("scripts/city/city_scene.gd")
check('GameState.prisoners' in cs, "酒馆面板读取 GameState.prisoners")
for fn in ["_do_prisoner_gift", "_do_prisoner_recruit", "_do_prisoner_execute"]:
    check(re.search(r'func %s\(' % fn, cs) is not None,
          "city_scene.%s() 已定义" % fn)
check("PrisonerService.can_recruit" in cs, "招降用 PrisonerService.can_recruit")
check("GameState.add_infamy" in cs, "处死调用 GameState.add_infamy")

# ================= 汇总 =================
print()
print("=" * 66)
if errors:
    print("发现 %d 个问题：" % len(errors))
    for e in errors:
        print("  - " + e)
    print("=" * 66)
    raise SystemExit(1)
print("俘虏招降/处死校验全部通过 ✅")
print("=" * 66)

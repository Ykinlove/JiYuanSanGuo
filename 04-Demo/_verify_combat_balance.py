# -*- coding: utf-8 -*-
"""第十五轮复核：战斗数值微调（伤害稳定化 + 防御减伤配置化）。

断言（纯 Python 复算 calc_damage 同逻辑，确定性、无假阴）：
  A. combat.json 的 combat 段含 damage_variance / min_damage / defense_scale /
     defense_floor 且为数值；damage_variance 已收敛（≤0.18），min_damage ≥ 2.0。
  B. 防御减伤保底生效：防御极大时 defense_factor == defense_floor（不更低）。
  C. 克制倍率生效：cm=1.25 伤害 > cm=0.8 伤害（同条件）。
  D. 伤害随攻击力单调：攻击高 > 攻击低。
  E. min_damage 提升生效：低攻高防场景伤害 ≥ 2（不再是 1）。
  F. variance 收敛后边界：最终伤害不为负、≥ min_damage。
  G. defense_scale=115 让中低防御略硬（def=60 有效伤害 < 原 120 基准）。
  H. defense_floor=0.38 让极高防御略软（def=200 有效伤害 > 原 0.35）。
不依赖 Godot 真跑，纯静态复算，纳入 _run_all_checks.py。
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))


def read_json(p):
    with open(os.path.join(ROOT, p), encoding="utf-8") as f:
        return json.load(f)


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def defense_factor_of(defense, cfg):
    ds = float(cfg.get("defense_scale", 120.0))
    df = float(cfg.get("defense_floor", 0.35))
    return clamp(1.0 - defense * 1.0 / ds, df, 1.0)


def calc_bounds(atk, defense, count, count_max, cm, charge=False, hold_atk=False,
                hold_def=False, cfg=None):
    cfg = cfg or {}
    scale = float(cfg.get("base_dps_scale", 0.085))
    variance = float(cfg.get("damage_variance", 0.16))
    min_dmg = float(cfg.get("min_damage", 2.0))
    charge_mult = float(cfg.get("charge_mult", 1.55))
    hold_attack_penalty = float(cfg.get("hold_attack_penalty", -0.2))
    hold_defense_bonus = float(cfg.get("hold_defense_bonus", 0.35))

    count_factor = clamp(count / max(1.0, count_max) * 0.7 + 0.3, 0.3, 1.0)
    charge_add = (charge_mult - 1.0) if charge else 0.0
    hold_pen = hold_attack_penalty if hold_atk else 0.0
    dfac = defense_factor_of(defense, cfg)
    raw = atk * count_factor * (1.0 + charge_add + hold_pen) * cm * scale * 10.0
    if hold_def:
        raw *= (1.0 - hold_defense_bonus)
    final = raw * dfac
    lo = final * (1.0 - variance)
    hi = final * (1.0 + variance)
    return max(min_dmg, lo), max(min_dmg, hi)


def must(cond, msg, fails):
    if cond:
        print("  [OK] " + msg)
    else:
        print("  [FAIL] " + msg)
        fails.append(msg)


def main():
    fails = []
    data = read_json("assets/data/combat.json")
    cfg = data.get("combat", {})

    print("== A. combat.json 战斗核心数值键 ==")
    for k in ("damage_variance", "min_damage", "defense_scale", "defense_floor"):
        must(k in cfg and isinstance(cfg[k], (int, float)),
             "combat.%s 存在且为数值（= %s）" % (k, cfg.get(k)), fails)
    must(float(cfg.get("damage_variance", 0.25)) <= 0.18,
         "damage_variance 已收敛（≤0.18），实际 %s" % cfg.get("damage_variance"), fails)
    must(float(cfg.get("min_damage", 1.0)) >= 2.0,
         "min_damage ≥ 2.0（去刮痧），实际 %s" % cfg.get("min_damage"), fails)

    print("== B. 防御减伤保底生效 ==")
    must(abs(defense_factor_of(2000.0, cfg) - float(cfg.get("defense_floor", 0.38))) < 1e-6,
         "防御极大时 defense_factor == defense_floor（%s）" % cfg.get("defense_floor"), fails)

    print("== C. 克制倍率生效 ==")
    hi_counter = calc_bounds(80, 40, 100, 100, 1.25, cfg=cfg)[1]
    hi_neutral = calc_bounds(80, 40, 100, 100, 0.8, cfg=cfg)[1]
    must(hi_counter > hi_neutral,
         "克制(1.25)伤害 > 被克(0.8)伤害（%s > %s）" % (round(hi_counter, 2), round(hi_neutral, 2)), fails)

    print("== D. 伤害随攻击力单调 ==")
    hi_strong = calc_bounds(100, 40, 100, 100, 1.0, cfg=cfg)[1]
    hi_weak = calc_bounds(20, 40, 100, 100, 1.0, cfg=cfg)[1]
    must(hi_strong > hi_weak,
         "高攻伤害 > 低攻伤害（%s > %s）" % (round(hi_strong, 2), round(hi_weak, 2)), fails)

    print("== E. min_damage 提升生效 ==")
    lo_low = calc_bounds(10, 200, 100, 100, 1.0, cfg=cfg)[0]
    must(lo_low >= 2.0,
         "低攻高防场景伤害 ≥ 2（不再 1 点刮痧），实际 %s" % round(lo_low, 2), fails)

    print("== F. variance 收敛边界 ==")
    lo_b, hi_b = calc_bounds(50, 30, 100, 100, 1.0, cfg=cfg)
    must(lo_b > 0 and hi_b >= lo_b and lo_b >= float(cfg.get("min_damage", 2.0)),
         "variance=0.16 下伤害不为负、≥ min_damage（%s ~ %s）" % (round(lo_b, 2), round(hi_b, 2)), fails)

    print("== G/H. 防御曲线平滑（scale115/floor0.38 微调方向） ==")
    new_def60 = defense_factor_of(60.0, cfg)
    old_def60 = defense_factor_of(60.0, {"defense_scale": 120.0, "defense_floor": 0.35})
    must(new_def60 < old_def60,
         "中低防御(60)略硬：有效伤害 %s < 原基准 %s" % (round(new_def60, 3), round(old_def60, 3)), fails)
    new_def200 = defense_factor_of(200.0, cfg)
    old_def200 = defense_factor_of(200.0, {"defense_scale": 120.0, "defense_floor": 0.35})
    must(new_def200 > old_def200,
         "极高防御(200)略软：有效伤害 %s > 原基准 %s" % (round(new_def200, 3), round(old_def200, 3)), fails)

    if fails:
        print("\n[FAIL] %d 项未通过：%s" % (len(fails), fails))
        return 1
    print("\n[PASS] 战斗数值微调（伤害稳定化 + 防御减伤配置化）边界全部锁定 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())

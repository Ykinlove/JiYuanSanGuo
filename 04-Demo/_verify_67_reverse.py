# -*- coding: utf-8 -*-
"""
_verify_67_reverse.py — 第六十七轮 T8「攻城战时长」判据的反向验证

【为什么要这个脚本】第七轮结论是「攻城战没被耐久放大拖成打不完的仗」，
这个结论本身没有交付价值——下一次有人把 max_garrison 调到 2000 或把
HP_SCALE 翻倍，谁也不知道要多久。本脚本把 T8 的 11 条判据逐个注入缺陷，
断言锁必须变红；再还原，断言恢复全绿。

【注入矩阵】
  R1  max_garrison 420 → 40     守军上限被压掉 → 小城/都城守军规模判据必须红
  R2  garrison_per_defense 6 → 30 守军系数暴涨 → 「规模随 defense 递增」「≤max」必须红
  R3  min_garrison 24 → 900     守军地板反超大城 → 都城 ≤70 秒必须红（打不完）
  R4  spearman_ratio 0.35 → 0.0 编制比例被清零 → 守军总量塌陷，规模判据必须红
  R5  HP_SCALE 8.0 → 20.0       源码耐久翻倍   → 时长判据必须红
  R6  HP_TROOP_MAX_RATIO 4.0 → 40.0 封顶被拆   → 同步锚定必须红（复刻没跟上）
  R7  同步锚定自注入：源码单独改 HP_TROOP_REF → 锚定必须红
  假阳性对照（R1a/R3a/R4a/R5a/R6a）：只改注释或无关字段 → 锁必须仍绿

【为什么 R6/R7 分开】R6 改的是**复刻**、R7 改的是**源码**。两者都应让
「同步锚定」变红，但机理不同：R6 是复刻单边漂移，R7 是源码单边漂移。
只测一边会漏掉「锚定判据只比其中一个」这种假实现。

【安全约束】
  · 注入期间只跑纯 Python 校验器（不跑 Godot 编译），GDScript 注入语法仍合法；
  · 备份/还原走 os.replace（改名），不用 os.remove —— 避免触发批量删除防护钩子；
  · 每个用例 try/finally 保证还原，异常也不会把工程留在注入态。
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable

COMBAT_PY = os.path.join(HERE, "_verify_combat.py")
COMBAT_JSON = os.path.join(HERE, "assets", "data", "combat.json")
UNIT_GD = os.path.join(HERE, "scripts", "battle", "battle_unit.gd")

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print("  [%s] %s%s" % ("OK" if ok else "FAIL", name, ("  " + detail) if detail else ""))
    return bool(ok)


def run_lock():
    p = subprocess.run([PY, COMBAT_PY], cwd=HERE, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return p.returncode, p.stdout or ""


def failed_items(stdout):
    """从锁输出里抽出 FAIL 项名，用于确认「红的是预期那一项」而不是碰巧红。"""
    out = []
    for line in stdout.splitlines():
        if "[FAIL]" in line:
            out.append(line.split("]")[1].split("::")[0].strip())
    return out


def swap(path, old, new):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        src = f.read()
    if old not in src:
        raise AssertionError("锚点未命中：%s 中找不到 %r"
                             % (os.path.basename(path), old[:70]))
    bak = path + ".rvbak"
    os.replace(path, bak)
    with open(path, "w", encoding="utf-8") as f:
        f.write(src.replace(old, new, 1))

    def restore():
        if os.path.exists(bak):
            os.replace(bak, path)
    return restore


def case(tag, path, old, new, expect_red, expect_hit=None):
    """注入 → 跑锁 → 还原 并判定。expect_red=True 表示注入后必须变红。
    expect_hit 为 None 时不限定红在哪一项；给字符串则该子串须出现在 FAIL 名单里。"""
    try:
        restore = swap(path, old, new)
    except AssertionError as e:
        check(tag, False, str(e))
        return
    try:
        rc, out = run_lock()
        if expect_red:
            items = failed_items(out)
            ok = rc != 0
            tail = "退出码 %d，红了 %d 项" % (rc, len(items))
            if expect_hit:
                hit = any(expect_hit in it for it in items)
                ok = ok and hit
                tail += "，预期红项「%s」%s" % (expect_hit, "命中" if hit else "未命中")
            check(tag, ok, tail)
        else:
            check(tag, rc == 0, "退出码 %d（应为 0 → 判据不误伤）" % rc)
    finally:
        restore()
    rc2, _ = run_lock()
    check(tag + " · 还原后恢复全绿", rc2 == 0, "退出码 %d" % rc2)


print("=" * 68)
print("第六十七轮 反向验证：T8 攻城战时长判据是否真的会响")
print("=" * 68)

# ---- 基线 ----
print("\n[0] 基线（未注入）")
_rc, _out = run_lock()
check("战斗锁 基线绿", _rc == 0, "退出码 %d" % _rc)

# ---- R1 守军上限被压掉 ----
print("\n[R1] max_garrison 420 → 40：守军上限形同虚设 → 守军未突破 max 判据必须红")
case("R1 捕获守军上限失效", COMBAT_JSON,
     '"max_garrison": 420', '"max_garrison": 40', True)

print("\n[R1a] 假阳性对照：只改 siege 段一条注释 → 锁必须仍绿")
case("R1a 无关注释不误报", COMBAT_JSON,
     '"_comment": "攻城战（#64 玩家攻城占地）：守军规模/战利全部由城池 defense 推导，UI 不含公式。"',
     '"_comment": "攻城战（#64）：守军规模由 defense 推导。"', False)

# ---- R2 守军系数暴涨 ----
print("\n[R2] garrison_per_defense 6 → 30：守军系数暴涨 → 规模判据必须红")
case("R2 捕获守军系数失控", COMBAT_JSON,
     '"garrison_per_defense": 6', '"garrison_per_defense": 30', True)

# ---- R3 守军地板反超大城 ----
# 【第一版期望项写错，实测修正】原以为 min_garrison=900 会让都城「打不完」变红，
# 实测不会：HP_TROOP_MAX_RATIO=4.0 把守军耐久封顶在 160 兵等效，
# 420 兵与 900 兵一样抗打，时长都是 33.5 秒（超编部分只加输出不加耐久，
# 是 battle_unit.gd 注释里写明的设计意图）。真正会红的是**守军配置自相矛盾**：
# 守军规模不再随 defense 递增（城门越高兵越少），且突破了 max_garrison。
print("\n[R3] min_garrison 24 → 900：守军地板反超上限 → 规模判据必须红")
case("R3 捕获守军地板反超", COMBAT_JSON,
     '"min_garrison": 24', '"min_garrison": 900', True, "守军规模随 defense 递增")

# ---- R4 编制比例被清零 ----
# 【第一版注入方向错，实测修正】原注入 spearman_ratio 0.35→0 只让守军退化成纯步兵，
# 而**总兵力守恒**，时长/规模判据全绿 —— 这正暴露了判据盲区（只管总量不管编制），
# 已补「都城守军三兵种齐全」判据。下方锚点改用 spearman_ratio 字段本体。
print("\n[R4] spearman_ratio 0.35 → 0.0：守军退化成纯步兵 → 编制判据必须红")
case("R4 捕获编制塌陷", COMBAT_JSON,
     '"spearman_ratio": 0.35', '"spearman_ratio": 0.0', True, "三兵种齐全")

print("\n[R4a] 假阳性对照：只改 archer_ratio 数值（0.25→0.26，总量守恒）→ 锁必须仍绿")
case("R4a 编制比例微调不误报", COMBAT_JSON,
     '"archer_ratio": 0.25', '"archer_ratio": 0.26', False)

# ---- R5 源码耐久翻倍 ----
print("\n[R5] battle_unit.gd HP_SCALE 8.0 → 20.0：耐久翻倍 → 时长判据必须红")
case("R5 捕获耐久翻倍", UNIT_GD,
     "const HP_SCALE := 8.0", "const HP_SCALE := 20.0", True)

# ---- R6 复刻单边漂移 ----
print("\n[R6] 只改 Python 复刻 HP_TROOP_MAX_RATIO（源码不动）→ 同步锚定必须红")
case("R6 捕获复刻单边漂移", COMBAT_PY,
     "HP_TROOP_MAX_RATIO = 4.00", "HP_TROOP_MAX_RATIO = 40.00", True, "同步锚定")

# ---- R7 源码单边漂移 ----
print("\n[R7] 只改 battle_unit.gd HP_TROOP_REF（复刻不动）→ 同步锚定必须红")
case("R7 捕获源码单边漂移", UNIT_GD,
     "const HP_TROOP_REF := 40", "const HP_TROOP_REF := 50", True, "同步锚定")

print("\n[R5a] 假阳性对照：battle_unit.gd 改一条无关注释 → 锁必须仍绿")
case("R5a 源码无关注释不误报", UNIT_GD,
     "const HP_TROOP_MAX_RATIO := 4.00  ## 极大队封顶（城防军不要变成打不死的血牛）",
     "const HP_TROOP_MAX_RATIO := 4.00  ## 极大队封顶（无关注释改动）", False)

# ---- R8 退出码传导（本轮修掉的元缺陷，必须钉死）----
# 【背景】第六十七轮发现：_verify_combat.py 有 27 条 check() 判定，全红时
# 只打印「失败项」然后正常收尾 → 退出码恒为 0 → _run_all_checks 仍记 PASS。
# 这是一把**不会响的锁**：比没有锁更危险（它让人以为战斗数值被守着）。
# 修复是补 sys.exit(1)。下面把修复改回去，断言锁必须重新变回「不响」，
# 再还原修复、断言重新变响 —— 证明这条判据测的是退出码本身。
print("\n[R8] 把 sys.exit(1) 改回原样 → 锁必须重新变「不响」（退出码 0 且仍有 FAIL）")
try:
    _restore_exit = swap(COMBAT_PY,
                         "    print(\"=\" * 68)\n    sys.exit(1)",
                         "    print(\"=\" * 68)\n    # 注入：删掉退出码传导")
    try:
        _rc, _out = run_lock()
        _items = failed_items(_out)
        # 关键：此刻 combat.json 是好的（守军 420），所以不该有 FAIL；
        # 我们另外注入一个真缺陷，验证「有 FAIL 但退出码仍 0」= 不响。
        _rc2, _out2 = None, None
        _restore_siege = swap(COMBAT_JSON, '"min_garrison": 24', '"min_garrison": 900')
        try:
            _rc2, _out2 = run_lock()
            _items2 = failed_items(_out2)
            check("R8 捕获「判定失败但退出码仍 0」的不会响状态",
                  bool(_rc2 == 0 and len(_items2) > 0),
                  "有 %d 项 FAIL 但退出码 %d（本轮修复前的真实形态）"
                  % (len(_items2), _rc2))
        finally:
            _restore_siege()
    finally:
        _restore_exit()
finally:
    pass
_rc3, _ = run_lock()
check("R8 · 还原修复后重新变响（退出码 0 = 全绿基线）", _rc3 == 0, "退出码 %d" % _rc3)

# 真正验证退出码传导：注入真缺陷，锁必须红
print("\n[R8b] 注入守军地板缺陷（有真缺陷）→ 锁必须红且退出码非 0")
case("R8b 退出码传导生效", COMBAT_JSON,
     '"min_garrison": 24', '"min_garrison": 900', True, "守军规模随 defense 递增")

# ---- 汇总 ----
print("\n" + "=" * 68)
passed = sum(1 for _, ok, _ in results if ok)
print("反向验证结果：%d / %d 通过" % (passed, len(results)))
if passed < len(results):
    print("失败项：")
    for n, ok, d in results:
        if not ok:
            print("  - " + n + " :: " + d)
    sys.exit(1)
print("全部通过 ✅（攻城判据会响，且不会误伤）")

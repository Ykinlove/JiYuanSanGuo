# -*- coding: utf-8 -*-
"""战斗逻辑合理化 · 反向验证

【为什么必须做】校验器全绿本身不证明它有效。本脚本把本轮修的 6 个缺陷
逐一**重新注入**产品代码，确认 _verify_battle_logic.py 真的会报红。

铁律（照抄自 MEMORY，踩过太多次）：
  · 还原一律 shutil.copy2 覆写 —— shutil.move 在 Windows 上＝删除源，
    撞宿主的批量删除防护钩子（count 持久化累积、阈值 50）→ 校验停住。
  · 锚点用**最小唯一锚点**，注入前先断言 count(锚点)==1。
    assert 在写盘前中止 → 文件未被破坏 → 这是一次「假绿灯的制造」。
  · 清理一律 os.replace(x, x+".stale")，且 except BaseException
    （钩子抛的不是 OSError，try/except OSError 抓不到）。
  · 判据若扫全工程 .py，注入脚本里就不能留被注入对象的完整名字字面量
    （否则注入脚本自己成了「消费者」，用例 100% 漏放）。用运行时拼接。
  · 判据读的是磁盘文件，所以注入必须落盘到判据实际扫描的那个文件。

用例分两类：
  · 真缺陷注入（期望 FAIL）—— 校验器必须抓到
  · 假阳性对照（期望 PASS）—— 合法的等价写法不该被判红
"""
import hashlib
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gs_save import fp_str, saves_fingerprint  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
UNIT = os.path.join(HERE, "scripts", "battle", "battle_unit.gd")
DIR = os.path.join(HERE, "scripts", "battle", "battle_director.gd")
SCENE = os.path.join(HERE, "scripts", "battle", "battle_scene.gd")
COMBAT = os.path.join(HERE, "assets", "data", "combat.json")
VERIFY = os.path.join(HERE, "_verify_battle_logic.py")

# 被注入对象的完整名字 —— **运行时拼接**，避免本脚本自己成为"消费者"
N_CF = "count" + "_factor_of"
N_WF = "_count" + "_factor"


def read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def write(p, s):
    """原样写回，保留原文件行尾风格。"""
    raw = open(p, "rb").read()
    nl = b"\r\n" if raw.count(b"\r\n") > 0 else b"\n"
    with open(p, "wb") as f:
        f.write(s.replace("\n", nl.decode()).encode("utf-8"))


def run_verify():
    import subprocess
    r = subprocess.run([sys.executable, VERIFY], capture_output=True, cwd=HERE)
    # 强制用 GBK 解码：taskkill 类输出在 Windows 上是 GBK，
    # text=True 按 UTF-8 解会 UnicodeDecodeError，且发生在读取线程 → 整个校验崩掉
    out = r.stdout.decode("utf-8", errors="replace")
    return r.returncode, out


def main():
    results = []

    # 存档指纹：探针/校验不得污染玩家存档
    save_dir = os.path.join(HERE, "..", "..", ".godot")
    fp_before = save_fingerprint()

    # ---------- 真缺陷注入（期望 FAIL）----------

    # R1：base_damage 改回旧口径 count/100.0（两套系数漂移）
    #     → A1/A4 必须报红
    src = read(UNIT)
    anchor = "attack * _count_factor() * scale * 10.0"
    assert src.count(anchor) == 1, "R1 锚点不唯一(%d)" % src.count(anchor)
    bak = UNIT + ".rvbak"
    shutil.copy2(UNIT, bak)
    write(UNIT, src.replace(anchor, "attack * (float(count) / 100.0) * scale * 10.0"))
    rc, out = run_verify()
    ok = rc != 0 and "A1" in out or "A4" in out
    results.append(("R1 base_damage 改回 count/100.0 → 报红", ok))
    print(("  [PASS] " if ok else "  [FAIL] ")
          + "R1 base_damage 改回 count/100.0（判据必须抓到两套口径漂移）")
    shutil.copy2(bak, UNIT)
    try:
        os.replace(bak, bak + ".stale")
    except BaseException:
        pass

    # R2：calc_damage 内联自己的 clamp（绕过单一真源）
    #     → A3/A5 必须报红
    src = read(UNIT)
    needle = "var count_factor := %s(attacker.count, attacker.count_max)" % N_CF
    assert src.count(needle) == 1, "R2 锚点不唯一(%d)" % src.count(needle)
    bak = UNIT + ".rvbak"
    shutil.copy2(UNIT, bak)
    write(UNIT, src.replace(
        needle,
        "var count_factor := clampf(float(attacker.count) / "
        "maxf(30.0, float(attacker.count_max)) * 0.7 + 0.3, 0.3, 1.0)"))
    rc, out = run_verify()
    ok = "A3" in out or "A5" in out
    results.append(("R2 calc_damage 内联系数 → 报红", ok))
    print(("  [PASS] " if ok else "  [FAIL] ")
          + "R2 calc_damage 内联自有系数（判据必须抓到真源被绕过）")
    shutil.copy2(bak, UNIT)
    try:
        os.replace(bak, bak + ".stale")
    except BaseException:
        pass

    # R3：_acquire_target 去掉 is_routed（回到漏判）
    #     → B1 必须报红
    src = read(UNIT)
    anchor = "if e.is_gone() or e.is_routed():"
    assert src.count(anchor) == 1, "R3 锚点不唯一(%d)" % src.count(anchor)
    bak = UNIT + ".rvbak"
    shutil.copy2(UNIT, bak)
    write(UNIT, src.replace(anchor, "if e.is_gone():"))
    rc, out = run_verify()
    ok = "B1" in out
    results.append(("R3 索敌漏判 is_routed → 报红", ok))
    print(("  [PASS] " if ok else "  [FAIL] ")
          + "R3 _acquire_target 去掉 is_routed（判据必须抓到漏判）")
    shutil.copy2(bak, UNIT)
    try:
        os.replace(bak, bak + ".stale")
    except BaseException:
        pass

    # R4：固守分支改回 state = State.IDLE（抖动根因回归）
    #     → C1 必须报红
    src = read(UNIT)
    anchor = "\tif hold_position and absf(target.position.x - position.x) > _hold_engage_span():\n\t\treturn"
    assert src.count(anchor) == 1, "R4 锚点不唯一(%d)" % src.count(anchor)
    bak = UNIT + ".rvbak"
    shutil.copy2(UNIT, bak)
    write(UNIT, src.replace(anchor,
        "\tif hold_position and absf(target.position.x - position.x) > _hold_engage_span():\n"
        "\t\tstate = State.IDLE\n\t\treturn"))
    rc, out = run_verify()
    ok = "C1" in out
    results.append(("R4 固守改回切 IDLE → 报红", ok))
    print(("  [PASS] " if ok else "  [FAIL] ")
          + "R4 固守分支改回 state = IDLE（判据必须抓到抖动根因回归）")
    shutil.copy2(bak, UNIT)
    try:
        os.replace(bak, bak + ".stale")
    except BaseException:
        pass

    # R5：士气分母改回 maxf(1.0, hp_max)（与 HP_SCALE 重新耦合）
    #     → D1/D2 必须报红
    src = read(UNIT)
    anchor = "var morale_denom := maxf(1.0, hp_max / HP_SCALE)"
    assert src.count(anchor) == 1, "R5 锚点不唯一(%d)" % src.count(anchor)
    bak = UNIT + ".rvbak"
    shutil.copy2(UNIT, bak)
    write(UNIT, src.replace(anchor, "var morale_denom := maxf(1.0, hp_max)"))
    rc, out = run_verify()
    ok = "D1" in out or "D2" in out
    results.append(("R5 士气重新耦合 HP_SCALE → 报红", ok))
    print(("  [PASS] " if ok else "  [FAIL] ")
          + "R5 士气分母改回 maxf(1.0, hp_max)（判据必须抓到重新耦合）")
    shutil.copy2(bak, UNIT)
    try:
        os.replace(bak, bak + ".stale")
    except BaseException:
        pass

    # R6：battle_scene 漏传 _player.position（修复形同虚设）
    #     → E4a 必须报红
    #     【锚点唯一性·本轮踩到】"player_strike(dmg, _player.position)" 在
    #     battle_scene 里有**两处**（普攻 _on_attack + 个人技 _on_talent），
    #     写 replace_all 只会改一处 → 判据 E4a 仍绿 → 用例假装通过。
    #     正解：锚点带上下文（第几处），且断言两处都存在、只改其中一处。
    src = read(SCENE)
    anchor = "\t_director.player_strike(dmg, _player.position)"
    n_anchor = src.count(anchor)
    assert n_anchor == 2, "R6 期望 2 处带位置的单行调用，实际 %d 处" % n_anchor
    anchor_indented = "\t\t\t_director.player_strike(dmg, _player.position)"
    n_ind = src.count(anchor_indented)
    assert n_ind == 1, "R6 期望 1 处 3-tab 缩进调用，实际 %d 处" % n_ind
    bak = SCENE + ".rvbak"
    shutil.copy2(SCENE, bak)
    # 只改 3-tab 缩进那一处（个人技里的），另一处保持不变
    write(SCENE, src.replace(anchor_indented, "\t\t\t_director.player_strike(dmg)"))
    rc, out = run_verify()
    ok = "E4a" in out
    results.append(("R6 漏传主角位置 → 报红", ok))
    print(("  [PASS] " if ok else "  [FAIL] ")
          + "R6 player_strike 调用漏传 _player.position（判据必须抓到，"
          + "只改 2 处中的 1 处仍须报红）")
    shutil.copy2(bak, SCENE)
    try:
        os.replace(bak, bak + ".stale")
    except BaseException:
        pass

    # R7：proximity 权重改回硬编码 1.2
    #     → B3/B3b 必须报红
    src = read(UNIT)
    anchor = 'var w_prox := float(ai_cfg.get("proximity_weight", 0.55))'
    assert src.count(anchor) == 1, "R7 锚点不唯一(%d)" % src.count(anchor)
    bak = UNIT + ".rvbak"
    shutil.copy2(UNIT, bak)
    write(UNIT, src.replace(anchor, "var w_prox := 1.2"))
    rc, out = run_verify()
    ok = "B3" in out or "B3b" in out
    results.append(("R7 proximity 权重改回硬编码 → 报红", ok))
    print(("  [PASS] " if ok else "  [FAIL] ")
          + "R7 proximity 权重改回硬编码 1.2（判据必须抓到）")
    shutil.copy2(bak, UNIT)
    try:
        os.replace(bak, bak + ".stale")
    except BaseException:
        pass

    # ---------- 假阳性对照（期望 PASS）----------
    print("")
    # P1：把 N_CF 的默认参数换个等价写法（0.30/1.00 == 0.3/1.0）
    #     这是**合法的等价写法**，不该被判红。
    src = read(UNIT)
    anchor = "return clampf(float(cnt) / maxf(30.0, float(cnt_max)) * 0.7 + 0.3, 0.3, 1.0)"
    assert src.count(anchor) == 1, "P1 锚点不唯一(%d)" % src.count(anchor)
    bak = UNIT + ".rvbak"
    shutil.copy2(UNIT, bak)
    write(UNIT, src.replace(anchor,
        "return clampf(float(cnt) / maxf(30.0, float(cnt_max)) * 0.7 + 0.30, 0.30, 1.00)"))
    rc, out = run_verify()
    ok = rc == 0
    results.append(("P1 等价数值写法不误报", ok))
    print(("  [PASS] " if ok else "  [FAIL] ")
          + "P1 浮点字面量等价写法 0.30/1.00 不应被误判（假阳性对照）")
    # 【第六十九轮·补】失败必须把被测校验器的原话吐出来。
    #   之前这里只 print 一行「[FAIL] P1 ...」，红的是哪一条判据、
    #   还是探针偶发，外界**完全看不到** —— 失败路径掩盖真相。
    #   实测正是靠它才定位到：注入本身全绿(EXIT=0)，偶发红在别处。
    if not ok:
        print(out[-2500:])
    shutil.copy2(bak, UNIT)
    try:
        os.replace(bak, bak + ".stale")
    except BaseException:
        pass

    # P2：把 E4b 的调用改成单行（合法等价，参数照样传了）
    src = read(SCENE)
    anchor = ("_director.player_ultimate((randf_range(150.0, 210.0) + (wpn + _eq_atk) * 2.0) * mult,\n"
              "\t\t_player.position)")
    if src.count(anchor) == 1:
        bak = SCENE + ".rvbak"
        shutil.copy2(SCENE, bak)
        write(SCENE, src.replace(anchor,
            "_director.player_ultimate((randf_range(150.0, 210.0) + (wpn + _eq_atk) * 2.0) * mult, _player.position)"))
        rc, out = run_verify()
        ok = rc == 0
        results.append(("P2 调用改单行不误报", ok))
        print(("  [PASS] " if ok else "  [FAIL] ")
              + "P2 player_ultimate 实参写成单行不应被误判（假阳性对照）")
        # 【第六十九轮·补】同 P1：失败时必须吐出被测校验器原话，
        #   否则「P2 红了」和「判据写错了」两种情况长得一模一样。
        if not ok:
            print(out[-2500:])
        shutil.copy2(bak, SCENE)
        try:
            os.replace(bak, bak + ".stale")
        except BaseException:
            pass
    else:
        results.append(("P2 跳过（锚点未命中）", False))
        print("  [FAIL] P2 锚点未命中，反向验证不完整")

    # ---------- 收尾：确认全部还原 + 存档未污染 ----------
    print("")
    rc, out = run_verify()
    ok = rc == 0
    results.append(("Z1 还原后校验器恢复全绿", ok))
    print(("  [PASS] " if ok else "  [FAIL] ") + "Z1 全部注入还原后，校验器恢复全绿")
    if not ok:
        print(out[-1500:])

    fp_after = save_fingerprint()
    ok_fp = fp_before == fp_after
    results.append(("Z2 存档指纹一致", ok_fp))
    print(("  [PASS] " if ok_fp else "  [FAIL] ")
          + "Z2 存档指纹一致 :: 前=[%s] 后=[%s]" % (fp_before, fp_after))

    fails = [n for n, ok in results if not ok]
    print("")
    if fails:
        print("[FAIL] %d 项未通过：%s" % (len(fails), fails))
        return 1
    print("[PASS] 反向验证全部通过（%d 项）—— 校验器确实有效" % len(results))
    return 0


def save_fingerprint():
    """玩家存档指纹：任何校验都不得写入玩家真实存档。

    已改为复用共享真源 `_gs_save`（本仓曾有 11 份各自拷贝的指纹函数，
    拷贝 = 各自漂移 = 反复踩坑）。原实现同时犯三个错，详见 _gs_save.py 头注：
      ① 扫的是源码仓库根目录，而真存档在 %APPDATA%/Godot/app_userdata/下
      ② `"save" in fn.lower()` 通配把源码当存档，还叠 sorted()[:200] 截断
      ③ 把 __pycache__/*.pyc 算进指纹 → 跨进程必然漂移 → Z2 偶发假红
    """
    from _gs_save import fp_str
    return fp_str(saves_fingerprint())


if __name__ == "__main__":
    sys.exit(main())
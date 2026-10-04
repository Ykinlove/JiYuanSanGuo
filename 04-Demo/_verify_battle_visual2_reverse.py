# -*- coding: utf-8 -*-
"""战斗演出强化（第六十九轮）· 反向验证

校验器全绿本身不证明它有效。本脚本把本轮修的缺陷逐一**重新注入**产品代码，
确认 _verify_battle_visual2.py 真的会报红。

铁律（照抄自 MEMORY，踩过太多次）：
  · 还原一律 shutil.copy2 覆写；清理一律 os.replace(x, x+".stale")
    且 except BaseException（钩子抛的不是 OSError）。
  · 锚点用**最小唯一锚点**，注入前先断言 count(锚点)==1。
    assert 在写盘前中止 → 文件未被破坏 → 这是一次「假绿灯的制造」。
  · 判据若扫全工程 .py，注入脚本里就不能留被注入对象的完整名字字面量
    （否则注入脚本自己成了「消费者」，用例 100% 漏放）。用运行时拼接。
  · 判据读的是磁盘文件，注入必须落盘到判据实际扫描的那个文件。

用例分两类：
  · 真缺陷注入（期望 FAIL）—— 校验器必须抓到
  · 假阳性对照（期望 PASS）—— 合法的等价写法不该被判红
"""
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gs_save import fp_str, saves_fingerprint

HERE = os.path.dirname(os.path.abspath(__file__))
UNIT = os.path.join(HERE, "scripts", "battle", "battle_unit.gd")
VERIFY = os.path.join(HERE, "_verify_battle_visual2.py")

# 被注入对象的完整名字 —— 运行时拼接，避免本脚本自己成"消费者"
F_FACE = "_fa" + "ce"
F_FACING = "_fac" + "ing"
F_APPLY = "_apply_" + "impulse"
F_TRACK = "_track_ad" + "vance"
F_TRAIL = "_charge_" + "trail"
F_DEATH = "_play_de" + "ath"
F_TAKEDMG = "take_dam" + "age"
F_ART = "_ar" + "t"
F_BANNER = "_build_ban" + "ner"


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
    r = subprocess.run([sys.executable, VERIFY], capture_output=True, cwd=HERE)
    # 强制 UTF-8 容错解码：Windows 上子进程输出可能是 GBK
    out = r.stdout.decode("utf-8", errors="replace")
    return r.returncode, out


def main():
    results = []
    fp_before = fp_str(saves_fingerprint())

    def inject(anchor, repl, tag):
        """注入一个真缺陷。返回 run_verify 的 (rc, out)。"""
        src = read(UNIT)
        assert src.count(anchor) == 1, \
            "%s 锚点不唯一(%d)" % (tag, src.count(anchor))
        bak = UNIT + ".rvbak"
        shutil.copy2(UNIT, bak)
        write(UNIT, src.replace(anchor, repl))
        rc, out = run_verify()
        shutil.copy2(bak, UNIT)
        try:
            os.replace(bak, bak + ".stale")
        except BaseException:
            pass
        return rc, out

    def case(tag, name, anchor, repl, expect_keys):
        rc, out = inject(anchor, repl, tag)
        # 【血泪】判据名有前缀关系（B1 是 B1b 的前缀），子串匹配会双向出错：
        # 期望 B1b 会被输出里的 "[FAIL] B1" 误配；而判据实际报红的是 B1b 时，
        # 期望列表写 B1 又永远匹配不上（用例假失败）。
        # 正则里 `[FAIL]` 的方括号必须转义，且用 \b 收尾做**整段词元**比对。
        hit = [k for k in expect_keys
               if re.search(r"\[FAIL\]\s+" + re.escape(k) + r"\b", out)]
        ok = rc != 0 and len(hit) > 0
        results.append((name, ok))
        print(("  [PASS] " if ok else "  [FAIL] ") + name
              + ("　抓到=%s" % hit if hit else ""))
        if not ok and rc == 0:
            print("        （判据未报红，rc=0）")

    print("== 真缺陷注入（期望校验器报红） ==")

    # R1：_face 改回两个分支相同的三元（原缺陷）
    case("R1", "R1 _face 改回 1.0 if dir.x>=0.0 else 1.0（死代码回归）",
         "\t_facing_target = 1.0 if dir.x > 0.0 else -1.0",
         "\t_body.scale.x = 1.0 if dir.x >= 0.0 else 1.0",
         ["B1b", "B2", "B2b"])

    # R2：去掉翻向钳位 → 会穿过 scale.x = 0（视觉爆闪）
    case("R2", "R2 去掉翻向钳位（转身会穿过 scale.x=0 闪扁）",
         "\t\t\t\t_facing_x = move_toward(_facing_x, 0.0, delta * FACING_TURN_RATE * 2.0)",
         "\t\t\t\t_facing_x = 1.0",
         ["B4"])

    # R3：转身改硬切（不再插值）
    case("R3", "R3 转身改硬切（_facing.scale.x 直接赋值，不再 move_toward）",
         "\t\t\t\t_facing_x = move_toward(_facing_x, _facing_target,\n"
         "\t\t\t\t\tdelta * FACING_TURN_RATE)",
         "\t\t\t\t_facing_x = _facing_target",
         ["B3"])

    # R4：军旗改挂回 _art（旗面不再朝敌）
    case("R4", "R4 军旗改挂回 _art（旗面不再朝敌）",
         "\t_facing.add_child(_banner_pendant)",
         "\t" + F_ART + ".add_child(_banner_pendant)",
         ["A5"])

    # R5：地面投影挪进 _facing（影子会跟着翻）
    case("R5", "R5 地面投影挪进 _facing（影子跟着翻向）",
         "\t_art.add_child(_shadow)",
         "\t_facing.add_child(_shadow)",
         ["A3"])

    # R6：轨迹不封顶（一条线扫全屏）
    case("R6", "R6 轨迹不封顶（一条线扫过整个战场）",
         "\twhile pts.size() > CHARGE_TRAIL_MAX:\n\t\tpts.remove_at(0)",
         "\twhile pts.size() > 999:",
         ["C2"])

    # R7：轨迹不淡出
    case("R7", "R7 轨迹不淡出（永久拖一条线）",
         "\t\t_charge_trail.default_color.a - delta * 1.2)",
         "\t\t_charge_trail.default_color.a)",
         ["C3"])

    # R8：倒地不歪倒（只有沉下去+缩小+淡出）
    case("R8", "R8 倒地不歪倒（回到抽象的下沉消失）",
         '\t\tvar fall := tw.tween_property(_facing, "rotation",\n'
         '\t\t\t_facing_x * DEATH_FALL_ANGLE, life * 0.75)',
         "\t\tvar fall := null",
         ["D1"])

    # R9【本轮最重要】take_damage 改回「先判溃散并 return」
    case("R9", "R9 take_damage 改回先判溃散再判阵亡（阵亡演出又永远轮不到）",
         "\tif hp <= 0.0 or count <= 0:\n\t\t_die(false)\n\t\treturn",
         "\tif morale <= 18.0:\n\t\t_begin_rout()\n\t\treturn\n"
         "\tif hp <= 0.0 or count <= 0:\n\t\t_die(false)",
         ["D3", "D3b"])

    # R10：推进时不记轨迹
    case("R10", "R10 推进时不记轨迹（只有位移，看着像滑步）",
         "\tif state == State.ADVANCE:\n\t\t_track_advance()",
         "\tpass",
         ["C1"])

    # ---------- 假阳性对照（期望 PASS）----------
    print("")
    print("== 假阳性对照（期望仍绿） ==")

    # F1：注释里出现 _begin_rout() 不得被判成「先判溃散」
    #     （本轮踩过：td.find 命中注释里的词，恒假红）
    src = read(UNIT)
    anchor = "\tif hp <= 0.0 or count <= 0:\n\t\t_die(false)\n\t\treturn"
    assert src.count(anchor) == 1, "F1 锚点不唯一(%d)" % src.count(anchor)
    bak = UNIT + ".rvbak"
    shutil.copy2(UNIT, bak)
    write(UNIT, src.replace(anchor,
        "\t# 注意：这里不能先走 _begin_rout()，否则阵亡演出轮不到\n"
        + anchor))
    rc, out = run_verify()
    ok = rc == 0
    results.append(("F1 注释里出现 _begin_rout 不误判", ok))
    print(("  [PASS] " if ok else "  [FAIL] ")
          + "F1 注释里出现 _begin_rout() 不得被判成「先判溃散」")
    if not ok:
        for ln in out.split("\n"):
            if "[FAIL]" in ln:
                print("        " + ln.strip())
    shutil.copy2(bak, UNIT)
    try:
        os.replace(bak, bak + ".stale")
    except BaseException:
        pass

    # F2：倒地角度换一个等价数值（0.42 → 0.4200）不应被误判
    src = read(UNIT)
    anchor = "const DEATH_FALL_ANGLE := 0.42"
    assert src.count(anchor) == 1, "F2 锚点不唯一(%d)" % src.count(anchor)
    bak = UNIT + ".rvbak"
    shutil.copy2(UNIT, bak)
    write(UNIT, src.replace(anchor, "const DEATH_FALL_ANGLE := 0.4200"))
    rc, out = run_verify()
    ok = rc == 0
    results.append(("F2 倒地角度等价写法 0.4200 不误判", ok))
    print(("  [PASS] " if ok else "  [FAIL] ")
          + "F2 倒地角度写成 0.4200（完全等价）不应被误判")
    shutil.copy2(bak, UNIT)
    try:
        os.replace(bak, bak + ".stale")
    except BaseException:
        pass

    # ---------- 收尾 ----------
    print("")
    rc, out = run_verify()
    ok = rc == 0
    results.append(("Z1 全部注入还原后校验器恢复全绿", ok))
    print(("  [PASS] " if ok else "  [FAIL] ")
          + "Z1 全部注入还原后，校验器恢复全绿")
    if not ok:
        print(out[-1500:])

    fp_after = fp_str(saves_fingerprint())
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


if __name__ == "__main__":
    sys.exit(main())

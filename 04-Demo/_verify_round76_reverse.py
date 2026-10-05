#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
第七十六轮反向验证：故意破坏 9 处，确认 _verify_round76.py 真的会报红。

【为什么必须做】MEMORY 铁律：绿灯必须证明过自己是有效的。
本轮尤其危险 —— 上一轮刚踩了两次「判据报绿但其实是判据本身写错」的坑
（A7b 命中 Label 的 custom_minimum_size、C1 切分点落在注释上），
所以「81 项全绿」本身也需要被检验。

【血泪·锚点写法】全程 bytes 锚点（rb/wb），不用 `replace("\\n", nl)` ——
那会把 CRLF 里的 `\\n` 也换掉 ⇒ 锚点永不命中，症状是 **SKIP 而非报错**，
极易误判成「判据功效不足」。

【血泪·行尾】先探测再写：`world_map.gd` 等是纯 LF、`city_scene.gd` 是纯 CRLF，
两者混用会让锚点失配。

【血泪·反向验证不得污染被测判据的输入】本注入脚本自己会被判据的
「全工程 .py 扫描」看到，所以脚本里**不能留被注入对象的完整名字字面量**，
一律用运行时拼接（"_build_market_" + "mall"）。
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
VERIFY = os.path.join(HERE, "_verify_round76.py")

WM = os.path.join(HERE, "scripts", "world", "world_map.gd")
EM = os.path.join(HERE, "scripts", "world", "encounter_manager.gd")
CM = os.path.join(HERE, "scripts", "world", "city_marker_art.gd")
SR = os.path.join(HERE, "scripts", "autoload", "scene_router.gd")
MW = os.path.join(HERE, "scripts", "ui", "main_menu_wheel.gd")
EP = os.path.join(HERE, "scripts", "ui", "economy_panel.gd")
CITY = os.path.join(HERE, "scripts", "city", "city_scene.gd")

# 后缀须在 .gitignore 内（MEMORY：不删除，只改名）
BAK = ".rvbak76"


def read_bytes(p):
    with open(p, "rb") as f:
        return f.read()


def write_bytes(p, b):
    with open(p, "wb") as f:
        f.write(b)


def detect_nl(b):
    crlf = b.count(b"\r\n")
    lf = b.count(b"\n")
    return b"\r\n" if crlf == lf and crlf > 0 else b"\n"


def inject(path, old, new, tag):
    """按 bytes 锚点注入。锚点必须**单行最小唯一**且 count==1。"""
    b = read_bytes(path)
    nl = detect_nl(b)
    old_b = old.encode("utf-8") if isinstance(old, str) else old
    new_b = new.encode("utf-8") if isinstance(new, str) else new
    cnt = b.count(old_b)
    if cnt != 1:
        print("    [SKIP] %s 锚点命中 %d 次（要求恰好 1）" % (tag, cnt))
        return False
    write_bytes(path, b.replace(old_b, new_b))
    return True


def run_verify():
    r = subprocess.run([PY, VERIFY], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", cwd=HERE)
    return r.returncode, r.stdout or ""


CASES = []


def case(name, target):
    def deco(fn):
        CASES.append((name, target, fn))
        return fn
    return deco


# ------------------------------------------------------------------
# 9 处注入
# ------------------------------------------------------------------

@case("I1 删轮盘商城表项（点了没反应 / 无入口）", MW)
def _i1():
    return inject(MW, '"action": "mall",', '"action": "XXXX",', "I1")


@case("I2 删轮盘 mall 分派分支", WM)
def _i2():
    return inject(WM, '\t\t"mall":', '\t\t"xxxx":', "I2")


@case("I3 城池倾斜上限改回 14°（= 角色，歪城回来了）", CM)
def _i3():
    return inject(CM, "const CITY_MAX_TILT_DEG := 2.5",
                  "const CITY_MAX_TILT_DEG := 14.0", "I3")


@case("I4 角色倾斜一并降到 2.5°（矫枉过正：人站不住）", WM)
def _i4():
    return inject(WM, "const MAX_TILT_DEG := 14.0",
                  "const MAX_TILT_DEG := 2.5", "I4")


@case("I5 城名改回挂 marker（不跟随抬升 = 用户原症状）", WM)
def _i5():
    return inject(WM, "art_host.add_child(label)", "marker.add_child(label)", "I5")


@case("I6 prewarm 挪到渐黑之后（黑屏等待回到原样）", SR)
def _i6():
    # 【锚点两次修正·血泪】
    # ① 首版锚 `\t*prewarm(scene_key)` 想跨行换位，但 prewarm 与渐黑之间**有空行**，
    #    `$` 只匹配行尾 ⇒ 位置没动，注入等于没做。
    # ② 二次修正锚「# 渐黑」注释 —— **也错**：那段注释在 tween **之上**，
    #    插进去仍落在渐黑之前，语义没变。手工复现时判据报绿，
    #    说明这次是**注入无效**而非判据功效不足。
    # 正解：锚**渐黑 tween 语句本身**，把 prewarm 插到它**之后**那一行。
    # 判据同时新增了「prewarm 与渐黑之间不得有 await」这条，
    # 正是为了让这类"挪错了但看起来挪了"的注入也能被抓。
    b = read_bytes(SR).decode("utf-8")
    nl = detect_nl(read_bytes(SR)).decode("ascii")
    m = re.search(r"^([ \t]*)prewarm\(scene_key\)\s*$", b, re.M)
    if not m:
        print("    [SKIP] I6 找不到 prewarm 调用行")
        return False
    ind = m.group(1)
    b2 = b[:m.start()] + ind + "var _moved := 0" + b[m.end():]
    anchor = nl + ind + "tween.tween_property(_overlay, " + \
        '"color:a", 1.0, fade_time)'
    if b2.count(anchor) != 1:
        print("    [SKIP] I6 渐黑 tween 锚点命中 %d 次" % b2.count(anchor))
        return False
    b2 = b2.replace(anchor, anchor + nl + ind + "await _moved" + nl
                    + ind + "prewarm(scene_key)")
    write_bytes(SR, b2.encode("utf-8"))
    return True


@case("I7 撒点不再避让玩家（战斗接连触发第一来源）", EM)
def _i7():
    # 【锚点修正·血泪】首版按 4 个 tab 缩进写锚点，实际是 3 个 ⇒ 命中 0 次。
    # 症状是 SKIP 而非报错。改锚**单行**（续行不写进锚点）。
    return inject(EM,
                  "if _player != null and is_instance_valid(_player) \\",
                  "if false and _player != null \\", "I7")


@case("I8 战斗类不累加 _def_resolved（配额对 battle 完全失效）", EM)
def _i8():
    b = read_bytes(EM)
    nl = detect_nl(b)
    old = (b"var def_id0 := str(def.get(\"id\", \"\"))" + nl
           + b"\t\t\tif not def_id0.is_empty():" + nl
           + b"\t\t\t\t_def_resolved[def_id0] = int(_def_resolved.get(def_id0, 0)) + 1")
    return inject(EM, old, b"var def_id0 := \"\"", "I8")


@case("I9 战后落点不再推离触发点（原地复活死循环）", WM)
def _i9():
    # 【锚点修正·血泪】首版注入改的是 `var safe :=` 的**变量名**，
    # 而判据盯的是「有没有调 _encounter_world_pos」——
    # 变量改名不影响那个调用 ⇒ 注入后校验仍绿。教训：**注入点必须落在
    # 判据真正检查的那条语句上**，而不是「同一段里的另一行」。
    # 正确注入：把落点推离的**唯一真源调用**换成恒等返回。
    return inject(WM,
                  "var enc_pos := _encounter_world_pos(encounter)",
                  "var enc_pos := Vector2.ZERO", "I9")


# ------------------------------------------------------------------
def main() -> int:
    # 基线：未注入时必须全绿，否则后续判定无意义
    rc, out = run_verify()
    if rc != 0:
        print("[FATAL] 基线就不绿，反向验证无意义：")
        print(out)
        return 2
    print("[基线] 未注入时校验全绿 —— 反向验证有效")

    backups = {}
    passed = 0
    skipped = 0
    for name, target, fn in CASES:
        if not os.path.exists(target + BAK):
            shutil.copy2(target, target + BAK)
            backups[target] = True
        ok = fn()
        if not ok:
            print("  [SKIP] %s" % name)
            skipped += 1
            # 还原
            shutil.copy2(target + BAK, target)
            continue
        rc, out = run_verify()
        # 还原（先还原再判定，避免下一个 case 建在坏版本上）
        shutil.copy2(target + BAK, target)
        if rc != 0:
            passed += 1
            # 提取第一条 FAIL 作为证据
            fails = [l.strip() for l in out.split("\n") if "[FAIL]" in l]
            print("  [PASS] %s" % name)
            if fails:
                print("         ↳ %s" % fails[0][:110])
        else:
            print("  [!!!!] %s —— 注入后校验仍报绿（判据功效不足！）" % name)

    # 全部还原后必须恢复全绿
    rc, out = run_verify()
    restored = (rc == 0)
    print("-" * 60)
    print("注入 %d 项：捕获 %d，SKIP %d" % (len(CASES), passed, skipped))
    print("还原后校验：%s" % ("全绿 OK" if restored else "仍报红（还原失败！）"))
    if not restored:
        print(out)
    for t in list(backups):
        try:
            os.remove(t + BAK)
        except OSError:
            pass
    return 0 if (passed == len(CASES) and restored and skipped == 0) else 1


if __name__ == "__main__":
    sys.exit(main())

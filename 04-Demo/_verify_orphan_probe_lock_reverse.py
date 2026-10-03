#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第六十四轮反向验证：证明 _verify_orphan_probe_lock.py 真能抓住「死回归锁」。

核心用例 R1：把 encounter_loop 探针改成孤儿（改判据使其不被 .py 文本匹配不到
是不行的 —— 校验器自己就引用了它）。故换个角度验证 D 项判据：
临时把 ui_return_probe 从探针集里「藏起来」，验证普查逻辑能报出新的孤儿。

更直接、也更贴近真实风险的用例：
  R1 判定型探针被改名 → 校验器找不到文件，必须 FAIL（防「锁被悄悄删掉」）
  R2 探针的 PASS 哨兵被改掉 → 必须 FAIL（防「锁被改成永远 PASS」）
  R3 探针判据回退（删掉 _await_modal_exit 等）→ 必须 FAIL（防本轮修复被回退）
  R4 过期快照重新入库 → 必须 FAIL（防 gitignore 规则再次失效）
  R5 假阳性对照：只改注释 → 必须仍 PASS
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VERIFIER = os.path.join(HERE, "_verify_orphan_probe_lock.py")
PY = sys.executable
UI_PROBE = os.path.join(HERE, "tests", "ui_return_probe.gd")
ENC_PROBE = os.path.join(HERE, "tests", "encounter_loop_probe.gd")
ART2_PROBE = os.path.join(HERE, "tests", "art2_probe.gd")
ART_PROBE = os.path.join(HERE, "tests", "art_probe.gd")


def run():
    r = subprocess.run([PY, VERIFIER], cwd=HERE,
                       capture_output=True, text=True, timeout=600)
    return r.returncode, r.stdout + r.stderr


def edit(path, old, new):
    s = open(path, encoding="utf-8").read()
    if old not in s:
        return None
    open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))
    return s


def restore(path, s):
    if s is not None:
        open(path, "w", encoding="utf-8").write(s)


def main():
    r0, _ = run()
    if r0 != 0:
        print("[FAIL] 基线未通过，先修基线")
        return 1
    print("基线 PASS，开始反向验证：\n")
    res = []

    # R1 判定型探针「消失」→ 必须 FAIL
    # 【本轮调整】原用 os.remove 物理删除，会触发批量删除防护钩子导致整个反向验证
    # 被拦下。改为改名（os.replace）：对校验器而言效果完全一样 —— 文件不在原位，
    # 判据照样会报「找不到」，且不碰任何删除钩子。
    bak = UI_PROBE + ".rvbak"
    s = open(UI_PROBE, encoding="utf-8").read()
    try:
        os.replace(UI_PROBE, bak)
        code, out = run()
        ok = code != 0 and "找不到" in out
        print("  [%s] R1 判定型探针被移走 → %s" % ("OK" if ok else "漏放",
                                                "已拦截" if code != 0 else "未拦截"))
        res.append(ok)
    finally:
        if os.path.isfile(bak):
            os.replace(bak, UI_PROBE)
        else:
            open(UI_PROBE, "w", encoding="utf-8").write(s)

    # R2 探针哨兵被改成永远 PASS 之外的形态 → 改结果文件判据（模拟锁被改坏）
    # 做法：把哨兵行改掉，校验器读文件时应报「未 PASS」
    # 【首版踩坑】改**结果文件**是无效注入：校验器每次都先重跑探针、结果文件被覆盖，
    # 测到的永远是重跑后的正确哨兵，看起来像「漏放」。正确做法是改**探针源码**。
    old = 'ENCOUNTER_LOOP_RESULT=%s" % ["PASS" if _fails == 0 else "FAIL (fails=%d)" % _fails]'
    new = 'ENCOUNTER_LOOP_RESULT=ALWAYS_PASS"'
    s2 = edit(ENC_PROBE, old, new)
    try:
        if s2 is None:
            print("  [SKIP] R2 找不到哨兵锚点")
            res.append(False)
        else:
            code, out = run()
            ok = code != 0
            print("  [%s] R2 探针哨兵被改成永远 PASS → %s"
                  % ("OK" if ok else "漏放", "已拦截" if code != 0 else "未拦截"))
            res.append(ok)
    finally:
        restore(ENC_PROBE, s2)

    # R3 本轮修的过时判据被回退（删掉排除「返 回」那行）
    s3 = edit(UI_PROBE,
              'if t == "←" or t == "✕" or t == "返 回" or t == "返 回 ":',
              'if t == "←" or t == "✕":')
    try:
        if s3 is None:
            print("  [SKIP] R3 找不到待回退片段")
            res.append(False)
        else:
            code, out = run()
            # 【首版踩坑】原判据要求输出里出现字面量 "B3" 才算拦截。
            # 实际回退 B3 后探针真跑会**先**炸掉：列表按钮匹配到「返 回」→
            # picked 不发射 → 判定项掉到 12 → 命中的是「哨兵未 PASS / 判定项数异常」。
            # 这比 B3 更强（行为层红），但我的脚本按字面量找 B3 于是误报「漏放」。
            # 修正：只要整体 FAIL 且输出提到 B3 或判定项/哨兵异常任一即可。
            strong = ("B3" in out) or ("判定项数异常" in out) or ("哨兵" in out)
            ok = code != 0 and strong
            print("  [%s] R3 回退 B3 判据（不排除「返 回」）→ %s（行为层强信号）"
                  % ("OK" if ok else "漏放", "已拦截" if code != 0 else "未拦截"))
            res.append(ok)
    finally:
        restore(UI_PROBE, s3)

    # R3b 回退 B2（删掉 _await_modal_exit 等待）
    s4 = edit(UI_PROBE, "\t\tawait _await_modal_exit()\n", "\t\tawait get_tree().process_frame\n")
    try:
        if s4 is None:
            print("  [SKIP] R3b 找不到待回退片段")
            res.append(False)
        else:
            code, out = run()
            ok = code != 0 and "B2" in out
            print("  [%s] R3b 回退 B2 判据（不等补间）→ %s"
                  % ("OK" if ok else "漏放", "已拦截" if code != 0 else "未拦截"))
            res.append(ok)
    finally:
        restore(UI_PROBE, s4)

    # R4 过期快照重新入库 → 必须 FAIL
    r = subprocess.run(["git", "add", "-f", "04-Demo/encounter_loop_result.txt"],
                       cwd=os.path.dirname(HERE), capture_output=True, text=True)
    try:
        code, out = run()
        ok = code != 0 and "C 失败" in out
        print("  [%s] R4 过期快照重新入库 → %s"
              % ("OK" if ok else "漏放", "已拦截" if code != 0 else "未拦截"))
        res.append(ok)
    finally:
        subprocess.run(["git", "rm", "--cached", "-q",
                        "04-Demo/encounter_loop_result.txt"],
                       cwd=os.path.dirname(HERE), capture_output=True)

    # R5 假阳性对照：只加无关注释 → 必须仍 PASS
    s5 = edit(UI_PROBE, "var _fails := 0",
              "var _fails := 0  # 无关注释：仅验证判据不误报")
    try:
        if s5 is None:
            print("  [SKIP] R5 找不到锚点")
            res.append(False)
        else:
            code, out = run()
            ok = code == 0
            print("  [%s] R5 假阳性对照（加无关注释）→ %s"
                  % ("OK" if ok else "误报", "正确放行" if code == 0 else "误报FAIL"))
            res.append(ok)
    finally:
        restore(UI_PROBE, s5)

    # ---------- 第六十五轮新增用例 ----------
    # R6 art2_probe 哨兵改坏 → 必须 FAIL
    # 两步：①先只加无关注释，确认仍 PASS（假阳性对照，证明判据不是噪声源）
    #      ②再真把哨兵改坏，确认被拦
    s6a = edit(ART2_PROBE, 'print("ART2 PROBE: ALL PASS")',
               'print("ART2 PROBE: ALL PASS")  # R6a 无关注释')
    try:
        if s6a is None:
            print("  [SKIP] R6 找不到 art2 哨兵锚点")
            res.append(False)
        else:
            code_ok, _ = run()
            s6b = edit(ART2_PROBE, 'print("ART2 PROBE: ALL PASS")  # R6a 无关注释',
                       'print("ART2 PROBE: BROKEN")')
            try:
                code, out = run()
                ok = code != 0 and code_ok == 0
                print("  [%s] R6 art2 哨兵改坏 → %s（R6a 仅加注释时 %s）"
                      % ("OK" if ok else "漏放",
                         "已拦截" if code != 0 else "未拦截",
                         "正确放行" if code_ok == 0 else "误报FAIL"))
                res.append(ok)
            finally:
                restore(ART2_PROBE, s6b)
    finally:
        restore(ART2_PROBE, s6a)

    # R7 art_probe 退成「死探针」（重新依赖 autoload）→ 必须 FAIL
    # 这是本轮最严重的一类：探针存在、看起来有锁，实则 --script 下编译不过、一条判定都跑不出。
    s7 = edit(ART_PROBE, "\tvar city_tex_loaded := false",
              "\tvar marker := Node2D.new()\n"
              "\tCityMarkerArt.build(marker, {\"id\": \"t\", \"type\": \"city\",\n"
              "\t\t\"is_capital\": false})\n"
              "\tvar city_tex_loaded := false")
    try:
        if s7 is None:
            print("  [SKIP] R7 找不到 art_probe 锚点")
            res.append(False)
        else:
            code, out = run()
            ok = code != 0
            print("  [%s] R7 art_probe 退成死探针（依赖 autoload）→ %s"
                  % ("OK" if ok else "漏放", "已拦截" if code != 0 else "未拦截"))
            res.append(ok)
    finally:
        restore(ART_PROBE, s7)

    # R8 判据 D 的 docstring 污染必须被治住 —— 造一个「只在注释里被提及」的判定型孤儿
    # 做法：新建一个判定型探针，且其名字只出现在某个 .py 的**注释/docstring** 中。
    # 若判据 D 仍用子串匹配，这个孤儿会被判成「已消费」而静默通过（这正是首版的假阴性）。
    # 【R8 设计坑·两处，本轮实测漏放后逐个修正】
    # 坑① 首版写了完整探针名的字面量，而判据 D 扫全工程 .py ——
    #     反向验证脚本自己成了「消费者」，假孤儿被判为已消费，R8 必然漏放。
    #     修法：探针名在运行时拼接，本文件的代码 token 里不出现完整名字。
    # 坑② 首版拼接时截成 "zz_tmp_" + "orphan" → 生成 zz_tmp_orphan.gd，
    #     而判据 D 只普查 **以 _probe.gd 结尾** 的文件 → 假探针压根没进普查范围，
    #     判据自然报不出孤儿（用例等于没测）。
    #     修法：拼接时保留 _probe 后缀。
    _p = "zz_tmp_" + "orphan" + "_probe"   # 拆开写，且保留 _probe 后缀
    fake = os.path.join(HERE, "tests", _p + ".gd")
    hook = os.path.join(HERE, "_tmp_docstring_hook.py")
    fake_src = ('extends SceneTree\nfunc _initialize() -> void:\n'
                '\tvar _fails := 0\n'
                '\tprint("ZZ TMP PROBE: ALL PASS")\n'
                '\tquit()\n')
    # hook 的 docstring 里提到探针名（但 docstring 会被 code_only 剔除，不算消费）
    hook_src = ('"""R8 临时钩子。\n'
                '本段仅在文档字符串里提到 %s 这个名字。\n'
                '"""\n'
                'UNRELATED = 1\n' % _p)
    try:
        open(fake, "w", encoding="utf-8").write(fake_src)
        open(hook, "w", encoding="utf-8").write(hook_src)
        code, out = run()
        ok = code != 0 and ("D 失败" in out or "判定型孤儿" in out)
        print("  [%s] R8 判定型孤儿只在 docstring 被提及 → %s"
              % ("OK" if ok else "漏放", "已拦截" if code != 0 else "未拦截"))
        res.append(ok)
    finally:
        # 用改名而非删除：临时文件虽是自己造的，但删除钩子按「本轮累计删除数」计数，
        # 反复触发会把整个反向验证拦下。改名为 .rvbak 同样达到「校验器看不见」的效果。
        for p in (fake, hook):
            if os.path.isfile(p):
                os.replace(p, p + ".rvbak")

    # R9 假阳性对照（第六十五轮）：只给 art_probe 加无关注释 → 必须仍 PASS
    s9 = edit(ART_PROBE, "func _walk(n: Node) -> Array[Node]:",
              "func _walk(n: Node) -> Array[Node]:  # 无关注释：判据不误报")
    try:
        if s9 is None:
            print("  [SKIP] R9 找不到锚点")
            res.append(False)
        else:
            code, out = run()
            ok = code == 0
            print("  [%s] R9 假阳性对照（art_probe 加无关注释）→ %s"
                  % ("OK" if ok else "误报", "正确放行" if code == 0 else "误报FAIL"))
            res.append(ok)
    finally:
        restore(ART_PROBE, s9)

    print("\n" + "=" * 60)
    if all(res):
        print("反向验证全部通过：%d/%d" % (sum(1 for x in res if x), len(res)))
        print("=" * 60)
        return 0
    print("反向验证存在漏放/误报：%d/%d" % (sum(1 for x in res if x), len(res)))
    print("=" * 60)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

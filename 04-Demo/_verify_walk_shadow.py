#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第五十九轮校验：WalkAnim 影子联动 —— 站定不得无意义抖动

背景
----
`walk_anim.gd` 的影子联动用**合成后的** `bob_offset` 算抬脚量：

    var lift_k := clampf(-bob_offset / maxf(bob_amp, 0.01), 0.0, 1.0)

而 `bob_offset = bob + idle`，其中
    bob  = -absf(sin(bob_phase)) * bob_amp * lerpf(0.6,1.25,ratio) * move_k
    idle = sin(_idle_t) * idle_amp * (1.0 - move_k)

`move_k` 站定时为 0 → bob 贡献为 0，但**idle 项按 (1-move_k) 保留满额**。
于是完全站定时 `lift_k` 仍随呼吸周期在 0 ~ idle_amp/bob_amp 之间变化，
影子持续做无意义的缩小/变淡 —— 玩家看到的现象是「角色站着一动不动，
脚下的影子却在缓慢呼吸」。

实测（headless 真跑，站定 120 帧）：
  原版scale 波动 0.0204（= 0.8/9.8 × 0.25，理论值零误差）
  原版   alpha 波动 0.00629（= 0.8/9.8 × 0.35）
  行走时 scale 波动 0.2475（联动正常，不能被修成「影子永不动」）

修复：抬脚量改用**纯 bob 分量**（bob 本身已含 move_k 与速度系数），
并在 `move_k <= 0` 时整体跳过写入 —— 站定既不抖动，也省掉每帧属性通知。

本校验分两层：
  【headless 真跑】（tests/walk_shadow_probe.gd + .tscn，真实 Godot 引擎）
    A 站定120 帧影子 scale/alpha 波动必须为 0
    B 行走 90 帧影子必须有可见起伏（防矫枉过正成「影子不动」）
    C idle_amp < bob_amp 量级自检
  【独立锚定上游源码】（本文件，防探针与被测代码同改而互相放过）
    G1 lift_k 必须基于 bob（纯踏步项），不得用 bob_offset
    G2 必须有 move_k 门控（站定跳过写入）
    G3 idle_amp 与 bob_amp 仍并存（呼吸本身不能被删掉——它驱动本体上下浮动）
    G4 影子写盘仍在 _process 内且分支完整
"""
import os
import re
import subprocess
import sys
import _safe_cleanup

HERE = os.path.dirname(os.path.abspath(__file__))
WALK = os.path.join(HERE, "scripts", "world", "walk_anim.gd")
PROBE_TSCN = os.path.join(HERE, "tests", "walk_shadow_probe.tscn")
RESULT = os.path.join(HERE, "walk_shadow_result.txt")
GODOT = r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe"

FAILS = []
CNT = [0]


def check(cond, msg):
    CNT[0] += 1
    if not cond:
        FAILS.append(msg)


def read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def strip_comments(src):
    out = []
    for line in src.split("\n"):
        s = line.lstrip()
        if s.startswith("#"):
            out.append("")
            continue
        i = line.find("#")
        out.append(line[:i] if i >= 0 else line)
    return "\n".join(out)


def func_body(src, name):
    """提取函数体：先按括号配平吃掉完整签名（**可跨行**），再按缩进定界取体。

    【参数两种历史形态都要支持】（本轮统一时踩过：只认裸名会让 9 个
     用「完整签名片段」调用的校验器集体返回 None → 假红）
      · 裸名：      "_process"
      · 带 func 前缀："func add_legs("
      · 带参数字面： "func _process(delta"
    统一规约为：去掉 "func " 前缀 → 取首个 "(" 之前的部分 → 即函数名。

    【血泪·五次踩坑的最终形态，勿再简化】
      1) 只按 {}/} 配对 → 遇 `var x: Dictionary = {}` 立刻 depth 归零 → 体被截成几十字符
      2) 加字符串跳过后被单引号 'Hint' 搞乱状态
      3) 正则只写 ^func → 匹配不到 `static func` → 判据集体假红
      4) 按「第一个换行」当签名结束 → 截到的是签名续行（缩进更深）→ 真体缩进更小 → 立即 break
      5) **基线缩进取错行**：拿「签名后第一行代码」当基线，而该行通常是 `if`（1 tab），
         体里同级的 `if`/`var`（也是 1 tab）会被判成「函数结束」→ 体被截断 → 判据假红。
         正解：基线 = **函数签名行自身的缩进**（顶层函数恒为 0）。
    """
    fname = name.strip()
    if fname.startswith("func "):
        fname = fname[5:]
    fname = fname.split("(")[0].strip()
    if not fname:
        return None
    m = re.search(r"^(?:static\s+)?func\s+%s\s*\(" % re.escape(fname), src, re.M)
    if not m:
        return None
    i = src.find("(", m.start())
    depth = 0
    j = i
    while j < len(src):
        if src[j] == "(":
            depth += 1
        elif src[j] == ")":
            depth -= 1
            if depth == 0:
                break
        j += 1
    sig_line_start = src.rfind("\n", 0, m.start()) + 1
    head = src[sig_line_start:m.start()]
    baseline = len(head) - len(head.lstrip("\t"))
    k = src.find("\n", j)
    lines = src[k + 1:].split("\n")
    out = []
    for ln in lines:
        s = ln.strip()
        if s == "":
            out.append(ln)
            continue
        ind = len(ln) - len(ln.lstrip("\t"))
        if ind <= baseline:
            break
        out.append(ln)
    return "\n".join(out)

def main():
    for p in (WALK, PROBE_TSCN):
        if not os.path.isfile(p):
            print("[FAIL] 找不到 %s" % p)
            return 1

    raw = read(WALK)
    code = strip_comments(raw)

    # ================= headless 真跑 =================
    if os.path.isfile(RESULT):
        _safe_cleanup.discard(RESULT)
    try:
        subprocess.run(
            [GODOT, "--headless", "--path", ".", "tests/walk_shadow_probe.tscn"],
            cwd=HERE, capture_output=True, text=True, timeout=300,
        )
    except subprocess.TimeoutExpired:
        FAILS.append("headless 探针超时 —— 很可能探针里漏了 get_tree().quit()"
                     "或协程调用处漏写 await（Parse Error 会让脚本加载失败、"
                     "场景空跑、进程不退出）")
    except FileNotFoundError:
        FAILS.append("找不到 Godot 可执行文件: " + GODOT)

    rlines = []
    if os.path.isfile(RESULT):
        rlines = read(RESULT).splitlines()
    check(bool(rlines), "headless 探针未产出结果文件 —— 引擎可能报 SCRIPT ERROR")

    if rlines:
        check(
            not any(ln.strip() == "WALK_SHADOW_FAIL" for ln in rlines),
            "headless 探针判定 FAIL：\n    " + "\n    ".join(
                ln.strip() for ln in rlines if ln.strip().startswith("[")),
        )
        for tag in ("A_IDLE_SHADOW_STILL", "B_WALK_SHADOW_MOVES", "C_AMPLITUDE_ORDER"):
            val = ""
            for ln in rlines:
                if ln.startswith(tag + "="):
                    val = ln.split("=", 1)[1].strip()
            check(val == "OK", "headless 判定 %s 未通过（实际=%r）" % (tag, val))

        # 量化取证：把关键数字抓出来，供人工核对（不是判据，仅留证）
        for ln in rlines:
            if ln.startswith("A_DETAIL") or ln.startswith("B_DETAIL"):
                print("    [取证] " + ln.strip())

    check(
        len(raw) > 5000,
        "锚定层失效：探针读到的源码长度异常小，可能未真正锚定 walk_anim.gd",
    )

    # ================= G1–G4 独立锚定上游源码 =================
    proc = func_body(code, "_process")
    check(bool(proc), "G1 前置：找不到 _process")
    if proc:
        # G1：lift_k 必须基于纯 bob，不得用 bob_offset
        m = re.search(r"var\s+lift_k\s*:=\s*clampf\(\s*([^,]+),", proc)
        check(
            m is not None,
            "G1 前置：找不到 lift_k 赋值语句 —— 影子联动可能被改写或删除",
        )
        if m:
            expr = m.group(1).strip()
            check(
                "bob" in expr and "bob_offset" not in expr,
                "G1 失败：抬脚量仍用合成后的 bob_offset（实际=%r）—— "
                "它含站定仍生效的 idle 呼吸项，会让影子在完全站定时持续"
                "缩小变淡。必须改用纯 bob 分量（bob 本身已含 move_k）。" % expr,
            )

        # G2：必须有 move_k 门控
        check(
            re.search(r"move_k\s*>\s*0", proc) is not None,
            "G2 失败：影子联动没有 move_k 门控 —— 站定（move_k=0）时仍会每帧"
            "写入影子属性，既抖动又白白触发属性通知。",
        )

        # G4：影子写盘仍在 _process 内，且 scale 与 alpha 两行都在
        # 【必须用赋值正则，不能用 `in` 子串】——"shadow_node.modulate.a" 这个
        # 串在 _process 里会出现多次（赋值 + 其它引用），子串匹配在「删掉
        # 其中一行」的退化下仍会命中 → 假绿灯（已实测漏网）。
        check(
            re.search(r"shadow_node\.scale\s*=", proc) is not None
            and re.search(r"shadow_node\.modulate\.a\s*=", proc) is not None,
            "G4 失败：影子联动缺 scale 或 alpha 的**赋值** —— 只改一半会出现"
            "「影子只缩不变淡」的半联动。（判据须锚定 `=`，不能用子串 in）",
        )

    # G3：站定呼吸项必须仍在参与合成（呼吸本身要保留，它驱动本体上下浮动）
    # 【必须锚定「idle 参与 bob_offset 合成」这一语义，不能只判`var idle` 存在】
    # ——退化 L5 正是把 idle 赋 0 而保留声明，子串判据会放行。
    check(
        re.search(r"bob_offset\s*=\s*bob\s*\+\s*idle\b", proc) is not None,
        "G3 失败：_process 里找不到 `bob_offset = bob + idle` —— 站定呼吸项"
        "被剔除或改名，角色会从『站着微微起伏』变成『完全僵死」。"
        "（不能只判 idle 声明存在：把 idle 赋 0 也能骗过声明判据）",
    )
    # 且 idle 必须真的由 idle_amp 与 (1-move_k) 加权（而非恒 0）
    m_idle = re.search(r"var\s+idle\s*:=\s*([^=]+)=", proc)
    check(
        m_idle is not None,
        "G3 失败：找不到 idle 的定义语句",
    )
    if m_idle:
        iexpr = m_idle.group(1).strip()
        check(
            "idle_amp" in iexpr and "move_k" in iexpr,
            "G3 失败：idle 的定义（实际=%r）里必须同时含idle_amp 与 move_k "
            "权重——说明站定呼吸确实是「按速度淡出」而非被写死。" % iexpr,
        )
    for field in ("var idle_amp", "var bob_amp"):
        check(
            re.search(rf"@export\s+{re.escape(field)}", raw) is not None,
            "G3 失败：%s 导出属性不见了 —— 挂载点（npc_manager/city_scene/"
            "battle_scene/player_controller）全都在覆写它。" % field,
    )

    # ================= 汇总 =================
    print("=" * 68)
    print("第五十九轮 WalkAnim 影子联动 · 校验")
    print("=" * 68)
    print("  目标文件：scripts\\world\\walk_anim.gd")
    print("  判定项：%d" % CNT[0])
    if FAILS:
        print("  结果：FAIL（%d 项）" % len(FAILS))
        print("-" * 68)
        for m in FAILS:
            print("  [FAIL] " + m)
        return 1
    print("  结果：PASS（0 FAIL）")
    print("-" * 68)
    print("  [headless 真跑]")
    print("    A 站定 120 帧影子 scale/alpha 波动 = 0 ✓")
    print("    B 行走 90 帧影子有可见起伏（联动未被矫枉过正）✓")
    print("    C idle_amp < bob_amp 量级自检 ✓")
    print("  [独立锚定上游源码]")
    print("    G1 抬脚量基于纯 bob，不得用 bob_offset ✓")
    print("    G2 有 move_k 门控（站定跳过写入）✓")
    print("    G3 idle_amp/bob_amp 导出属性与 idle 项均保留 ✓")
    print("    G4 影子 scale 与 alpha 两行都在 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())

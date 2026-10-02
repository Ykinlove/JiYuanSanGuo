#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第六十轮校验：小地图重绘节流（静止省帧 + 移动跟手）

背景
----
`minimap.update_view()` 每帧被 `world_map._process` 调用，原先**无条件**
`queue_redraw()`。而 `_draw()` 要遍历 **110 城全表**（局部模式下窗口内
其实只有 0 座，仍全表扫一遍做剔除）+ 地貌纹理 + 边框 + 标题。

真正逐帧变化的只有 `_draw_player` 里那个半径约 8px 的呼吸光晕
`sin(t * 3.0)` —— 为它每帧重画 110 城不划算。

改造：光晕脉动节流到 `PULSE_FPS`(12fps，柔和渐变视觉上依旧连贯)，
其余任何真实变化（玩家位置/朝向/相机视野/几何输入）**立即重绘、零延迟**。

**这类改造最危险的失败模式是「省帧省到手感也没了」**：
玩家移动时若被节流吞帧，小地图就会拖影、滞后。编译期完全无感。

**第二个危险点（有副作用的函数被复用）**：`_static_geometry_dirty()`
判脏时**会写快照**。若 `_redraw_needed()` 调它来判几何变化，则
`update_view` 里的判脏将永远为 false —— 第五十八轮做的几何脏标记被
**静默架空**。故 `_redraw_needed` 必须用独立的只读比较。

本校验分两层：
  【headless 真跑】（tests/minimap_throttle_probe.gd + .tscn）
    A 玩家位置变 → 同帧必须重绘（节流不得引入滞后）
    B 玩家朝向变 → 同帧必须重绘
    C 几何输入变（_zoom）→ 同帧必须重绘
    D 静止 60 帧重绘次数 ≤30 且 ≥3（节流生效、但呼吸没被冻住）
    E 移动 60 帧重绘 ≥48 次（不得吞移动帧）
  【独立锚定上游源码】（本文件，防探针与被测代码同改而互相放过）
    H1 update_view 的 queue_redraw 必须受 _redraw_needed 保护
    H2 _redraw_needed 不得调用 _static_geometry_dirty（副作用）
    H3 _consume_redraw_state 必须写全三类状态（玩家/几何/光晕时钟）
    H4 节流常量存在且 >0
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MINIMAP = os.path.join(HERE, "scripts", "ui", "minimap.gd")
PROBE_TSCN = os.path.join(HERE, "tests", "minimap_throttle_probe.tscn")
RESULT = os.path.join(HERE, "minimap_throttle_result.txt")
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


def func_body(code, name):
    m = re.search(rf"^func {re.escape(name)}\s*\(", code, re.M)
    if not m:
        return ""
    start = m.start()
    nxt = re.search(r"^func ", code[m.end():], re.M)
    end = m.end() + nxt.start() if nxt else len(code)
    return code[start:end]


def main():
    for p in (MINIMAP, PROBE_TSCN):
        if not os.path.isfile(p):
            print("[FAIL] 找不到 %s" % p)
            return 1

    raw = read(MINIMAP)
    code = strip_comments(raw)

    # ================= headless 真跑 =================
    if os.path.isfile(RESULT):
        os.remove(RESULT)
    try:
        subprocess.run(
            [GODOT, "--headless", "--path", ".", "tests/minimap_throttle_probe.tscn"],
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
            not any(ln.strip() == "MINIMAP_THROTTLE_FAIL" for ln in rlines),
            "headless 探针判定 FAIL：\n    " + "\n    ".join(
                ln.strip() for ln in rlines if ln.strip().startswith("[")),
        )
        for tag in ("A_MOVE_IMMEDIATE", "B_FACING_IMMEDIATE", "C_GEOM_IMMEDIATE",
                    "D_IDLE_THROTTLED", "E_MOVE_NOT_THROTTLED"):
            val = ""
            for ln in rlines:
                if ln.startswith(tag + "="):
                    val = ln.split("=", 1)[1].strip()
            check(val == "true", "headless 判定 %s 未通过（实际=%r）" % (tag, val))
        # 取证行（仅留证，不是判据）
        for ln in rlines:
            if ln.startswith("D_DETAIL") or ln.startswith("E_DETAIL"):
                print("    [取证] " + ln.strip())

    check(
        len(raw) > 10000,
        "锚定层失效：探针读到的源码长度异常小，可能未真正锚定 minimap.gd",
    )

    # ================= H1–H4 独立锚定上游源码 =================
    uv = func_body(code, "update_view")
    check(bool(uv), "H1 前置：找不到 update_view")
    if uv:
        # H1：queue_redraw 必须受 _redraw_needed 保护
        check(
            "_redraw_needed()" in uv,
            "H1 失败：update_view 未调用 _redraw_needed() —— "
            "仍是每帧无条件 queue_redraw，静止时照样每帧重画 110 城。",
        )
        # 且必须是有条件的：queue_redraw 出现在 if 内
        lines = [ln.strip() for ln in uv.split("\n") if ln.strip()]
        cond_ok = False
        for i, ln in enumerate(lines):
            if "queue_redraw()" in ln:
                for j in range(i - 1, max(-1, i - 3), -1):
                    if lines[j].startswith("if ") and "_redraw_needed" in lines[j]:
                        cond_ok = True
        check(
            cond_ok,
            "H1 失败：update_view 里的 queue_redraw() 不受 _redraw_needed 条件保护"
            " —— 节流形同虚设。",
        )

    # H2：_redraw_needed 不得调用有副作用的 _static_geometry_dirty
    rn = func_body(code, "_redraw_needed")
    check(bool(rn), "H2 前置：找不到 _redraw_needed")
    if rn:
        check(
            "_static_geometry_dirty()" not in rn,
            "H2 失败（会导致几何脏标记被静默架空）：_redraw_needed 里调用了"
            " _static_geometry_dirty() —— 该函数**判脏时会写快照**，调它之后"
            " update_view 里的判脏将永远为 false，第五十八轮的脏标记等于作废。"
            "必须用独立的只读比较。",
        )
        # 必须真的做了「立即重绘」的三类比较
        for field, why in (
            ("_player_pos", "玩家移动（否则小地图滞后/拖影）"),
            ("_player_facing", "朝向箭头（否则停在旧方向）"),
            ("_geom_sig", "几何输入（否则内容与控件不匹配）"),
        ):
            check(
                field in rn,
                "H2 失败：_redraw_needed 未比较 %s（%s）" % (field, why),
            )
        check(
            "PULSE_INTERVAL_MS" in rn,
            "H2 失败：_redraw_needed 里没有光晕节流间隔判定 —— "
            "要么没节流（每帧重画），要么把真实变化也节流了。",
        )

    # H3：_consume_redraw_state 必须写全三类状态
    cs = func_body(code, "_consume_redraw_state")
    check(bool(cs), "H3 前置：找不到 _consume_redraw_state")
    if cs:
        for field in (
            "_last_redraw_pos",
            "_last_redraw_facing",
            "_last_redraw_view",
            "_last_pulse_ms",
        ):
            check(
                re.search(rf"{re.escape(field)}\s*=(?!=)", cs) is not None,
                "H3 失败：_consume_redraw_state 未写 %s —— 该状态会被反复判为"
                "「有变化」，导致每帧都判定需要重绘（节流完全失效）。" % field,
            )
        for field in ("_geom_sig_ctrl", "_geom_sig_zoom"):
            check(
                re.search(rf"{re.escape(field)}\s*=(?!=)", cs) is not None,
                "H3 失败：_consume_redraw_state 未写 %s —— 几何签名不推进，"
                "静止后仍会每帧判「几何变了」。" % field,
            )

    # H4：节流常量存在且为正
    m_fps = re.search(r"const\s+PULSE_FPS\s*:=\s*([0-9.]+)", code)
    check(m_fps is not None, "H4 失败：找不到常量 PULSE_FPS")
    if m_fps:
        try:
            v = float(m_fps.group(1))
            check(0.0 < v <= 60.0, "H4 失败：PULSE_FPS=%r 不在 (0,60] 内" % v)
        except ValueError:
            check(False, "H4 失败：PULSE_FPS 取值无法解析: " + m_fps.group(1))
    check(
        re.search(r"const\s+PULSE_INTERVAL_MS\s*:=", code) is not None,
        "H4 失败：找不到常量 PULSE_INTERVAL_MS",
    )

    # ================= 汇总 =================
    print("=" * 68)
    print("第六十轮 小地图重绘节流 · 校验")
    print("=" * 68)
    print("  目标文件：scripts\\ui\\minimap.gd")
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
    print("    A 玩家位置变 → 同帧立即重绘（无滞后）✓")
    print("    B 玩家朝向变 → 同帧立即重绘 ✓")
    print("    C 几何输入变 → 同帧立即重绘 ✓")
    print("    D 静止 60 帧重绘 ≤30 且 ≥3（省帧且呼吸未被冻住）✓")
    print("    E 移动 60 帧重绘 ≥48 次（跟手，未被节流吞帧）✓")
    print("  [独立锚定上游源码]")
    print("    H1 update_view 的 queue_redraw 受 _redraw_needed 保护✓")
    print("    H2 未复用有副作用的 _static_geometry_dirty（几何脏标记未被架空）✓")
    print("    H3 _consume_redraw_state 写全三类状态 ✓")
    print("    H4 节流常量 PULSE_FPS / PULSE_INTERVAL_MS 有效 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())

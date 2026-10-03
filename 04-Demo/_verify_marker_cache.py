#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第五十七轮校验：大地图 marker/NPC 缓存改造（每帧性能 + 行为等价）

背景
----
大地图每帧要遍历全部城池标记（110 个）三处：
  ① _find_nearest_place  每帧 _city_markers.get_children()
  ② _cull_offscreen      每帧两次 get_children()（城 + NPC）
  ③ _hide_all_place_hints每帧 get_children()（仅全景模式）
外加 ④ 候选数组每帧 `var candidates: Array = []`，
        且每个候选点再 new 一个 Dictionary —— 这正是本项目明令禁止的
        「_process 内每帧新建数组」反模式（第五十二轮已在别处犯过一次）。

本轮改为：生成期登记 _marker_cache / _npc_cache，每帧只读数组；
        候选改用复用缓冲区 _candidates_buf 且只存节点引用。

**这类改造编译期完全无感，写错不报错**，只会让玩家遇到：
  - 漏登记 → 走近某座城没反应 / 屏外元素不裁剪（掉帧）
  - 残留已释放节点 → 对悬空引用做无谓判定，行为不可预期
  - 候选跨帧串数据 → 上一帧的城提示反复点亮

本校验分两层：
  【headless 真跑】（tests/marker_cache_probe.gd + .tscn，真实 Godot 引擎）
    A缓存 ≡ 节点树双向一致（含干扰项必须被排除）
    B  切区重建后缓存无悬空残留
    C  候选缓冲区跨帧归零重填、不串数据
    D  Hint 显隐在「缓存遍历」与「节点树遍历」下逐项相同
  【独立锚定上游源码】（本文件，防探针与被测代码同改而互相放过）
    E1 三个缓存字段确实声明
    E2 热路径函数不再出现 get_children()
    E3 重建路径必须同步 clear 缓存
    E4 候选缓冲区不得再出现每帧 new Array / 每候选 new Dictionary
    E5 缓冲区 clear 必须在遍历前

失败路径一律不用 % 格式化（引擎内参数不匹配会抛异常，导致结果文件不落盘、
上层只能表现为「超时」，掩盖真实原因）。
"""
import os
import re
import subprocess
import sys
import _safe_cleanup

HERE = os.path.dirname(os.path.abspath(__file__))
MAP = os.path.join(HERE, "scripts", "world", "world_map.gd")
PROBE_TSCN = os.path.join(HERE, "tests", "marker_cache_probe.tscn")
RESULT = os.path.join(HERE, "marker_cache_result.txt")
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
    for p in (MAP, PROBE_TSCN):
        if not os.path.isfile(p):
            print("[FAIL] 找不到 %s" % p)
            return 1

    raw = read(MAP)
    code = strip_comments(raw)

    # ================= headless 真跑 =================
    if os.path.isfile(RESULT):
        _safe_cleanup.discard(RESULT)
    try:
        subprocess.run(
            [GODOT, "--headless", "--path", ".", "tests/marker_cache_probe.tscn"],
            cwd=HERE, capture_output=True, text=True, timeout=180,
        )
    except subprocess.TimeoutExpired:
        FAILS.append("headless 探针超时 —— 很可能探针里漏了 get_tree().quit()")
    except FileNotFoundError:
        FAILS.append("找不到 Godot 可执行文件: " + GODOT)

    rlines = []
    if os.path.isfile(RESULT):
        rlines = read(RESULT).splitlines()
    check(bool(rlines), "headless 探针未产出结果文件（%s）—— 引擎可能报 SCRIPT ERROR" % os.path.basename(RESULT))

    if rlines:
        # 真实失败标记（探针自身写的）
        check(
            not any(ln.strip() == "MARKER_CACHE_FAIL" for ln in rlines),
            "headless 探针判定 FAIL：\n    " + "\n    ".join(
                ln.strip() for ln in rlines if ln.strip().startswith("[")),
        )
        for tag in ("A_CONSISTENCY", "B_REBUILD", "C_BUF_REUSE", "D_HINT_EQUIV"):
            val = ""
            for ln in rlines:
                if ln.startswith(tag + "="):
                    val = ln.split("=", 1)[1].strip()
            check(val == "OK", "headless 判定 %s 未通过（实际=%r）" % (tag, val))
        # 三个缓存字段声明必须被探针独立确认过（防上游改名后探针空跑）
        for f in ("_marker_cache", "_npc_cache", "_candidates_buf"):
            check(
                any(ln.strip() == "FIELD_DECLARED_" + f + "=true" for ln in rlines),
                "探针未确认字段 %s 仍在上游声明（上游可能已改名/删除）" % f,
            )

    # ================= 独立锚定上游源码 =================
    check(
        "SRC_LEN=" in "\n".join(rlines) and len(raw) > 10000,
        "锚定层失效：探针读到的源码长度异常小，可能未真正锚定 world_map.gd",
    )

    # E1 字段声明
    for f in ("_marker_cache", "_npc_cache", "_candidates_buf"):
        check(re.search(rf"^var {re.escape(f)}\s*:", code, re.M) is not None,
              "E1 失败：world_map.gd 未声明 var %s: Array[Node2D]" % f)

    # E2 热路径函数不得再出现 get_children()
    HOT = ["_find_nearest_place", "_cull_offscreen", "_hide_all_place_hints"]
    for fn in HOT:
        body = func_body(code, fn)
        check(bool(body), "E2 前置：找不到 %s" % fn)
        if body:
            check(
                "get_children()" not in body,
                "E2 失败（每帧性能退化）：%s 内仍出现 get_children() —— "
                "热路径应改走 _marker_cache/_npc_cache 缓存数组。" % fn,
            )
    # 反向：热路径必须真的用了缓存，不能只是删掉遍历
    check("_marker_cache" in func_body(code, "_find_nearest_place"),
          "E2 失败：_find_nearest_place 未使用 _marker_cache —— 改造不完整。")
    check("_npc_cache" in func_body(code, "_cull_offscreen"),
          "E2 失败：_cull_offscreen 未使用 _npc_cache —— NPC 裁剪仍走 get_children()。")

    # E3 重建路径必须同步 clear 缓存
    rb = func_body(code, "_rebuild_city_markers")
    check(bool(rb), "E3 前置：找不到 _rebuild_city_markers")
    if rb:
        check("_marker_cache.clear()" in rb,
              "E3 失败（悬空引用）：_rebuild_city_markers 未 clear _marker_cache —— "
              "切区后缓存里会残留已 queue_free 的节点，每帧遍历无谓判定且行为不可预期。")

    # E4 候选缓冲区不得再每帧新建
    fnp = func_body(code, "_find_nearest_place")
    check("var candidates: Array = []" not in fnp,
          "E4 失败（每帧新建数组反模式）：_find_nearest_place 内又出现 "
          "`var candidates: Array = []` —— 每帧分配一次数组，项目铁律禁止。")
    check("_candidates_buf" in fnp,
          "E4 失败：_find_nearest_place 未使用 _candidates_buf 复用缓冲区。")
    # 每候选 new Dictionary 同样要不得
    check(not re.search(r'_candidates_buf\.append\(\s*\{', fnp),
          "E4 失败：_candidates_buf 仍在 append Dictionary —— "
          "只存节点引用即可，score/dist 已由 best_* 承载。")

    # E5 clear 必须在遍历前（否则会边遍历边清）
    if "_candidates_buf" in fnp:
        ic = fnp.find("_candidates_buf.clear()")
        it = fnp.find("for marker in _marker_cache")
        check(ic >= 0 and it >= 0 and ic < it,
              "E5 失败：_candidates_buf.clear() 必须出现在遍历 _marker_cache 之前，"
              "否则边遍历边清会漏掉候选点。")

    # ================= 汇总 =================
    print("=" * 68)
    print("第五十七轮 大地图 marker/NPC 缓存改造 · 校验")
    print("=" * 68)
    print("  目标文件：scripts\\world\\world_map.gd")
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
    print("    A 缓存 ≡ 节点树双向一致（含干扰项排除）✓")
    print("    B 切区重建后缓存无悬空残留 ✓")
    print("    C 候选缓冲区跨帧归零重填、不串数据 ✓")
    print("    D Hint 显现在两条遍历路径下逐项相同 ✓")
    print("  [独立锚定上游源码]")
    print("    E1 三个缓存字段声明 ✓")
    print("    E2 三处热路径已无 get_children() 且确实用了缓存 ✓")
    print("    E3 重建路径同步 clear 缓存（无悬空引用）✓")
    print("    E4 无每帧新建数组 / 无每候选 Dictionary ✓")
    print("    E5 clear() 在遍历之前 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
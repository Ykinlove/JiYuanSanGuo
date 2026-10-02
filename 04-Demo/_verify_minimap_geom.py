#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第五十八轮校验：小地图静态几何脏标记改造（每帧性能 + 显示等价）

背景
----
小地图常驻左上角，world_map._process 每帧调 `update_view()`，其中原本
**无条件**调 `_recalc_geometry()` + `queue_redraw()`。而 `_recalc_geometry`
内部要重算局部/整图/放大三种窗口、缩放、origin、scale，并驱动
`_clip_polyline`（Liang-Barsky 逐段裁剪）的裁剪基准。
实测数据量：terrain.json 有 **163 条官道**，每条每帧遍历全部点并跑折线裁剪。

而真正每帧变的只有玩家朝向与视野框 —— 它们**不参与** `_recalc_geometry`。
所以改为「几何输入真变了才重算」。

**这类改造编译期完全无感、写错不报错**，最危险的是悄悄改坏显示：
  - 漏把 `_player_pos` 计入脏标记 → 局部模式窗口不跟随玩家（小地图"卡住"）
  - 快照同步写在clamp 之前 → `_pan_center` 被就地改写后每帧必判脏，优化失效
  - 快照不同步到 7 处直接调用路径 → 漏掉一次本该发生的重算

本校验分两层：
  【headless 真跑】（tests/minimap_geom_probe.gd + .tscn，真实 Godot 引擎）
    A 窗口等价：脏标记版 vs 每帧必重算版，_world_window/_scale/_origin
      在静止、位移、越界夹取、切模式等序列下逐帧逐字段相等
    B 跟随不失效：局部模式下玩家移动后窗口必须跟着变
    C 快照同步：直接调 _recalc_geometry 的路径后不得重复判脏
    D 脏标记确实生效：静止 20 帧判脏次数 ≤ 1（否则改造没收益）
    E 提前return 路径：控件尺寸未就绪时 _recalc_geometry 走 :245 早退分支，
      末尾快照同步不执行，只有 _static_geometry_dirty 内部的自写快照兜底。
      该兜底一旦被后人删掉，脏标记会永久失效且零报错，故必须锁死。
  【独立锚定上游源码】（本文件，防探针与被测代码同改而互相放过）
    F1 两个新函数必须存在
    F2 update_view 不得再无条件调用 _recalc_geometry
    F3 脏标记必须包含 _player_pos（局部模式跟随）
    F4 快照同步必须在 _recalc_geometry 内部且位于计算之后
    F5 快照必须覆盖全部七个几何输入
    F6 判脏分支必须自带全七项快照赋值，且在 return true 之前完成
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MINIMAP = os.path.join(HERE, "scripts", "ui", "minimap.gd")
PROBE_TSCN = os.path.join(HERE, "tests", "minimap_geom_probe.tscn")
RESULT = os.path.join(HERE, "minimap_geom_result.txt")
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
            [GODOT, "--headless", "--path", ".", "tests/minimap_geom_probe.tscn"],
            cwd=HERE, capture_output=True, text=True, timeout=180,
        )
    except subprocess.TimeoutExpired:
        FAILS.append("headless 探针超时 —— 很可能探针里漏了 get_tree().quit()")
    except FileNotFoundError:
        FAILS.append("找不到 Godot 可执行文件: " + GODOT)

    rlines = []
    if os.path.isfile(RESULT):
        rlines = read(RESULT).splitlines()
    check(bool(rlines), "headless 探针未产出结果文件 —— 引擎可能报 SCRIPT ERROR")

    if rlines:
        check(
            not any(ln.strip() == "MINIMAP_GEOM_FAIL" for ln in rlines),
            "headless 探针判定 FAIL：\n    " + "\n    ".join(
                ln.strip() for ln in rlines if ln.strip().startswith("[")),
        )
        for tag in ("A_EQUIV", "B_FOLLOW", "C_SNAPSHOT", "D_EFFECTIVE", "E_EARLY_RETURN"):
            val = ""
            for ln in rlines:
                if ln.startswith(tag + "="):
                    val = ln.split("=", 1)[1].strip()
            check(val == "OK", "headless 判定 %s 未通过（实际=%r）" % (tag, val))
        for fn in ("_static_geometry_dirty", "_sync_geometry_snapshot"):
            check(
                any(ln.strip() == "FUNC_FOUND_" + fn + "=true" for ln in rlines),
                "探针未确认函数 %s 仍在上游存在（上游可能已改名/删除）" % fn,
            )

    check(
        len(raw) > 10000,
        "锚定层失效：探针读到的源码长度异常小，可能未真正锚定 minimap.gd",
    )

    # ================= F1–F5 独立锚定上游源码 =================
    # F1 函数存在
    for fn in ("_static_geometry_dirty", "_sync_geometry_snapshot"):
        check(
            re.search(rf"^func {re.escape(fn)}\s*\(", code, re.M) is not None,
            "F1 失败：minimap.gd 未定义 func %s" % fn,
        )

    # F2 update_view 不得无条件重算
    uv = func_body(code, "update_view")
    check(bool(uv), "F2 前置：找不到 update_view")
    if uv:
        check(
            "_static_geometry_dirty()" in uv,
            "F2 失败：update_view 未调用 _static_geometry_dirty() —— "
            "脏标记没接上，每帧仍然无条件重算（改造无效）。",
        )
        # 允许 _recalc_geometry 出现在脏判定分支内，但必须是「有条件」的：
        # 形如 if _static_geometry_dirty(): _recalc_geometry()
        lines = [ln.strip() for ln in uv.split("\n") if ln.strip()]
        cond_ok = False
        for i, ln in enumerate(lines):
            if "_recalc_geometry()" in ln:
                # 往前找最近的 if 判定
                for j in range(i - 1, max(-1, i - 3), -1):
                    if lines[j].startswith("if ") and "_static_geometry_dirty" in lines[j]:
                        cond_ok = True
        check(
            cond_ok,
            "F2 失败：update_view 里的 _recalc_geometry() 不受 _static_geometry_dirty "
            "条件保护 —— 仍是每帧无条件重算。",
        )

    # F3 脏标记必须含 _player_pos
    dirty = func_body(code, "_static_geometry_dirty")
    check(bool(dirty), "F3 前置：找不到 _static_geometry_dirty")
    if dirty:
        check(
            "_player_pos" in dirty,
            "F3 失败（会导致小地图卡住不跟随）：_static_geometry_dirty 未把 _player_pos "
            "计入判据 —— 局部模式下可视窗口由 _player_pos 推导，漏掉它玩家移动时"
            "窗口不更新，玩家看到的是「地图不动」。",
        )

    # F4 快照同步必须在 _recalc_geometry 内且在计算之后
    recalc = func_body(code, "_recalc_geometry")
    check(bool(recalc), "F4 前置：找不到 _recalc_geometry")
    if recalc:
        check(
            "_sync_geometry_snapshot()" in recalc,
            "F4 失败：_recalc_geometry 内部未调 _sync_geometry_snapshot() —— "
            "本函数有 7 处直接调用（_expanded_input/_zoom_at 两处/reset_view/"
            "_load_data/set_mode/_notification），那些路径不经脏判定，"
            "不同步快照会漏掉一次本该发生的重算。",
        )
        # 必须位于函数末尾（clamp 改写 _pan_center 之后）：
        # 取最后一次出现的位置，与 _scale/_origin 赋值比较
        sync_at = recalc.rfind("_sync_geometry_snapshot()")
        scale_at = recalc.find("_scale = minf(")
        origin_at = recalc.find("_origin = (ctrl - drawn)")
        check(
            scale_at >= 0 and sync_at > scale_at,
            "F4 失败：_sync_geometry_snapshot() 必须出现在 _scale 计算之后 —— "
            "expanded 分支会就地 clamp 改写 _pan_center，快照记在改写前会导致"
            "每帧必判脏（脏标记永久失效）。",
        )
        check(
            origin_at >= 0 and sync_at > origin_at,
            "F4 失败：快照同步应在 _origin 计算完成之后。",
        )

    # F5 快照必须覆盖全部六个几何输入
    sync = func_body(code, "_sync_geometry_snapshot")
    check(bool(sync), "F5 前置：找不到 _sync_geometry_snapshot")
    if sync:
        for field, why in (
            ("_last_ctrl_size", "控件尺寸（resize 后必须重算）"),
            ("_last_map_size", "地图尺寸"),
            ("_last_expanded", "放大/缩略形态"),
            ("_last_view_mode", "局部/整图模式"),
            ("_last_zoom", "放大版缩放倍率"),
            ("_last_pan_center", "放大版平移中心"),
            ("_last_player_pos", "玩家位置（局部模式跟随）"),
        ):
            check(
                field in sync,
                "F5 失败：快照未记录 %s（%s）—— 该项变化时脏标记将失效。" % (field, why),
            )

    # F6 判脏分支必须自带快照写入，且在 return true 之前全部写完。
    #注意：源码是**内联逐字段赋值**（7 行 _last_* = ...），不是调
    # _sync_geometry_snapshot()—— 判据不能锚定函数调用，只能锚定字段赋值。
    if dirty:
        body = dirty
        ret_true = body.find("return true")
        check(
            ret_true > 0,
            "F6 前置：_static_geometry_dirty 里找不到 return true —— "
            "脏判定未成立，脏标记形同虚设。",
        )
        missing = []
        for field in (
            "_last_ctrl_size",
            "_last_map_size",
            "_last_expanded",
            "_last_view_mode",
            "_last_zoom",
            "_last_pan_center",
            "_last_player_pos",
        ):
            # 只认「赋值」出现（=），不接受纯比较出现
            assign_at = -1
            for m2 in re.finditer(rf"{re.escape(field)}\s*=(?!=)", body):
                assign_at = m2.start()
                break
            if assign_at < 0:
                missing.append(field + " 未写入快照")
            elif ret_true > 0 and assign_at > ret_true:
                missing.append(field + " 在 return true 之后才写入")
        check(
            not missing,
            "F6 失败：_static_geometry_dirty 的判脏分支必须自己写全七项快照 —— "
            + "；".join(missing)
            + "。原因：_recalc_geometry 开头有「控件尺寸未就绪」早退分支"
            "（return 时跳过末尾同步），若判脏自己也不写快照，该期间快照永不更新"
            " → 每帧都判脏 → 优化静默失效且零报错；或本次判 true 却漏记 → "
            "下一帧输入没变会漏掉本该发生的重算。",
        )

    # ================= 汇总 =================
    print("=" * 68)
    print("第五十八轮 小地图静态几何脏标记 · 校验")
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
    print("    A 窗口等价（静止/位移/越界夹取/切模式 逐帧逐字段一致）✓")
    print("    B 局部模式窗口随玩家移动更新（小地图不会卡住）✓")
    print("    C 快照已同步，直接调用路径不重复判脏 ✓")
    print("    D 静止 20 帧判脏 ≤1 次（脏标记确实生效）✓")
    print("    E 提前 return 路径判脏收敛 + 尺寸就绪后正确重算 ✓")
    print("  [独立锚定上游源码]")
    print("    F1 两个新函数存在 ✓")
    print("    F2 update_view 已受脏判定保护 ✓")
    print("    F3 脏标记含 _player_pos（跟随不失效）✓")
    print("    F4 快照同步在 clamp 之后 ✓")
    print("    F5 快照覆盖全部七项几何输入 ✓")
    print("    F6 判脏分支自带全七项快照赋值且在 return true 之前（提前 return 路径兜底）✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
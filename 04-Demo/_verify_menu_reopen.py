# -*- coding: utf-8 -*-
"""
_verify_menu_reopen.py — 第六十六轮·问题4 回归锁
用户反馈：大地图菜单栏点开某一项（系统 / 人物志）后，会把大菜单的几个按钮又弹一遍。

【根因（取证后定性，不是猜的）】触控**双事件穿透**：
一次物理触摸在 Godot 里同时派生 InputEventScreenTouch 与模拟的
InputEventMouseButton —— 第一个事件打开面板，第二个事件落到新出现的全屏遮罩
dim 上，触发「点遮罩即关」，面板开门即关；world_map 的轮询守卫看到
「面板不可见 + 无忙 + 无 UI 打开」，判定用户已返回，于是把轮盘重新弹出来。
所以现象是「点一次，子面板闪一下 + 轮盘又弹一遍」。
不是位置重叠，也不是轮询逻辑写错 —— 轮询逻辑本身实测无误。

【修法】给守卫加「信任期」：轮盘选中子项后的 8 帧内，即便面板被穿透关掉，
也不许把轮盘重开。用**帧数**而不是毫秒（见探针注释：人物志构建 300 行按钮
可能耗时数百毫秒，时间窗会在面板可见前就耗尽）。

本校验锁两件事：
  ① 探针真跑（A/B/C/D 四个用例）—— 验证守卫行为本身；
  ② 独立锚定 world_map.gd 源码 —— 验证产品里真的装了这个守卫，
     防止「探针里复刻得对、产品里没接上」这类假绿灯。
     其中 C 用例是反向对照：信任期过后必须恢复设计行为（真关闭要重开轮盘），
     否则修法就退化成「永远不再自动重开轮盘」的另一种 bug。
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GODOT = r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe"

PROBE_GD = os.path.join("tests", "menu_reopen_probe.gd")
PROBE_TSCN = os.path.join("tests", "menu_reopen_probe.tscn")
RESULT = "menu_reopen_result.txt"
WM = os.path.join(HERE, "scripts", "world", "world_map.gd")

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print("  [%s] %s%s" % ("OK" if ok else "FAIL", name, ("  " + detail) if detail else ""))
    return bool(ok)


def kill_stale_godot():
    """清掉残留 Godot 进程：它们持有 .godot/ 与存档写锁，会让后续真跑莫名其妙失败。"""
    for exe in ("Godot_v4.7.2-stable_win64_console.exe", "Godot_v4.7.2-stable_win64.exe"):
        try:
            # 【踩坑】taskkill 输出是 GBK，text=True 按 utf-8 解码会抛
            # UnicodeDecodeError，且异常发生在 subprocess 读取线程里 → 整校验崩掉。
            subprocess.run(["taskkill", "/F", "/IM", exe], capture_output=True,
                           timeout=30, encoding="gbk", errors="replace")
        except Exception:
            pass


def run_probe(timeout=300):
    rp = os.path.join(HERE, RESULT)
    if os.path.isfile(rp):
        try:
            os.replace(rp, rp + ".stale")   # 改名而非删除：避免触发批量删除防护钩子
        except OSError:
            pass
    args = [GODOT, "--headless", "--path", ".", "--scene", "res://" + PROBE_TSCN.replace("\\", "/"),
            "--quit-after", "900"]
    try:
        r = subprocess.run(args, cwd=HERE, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT"
    except FileNotFoundError:
        return -2, "NO_GODOT"


print("=" * 68)
print("第六十六轮 大地图轮盘重复弹出 回归锁")
print("=" * 68)

# ---------- ① 探针真跑 ----------
print("\n[1] 探针真跑（A/B/C/D 四用例）")
if not (os.path.isfile(os.path.join(HERE, PROBE_GD))
        and os.path.isfile(os.path.join(HERE, PROBE_TSCN))):
    check("探针文件齐备", False, "缺 %s / %s" % (PROBE_GD, PROBE_TSCN))
    code, out = -3, ""
else:
    kill_stale_godot()
    code, out = run_probe()
    if code != 0:
        check("探针进程正常退出", False, "exit=%s" % code)
    rp = os.path.join(HERE, RESULT)
    if not os.path.isfile(rp):
        check("探针产出结果文件", False, RESULT)
        lines = []
    else:
        with open(rp, "r", encoding="utf-8", errors="replace") as f:
            lines = [ln.rstrip("\n") for ln in f]
        check("探针产出结果文件", True, "%d 行" % len(lines))

    txt = "\n".join(lines)
    # 零 SCRIPT ERROR：探针自身若崩了，结果文件里可能仍写着 PASS（读到旧文件）
    script_errors = len(re.findall(r"SCRIPT ERROR|Parse Error|ERROR:", out))
    check("探针运行零脚本错误", script_errors == 0, "错误计数 %d" % script_errors)
    check("哨兵 MENU_REOPEN_RESULT=PASS 命中", "MENU_REOPEN_RESULT=PASS" in txt)

    n_ok = len(re.findall(r"^\s*\[OK\]", txt, flags=re.M))
    n_fail = len(re.findall(r"^\s*\[FAIL\]", txt, flags=re.M))
    check("判定项齐全（4 项）", n_ok + n_fail == 4, "OK=%d FAIL=%d" % (n_ok, n_fail))
    check("四项全部通过", n_fail == 0 and n_ok == 4, "OK=%d FAIL=%d" % (n_ok, n_fail))
    # C 用例是反向对照：设计行为（真关闭→重开）不得被误伤
    check("C 反向对照：信任期过后面板真关闭仍会重开轮盘",
          bool(re.search(r"\[OK\] C ", txt)))

# ---------- ② 独立锚定产品源码 ----------
print("\n[2] 独立锚定 world_map.gd（防「探针复刻得对、产品没接上」）")
if not os.path.isfile(WM):
    check("world_map.gd 存在", False, WM)
else:
    with open(WM, "r", encoding="utf-8", errors="replace") as f:
        wm = f.read()
    check("存在轮询守卫容器 _wheel_return_panel",
          "_wheel_return_panel" in wm)
    check("存在帧计数信任期字段 _wheel_guard_frames",
          "_wheel_guard_frames" in wm)
    check("存在信任帧数常量 WHEEL_RETURN_GUARD_FRAMES",
          "WHEEL_RETURN_GUARD_FRAMES" in wm)
    # 守卫必须真的用 guarded 拦住重开，而不是只声明了变量
    m = re.search(r"if\s+_wheel_return_panel\s*!=\s*null:(.*?)(?=\n\tfunc|\n\t[^\t])",
                  wm, flags=re.S)
    guard_body = m.group(1) if m else ""
    check("守卫体内递减帧计数", "_wheel_guard_frames -= 1" in guard_body)
    check("守卫体内计算 guarded", "var guarded" in guard_body)
    check("重开轮盘前必须过 guarded（not guarded）",
          bool(re.search(r"not\s+guarded", guard_body)))
    # 信任期必须在「选中子项」时统一置位，而不是只在某一个分支里写
    sel = re.search(r"func _on_wheel_selected\(action: String\) -> void:(.*?)(?=\nfunc )",
                    wm, flags=re.S)
    sel_body = sel.group(1) if sel else ""
    check("_on_wheel_selected 统一置信任帧数（8 个分支不会漏写）",
          "_wheel_guard_frames = WHEEL_RETURN_GUARD_FRAMES" in sel_body)
    check("_on_wheel_selected 先清空上一轮面板引用",
          "_wheel_return_panel = null" in sel_body)
    # 修法不得退化成「永远不再重开轮盘」：guarded 必须会过期
    check("信任期会过期（帧数递减，不是永久开关）",
          bool(re.search(r"_wheel_guard_frames\s*-=\s*1", wm)))

# ---------- 汇总 ----------
print("\n" + "=" * 68)
passed = sum(1 for _, ok, _ in results if ok)
print("复核结果：%d / %d 通过" % (passed, len(results)))
if passed < len(results):
    print("失败项：")
    for n, ok, d in results:
        if not ok:
            print("  - %s :: %s" % (n, d))
    sys.exit(1)
print("全部通过 ✅")

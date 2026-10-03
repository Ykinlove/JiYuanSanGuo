# -*- coding: utf-8 -*-
"""对话选项布局校验：用 Godot 真跑 tests/dialogue_layout_probe.tscn，
对全部 dialogues.json 节点实例化 DialogueUI 并断言「每个选项按钮都在
1080p 屏幕内、高度 >= 84px、互不重叠、超 4 项走两列」。

为什么必须有这条：第五十一轮把选项按钮从 62px 抬到 84px 触控铁律后，
单列排布下 8~10 项的对话尾部按钮会溢出屏幕下边界 236~428px —— 编译期
与静态扫描都抓不到（那只是几何问题，不是语法问题），只有真实引擎跑出
get_global_rect() 才能确诊。修法是超 4 项切两列，本校验锁死不回归。

与 _verify_save_load.py 同套：真实引擎跑，结果落 dialogue_layout_result.txt
（Windows 控制台编码兜底），并从引擎 stderr 抓真实 WARNING/ERROR
（过滤 headless 良性告警）。

判据：
    - 探针必须产出 dialogue_layout_result.txt 且含 DIALOGUE_LAYOUT=PASS
    - 校验节点数 >= 100（证明确实覆盖了全量对话，而非只跑了几条）
    - stderr 不得出现非良性真实 WARNING/ERROR
"""
import os
import re
import subprocess
import sys
import _safe_cleanup

ROOT = os.path.dirname(os.path.abspath(__file__))
GODOT_CANDIDATES = [
    r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe",
    r"D:\Godot\Godot_v4.7.2-stable_win64.exe",
]
SCENE = "res://tests/dialogue_layout_probe.tscn"
RESULT_FILE = os.path.join(ROOT, "dialogue_layout_result.txt")

# 无头环境下与本游戏代码无关的引擎级良性告警（子串匹配，忽略大小写）
BENIGN_SUBSTR = [
    "audiodriver", "audioserver", "servers/audio",
    "vulkan", "opengl", "glcomp", "renderingdevice",
    "display server", "x11", "wayland", "egl", "gles",
    "context", "unable to create", "could not open", "couldn't open",
    "textserver", "font", "fallback", "no cache file",
    "servers/display", "scene/main/window", "drivers",
    "resources still in use", "resource still in use", "objectdb", "leaked",
    "audiomanager", "占位音", "音频资源缺失",
    "not in a scene tree",
    "remapping", "import",
]

ALERT_RE = re.compile(r"(?:^|\s)(WARNING|SCRIPT ERROR|ERROR)\s*:", re.IGNORECASE)
# 覆盖下限：dialogues.json 有 192 个节点，其中带选项的约 180 个
MIN_NODES = 100
# 按钮数下限：带选项的节点共约 180 个、选项总数约 400+。
# 这条闸门是踩过坑才加的——首版探针在循环里漏了 await，180 个节点的协程
# 全挂在第一个 await 上空跑，按钮数 0 却照样输出 PASS。没有下限就等于
# 给假绿灯开了绿灯。
MIN_BUTTONS = 300


def _is_benign(line: str) -> bool:
    low = line.lower()
    return any(b in low for b in BENIGN_SUBSTR)


def main() -> int:
    godot = next((g for g in GODOT_CANDIDATES if os.path.exists(g)), None)
    if godot is None:
        print("[SKIP] 未找到 Godot 可执行文件，跳对话选项布局校验")
        return 0

    print("对话选项布局校验（headless --verbose，抓引擎 WARNING/ERROR）")
    print("  场景：%s" % SCENE)

    if os.path.exists(RESULT_FILE):
        _safe_cleanup.discard(RESULT_FILE)

    try:
        p = subprocess.run(
            [godot, "--headless", "--verbose", "--path", ROOT, SCENE],
            cwd=ROOT, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=300,
        )
    except subprocess.TimeoutExpired:
        print("[FAIL] 对话选项布局校验超时（300s）")
        return 1

    combined = (p.stdout or "") + "\n" + (p.stderr or "") or ""

    if not os.path.exists(RESULT_FILE):
        print("[FAIL] 探针未产出结果文件（可能脚本编译失败或启动即崩）")
        for line in combined.strip().splitlines()[-25:]:
            print("       " + line)
        return 1

    with open(RESULT_FILE, encoding="utf-8", errors="replace") as f:
        rlines = f.read().splitlines()

    # 只打失败行 + 摘要，全量 180 节点刷屏没意义
    for ln in rlines:
        if ln.startswith("[FAIL]") or ln.startswith("DIALOGUE_LAYOUT=") \
                or ln.startswith("节点数=") or ln.startswith("失败项"):
            print(ln)

    alerts = [ln.rstrip() for ln in combined.splitlines() if ALERT_RE.search(ln)]
    real = [ln for ln in alerts if not _is_benign(ln)]

    print("")
    if alerts:
        benign_n = len(alerts) - len(real)
        print("  引擎日志命中告警行 %d（良性 %d，真实 %d）"
              % (len(alerts), benign_n, len(real)))
        if real:
            print("  ---- 真实 WARNING/ERROR（需处理）----")
            for ln in real[:40]:
                print("    ! " + ln)
    else:
        print("  引擎日志无 WARNING/ERROR 命中")

    layout_ok = any(ln.startswith("DIALOGUE_LAYOUT=PASS") for ln in rlines)
    if not layout_ok:
        print("[FAIL] 对话选项布局探针自身未 PASS")
        return 1

    # 覆盖度闸门：节点/按钮太少说明探针空跑，等于没测
    node_n = 0
    btn_n = 0
    for ln in rlines:
        m = re.match(r"节点数=(\d+)", ln)
        if m:
            node_n = int(m.group(1))
            mb = re.search(r"按钮数=(\d+)", ln)
            if mb:
                btn_n = int(mb.group(1))
            break
    if node_n < MIN_NODES:
        print("[FAIL] 覆盖节点数 %d < %d，探针可能空跑"
              % (node_n, MIN_NODES))
        return 1
    if btn_n < MIN_BUTTONS:
        print("[FAIL] 实测按钮数 %d < %d，探针空跑（未真正生成选项按钮）"
              % (btn_n, MIN_BUTTONS))
        return 1

    if real:
        print("[FAIL] 发现 %d 条真实启动期 WARNING/ERROR" % len(real))
        return 1

    print("对话选项布局校验通过 ✅（%d 节点全量：不出屏/≥84px/不重叠/超量两列，"
          "启动期无真实告警）" % node_n)
    return 0


if __name__ == "__main__":
    sys.exit(main())

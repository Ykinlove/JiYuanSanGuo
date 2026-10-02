# -*- coding: utf-8 -*-
"""Toast 多提示队列校验：用 Godot 真跑 tests/toast_queue_probe.tscn，
连发多条提示后断言「各自独立面板、互不覆盖、超上限挤掉最旧、释放不泄漏」。

为什么必须有这条：第五十一轮之前 ToastLayer 是单 Label + 单 Tween + 单 Panel，
新提示直接改写同一 Label 并 kill 上一个 Tween → 后一条顶掉前一条。
story_director.gd 一次章节结算连发两条（【史官】终 + 主线推进），
玩家只读得到最后一条。这是纯运行时行为——编译期不报错、静态扫描看不见，
只有真跑并逐面板取回 Label 文本才能确诊。

与 _verify_dialogue_layout.py 同套：真实引擎跑，结果落 toast_queue_result.txt，
并从引擎 stderr 抓真实 WARNING/ERROR（过滤 headless 良性告警）。

判据：
    - 探针必须产出 toast_queue_result.txt 且含 TOAST_QUEUE=PASS
    - 探针必须实测到 >=3 个存活面板（覆盖度闸门，防空跑假绿灯）
    - stderr 不得出现非良性真实 WARNING/ERROR
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
GODOT_CANDIDATES = [
    r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe",
    r"D:\Godot\Godot_v4.7.2-stable_win64.exe",
]
SCENE = "res://tests/toast_queue_probe.tscn"
RESULT_FILE = os.path.join(ROOT, "toast_queue_result.txt")

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
# 连发 3 条至少要同时存活 3 个面板，否则说明仍在复用单 Panel
MIN_LIVE = 3


def _is_benign(line: str) -> bool:
    low = line.lower()
    return any(b in low for b in BENIGN_SUBSTR)


def main() -> int:
    godot = next((g for g in GODOT_CANDIDATES if os.path.exists(g)), None)
    if godot is None:
        print("[SKIP] 未找到 Godot 可执行文件，跳 Toast 队列校验")
        return 0

    print("Toast 多提示队列校验（headless --verbose，抓引擎 WARNING/ERROR）")
    print("  场景：%s" % SCENE)

    if os.path.exists(RESULT_FILE):
        os.remove(RESULT_FILE)

    try:
        p = subprocess.run(
            [godot, "--headless", "--verbose", "--path", ROOT, SCENE],
            cwd=ROOT, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=180,
        )
    except subprocess.TimeoutExpired:
        print("[FAIL] Toast 队列校验超时（180s）")
        return 1

    combined = (p.stdout or "") + "\n" + (p.stderr or "") or ""

    if not os.path.exists(RESULT_FILE):
        print("[FAIL] 探针未产出结果文件（可能脚本编译失败或启动即崩）")
        for line in combined.strip().splitlines()[-25:]:
            print("       " + line)
        return 1

    with open(RESULT_FILE, encoding="utf-8", errors="replace") as f:
        rlines = f.read().splitlines()
    for ln in rlines:
        if ln.startswith("[FAIL]") or ln.startswith("TOAST_QUEUE=") \
                or "存活" in ln or "各面板文本" in ln or ln.startswith("失败项"):
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

    ok = any(ln.startswith("TOAST_QUEUE=PASS") for ln in rlines)
    if not ok:
        print("[FAIL] Toast 队列探针自身未 PASS")
        return 1

    # 覆盖度闸门：实测存活面板数不足说明探针空跑（假绿灯防线）
    live_n = 0
    for ln in rlines:
        m = re.search(r"连发 3 条后存活面板数：(\d+)", ln)
        if m:
            live_n = int(m.group(1))
            break
    if live_n < MIN_LIVE:
        print("[FAIL] 连发 3 条实测存活 %d < %d，探针空跑或仍在复用单面板"
              % (live_n, MIN_LIVE))
        return 1

    if real:
        print("[FAIL] 发现 %d 条真实启动期 WARNING/ERROR" % len(real))
        return 1

    print("Toast 队列校验通过 ✅（连发 3 条独立成 %d 个面板互不覆盖、"
          "超上限挤最旧、释放不泄漏，启动期无真实告警）" % live_n)
    return 0


if __name__ == "__main__":
    sys.exit(main())

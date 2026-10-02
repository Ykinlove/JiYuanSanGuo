# -*- coding: utf-8 -*-
"""存档读档往返校验：用 Godot 真跑 tests/save_load_probe.tscn，覆盖
SaveManager.save_game / load_game + GameState.to_dict / from_dict 这条
「整局游戏生死线」。

与 _run_scene_boot.py / _run_boot_flow.py 同套：真实引擎环境下跑，结果落
save_load_result.txt（Windows 控制台编码兜底），并从引擎 stderr 抓取真实
WARNING/ERROR（过滤 headless 良性告警）。

判据：
    - 探针必须产出 save_load_result.txt 且含 SAVE_LOAD=PASS
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
SCENE = "res://tests/save_load_probe.tscn"
RESULT_FILE = os.path.join(ROOT, "save_load_result.txt")

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


def _is_benign(line: str) -> bool:
    low = line.lower()
    return any(b in low for b in BENIGN_SUBSTR)


def main() -> int:
    godot = next((g for g in GODOT_CANDIDATES if os.path.exists(g)), None)
    if godot is None:
        print("[SKIP] 未找到 Godot 可执行文件，跳存档读档往返校验")
        return 0

    print("存档读档往返校验（headless --verbose，抓引擎 WARNING/ERROR）")
    print("  场景：%s" % SCENE)

    if os.path.exists(RESULT_FILE):
        os.remove(RESULT_FILE)

    try:
        p = subprocess.run(
            [godot, "--headless", "--verbose", "--path", ROOT, SCENE],
            cwd=ROOT, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=120,
        )
    except subprocess.TimeoutExpired:
        print("[FAIL] 存档读档往返校验超时（120s）")
        return 1

    combined = (p.stdout or "") + "\n" + (p.stderr or "")

    if not os.path.exists(RESULT_FILE):
        print("[FAIL] 探针未产出结果文件（可能脚本编译失败或启动即崩）")
        for line in combined.strip().splitlines()[-25:]:
            print("       " + line)
        return 1

    with open(RESULT_FILE, encoding="utf-8", errors="replace") as f:
        rlines = f.read().splitlines()
    for ln in rlines:
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

    save_ok = any(ln.startswith("SAVE_LOAD=PASS") for ln in rlines)
    if not save_ok:
        print("[FAIL] 存档读档往返探针自身未 PASS")
        return 1
    if real:
        print("[FAIL] 发现 %d 条真实启动期 WARNING/ERROR" % len(real))
        return 1

    print("存档读档往返校验通过 ✅（save→load 往返 + int 键还原 + 空槽优雅返回，启动期无真实告警）")
    return 0


if __name__ == "__main__":
    sys.exit(main())

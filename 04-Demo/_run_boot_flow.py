# -*- coding: utf-8 -*-
"""真实入口链路冒烟：直接无头启动游戏（boot.tscn → SceneRouter.goto main_menu），
抓取启动期（boot + 转场 + 主菜单 _ready）的引擎 WARNING/ERROR。

与 _run_scene_boot.py 的分工：
    _run_scene_boot.py  —— 孤立实例化五大场景（不经过 SceneRouter 转场）
    _run_boot_flow.py   —— 跑「真实游戏入口」，覆盖 boot._ready → SceneRouter.goto
                            → change_scene_to_file → main_menu._ready 这条玩家实际经历的
                            启动链路（autoload 注册 / 转场淡入淡出 / EventBus 发射 /
                            主菜单建设置面板 / 播 BGM），孤立实例化抓不到转场期缺陷。

游戏在 main_menu 会停等用户输入，不会自行退出，故本脚本用超时（默认 8s）截断进程，
分析截断前已刷出的 stderr。进程因崩溃提前非零退出即判真失败；超时仍在跑=正常停等=分析告警。

【headless 良性告警】与 _run_scene_boot.py 同套 denylist（音频驱动/渲染后端回退/字体回退/
退出期 class_name 资源仍在使用/占位音缺失/退出期 get_path 拆卸噪声）。
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
ENTRY = "res://scenes/main/boot.tscn"
TIMEOUT = 8

# headless 良性告警（子串匹配，忽略大小写）。同 _run_scene_boot.py。
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
        print("[SKIP] 未找到 Godot 可执行文件，跳过真实入口链路冒烟")
        return 0

    print("真实入口链路冒烟（headless 启动 boot.tscn，超时 %ds 截断）" % TIMEOUT)
    print("  入口：%s" % ENTRY)

    try:
        p = subprocess.run(
            [godot, "--headless", "--verbose", "--path", ROOT, ENTRY],
            cwd=ROOT, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=TIMEOUT,
        )
        # 正常退出（理论上不会，游戏停等输入；但若很快非零退出=崩溃）
        code = p.returncode
        out = (p.stdout or "") + "\n" + (p.stderr or "")
        timed_out = False
    except subprocess.TimeoutExpired as e:
        timed_out = True
        code = None
        out = (e.stdout or "") + "\n" + (e.stderr or "")
        # 超时=游戏停等输入（正常），确保子进程退出
        try:
            e.process.kill()
        except Exception:
            pass

    print("  进程%s" % ("超时停等（正常）" if timed_out else "提前退出 code=%s" % code))

    alerts = [ln.rstrip() for ln in out.splitlines() if ALERT_RE.search(ln)]
    real = [ln for ln in alerts if not _is_benign(ln)]

    print("")
    if alerts:
        benign_n = len(alerts) - len(real)
        print("  引擎日志命中告警行 %d（良性 %d，真实 %d）" % (len(alerts), benign_n, len(real)))
        if real:
            print("  ---- 真实 WARNING/ERROR（需处理）----")
            for ln in real[:40]:
                print("    ! " + ln)
    else:
        print("  引擎日志无 WARNING/ERROR 命中")

    # 判定：非超时提前退出（崩溃）= 失败；超时但存在真实告警 = 失败
    if not timed_out:
        print("[FAIL] 游戏入口进程提前非零退出（疑似启动崩溃）")
        return 1
    if real:
        print("[FAIL] 发现 %d 条真实启动期 WARNING/ERROR" % len(real))
        return 1

    print("真实入口链路冒烟通过 ✅（boot → 主菜单转场启动期无真实告警）")
    return 0


if __name__ == "__main__":
    sys.exit(main())

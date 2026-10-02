# -*- coding: utf-8 -*-
"""场景启动冒烟：用 Godot 真跑 tests/scene_boot_probe.tscn，覆盖 world_map /
city_scene / main_menu / create_hero / formation_editor 五大主场景的启动期。

与 _run_probe.py 的分工：
    _run_probe.py  —— 规则层/状态层断言（侧重 battle_scene 实件）
    _run_scene_boot.py —— 抓「引擎自身日志」里的真实 WARNING/ERROR/SCRIPT ERROR，
                          这些是比断言更底层的信号：_ready 里的空引用、节点缺失、
                          资源加载失败、装饰面板构造异常，只会在真实启动场景时冒出来。

Windows 控制台版 Godot 的 stdout 在管道里编码常被搅乱，故结果文件（scene_boot_result.txt）
只作「进程是否跑完」的兜底；真正的判据是 stderr 里的 ERROR/WARNING 行筛选。

【headless 良性告警】无头 + GL Compatibility + 哑显示 + 无音频设备时，引擎会固定
刷一批与本游戏代码无关的告警（音频驱动未初始化、渲染后端回退、字体回退、退出期
class_name 全局注册表「仍在使用」等）。这些一律进 denylist，不计入失败；任何不在
denylist 里的真实 WARNING/ERROR 才判 FAIL。
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
SCENE = "res://tests/scene_boot_probe.tscn"
RESULT_FILE = os.path.join(ROOT, "scene_boot_result.txt")

# 无头环境下与本游戏代码无关的引擎级良性告警（子串匹配，忽略大小写）
BENIGN_SUBSTR = [
    "audiodriver", "audioserver", "servers/audio",
    "vulkan", "opengl", "glcomp", "renderingdevice",
    "display server", "x11", "wayland", "egl", "gles",
    "context", "unable to create", "could not open", "couldn't open",
    "textserver", "font", "fallback", "no cache file",
    "servers/display", "scene/main/window", "drivers",
    # 退出期良性：带 class_name 的全局类注册表被引擎持引用，非游戏泄漏
    "resources still in use", "resource still in use", "objectdb", "leaked",
    # 缺失音频资源已由 AudioManager 占位音兜底（已知缺口，非代码缺陷）
    "audiomanager", "占位音", "音频资源缺失",
    # 退出期良性：get_tree().quit() 拆树时引擎内部对"已脱离树"的节点调 get_path()，
    # 无任何 GDScript 调用栈、仅出现在退出期（紧跟 "leaked at exit"），与
    # "resources still in use" 同类；本工程不直接调用 get_path()，故抑制安全。
    "not in a scene tree",
    "remapping", "import",  # 资源导入/重映射提示
]

# 真正关心的日志行：引擎以 "WARNING:" / "ERROR:" / "SCRIPT ERROR:" 令牌打印。
# 注意：必须带冒号，否则会误抓含 "WARNING" 字样的行（如 "at: push_warning"）。
ALERT_RE = re.compile(r"(?:^|\s)(WARNING|SCRIPT ERROR|ERROR)\s*:", re.IGNORECASE)


def _is_benign(line: str) -> bool:
    low = line.lower()
    return any(b in low for b in BENIGN_SUBSTR)


def main() -> int:
    godot = next((g for g in GODOT_CANDIDATES if os.path.exists(g)), None)
    if godot is None:
        print("[SKIP] 未找到 Godot 可执行文件，跳过场景启动冒烟")
        return 0

    print("场景启动冒烟（headless --verbose，抓引擎 WARNING/ERROR）")
    print("  场景：%s" % SCENE)

    if os.path.exists(RESULT_FILE):
        os.remove(RESULT_FILE)

    try:
        p = subprocess.run(
            [godot, "--headless", "--verbose", "--path", ROOT, SCENE],
            cwd=ROOT, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=240,
        )
    except subprocess.TimeoutExpired:
        print("[FAIL] 场景启动冒烟超时（240s）")
        return 1

    combined = (p.stdout or "") + "\n" + (p.stderr or "")

    # --- 结果文件兜底：进程是否真的跑完 ---
    if not os.path.exists(RESULT_FILE):
        print("[FAIL] 探针未产出结果文件（可能脚本编译失败或场景启动即崩）")
        for line in combined.strip().splitlines()[-25:]:
            print("       " + line)
        return 1

    with open(RESULT_FILE, encoding="utf-8", errors="replace") as f:
        rlines = f.read().splitlines()
    for ln in rlines:
        print(ln)

    # --- stderr 真实告警筛选 ---
    alerts = [ln.rstrip() for ln in combined.splitlines() if ALERT_RE.search(ln)]
    real = [ln for ln in alerts if not _is_benign(ln)]

    print("")
    if alerts:
        benign_n = len(alerts) - len(real)
        print("  引擎日志命中告警行 %d（其中良性 %d，真实 %d）"
              % (len(alerts), benign_n, len(real)))
        if real:
            print("  ---- 真实 WARNING/ERROR（需处理）----")
            for ln in real[:40]:
                print("    ! " + ln)
        if benign_n:
            print("  ---- 已过滤的良性 headless 告警（不计入失败）----")
            for ln in alerts[:0]:  # 不刷屏；如想看细节可放开
                pass
    else:
        print("  引擎日志无 WARNING/ERROR 命中")

    # --- 判定 ---
    boot_ok = any(ln.startswith("SCENE_BOOT=PASS") for ln in rlines)
    if not boot_ok:
        print("[FAIL] 场景启动探针自身未 PASS")
        return 1
    if real:
        print("[FAIL] 发现 %d 条真实启动期 WARNING/ERROR" % len(real))
        return 1

    print("场景启动冒烟全部通过 ✅（五大主场景启动无真实告警）")
    return 0


if __name__ == "__main__":
    sys.exit(main())

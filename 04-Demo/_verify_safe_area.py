# -*- coding: utf-8 -*-
"""移动端安全区适配校验：用 Godot 真跑 tests/safe_area_probe.tscn。

覆盖第五十四轮新增的刘海/挖孔屏安全区适配：
  ① UITheme.safe_insets() 在无刘海环境（桌面/平板/headless）必须返回全 0
     —— 这是「安全区改造对绝大多数机型零副作用」的可执行证据：
     布局与改造前逐像素一致，不会有机型莫名其妙错位。
  ② 四边内缩量必须非负且有限：负值会把 UI 推出屏幕，NaN 会让布局整体崩掉。
  ③ apply_safe_top_left / apply_safe_bottom_right 在零内缩时必须**逐字段**
     不改动控件 offset（否则「无刘海机零副作用」只是嘴上说说）。
  ④ null viewport / null 控件兜底不得崩。
  ⑤ HUD 接线存在性：必须有 safe 成员、必须读安全区，且资源条右缘不得
     写死 -24.0 —— 写死会把 _ready 里加的安全区左移量顶掉，
     症状是右侧日期/区域标签仍被刘海遮挡。

与其它 _verify_*.py 同套：真实引擎跑，结果落 encounter_safe_area_result.txt，
并从引擎 stderr 抓真实 WARNING/ERROR（过滤 headless 良性告警）。
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
SCENE = "res://tests/safe_area_probe.tscn"
RESULT_FILE = os.path.join(ROOT, "encounter_safe_area_result.txt")

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


def _static_checks() -> list:
    """静态接线核对：确保三个接入点都真的调了安全区工具，而不是只写了工具没人用。"""
    fails = []
    hud = os.path.join(ROOT, "scripts", "ui", "hud.gd")
    wmap = os.path.join(ROOT, "scripts", "world", "world_map.gd")
    theme = os.path.join(ROOT, "scripts", "ui", "ui_theme.gd")

    if not os.path.isfile(theme):
        return ["ui_theme.gd 缺失"]
    with open(theme, encoding="utf-8") as f:
        tsrc = f.read()
    for fn in ("safe_insets", "apply_safe_top_left", "apply_safe_bottom_right"):
        if "static func %s(" % fn not in tsrc:
            fails.append("ui_theme.gd 缺少 static func %s" % fn)
    if "get_display_safe_area" not in tsrc:
        fails.append("ui_theme.gd 未调用 DisplayServer.get_display_safe_area，"
                     "安全区永远读不到真实值")

    if not os.path.isfile(hud):
        fails.append("hud.gd 缺失")
    else:
        with open(hud, encoding="utf-8") as f:
            hsrc = f.read()
        if "apply_safe_top_left" not in hsrc:
            fails.append("hud.gd 未接入 apply_safe_top_left（顶栏仍会被刘海遮挡）")
        if re.search(r"bar\.offset_right\s*=\s*-24\.0\s*\n", hsrc):
            fails.append("hud.gd 资源条右缘仍写死 -24.0，会顶掉 _ready 加的安全区左移量")

    if not os.path.isfile(wmap):
        fails.append("world_map.gd 缺失")
    else:
        with open(wmap, encoding="utf-8") as f:
            wsrc = f.read()
        # 右下角交互按钮是最容易被遮挡/点不到的元素，必须接安全区
        if "apply_safe_bottom_right" not in wsrc:
            fails.append("world_map.gd 未接入 apply_safe_bottom_right"
                         "（右下角圆形交互按钮会被手势条遮挡）")
    return fails


def main() -> int:
    static_fail = _static_checks()
    if static_fail:
        print("[FAIL] 静态接线核对未通过：")
        for m in static_fail:
            print("       - " + m)
        return 1
    print("  静态接线核对通过（三个接入点齐全、资源条右缘非写死）")

    godot = next((g for g in GODOT_CANDIDATES if os.path.exists(g)), None)
    if godot is None:
        print("[SKIP] 未找到 Godot 可执行文件，跳安全区校验")
        return 0

    print("移动端安全区适配校验（headless --verbose，抓引擎 WARNING/ERROR）")
    print("  场景：%s" % SCENE)

    if os.path.exists(RESULT_FILE):
        _safe_cleanup.discard(RESULT_FILE)

    try:
        p = subprocess.run(
            [godot, "--headless", "--verbose", "--path", ROOT, SCENE],
            cwd=ROOT, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=180,
        )
    except subprocess.TimeoutExpired:
        print("[FAIL] 安全区校验超时（180s）")
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

    ok = any(ln.startswith("SAFE_AREA_PASS") for ln in rlines)
    if not ok:
        print("[FAIL] 安全区探针自身未 PASS")
        return 1

    # 覆盖度闸门：探针必须真的跑到了 safe_insets，而不是全靠 if 跳过
    if not any(ln.startswith("SAFE_INSETS=") for ln in rlines):
        print("[FAIL] 探针未输出 SAFE_INSETS 实测值（判定可能被整体跳过）")
        return 1

    if real:
        print("[FAIL] 发现 %d 条真实运行时 WARNING/ERROR" % len(real))
        return 1

    print("安全区校验通过 ✅（无刘海环境返回全 0 → 布局逐像素不变，"
          "贴顶/贴右下控件 offset 零改动，非负有限，null 兜底不崩，"
          "HUD 与右下交互钮接线齐全，运行时零真实告警）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
# -*- coding: utf-8 -*-
"""人物志搜索响应性校验：用 Godot 真跑 tests/hero_dex_search_probe.tscn。

覆盖第五十三轮两项搜索性能改造 + 顺带抓出的一个真实运行时错误：
  ① DataManager.get_heroes6() 缓存：两次调用须返回同一实例（原来每次
     遍历 825 条表重建数组）；且过滤语义不能被缓存改错（不含占位/模板/空名）。
  ② hero_dex 输入去抖（SEARCH_DEBOUNCE=0.22s）：连打多字只触发一次列表
     重建；去抖窗口内清空旧结果并提示「筛选中」；窗口过后出正确结果；
     回车提交立即出结果不等窗口。
  ③【探针首跑就抓到的真错误】`_on_search_changed` 里对 `_list`（VBoxContainer，
     Container 节点）调了 `is_empty()`——那是 Array 的方法，真实玩家一打字
     就报 "Nonexistent function 'is_empty' in base 'VBoxContainer'"。
     编译期抓不到，只有真跑才现形。这正是本校验存在的意义。

与其它 _verify_*.py 同套：真实引擎跑，结果落 hero_dex_search_result.txt，
并从引擎 stderr 抓真实 WARNING/ERROR（过滤 headless 良性告警）。

判据：
    - 探针产出 hero_dex_search_result.txt 且含 HERO_DEX_SEARCH=PASS
    - 缓存实测条数 > 0 且 < 原始表条数（证明既没滤光也没忘了过滤）
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
SCENE = "res://tests/hero_dex_search_probe.tscn"
RESULT_FILE = os.path.join(ROOT, "hero_dex_search_result.txt")

BENIGN_SUBSTR = [
    "audiodriver", "audioserver", "servers/audio",
    "vulkan", "opengl", "glcomp", "renderingdevice",
    "display server", "x11", "wayland", "egl", "gles",
    "context", "unable to create", "could not open", "couldn't open",
    "textserver", "font", "fallback", "no cache file",
    "servers/display", "scene/main/window", "drivers",
    "resources still in use", "resource still in use", "objectdb", "leaked",
    # 本工程已知的良性告警：程序化占位音效缺失回退
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
        print("[SKIP] 未找到 Godot 可执行文件，跳人物志搜索校验")
        return 0

    print("人物志搜索响应性校验（headless --verbose，抓引擎 WARNING/ERROR）")
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
        print("[FAIL] 人物志搜索校验超时（180s）")
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
        if (ln.startswith("[FAIL]") or ln.startswith("HERO_DEX_SEARCH=")
                or ln.startswith("失败项") or "：" in ln or "true" in ln or "false" in ln):
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

    ok = any(ln.startswith("HERO_DEX_SEARCH=PASS") for ln in rlines)
    if not ok:
        print("[FAIL] 人物志搜索探针自身未 PASS")
        return 1

    # 覆盖度闸门：过滤后条数必须落在 (0, 原始表) 区间
    n_cached = 0
    n_raw = 0
    for ln in rlines:
        m = re.search(r"原始表\s+(\d+)\s+条\s+→\s+过滤后\s+(\d+)", ln)
        if m:
            n_raw = int(m.group(1))
            n_cached = int(m.group(2))
            break
    if not n_cached or n_cached >= n_raw:
        print("[FAIL] 缓存条数异常：原始 %d → 过滤后 %d（须 0 < 后者 < 前者）"
              % (n_raw, n_cached))
        return 1

    if real:
        print("[FAIL] 发现 %d 条真实运行时 WARNING/ERROR" % len(real))
        return 1

    print("人物志搜索校验通过 ✅（缓存命中 %d/%d 条且过滤语义正确、"
          "连打合并为一次重建、去抖窗口内提示筛选中、回车立即出结果，"
          "运行时零真实告警）" % (n_cached, n_raw))
    return 0


if __name__ == "__main__":
    sys.exit(main())

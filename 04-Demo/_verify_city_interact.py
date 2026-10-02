# -*- coding: utf-8 -*-
"""大地图城池交互判定 · 几何等价性校验：Godot 真跑 tests/city_interact_probe.tscn。

覆盖第五十五轮两项每帧性能改造：
  ① 交互半径预计算：原 _place_radius 每帧对全部 110 个 marker 做 4 次 get_meta
     （其中 city_data 取出整个城池字典）→ 约 440 次元数据查询/帧。
     现改为 _create_marker 时算好落 "place_radius" meta，_place_radius 退化为 O(1) 读取。
  ② 平方距离粗筛：原 _find_nearest_place 每帧对 110 个 marker 各做一次
     distance_to 开方 → 110 次开方/帧。现改为 distance_squared_to + cutoff 平方阈值。
  ③ cull 仅变化才写：原 _cull_offscreen 每帧无条件写 110 次 visible + 110 次 scale
     （写同值也触发属性通知与重绘失效）。

**为什么必须真跑**：这三项都是几何/缓存判定，编译期完全无感，
写错方向不报错，只会让玩家「某个城突然进不去」「远处城老远就弹提示」
「marker 缩放不生效」——都是玩家可见但不崩不报的问题。
探针做三件事：
  A. 逐城比对新旧两套半径算式（110 城必须逐个相等）；
  A2. 独立核对上游源码：place_radius meta 是否真的落、_place_radius 是否真的
     退化为读 meta、等级加成与 capital 兜底是否被重构丢掉。
     （若只让探针自测，新旧两套都照抄改造后版本，上游改错反而放过。）
  B. 14.5 万次判定比对平方粗筛与原开方判定的接受集合（含边界 ±0.5/±1px 加密
     采样，专抓等号附近漏判），并独立核对上游确实用了 distance_squared_to。
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
SCENE = "res://tests/city_interact_probe.tscn"
RESULT_FILE = os.path.join(ROOT, "city_interact_result.txt")
TARGET = os.path.join(ROOT, "scripts", "world", "world_map.gd")

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
    # 本工程已知良性告警：RID 泄漏 / 退出期析构（headless 退出必报）
    "rid allocations", "unreferenced static string", "thread object is being destroyed",
    "pages in use exist at exit",
]

ALERT_RE = re.compile(r"(?:^|\s)(WARNING|SCRIPT ERROR|ERROR)\s*:", re.IGNORECASE)


def _is_benign(line: str) -> bool:
    low = line.lower()
    return any(b in low for b in BENIGN_SUBSTR)


def _strip_comments(src: str) -> str:
    out = []
    for line in src.split("\n"):
        s = line.lstrip()
        if s.startswith("#"):
            out.append("")
            continue
        i = line.find("#")
        out.append(line[:i] if i >= 0 else line)
    return "\n".join(out)


def _static_checks() -> list:
    """静态层：确保优化真的落到源码里，而不是只写在注释里。"""
    fails = []
    if not os.path.isfile(TARGET):
        return ["world_map.gd 缺失"]
    with open(TARGET, encoding="utf-8", errors="replace") as f:
        src = _strip_comments(f.read())

    if 'set_meta("place_radius"' not in src:
        fails.append("_create_marker 未落 place_radius meta（半径仍每帧重算）")

    i = src.find("func _place_radius")
    if i < 0:
        fails.append("缺少 _place_radius")
    else:
        body = src[i:src.find("\nfunc ", i + 1) if src.find("\nfunc ", i + 1) > 0 else len(src)]
        if 'get_meta("place_radius"' not in body:
            fails.append("_place_radius 未读 place_radius meta，优化被绕过")
        if 'get_meta("city_data"' in body:
            fails.append("_place_radius 仍读 city_data，每帧取出整个城池字典")
        if "PLACE_LEVEL_STEP" in body:
            fails.append("_place_radius 仍含等级加成计算，未退化为纯读取")

    i = src.find("func _compute_place_radius")
    if i < 0:
        fails.append("缺少 _compute_place_radius（创建期算半径）")
    else:
        body = src[i:src.find("\nfunc ", i + 1) if src.find("\nfunc ", i + 1) > 0 else len(src)]
        if "PLACE_LEVEL_STEP" not in body:
            fails.append("_compute_place_radius 丢了等级半径加成（高等级城交互范围会缩小）")
        if "capital" not in body:
            fails.append("_compute_place_radius 丢了 capital 兜底（都城交互范围会缩小）")

    i = src.find("func _find_nearest_place")
    if i < 0:
        fails.append("缺少 _find_nearest_place")
    else:
        body = src[i:src.find("\nfunc ", i + 1) if src.find("\nfunc ", i + 1) > 0 else len(src)]
        if "distance_squared_to" not in body:
            fails.append("_find_nearest_place 未用平方距离粗筛（110 次开方/帧仍在）")
        if "cutoff" not in body:
            fails.append("_find_nearest_place 缺少 cutoff 平方阈值变量")
        # 平方粗筛后必须仍然开方一次给下游用（best_dist / score 依赖真实距离）
        if "sqrt(" not in body:
            fails.append("_find_nearest_place 粗筛后未对命中项开方还原真实距离，"
                         "best_dist/score 量纲会错")

    i = src.find("func _cull_offscreen")
    if i < 0:
        fails.append("缺少 _cull_offscreen")
    else:
        body = src[i:src.find("\nfunc ", i + 1) if src.find("\nfunc ", i + 1) > 0 else len(src)]
        if "nd.visible != vis" not in body:
            fails.append("_cull_offscreen 的 visible 未做「仅变化才写」判定")
        if "is_equal_approx(want)" not in body:
            fails.append("_cull_offscreen 的 scale 未做「仅变化才写」判定")

    return fails


def main() -> int:
    static_fail = _static_checks()
    if static_fail:
        print("[FAIL] 静态层核对未通过：")
        for m in static_fail:
            print("       - " + m)
        return 1
    print("  静态层通过（半径已预计算落 meta、粗筛用平方距离、cull 仅变化才写）")

    godot = next((g for g in GODOT_CANDIDATES if os.path.exists(g)), None)
    if godot is None:
        print("[SKIP] 未找到 Godot 可执行文件，跳城池交互校验")
        return 0

    print("大地图城池交互判定校验（headless --verbose，抓引擎 WARNING/ERROR）")
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
        print("[FAIL] 城池交互校验超时（240s）")
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

    if not any(ln.startswith("CITY_INTERACT_PASS") for ln in rlines):
        print("[FAIL] 城池交互探针自身未 PASS")
        return 1

    # ---- 覆盖度闸门：数字必须真的达到量级，否则等于没测 ----
    n_city = 0
    n_total = 0
    n_hit = 0
    for ln in rlines:
        m = re.search(r"半径比对 城数=(\d+) 不等=(\d+)", ln)
        if m:
            n_city = int(m.group(1))
        m = re.search(r"粗筛比对 判定总数=(\d+) 通过数=(\d+) 不等=(\d+)", ln)
        if m:
            n_total = int(m.group(1))
            n_hit = int(m.group(2))

    # 锚定层标记必须真实出现（探针若整体跳过某段，仍会 PASS —— 靠这两个标记兜底）
    if not any(ln.startswith("A_RADIUS_EQUIV=OK") for ln in rlines):
        print("[FAIL] 探针未输出 A_RADIUS_EQUIV=OK —— 半径等价段可能未执行")
        return 1
    if not any(ln.startswith("B_FILTER_EQUIV=OK") for ln in rlines):
        print("[FAIL] 探针未输出 B_FILTER_EQUIV=OK —— 粗筛等价段可能未执行")
        return 1

    if n_city < 100:
        print("[FAIL] 半径比对样本不足：%d 城（须 ≥100）" % n_city)
        return 1
    if n_total < 100000:
        print("[FAIL] 粗筛比对判定数不足：%d（须 ≥100000）" % n_total)
        return 1
    if n_hit < 100:
        print("[FAIL] 粗筛比对中命中数过少：%d（须 ≥100）—— 全被拦掉等于没验证接受集合"
              % n_hit)
        return 1

    if real:
        print("[FAIL] 发现 %d 条真实运行时 WARNING/ERROR" % len(real))
        return 1

    print("城池交互判定校验通过 ✅（%d 城半径逐个相等；%d 次判定（含边界 ±0.5/±1px "
          "加密采样）接受集合完全一致、其中命中 %d 次；上游平方粗筛与 cull 仅变化"
          "才写均已核对；运行时零真实告警）" % (n_city, n_total, n_hit))
    return 0


if __name__ == "__main__":
    sys.exit(main())
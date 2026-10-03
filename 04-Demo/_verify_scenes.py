# -*- coding: utf-8 -*-
"""场景完整性校验：用 Godot 真 load() 全工程所有 .tscn，锁「场景引用闭合」不变量。

与 _compile_check.py 分工：
    _compile_check.py —— 只看 .gd 能否编译（语法 / 类型 / 引用）
    _verify_scenes.py —— 看 .tscn 能否加载且可实例化（外部资源闭合）
                         专抓「脚本改名/移动后 .tscn 仍指向旧 ExtResource」这类
                         编译期完全抓不到、运行时才爆发的破坏。

结果由探针写 res://scene_integrity_result.txt（Windows 控制台编码兜底），
本脚本只读该文件判定成败。
"""
import os
import subprocess
import sys
import _safe_cleanup

ROOT = os.path.dirname(os.path.abspath(__file__))
GODOT_CANDIDATES = [
    r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe",
    r"D:\Godot\Godot_v4.7.2-stable_win64.exe",
]
SCENE = "res://tests/scene_integrity_probe.tscn"
RESULT_FILE = os.path.join(ROOT, "scene_integrity_result.txt")

godot = next((g for g in GODOT_CANDIDATES if os.path.exists(g)), None)
if godot is None:
    print("[SKIP] 未找到 Godot 可执行文件，跳过场景完整性校验")
    sys.exit(0)

print("场景完整性校验（headless 真 load() 全工程 .tscn）")
print("  探针：%s" % SCENE)

if os.path.exists(RESULT_FILE):
    _safe_cleanup.discard(RESULT_FILE)

p = subprocess.run([godot, "--headless", "--path", ROOT, SCENE],
                   cwd=ROOT, capture_output=True, text=True,
                   encoding="utf-8", errors="replace", timeout=240)

if not os.path.exists(RESULT_FILE):
    print("[FAIL] 探针未产出结果文件（可能脚本编译失败或场景加载即崩）")
    tail = (p.stdout or "") + (p.stderr or "")
    for line in tail.strip().splitlines()[-20:]:
        print("       " + line)
    sys.exit(1)

with open(RESULT_FILE, encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()

for ln in lines:
    print(ln)

fails = [ln for ln in lines if "[FAIL]" in ln]
ok = any(ln.startswith("SCENE_INTEGRITY=PASS") for ln in lines)

print("")
if fails or not ok:
    print("[FAIL] 场景完整性校验 %d 个场景加载/实例化失败" % len(fails))
    sys.exit(1)
print("场景完整性校验全部通过 ✅（全工程 .tscn 引用闭合，无悬空 ExtResource）")
sys.exit(0)

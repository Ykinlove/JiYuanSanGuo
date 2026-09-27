# -*- coding: utf-8 -*-
"""运行时探针：用 Godot 真跑一遍 tests/probe_runner.tscn，断言规则层/状态层行为。

与 _compile_check.py 的分工：
    _compile_check.py —— 只看「能不能编译」（语法 / 类型 / 引用）
    _run_probe.py     —— 看「跑起来对不对」（数值判定 / 状态流转 / 解锁接线）

【为什么必须挂场景跑】--script 模式下引擎不注册 autoload，主脚本在注册之前就编译，
凡引用 DataManager / GameState 的服务层脚本都会编译失败并退化成裸 GDScript，
断言于是静默假阴性（成就探针 7 项 FAIL 就是这个坑）。挂场景跑则由引擎按
project.godot 正常注册 autoload，断言才有意义。

探针结果由脚本自身写 res://probe_result.txt（Windows 控制台版 Godot 的 stdout
在管道里编码常被搅乱，不能依赖终端输出），本脚本只读该文件判定成败。
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
GODOT_CANDIDATES = [
    r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe",
    r"D:\Godot\Godot_v4.7.2-stable_win64.exe",
]
SCENE = "res://tests/probe_runner.tscn"
RESULT_FILE = os.path.join(ROOT, "probe_result.txt")

godot = next((g for g in GODOT_CANDIDATES if os.path.exists(g)), None)
if godot is None:
    print("[SKIP] 未找到 Godot 可执行文件，跳过运行时探针")
    print("       请修改本脚本顶部的 GODOT_CANDIDATES 路径")
    sys.exit(0)

print("运行时探针（场景式 harness，真实 autoload 环境）")
print("  场景：%s" % SCENE)

if os.path.exists(RESULT_FILE):
    os.remove(RESULT_FILE)

p = subprocess.run([godot, "--headless", "--path", ROOT, SCENE],
                   cwd=ROOT, capture_output=True, text=True,
                   encoding="utf-8", errors="replace", timeout=180)

if not os.path.exists(RESULT_FILE):
    print("[FAIL] 探针未产出结果文件（可能脚本编译失败或场景未跑起来）")
    tail = (p.stdout or "") + (p.stderr or "")
    for line in tail.strip().splitlines()[-20:]:
        print("       " + line)
    sys.exit(1)

with open(RESULT_FILE, encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()

for ln in lines:
    print(ln)

fails = [ln for ln in lines if "[FAIL]" in ln]
ok = any(ln.startswith("PROBE_RESULT=PASS") for ln in lines)

print("")
if fails or not ok:
    print("[FAIL] 运行时探针 %d 项未通过" % len(fails))
    sys.exit(1)
print("运行时探针全部通过 ✅")
sys.exit(0)

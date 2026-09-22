# -*- coding: utf-8 -*-
"""用 Godot 本身编译全部 GDScript 脚本，捕获真实的编译/解析错误。

这是最可靠的检查方式 —— 不靠正则猜，直接让引擎告诉我们能不能跑。

原理：
  临时生成一个 .gd 脚本，用 load() 逐个加载工程内所有 .gd 文件，
  Godot 会真实编译它们，任何 Parse Error / Compile Error 都会打印出来。

注意：
  必须用 --headless --script 模式，且此时 autoload 单例不可用，
  会产生 "Identifier not found: GameState" 之类的**假错误** ——
  这些需要被过滤掉（它们不是语法/类型问题）。
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

godot = next((g for g in GODOT_CANDIDATES if os.path.exists(g)), None)
if godot is None:
    print("[SKIP] 未找到 Godot 可执行文件，跳过实际编译检查")
    print("       请修改本脚本顶部的 GODOT_CANDIDATES 路径")
    sys.exit(0)

# ---- 收集所有脚本 ----
scripts = []
for dp, _d, fs in os.walk(os.path.join(ROOT, "scripts")):
    for f in fs:
        if f.endswith(".gd"):
            rel = os.path.relpath(os.path.join(dp, f), ROOT).replace("\\", "/")
            scripts.append(rel)
scripts.sort()

probe = '''@tool
extends SceneTree
func _init() -> void:
\tvar targets := %s
\tfor t in targets:
\t\tvar r = load("res://" + t)
\t\tif r == null:
\t\t\tprint("CANNOT_LOAD=", t)
\t\telse:
\t\t\tprint("LOADED=", t)
\tprint("COMPILE_SCAN_DONE")
\tquit()
''' % (str(scripts).replace("'", '"'))

probe_path = os.path.join(ROOT, "_compile_probe.gd")
with open(probe_path, "w", encoding="utf-8") as fh:
    fh.write(probe)

try:
    proc = subprocess.run(
        [godot, "--headless", "--script", "res://_compile_probe.gd"],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
        errors="replace", timeout=180)
    out = (proc.stdout or "") + (proc.stderr or "")
finally:
    pass

# ---- 过滤 autoload 假错误 ----
AUTOLOADS = ["GameState", "EventBus", "DataManager", "SaveManager",
             "AudioManager", "SceneRouter"]
real_errors = []
for line in out.split("\n"):
    s = line.strip()
    if not s:
        continue
    is_err = ("SCRIPT ERROR" in s or "Parse Error" in s
              or "Compile Error" in s or "Parse error" in s)
    if not is_err:
        continue
    # 过滤：仅因 autoload 缺失导致的 "Identifier not found"
    if "Identifier not found:" in s:
        ident = s.split("Identifier not found:")[-1].strip()
        if ident in AUTOLOADS:
            continue
    # 过滤：autoload 缺失的级联消息（被依赖脚本编译失败的转述，无独立定位信息；
    # 真正的语法/类型错误都会带自己的 Parse/Compile Error 行）
    if "Failed to compile depended scripts" in s:
        continue
    real_errors.append(s)

loaded = [l for l in out.split("\n") if l.startswith("LOADED=")]
failed = [l for l in out.split("\n") if l.startswith("CANNOT_LOAD=")]

print("=" * 62)
print("Godot 实际编译检查")
print("=" * 62)
print("  尝试加载脚本：%d 个" % len(scripts))
print("  成功加载：%d 个" % len(loaded))
print("  加载失败：%d 个" % len(failed))
for f in failed:
    print("      " + f)

print()
if real_errors:
    print("[ERROR] 真实编译错误 %d 条：" % len(real_errors))
    seen = set()
    for e in real_errors:
        if e in seen:
            continue
        seen.add(e)
        print("  - " + e)
else:
    print("[OK] 无真实编译/解析错误")

# 清理
try:
    os.remove(probe_path)
except OSError:
    pass

sys.exit(1 if real_errors or failed else 0)

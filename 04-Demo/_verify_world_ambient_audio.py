# -*- coding: utf-8 -*-
"""三十一轮 大地图环境音层 静态复核（风声循环/昼夜联动鸟鸣虫鸣/合成安全/轨位）"""
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(ROOT, "scripts", "world", "world_ambient_audio.gd")
WMAP = os.path.join(ROOT, "scripts", "world", "world_map.gd")

passes, fails = [], []


def check(name, cond):
    if cond:
        passes.append(name)
    else:
        fails.append(name)


check("A1 环境音脚本在位", os.path.exists(SCRIPT))
src = ""
if os.path.exists(SCRIPT):
    with open(SCRIPT, "r", encoding="utf-8") as f:
        src = f.read()
wmap = ""
if os.path.exists(WMAP):
    with open(WMAP, "r", encoding="utf-8") as f:
        wmap = f.read()

# ---- A. 接线 ----
check("A2 world_map 实例化 WorldAmbientAudio", "WorldAmbientAudio.new()" in wmap)
check("A3 注入 WorldClock（昼夜联动）", "amb_audio.setup($WorldClock)" in wmap)
check("A4 class_name 已注册（类缓存已刷）", "class_name WorldAmbientAudio" in src)

# ---- B. 风声循环 ----
check("B1 程序化风声合成 _make_wind", "_make_wind" in src and "randf_range" in src)
check("B2 一阶低通粉噪（a 系数累积）", "lp += a *" in src)
check("B3 整周期包络（循环点连续）",
      "TAU * 2.0 * t / WIND_DUR" in src and "TAU * 3.0 * t / WIND_DUR" in src)
check("B4 环形交叉淡化（噪声首尾无缝）",
      "buf[n - xw + k] = buf[n - xw + k] * (1.0 - w) + head * w" in src)
check("B5 循环模式 LOOP_FORWARD", "LOOP_FORWARD" in src and "_encode_wav(buf, true)" in src)

# ---- C. 昼夜联动 ----
check("C1 相位源 day_fraction（与 DayNightTint 同源）", "day_fraction()" in src)
check("C2 白天相位区间常量", "DAY_PHASE_LO" in src and "DAY_PHASE_HI" in src)
check("C3 昼鸟鸣/夜虫鸣双分支", "_play_bird" in src and "_play_cricket" in src and "_is_day" in src)
check("C4 触发间隔常量（防连续轰炸）",
      "BIRD_INTERVAL" in src and "CRICKET_INTERVAL" in src)
check("C5 时钟缺失兜底（按白天不报错）",
      "is_instance_valid(clock)" in src and "return true" in src)

# ---- D. 合成与混音安全 ----
check("D1 16bit 编码削波保护 clampf",
      "encode_s16" in src and "clampf(samples[i], -1.0, 1.0)" in src)
check("D2 走 BGM 轨（随背景音量缩放）", 'bus = "BGM"' in src)
check("D3 自身音量压低不抢音乐", "WIND_DB" in src and "BIRD_DB" in src)
check("D4 发声器池（复用不叠加爆音）", "CALL_PLAYERS" in src and "_pick_caller" in src)
check("D5 鸟鸣随机音高/音量（防复读机感）",
      "pitch_scale = randf_range" in src and "volume_db = BIRD_DB + randf_range" in src)

# ---- E. 探针在位 ----
check("E1 运行时探针场景在位",
      os.path.exists(os.path.join(ROOT, "tests", "ambient_audio_probe.tscn")))
check("E2 _process 只做倒计时（无每帧合成）",
      "_next_call -= delta" in src and src.count("for i in range(n)") <= 3)

print("=" * 50)
print("大地图环境音层校验")
print("=" * 50)
for p in passes:
    print("  [PASS] %s" % p)
for f_ in fails:
    print("  [FAIL] %s" % f_)
print("-" * 50)
print("通过 %d / %d" % (len(passes), len(passes) + len(fails)))
sys.exit(1 if fails else 0)

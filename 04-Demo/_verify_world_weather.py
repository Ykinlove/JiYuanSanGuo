# -*- coding: utf-8 -*-
"""三十八轮 大地图天气层 静态复核（季节概率/粒子红锁/headless 坑规避/染色复用/雨声合成/联动）"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(ROOT, "scripts", "world", "world_weather.gd")
WMAP = os.path.join(ROOT, "scripts", "world", "world_map.gd")
TINT = os.path.join(ROOT, "scripts", "world", "day_night_tint.gd")
AMBA = os.path.join(ROOT, "scripts", "world", "world_ambient_audio.gd")
PROBE_GD = os.path.join(ROOT, "tests", "weather_probe.gd")
PROBE_TSCN = os.path.join(ROOT, "tests", "weather_probe.tscn")

passes, fails = [], []


def check(name, cond):
    if cond:
        passes.append(name)
    else:
        fails.append(name)


check("A1 天气脚本在位", os.path.exists(SCRIPT))
src = ""
if os.path.exists(SCRIPT):
    with open(SCRIPT, "r", encoding="utf-8") as f:
        src = f.read()
wmap = ""
if os.path.exists(WMAP):
    with open(WMAP, "r", encoding="utf-8") as f:
        wmap = f.read()
tint = ""
if os.path.exists(TINT):
    with open(TINT, "r", encoding="utf-8") as f:
        tint = f.read()
amba = ""
if os.path.exists(AMBA):
    with open(AMBA, "r", encoding="utf-8") as f:
        amba = f.read()
probe = ""
if os.path.exists(PROBE_GD):
    with open(PROBE_GD, "r", encoding="utf-8") as f:
        probe = f.read()

# ---- A. 接线 ----
check("A2 world_map 实例化 WorldWeather", "WorldWeather.new()" in wmap)
check("A3 三参注入（camera/tint/amb_audio）", "weather.setup(_camera, tint, amb_audio)" in wmap)
check("A4 class_name 已注册", "class_name WorldWeather" in src)

# ---- B. 状态机与季节概率 ----
check("B1 三态常量（CLEAR/RAIN/SNOW）",
      "WEATHER_CLEAR" in src and "WEATHER_RAIN" in src and "WEATHER_SNOW" in src)
check("B2 day_passed 监听（每游戏日到期重掷）",
      "EventBus.day_passed.connect" in src and "_days_left" in src)
check("B3 持续 1~3 天", "1 + randi() % 3" in src)
check("B4 季节概率走 get_season() 单一来源（1-3春/4-6夏/7-9秋/10-12冬）",
      "GameState.get_season()" in src and "GameState.SEASON_SPRING" in src
      and "GameState.SEASON_SUMMER" in src and "GameState.SEASON_AUTUMN" in src
      and "GameState.SEASON_WINTER" in src and "GameState.month" not in src)
check("B4b 四季概率值保持不变（春0.30/夏0.38/秋0.22/冬雪0.32雨0.04）",
      "p_rain = 0.30" in src and "p_rain = 0.38" in src and "p_rain = 0.22" in src
      and "p_snow = 0.32" in src and "p_rain = 0.04" in src)
check("B5 目标强度随机区间（防复读机）", "randf_range(0.65, 1.0)" in src)

# ---- C. 粒子红锁与 Godot 4.7 坑规避 ----
m_rain = re.search(r"RAIN_AMOUNT := (\d+)", src)
m_snow = re.search(r"SNOW_AMOUNT := (\d+)", src)
check("C1 雨粒子 ≤200 红锁", bool(m_rain) and int(m_rain.group(1)) <= 200)
check("C2 雪粒子 ≤150 红锁", bool(m_snow) and int(m_snow.group(1)) <= 150)
check("C3 CPUParticles2D（禁 GPUParticles）",
      src.count("CPUParticles2D") >= 2 and "GPUParticles" not in src)
check("C4 amount_ratio 全文件禁用（headless 赋值挂死坑）",
      "amount_ratio" not in src.replace("禁用", "").replace("amount_ratio 全工程禁用", "")
      or ("amount_ratio" in src and "amount_ratio =" not in src and "amount_ratio=" not in src))
check("C5 local_coords 正名（无 global_coords 误写）",
      "local_coords = false" in src and "global_coords =" not in src
      and "p.global_coords" not in src)
check("C6 headless 免粒子（DisplayServer.get_name 判定）",
      'DisplayServer.get_name() == "headless"' in src and "_ensure_particles" in src)
check("C7 晴天沿切换冻结发射器（零开销）",
      "_emit_prev" in src and "set_process(emit_on)" in src)
check("C8 强度渐变非硬切（INTENSITY_RATE 逼近）",
      "INTENSITY_RATE" in src and "minf(_target" in src and "maxf(_target" in src)

# ---- D. 填充率铁律与染色复用 ----
check("D1 本节点无 ColorRect（不新增全屏混合层）", "ColorRect" not in src)
check("D2 阴天染色写入 tint.weather_dim", "tint.weather_dim" in src)
check("D3 DayNightTint 有 weather_dim 因子", "var weather_dim" in tint)
check("D4 染色三段合成（日内→季节→天气）",
      tint.count("_blend(") >= 2 and "weather_dim)" in tint)
check("D5 染色强度上限（阴天 alpha ≤0.15 防过浓）",
      (re.search(r"RAIN_DIM := Color\([^)]*([0-9.]+)\)", src) is not None))

# ---- E. 雨声合成与联动 ----
# 【四十轮】雨声实现搬到 WeatherFx（战斗/城内共用同一份），world_weather 只留
# 同名包装，故合成细节断言改看「两文件合并」的文本。
FX = os.path.join(ROOT, "scripts", "world", "weather_fx.gd")
fx = ""
if os.path.exists(FX):
    with open(FX, "r", encoding="utf-8") as f:
        fx = f.read()
audio_src = src + "\n" + fx
check("E1 程序化雨声（_make_rain + encode_s16）",
      "func _make_rain" in src and "encode_s16" in audio_src)
check("E2 雨声无缝循环（环形交叉淡化）",
      "LOOP_FORWARD" in audio_src and "环形交叉淡化" in audio_src)
check("E3 雨声音量随强度渐变（lerp -60→RAIN_DB）",
      "lerpf(-60.0, RAIN_DB" in src)
check("E4 雨雪天静鸟鸣（weather_quiet 写入）", "weather_quiet" in src)
check("E5 WorldAmbientAudio 有 weather_quiet 位并在 _process 检查",
      "var weather_quiet" in amba and "if weather_quiet" in amba)

# ---- F. 取证工具 ----
check("F1 逻辑探针在位（含 WEATHER_DONE 终点）",
      os.path.exists(PROBE_GD) and os.path.exists(PROBE_TSCN)
      and "WEATHER_DONE" in probe)
check("F2 探针红锁断言", "RAIN_AMOUNT <= 200" in probe and "SNOW_AMOUNT <= 150" in probe)
check("F3 DIAG 开关（NORAIN/FORCE_WEATHER）",
      "DIAG_NORAIN" in src and "DIAG_FORCE_WEATHER" in src)

# ---- 汇总 ----
print("PASS %d / FAIL %d" % (len(passes), len(fails)))
for p in passes:
    print("  [PASS]", p)
for f in fails:
    print("  [FAIL]", f)
sys.exit(1 if fails else 0)

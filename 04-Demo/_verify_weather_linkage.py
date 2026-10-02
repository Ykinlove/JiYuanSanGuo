# -*- coding: utf-8 -*-
"""四十轮 天气×场景联动 静态复核（事实层 GameState / 演出层 WeatherFx / 战斗+城内接线）"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))

FX = os.path.join(ROOT, "scripts", "world", "weather_fx.gd")
WX = os.path.join(ROOT, "scripts", "world", "world_weather.gd")
GS = os.path.join(ROOT, "scripts", "autoload", "game_state.gd")
CLOCK = os.path.join(ROOT, "scripts", "world", "world_clock.gd")
BATTLE = os.path.join(ROOT, "scripts", "battle", "battle_scene.gd")
CITY = os.path.join(ROOT, "scripts", "city", "city_scene.gd")
PROBE_GD = os.path.join(ROOT, "tests", "weather_linkage_probe.gd")
PROBE_TSCN = os.path.join(ROOT, "tests", "weather_linkage_probe.tscn")

passes, fails = [], []


def check(name, cond):
    if cond:
        passes.append(name)
    else:
        fails.append(name)


def read(path):
    if not os.path.exists(path):
        return ""
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


fx = read(FX)
wx = read(WX)
gs = read(GS)
clock = read(CLOCK)
battle = read(BATTLE)
city = read(CITY)
probe = read(PROBE_GD)

# ---- A. 事实层：天气/时辰落在 GameState（跨场景唯一来源） ----
check("A1 WeatherFx 在位并注册 class_name",
      os.path.exists(FX) and "class_name WeatherFx" in fx)
check("A2 GameState 四字段（weather_id/days_left/intensity/day_fraction）",
      all(k in gs for k in ["var weather_id", "var weather_days_left",
                            "var weather_intensity", "var day_fraction"]))
check("A3 存档往返（to_dict 写出 + from_dict 读回）",
      '"weather_id": weather_id' in gs and 'data.get("weather_id"' in gs
      and 'data.get("day_fraction"' in gs)
check("A4 WorldWeather 掷天气后写回 GameState",
      "GameState.weather_id = w" in wx and "GameState.weather_intensity = _target" in wx)
check("A5 WorldWeather 未到期续场（_restore_or_reroll 读 days_left）",
      "_restore_or_reroll" in wx and "GameState.weather_days_left > 0" in wx)
check("A6 过一天回写天数（未到期也写）",
      "GameState.weather_days_left = _days_left" in wx)
check("A7 WorldClock 每帧写 GameState.day_fraction",
      "GameState.day_fraction = clampf" in clock and "day_fraction()" in clock)

# ---- B. 演出层 WeatherFx ----
check("B1 雨雪粒子红锁（雨≤200 / 雪≤150，与 WorldWeather 同口径）",
      bool(re.search(r"RAIN_AMOUNT := (\d+)", fx))
      and int(re.search(r"RAIN_AMOUNT := (\d+)", fx).group(1)) <= 200
      and bool(re.search(r"SNOW_AMOUNT := (\d+)", fx))
      and int(re.search(r"SNOW_AMOUNT := (\d+)", fx).group(1)) <= 150)
check("B2 CPUParticles2D（禁 GPUParticles）",
      "CPUParticles2D" in fx and "GPUParticles" not in fx)
# 【按源码字面切段的老坑】注释里也会提到这两个属性名（说明为何禁用），
# 故只禁「赋值」而非「出现」。
check("B3 local_coords 正名（无 global_coords 赋值）",
      "local_coords = false" in fx and "global_coords =" not in fx
      and "p.global_coords" not in fx)
check("B4 amount_ratio 禁用（headless 赋值挂死坑）",
      "amount_ratio =" not in fx and "amount_ratio=" not in fx)
check("B5 headless 粒子恒 null（DisplayServer.get_name 判定）",
      'DisplayServer.get_name() == "headless"' in fx and "return null" in fx)
check("B6 雨声三场景共用一份（LOOP_FORWARD + encode_s16 + 环形交叉淡化）",
      "LOOP_FORWARD" in fx and "encode_s16" in fx and "环形交叉淡化" in fx)
check("B7 夜色系数跨日连续（端点 0.0 与 1.0 同值）",
      "0.55 * (1.0 - x / 0.12)" in fx and "1.0 - 0.45 *" in fx)
check("B8 雪地泛白层（仅在雪天建，鼠标穿透）",
      "build_snow_ground" in fx and "MOUSE_FILTER_IGNORE" in fx)

# ---- C. 战斗场景接线 ----
check("C1 _ready 调用 _build_weather_layer",
      "_build_weather_layer()" in battle and re.search(r"func _build_weather_layer", battle) is not None)
check("C2 雨天雨声（bus + 音量常量）",
      'a.bus = "BGM"' in battle and "WeatherFx.RAIN_DB_BATTLE" in battle)
check("C3 雪天地面泛白（插在 Player 之前，不盖单位）",
      "WeatherFx.build_snow_ground" in battle
      and re.search(r"move_child\(ground, \$Player\.get_index\(\)\)", battle) is not None)
check("C4 雨雪层走 WeatherFx.build_precip", "WeatherFx.build_precip" in battle)
check("C5 晴天零开销（CLEAR 直接 return）",
      re.search(r"if kind == WeatherFx\.CLEAR:\s*\n\s*return", battle) is not None)

# ---- D. 城内场景接线 ----
check("D1 灯火句柄收集（每帧重写 alpha）",
      "_lamps.append(lamp)" in city and "_lamps.clear()" in city
      and "_update_city_night" in city)
check("D2 灯火昼夜两档（白天灶烟 / 夜里灯笼）",
      "CITY_ATMOS_LAMP_ALPHA_DAY := 0.10" in city
      and "CITY_ATMOS_LAMP_ALPHA_NIGHT := 0.62" in city)
check("D3 夜色压暗层（插在灯火之前，不压玩家/NPC）",
      "NightVeil" in city and "_interior.move_child(_night_veil, _atmos.get_index())" in city)
check("D4 雨雪层跟随视野（_weather_screen + 每帧定位）",
      "_weather_screen" in city and "_weather_fx.position = _player.position" in city)
check("D5 _process 每帧驱动夜色",
      re.search(r"func _process\([^)]*\) -> void:\s*\n\s*# 【四十轮】", city) is not None)
check("D6 城内雨声（独立音量档）",
      "WeatherFx.RAIN_DB_CITY" in city)

# ---- E. 取证 ----
check("E1 联动探针在位（含 WEATHER_LINKAGE_DONE 终点）",
      os.path.exists(PROBE_GD) and os.path.exists(PROBE_TSCN)
      and "WEATHER_LINKAGE_DONE" in probe)
check("E2 探针覆盖七项断言",
      all(k in probe for k in ["ok_write", "ok_read", "ok_restore", "ok_expire",
                               "ok_day", "ok_fx", "ok_night", "ok_rain"]))

# ---- 汇总 ----
print("PASS %d / FAIL %d" % (len(passes), len(fails)))
for p in passes:
    print("  [PASS]", p)
for f in fails:
    print("  [FAIL]", f)
sys.exit(1 if fails else 0)

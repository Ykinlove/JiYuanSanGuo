# -*- coding: utf-8 -*-
"""大地图史诗感（第十七轮续·二）· 接线静态复核

锁定「世界事件横幅 + 昼夜时辰氛围」两组纯演出层接线，防止后人改回：

  E1 日内相位源：WorldClock 暴露 day_fraction()（只读演出，不参与规则结算）
  E2 氛围层：DayNightTint 全屏染色、压 $UI 最底层（只染地图不盖 HUD）、
     日内四段插值 + 季节色偏、不吞点击
  E3 横幅层：WorldEventBanner 四类事件方法绑定连接（铁律禁 lambda）、
     队列播放防刷屏、不吞点击、居中容器配 grow BOTH
  E4 世界场景接线：world_map._ready 实例化两层并注入时钟
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CLOCK = os.path.join(HERE, "scripts", "world", "world_clock.gd")
TINT = os.path.join(HERE, "scripts", "world", "day_night_tint.gd")
BANNER = os.path.join(HERE, "scripts", "ui", "world_event_banner.gd")
MAP = os.path.join(HERE, "scripts", "world", "world_map.gd")

results = []


def check(name, ok, detail):
    results.append((name, ok, detail))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def func_body(src, sig):
    i = src.find(sig)
    if i < 0:
        return ""
    j = src.find("\nfunc ", i + 1)
    if j < 0:
        j = len(src)
    return src[i:j]


print("=" * 68)
print("大地图史诗感 · 接线静态复核")
print("=" * 68)

ck = read(CLOCK)
tn = read(TINT)
bn = read(BANNER)
mp = read(MAP)

# ---------- E1 日内相位源 ----------
print("\n[E1] WorldClock.day_fraction()")
check("day_fraction() 已实现", bool(re.search(r"func day_fraction\(\) -> float", ck)), "已定义")
df = func_body(ck, "func day_fraction()")
# 【四十轮】日内相位改成两段：_process 里算好 0..1 并快照写 GameState
# （进城/战斗时时钟暂停，演出层读的是"进入那一刻的时辰"），day_fraction() 只做返回。
proc = func_body(ck, "func _process(delta: float)")
check("相位取自日内累加器（快照写 GameState，跨场景可读）",
      "_accumulator" in proc and "seconds_per_day" in proc
      and "GameState.day_fraction =" in proc, "0..1 归一 + 跨场景快照")
check("相位 clamp 到 0..1", "clampf(" in df, "越界防护")

# ---------- E2 昼夜氛围层 ----------
print("\n[E2] DayNightTint 昼夜氛围层")
check("class_name DayNightTint", "class_name DayNightTint" in tn, "可被 world_map 引用")
check("基于 ColorRect 全屏染色", tn.strip().startswith("extends ColorRect"), "纯演出零资源")
check("日内四段关键帧（首尾衔接）", "const DAY_KEYS" in tn and tn.count("Color(") >= 6,
      "拂晓/清晨/白昼/黄昏/夜/回环")
check("读取 day_fraction 相位", "day_fraction()" in tn, "与世界时钟同源")
check("季节色偏（按月）", "GameState.month" in tn and "_season_color" in tn, "春青/秋金/冬霜蓝")
check("两层染色 over 合成", "_blend(" in tn, "近似大气叠色")
check("全屏锚点用 set_anchors_and_offsets_preset", "set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)" in tn,
      "铁律写法")
check("不吞点击", "MOUSE_FILTER_IGNORE" in tn, "鼠标过滤已设")

# ---------- E3 世界事件横幅 ----------
print("\n[E3] WorldEventBanner 世界事件横幅")
check("class_name WorldEventBanner", "class_name WorldEventBanner" in bn, "可被 world_map 引用")
for sig, fn in [
    ("city_captured", "_on_city_captured"),
    ("city_lost", "_on_city_lost"),
    ("hero_recruited", "_on_hero_recruited"),
    ("prisoner_captured", "_on_prisoner_captured"),
]:
    check("信号 %s 方法绑定连接" % sig, "EventBus.%s.connect(%s)" % (sig, fn) in bn,
          "铁律：autoload 信号禁 lambda")
rdy = func_body(bn, "func _ready()")
check("连接集中在 _ready", rdy.count(".connect(_on_") == 4, "场景释放自动断连")
check("队列播放防刷屏", "const QUEUE_MAX" in bn and "_queue.pop_front()" in bn, "上限丢弃溢出")
check("淡入/停留/淡出/回收", "FADE_IN" in bn and "FADE_OUT" in bn and "queue_free" in bn,
      "tween 三段")
check("横幅不吞点击", "MOUSE_FILTER_IGNORE" in bn, "鼠标过滤已设")
vb = func_body(bn, "func _show_banner(")
check("居中容器配 grow BOTH（铁律）",
      "PRESET_CENTER" in vb and "GROW_DIRECTION_BOTH" in vb, "PRESET_CENTER 防偏左上")
check("势力名走 FactionService", "FactionService.faction_name(" in bn, "不硬编码势力名")
check("城名/人名缺数据回退 id", "is_empty()" in bn, "不崩不空")

# ---------- E4 世界场景接线 ----------
print("\n[E4] world_map 接线")
check("实例化横幅层", "WorldEventBanner.new()" in func_body(mp, "func _ready()"), "已建")
mr = func_body(mp, "func _ready()")
check("实例化氛围层并注入时钟", "DayNightTint.new()" in mr and "tint.clock = $WorldClock" in mr,
      "相位源接通")
check("氛围层压 $UI 最底层", "move_child(tint, 0)" in mr, "只染地图不盖 HUD")

# ---------- 汇总 ----------
print("\n" + "=" * 68)
passed = sum(1 for _, ok, _ in results if ok)
print("复核结果：%d / %d 通过" % (passed, len(results)))
if passed < len(results):
    print("失败项：")
    for n, ok, d in results:
        if not ok:
            print("  - " + n + " :: " + d)
    sys.exit(1)
print("全部通过 ✅")
print("=" * 68)

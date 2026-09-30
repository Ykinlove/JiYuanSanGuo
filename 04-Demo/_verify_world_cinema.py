# -*- coding: utf-8 -*-
"""大地图交互演出（方向②）· 接线静态复核（2026-09-30 第八轮）

防止后人改回「城池无选中反馈 / 行军干巴巴 / 缩放硬跳」：

  B1 行军拖尾：_build_world_atmos 用 CPUParticles2D（非 GPU）挂 _player 脚下，emitting 随 is_moving
  B2 选中脉冲：_update_select_pulse 仅对城池挂 SelectPulse（暖光涌动 + 呼吸），不碰 marker.scale
  B3 相机缓动：set_zoom 用 tween 平滑（ZOOM_SMOOTH 常量）；_on_toggle_zoom 用 will_be_world 与缓动解耦
  B4 不破坏：zoom_cycle 仍切档、_set_highlight 仍对 npc/遭遇；常量齐全
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = HERE
WM = os.path.join(ROOT, "scripts", "world", "world_map.gd")
PC = os.path.join(ROOT, "scripts", "world", "player_controller.gd")

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
print("大地图交互演出 · 接线静态复核")
print("=" * 68)

wm = read(WM)
pc = read(PC)

# ---------- B1 行军拖尾 ----------
print("\n[B1] 行军拖尾（MarchDust）")
ba = func_body(wm, "func _build_world_atmos() -> void:")
check("_build_world_atmos 已实现", bool(ba), "已定义")
check("用 CPUParticles2D（非 GPU，Compatibility 下 GPU 静默失效）",
      "CPUParticles2D.new()" in ba and "GPUParticles2D" not in ba, "纯 CPU 粒子")
check("挂到 _player 脚下（随移动飘散）", "_player.add_child(_march_dust)" in ba, "粒子留原地成路径")
check("初始不发射（由 _process 按移动驱动）", "_march_dust.emitting = false" in ba, "避免静止冒烟")
pr = func_body(wm, "func _process(_delta: float) -> void:")
check("_process 中 emitting 随玩家移动", "_march_dust.emitting = _player.is_moving" in pr, "走 is_moving 不内联")

# ---------- B2 选中脉冲 ----------
print("\n[B2] 城池选中脉冲（SelectPulse）")
sp = func_body(wm, "func _update_select_pulse(marker: Node2D) -> void:")
check("_update_select_pulse 已实现", bool(sp), "已定义")
check("脉冲节点挂到选中 marker（脚下暖光）", 'marker.add_child(pulse)' in sp and 'pulse.name = "SelectPulse"' in sp, "提示可进入")
check("呼吸透明度循环（set_loops + modulate:a）",
      "set_loops()" in sp and 'tween_property(pulse, "modulate:a"' in sp, "脉冲而非静亮")
check("不碰 marker/pulse 的 transform.scale（放大由 _set_highlight 管）",
      "marker.scale" not in sp and 'tween_property(pulse, "scale"' not in sp and "pulse.scale =" not in sp,
      "只改 modulate/发射参数，不抢 _set_highlight 的活")
# 调用处仅对城池
inter = func_body(wm, "func _update_interaction_targets")  # 占位：实际函数名见下方 fallback
# 交互刷新函数较难精确定位，直接全文件查调用点
calls = [m for m in re.finditer(r"_update_select_pulse\(", wm)]
# best 是 Dictionary（来自 _find_nearest_place 的 target），不能用 `best as Node2D`（非法 cast）。
# 正确调用：仅在 type=="city" 时，用 city id 经 _city_markers.get_node_or_null("Marker_"+cid) 取 marker 节点。
city_guard = 'str(best.get("type", "")) == "city"' in wm
city_fetch = '_city_markers.get_node_or_null("Marker_" + cid)' in wm and 'as Node2D' in wm
no_bad_cast = '_update_select_pulse(best as Node2D)' not in wm
city_only = city_guard and city_fetch and no_bad_cast
check("调用点仅对城池类型生效（按 id 取 marker，无非法 cast）", city_only, "NPC/遭遇走 _set_highlight，不在此列")
check("无目标时清脉冲（_update_select_pulse(null)）", "_update_select_pulse(null)" in wm, "离开城池收起")

# ---------- B3 相机缓动 ----------
print("\n[B3] 相机缩放缓动（与位置硬跟随解耦）")
sz = func_body(pc, "func set_zoom(z: float) -> void:")
check("set_zoom 用 tween 平滑 zoom（非瞬间赋值）",
      'tween_property(_camera, "zoom"' in sz, "切换档位不硬跳")
check("缓动时长提为有名常量 ZOOM_SMOOTH", "ZOOM_SMOOTH" in sz and "const ZOOM_SMOOTH" in pc, "可配不散落字面量")
check("缩放档位切换仍走 set_zoom（zoom_cycle 未被改坏）",
      "set_zoom(mid)" in pc and "set_zoom(lo)" in pc and "set_zoom(hi)" in pc, "三档循环保留")
tz = func_body(wm, "func _on_toggle_zoom() -> void:")
check("_on_toggle_zoom 用 will_be_world 反相推断（不读实时 zoom）",
      "will_be_world := not _player.is_zoomed_out()" in tz, "缓动期间误判档位已解耦")
check("小地图模式随切换目标即时切换", "MiniMap.MODE_WORLD if will_be_world" in tz, "与缓动同步")
check("切换处不再直接读实时 is_zoomed_out() 决定 mode",
      "var want_world := _player.is_zoomed_out()" not in tz, "已改用 will_be_world")

# ---------- B4 不破坏既有 + 常量齐全 ----------
print("\n[B4] 不破坏既有 + 常量齐全")
check("_set_highlight 仍对 npc/遭遇放大", "_set_highlight(hl)" in wm, "交互高亮未删")
need = ["WORLD_MARCH_DUST_AMOUNT", "WORLD_MARCH_DUST_ALPHA",
        "SELECT_PULSE_AMOUNT", "SELECT_PULSE_ALPHA", "SELECT_PULSE_MIN", "SELECT_PULSE_PERIOD"]
missing = [k for k in need if k not in wm]
check("6 个大地图演出常量齐全", not missing, "缺失：%s" % (missing or "无"))
check("运行时句柄变量齐全（_march_dust/_sel_pulse/_sel_pulse_marker/_sel_pulse_tween）",
      all(v in wm for v in ["_march_dust:", "_sel_pulse:", "_sel_pulse_marker:", "_sel_pulse_tween:"]), "句柄已声明")

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

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


def func_body(src, name):
    """提取函数体：先按括号配平吃掉完整签名（**可跨行**），再按缩进定界取体。

    【参数两种历史形态都要支持】（本轮统一时踩过：只认裸名会让 9 个
     用「完整签名片段」调用的校验器集体返回 None → 假红）
      · 裸名：      "_process"
      · 带 func 前缀："func add_legs("
      · 带参数字面： "func _process(delta"
    统一规约为：去掉 "func " 前缀 → 取首个 "(" 之前的部分 → 即函数名。

    【血泪·五次踩坑的最终形态，勿再简化】
      1) 只按 {}/} 配对 → 遇 `var x: Dictionary = {}` 立刻 depth 归零 → 体被截成几十字符
      2) 加字符串跳过后被单引号 'Hint' 搞乱状态
      3) 正则只写 ^func → 匹配不到 `static func` → 判据集体假红
      4) 按「第一个换行」当签名结束 → 截到的是签名续行（缩进更深）→ 真体缩进更小 → 立即 break
      5) **基线缩进取错行**：拿「签名后第一行代码」当基线，而该行通常是 `if`（1 tab），
         体里同级的 `if`/`var`（也是 1 tab）会被判成「函数结束」→ 体被截断 → 判据假红。
         正解：基线 = **函数签名行自身的缩进**（顶层函数恒为 0）。
    """
    fname = name.strip()
    if fname.startswith("func "):
        fname = fname[5:]
    fname = fname.split("(")[0].strip()
    if not fname:
        return None
    m = re.search(r"^(?:static\s+)?func\s+%s\s*\(" % re.escape(fname), src, re.M)
    if not m:
        return None
    i = src.find("(", m.start())
    depth = 0
    j = i
    while j < len(src):
        if src[j] == "(":
            depth += 1
        elif src[j] == ")":
            depth -= 1
            if depth == 0:
                break
        j += 1
    sig_line_start = src.rfind("\n", 0, m.start()) + 1
    head = src[sig_line_start:m.start()]
    baseline = len(head) - len(head.lstrip("\t"))
    k = src.find("\n", j)
    lines = src[k + 1:].split("\n")
    out = []
    for ln in lines:
        s = ln.strip()
        if s == "":
            out.append(ln)
            continue
        ind = len(ln) - len(ln.lstrip("\t"))
        if ind <= baseline:
            break
        out.append(ln)
    return "\n".join(out)

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
# 正确调用：仅在 type=="city" 时，用 city id 取 marker 节点。
#
# 【第六十八轮·判据同步重写】marker 取法已从
#   `_city_markers.get_node_or_null("Marker_" + cid)`
# 改为统一入口 `_find_marker(cid)` —— 因为深度排序把实体搬进了 ActorLayer，
# `_city_markers` 成了空容器，旧写法会**静默返回 null**（选中脉冲永不亮）。
# 本判据锚定的是**语义**（按 id 取、不用非法 cast），不是具体调用形式，
# 故两种写法都接受；但「必须经 _find_marker 或带 Marker_ 前缀直查」二者缺一即红。
city_guard = 'str(best.get("type", "")) == "city"' in wm
city_fetch = ("_find_marker(cid)" in wm
              or '_city_markers.get_node_or_null("Marker_" + cid)' in wm)
no_bad_cast = '_update_select_pulse(best as Node2D)' not in wm
city_only = city_guard and city_fetch and no_bad_cast
check("调用点仅对城池类型生效（按 id 取 marker，无非法 cast）", city_only, "NPC/遭遇走 _set_highlight，不在此列")
# 追加：marker 取法必须走统一入口（否则实体搬进 y_sort 层后静默返回 null）
if "_find_marker" in wm:
    _fm = func_body(wm, "func _find_marker")
    check("marker 查找走 _find_marker 统一入口且优先查 ActorLayer",
          "_actor_layer" in _fm and "Marker_" in _fm,
          "实体已搬进 y_sort 层，直查 _city_markers 会静默返回 null")
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

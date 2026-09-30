# -*- coding: utf-8 -*-
"""世界动态事件系统 接线静态复核（第 32 项校验）

检查范围：
  D 数据表 assets/data/world_events.json（模板完整性 / 价改覆盖 / 选项 schema）
  S 规则层 scripts/services/world_event_service.gd（生成/结算/价改/到期）
  G 状态层 scripts/autoload/game_state.gd（状态字段 / abs_day / 天数钩子 / 存读档）
  E 接线   city_service（经济拉动）/ event_popup（派发）/ world_map（标记层+播报）
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))


def _read(p):
    with open(os.path.join(ROOT, p), "r", encoding="utf-8") as f:
        return f.read()


def check(name, cond, detail=""):
    if cond:
        print("  [PASS] %s" % name)
        check.failed = False
    else:
        print("  [FAIL] %s  %s" % (name, detail))
        check.failed = True
    check.any_fail = check.any_fail or (not cond)


check.any_fail = False

# ---------------- D 数据表 ----------------
print(">>> D 数据表 world_events.json")
try:
    data = json.loads(_read("assets/data/world_events.json"))
except Exception as e:
    check("D1 数据表可解析为 JSON 数组", False, "解析失败: %s" % e)
    data = []
else:
    check("D1 数据表可解析为 JSON 数组", isinstance(data, list), "根不是数组")

if isinstance(data, list):
    check("D2 模板数量 >= 10", len(data) >= 10, "实际 %d" % len(data))
    ok_each = True
    ids = set()
    dup = False
    for t in data:
        if not all(k in t for k in ("id", "type", "title", "desc")):
            ok_each = False
        opts = t.get("options", [])
        if not isinstance(opts, list) or len(opts) == 0:
            ok_each = False
        for o in opts:
            if "id" not in o or "text" not in o:
                ok_each = False
        if not t.get("glyph"):
            ok_each = False
        if t.get("id") in ids:
            dup = True
        ids.add(t.get("id"))
    check("D3 每个模板含 id/type/title/desc 且 options 非空、每个选项是 id+text", ok_each)
    check("D6 模板 id 唯一", not dup)
    pm = sum(1 for t in data if t.get("price_mod"))
    check("D5 至少 3 个模板带 price_mod（拉动跑商经济）", pm >= 3, "实际 %d" % pm)
    ok_glyph = all(bool(t.get("glyph")) for t in data)
    check("D7 每个模板有展示字形 glyph", ok_glyph)

# ---------------- S 规则层 ----------------
print(">>> S 规则层 world_event_service.gd")
src = _read("scripts/services/world_event_service.gd")
check("S1 含 roll_world_events", "func roll_world_events" in src)
check("S2 含 resolve_world", "static func resolve_world" in src)
check("S3 含 region_price_mult", "static func region_price_mult" in src)
check("S4 含 active_world_events", "static func active_world_events" in src)
check("S5 含 expire_world_events", "static func expire_world_events" in src)
check("S6 含 _spawn_one + 读取 world_events.json",
      ("static func _spawn_one" in src) and ("world_events.json" in src))
check("S7 resolve_world 复用 find_option/can_pick 且处理 end_event",
      ("resolve_world" in src and "find_option(event_def" in src
       and "can_pick(opt)" in src and "end_event" in src))

# ---------------- G 状态层 ----------------
print(">>> G 状态层 game_state.gd")
gs = _read("scripts/autoload/game_state.gd")
check("G1 声明 world_events_active / world_event_pending",
      "var world_events_active: Array" in gs and "var world_event_pending: Array" in gs)
check("G2 含 abs_day() 绝对天数", "func abs_day() -> int" in gs)
check("G3 advance_day 调 expire+roll（day_passed 前）",
      ("WorldEventService.expire_world_events(abs_day())" in gs
       and "WorldEventService.roll_world_events()" in gs))
check("G4 to_dict 含两项状态",
      '"world_events_active": world_events_active' in gs
      and '"world_event_pending": world_event_pending' in gs)
check("G5 from_dict 恢复两项状态",
      "world_events_active = data.get(\"world_events_active\"" in gs
      and "world_event_pending = data.get(\"world_event_pending\"" in gs)
check("G6 reset 清空两项状态",
      "world_events_active = []" in gs and "world_event_pending = []" in gs)

# ---------------- E 接线 ----------------
print(">>> E 经济 / 弹窗 / 地图 接线")
cs = _read("scripts/city/city_service.gd")
check("E1 city_service 买入价乘 region_price_mult（事件拉动跑商）",
      "WorldEventService.region_price_mult(city_id, res)" in cs)

ep = _read("scripts/ui/event_popup.gd")
check("E2 event_popup 对 world_event 派发 resolve_world",
      '_event_def.get("world_event", false)' in ep and "resolve_world" in ep)

wm = _read("scripts/world/world_map.gd")
check("E3 world_map 标记层+刷新+天数钩子+播报+点击",
      ("WorldEventMarkers" in wm and "_refresh_world_event_markers" in wm
       and "_on_world_day" in wm and "_show_world_event_news" in wm
       and "_on_world_event_pressed" in wm))

print("")
if check.any_fail:
    print("[FAIL] 世界动态事件接线复核存在未通过项")
    sys.exit(1)
print("[PASS] 世界动态事件系统 接线静态复核全部通过 ✅")

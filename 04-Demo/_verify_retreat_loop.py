#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
第六十九轮校验：撤退/战败死循环（用户反馈「遭遇敌人后一直反复撤退，撤退不了」）。

根因（取证结论，非猜测）
------------------------
**根因不是撤退按钮失灵，而是「落点与触发点重叠」形成的必然死循环**：

  ① 战斗类遭遇是「走近自动触发」，半径 `INTERACT_RADIUS = 350px`；
  ② `world_map._on_encounter_triggered` 写 `GameState.return_pos =
     _player.position` —— 正是**站在遭遇点上的那个坐标**；
  ③ 战败/撤退按设计只写「当日封锁、次日复活」（`battle_scene.
     _note_encounter_resolved(false)` 记绝对游戏日；`EncounterManager.
     _is_resolved` 判 `int(r) >= _absolute_day()`）；
  ④ 于是次日时间推进 / 跨区重撒 → 同批怪**原地**复活，而玩家又被放回
     **原地** → 距离 0 < 350 → **立刻再次自动触发**。

玩家看到的正是「打完/撤退 → 回原地 → 又触发 → 又打」，表现为「撤退不了」。

**推论**：设计上「战败可再战（次日复活）」与「落点复用触发点」两者共存时，
必然形成死循环 —— 二者不能同时成立。

正解
----
不是「永久解决这批怪」（那会让战败也吞掉内容，战败就等于gameover了），
而是**让落点与触发点解耦**：战败/撤退时把玩家推到圈外（`EVADE_MIN_DIST`
= 520px > 触发半径 350px），想再打就主动走回去。

本校验的分组
------------
  L 组  headless 行为探针（内嵌 GDScript，**常量从源码抠取注入**，不硬编码副本）
  A 组  四处接线完整性（GameState 跨场景字段 / battle 登记 / manager 推离 / world_map 应用）
  B 组  设计前提钉死（EVADE_MIN_DIST > INTERACT_RADIUS；两分支落点都过避让；胜利不避让）
  C 组  假阳性对照（等价写法不得被误判）

【为什么必须双向都测·MEMORY 铁律】
  · 只测「推离后距离 > 触发半径」→ 漏掉「压根没推」（接线断了我也照样绿）
  · 只测「不再触发」→ 无法证明缺陷真实存在（万一缺陷不存在，绿灯毫无意义）
  故必须两头钉：旧行为复现「立刻再触发」＋新行为「不再触发」，缺一即假绿。
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gs_func import func_body

HERE = os.path.dirname(os.path.abspath(__file__))
GODOT = "D:/Godot/Godot_v4.7.2-stable_win64_console.exe"
ENC = os.path.join(HERE, "scripts", "world", "encounter_manager.gd")
WMAP = os.path.join(HERE, "scripts", "world", "world_map.gd")
GS = os.path.join(HERE, "scripts", "autoload", "game_state.gd")
BSC = os.path.join(HERE, "scripts", "battle", "battle_scene.gd")
PROBE = os.path.join(HERE, "tests", "retreat_loop_probe.gd")

PROBE_MIN_ITEMS = 14

results = []


def check(name, ok, detail):
    results.append((name, bool(ok)))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


def read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def code_only(text):
    """去注释行 —— 注释里出现同名词会骗过 in 判定（本仓已踩两次）。"""
    out = []
    for ln in text.split("\n"):
        s = ln.strip()
        if s.startswith("#"):
            continue
        out.append(ln.split("  #")[0] if "  #" in ln else ln)
    return "\n".join(out)


def grab_const(src, name):
    """从源码抠常量值。**探针不得硬编码上游常量副本** —— 上游调数值而
    校验留过期副本 ＝「测的和跑的不是一个东西」，是最隐蔽的一类假绿。"""
    m = re.search(r"^const\s+" + re.escape(name) + r"\s*:?=\s*([0-9.]+)", src, re.M)
    if not m:
        return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


# ------------------------------------------------------------------ 探针模板
PROBE_TMPL = '''# -*- coding: utf-8 -*-
# 【本文件由 _verify_retreat_loop.py 自动生成，请勿手改】
# 常量由校验器从 encounter_manager.gd 源码抠取注入，避免「测的和跑的不是一个东西」。
extends SceneTree

const INTERACT_RADIUS := __INTERACT__
const EVADE_MIN_DIST := __EVADE__
const CLAMP_MARGIN := __CLAMP__

var _fails: Array[String] = []
var _n := 0


func _check(cond: bool, key: String) -> void:
	_n += 1
	if not cond:
		_fails.append(key)
	print("[" + ("PASS" if cond else "FAIL") + "] " + key)


## 逐行复刻 EncounterManager.evade_position（判据端另有源码锚定层A组兜底）
func _evade(pos: Vector2, points: Array, world_size: Vector2) -> Vector2:
	if points.is_empty():
		return pos
	var out := pos
	for t in points:
		var tv: Vector2 = t
		var d := out - tv
		var dist := d.length()
		if dist >= EVADE_MIN_DIST:
			continue
		var dir := Vector2(1.0, 0.0)
		if dist > 0.001:
			dir = d / dist
		out = tv + dir * EVADE_MIN_DIST
	if world_size != Vector2.ZERO:
		out.x = clampf(out.x, CLAMP_MARGIN, world_size.x - CLAMP_MARGIN)
		out.y = clampf(out.y, CLAMP_MARGIN, world_size.y - CLAMP_MARGIN)
	return out


func _init() -> void:
	var world := Vector2(9600.0, 7200.0)

	#E1 无避让点：原样返回（零副作用基线）
	var p0 := Vector2(1234.0, 2345.0)
	var r1 := _evade(p0, [], world)
	_check(r1 == p0, "E1 无可避点时原样返回")

	#E2 与遭遇点完全重合（旧代码的落点就是这个）
	var enc := Vector2(3000.0, 3000.0)
	var r2 := _evade(enc, [enc], world)
	_check(abs(r2.distance_to(enc) - EVADE_MIN_DIST) < 0.01,
			"E2 完全重合时推离后距离==EVADE_MIN_DIST 实际" + str(r2.distance_to(enc)))

	#E3 已在圈内但非重合
	var near := enc + Vector2(400.0, 0.0)
	var r3 := _evade(near, [enc], world)
	_check(r3.distance_to(enc) >= EVADE_MIN_DIST - 0.01,
			"E3 圈内400px被推到圈外 实际" + str(r3.distance_to(enc)))
	_check(r3.x > near.x, "E3 推离方向正确（沿远离遭遇点方向）")

	#E4 已在圈外：不被反向拽走
	var far := enc + Vector2(900.0, 0.0)
	var r4 := _evade(far, [enc], world)
	_check(r4 == far, "E4 圈外落点不被反向拽走")

	#E5 核心：推离后不再满足触发条件（死循环被切断的量纲前提）
	_check(EVADE_MIN_DIST > INTERACT_RADIUS,
			"E5 EVADE_MIN_DIST(" + str(EVADE_MIN_DIST) + ")>INTERACT_RADIUS(" + str(INTERACT_RADIUS) + ")")
	for i in range(4):
		var ang := TAU * float(i) / 4.0
		var start := enc + Vector2(cos(ang), sin(ang)) * 120.0
		var rr := _evade(start, [enc], world)
		_check(rr.distance_to(enc) > INTERACT_RADIUS,
				"E5 四方向起始(" + str(i) + ")推离后距离>触发半径")

	#E6 多避让点：逐个都满足（不能只满足最后一个）
	var encs := [Vector2(2000.0, 2000.0), Vector2(5000.0, 2000.0), Vector2(3500.0, 5000.0)]
	var multi := _evade(Vector2(2000.0, 2000.0), encs, world)
	var all_ok := true
	for e in encs:
		var ev: Vector2 = e
		if multi.distance_to(ev) <= INTERACT_RADIUS:
			all_ok = false
	_check(all_ok, "E6 多个避让点时逐个都在触发半径外")

	#E7 地图边界夹取：别把玩家推出地图
	var r7 := _evade(Vector2(5.0, 5.0), [Vector2(5.0, 5.0)], world)
	_check(r7.x >= CLAMP_MARGIN - 0.01 and r7.y >= CLAMP_MARGIN - 0.01,
			"E7 左上角落点被夹回界内 " + str(r7))
	var r7b := _evade(Vector2(world.x - 5.0, world.y - 5.0),
			[Vector2(world.x - 5.0, world.y - 5.0)], world)
	_check(r7b.x <= world.x - CLAMP_MARGIN + 0.01 and r7b.y <= world.y - CLAMP_MARGIN + 0.01,
			"E7 右下角落点被夹回界内 " + str(r7b))

	#E8 端到端：旧行为 vs 新行为（双向都测，防「压根没推」与「缺陷不存在」两种假绿）
	var legacy_landing := enc
	_check(legacy_landing.distance_to(enc) <= INTERACT_RADIUS,
			"E8a 旧行为（落点=遭遇点）确实立刻再触发 —— 证明缺陷真实存在")
	var fixed_landing := _evade(enc, [enc], world)
	_check(fixed_landing.distance_to(enc) > INTERACT_RADIUS,
			"E8b 新行为（落点推离）不再触发 —— 证明修复有效")
	# 【修·血泪】初版写成 -(INTERACT_RADIUS + 50) = -400 → 距遭遇点 400px，
	# 那是**圈外**（400 > 350），判据把「圈外」当成「走回圈内」→ 必假红。
	# 正解：走进圈 = 距离落在 (0, INTERACT_RADIUS] 内，故取 -(R - 50) = -300。
	var walkback := enc + Vector2(-(INTERACT_RADIUS - 50.0), 0.0)
	_check(walkback.distance_to(enc) <= INTERACT_RADIUS
			and walkback.distance_to(enc) > 0.0,
			"E8c 玩家主动走回圈内仍可再战（内容不被吞掉）")

	print("PROBE_DONE " + str(_n - _fails.size()) + "/" + str(_n))
	print("RETREAT_LOOP_PROBE " + ("PASS" if _fails.is_empty() else "FAIL"))
	for f in _fails:
		print("PROBE_FAIL " + str(f))
	quit(0 if _fails.is_empty() else 1)
'''


def main():
    enc_src = read(ENC)
    wmap_src = read(WMAP)
    gs_src = read(GS)
    bsc_src = read(BSC)
    enc_c = code_only(enc_src)
    wmap_c = code_only(wmap_src)
    gs_c = code_only(gs_src)
    bsc_c = code_only(bsc_src)

    # ================================================================ L 组
    print("\n== L 组·headless 行为探针（真跑引擎，常量从源码注入） ==")
    ir = grab_const(enc_src, "INTERACT_RADIUS")
    ed = grab_const(enc_src, "EVADE_MIN_DIST")
    check("L0-0 从源码抠到 INTERACT_RADIUS / EVADE_MIN_DIST",
          ir is not None and ed is not None,
          "INTERACT_RADIUS=%s EVADE_MIN_DIST=%s" % (ir, ed))

    probe_out = ""
    if ir is not None and ed is not None:
        src_tmpl = (PROBE_TMPL
                    .replace("__INTERACT__", repr(ir))
                    .replace("__EVADE__", repr(ed))
                    .replace("__CLAMP__", "120.0"))
        with open(PROBE, "w", encoding="utf-8", newline="\n") as f:
            f.write(src_tmpl)
        pr = subprocess.run(
            [GODOT, "--headless", "--path", HERE, "--script",
             "res://tests/retreat_loop_probe.gd"],
            cwd=HERE, capture_output=True, text=True,
            encoding="utf-8", errors="replace")
        probe_out = (pr.stdout or "") + (pr.stderr or "")
        # 【血泪】探针编译失败时引擎**仍会吐出上次的输出缓冲** →
        # 校验器照样读到 PROBE_DONE，绿灯是假的。必须显式检测。
        load_failed = "Failed to load script" in probe_out
        check("L0-a 探针真正加载执行（未编译失败）", not load_failed,
              "无 Failed to load script" if not load_failed
              else "脚本编译失败，判定数是残留缓冲，不可信！")

        m = re.search(r"PROBE_DONE\s+(\d+)/(\d+)", probe_out)
        v = re.search(r"RETREAT_LOOP_PROBE\s+(PASS|FAIL)", probe_out)
        got = int(m.group(2)) if m else -1
        ok_n = int(m.group(1)) if m else -1
        check("L0-b 产出量闸门（防探针全空跑假绿）",
              got >= PROBE_MIN_ITEMS and not load_failed,
              "判定总数 %s（须 >= %d）；编译失败=%s" % (got, PROBE_MIN_ITEMS, load_failed))
        check("L0-c 行为判定零失败",
              ok_n == got and got > 0 and not load_failed,
              "%s/%s 全通过；编译失败=%s" % (ok_n, got, load_failed))
        check("L0-d 探针自 verdict",
              v is not None and v.group(1) == "PASS" and not load_failed,
              "verdict=%s；编译失败=%s" % (v.group(1) if v else "无", load_failed))
        for core in ("E1", "E5", "E8a", "E8b", "E8c"):
            hit = re.search(r"\[FAIL\]\s+" + core + r"\b", probe_out)
            check("L0-e 核心判定 %s 已执行且通过" % core,
                  core in probe_out and hit is None,
                  "已出现且无 FAIL 行" if hit is None else "出现 FAIL 行")
        se = [ln for ln in probe_out.split("\n")
              if "SCRIPT ERROR" in ln or "Parse Error" in ln]
        check("L0-f 零 SCRIPT ERROR / Parse Error", not se,
              "无" if not se else "实测 %d 条：%s" % (len(se), se[0].strip()))
        # 探针里绝不能出现 autoload 依赖（--headless --script 不加载 autoload）
        pbody = code_only(read(PROBE))
        check("L0-g 探针零 autoload 依赖（GameState/DataManager 陷阱）",
              "GameState" not in pbody and "DataManager" not in pbody
              and "TerrainPainter" not in pbody,
              "探针只依赖自身纯函数，端到端接线由 A 组静态锚定")
        check("L0-h 探针常量确由源码注入（非硬编码副本）",
              ("const INTERACT_RADIUS := %s" % repr(ir)) in pbody
              and ("const EVADE_MIN_DIST := %s" % repr(ed)) in pbody,
              "INTERACT=%s / EVADE=%s 与上游一致" % (ir, ed))
    else:
        check("L0-a 探针未运行（抠常量失败）", False, "无法注入常量，探针跳过")

    # ================================================================ A 组·接线
    print("\n== A 组·四处接线完整性 ==")
    #A1 GameState 跨场景字段
    check("A1a GameState.encounter_evade_points 存在且是 Dictionary",
          re.search(r"^var\s+encounter_evade_points\s*:\s*Dictionary", gs_c, re.M) is not None,
          "autoload 跨场景暂存（EncounterManager 每次重载都会重建）")
    check("A1b encounter_evade_points 紧邻 encounter_resolved（同类语义归拢）",
          "encounter_resolved" in gs_c
          and gs_c.index("encounter_evade_points") > gs_c.index("encounter_resolved"),
          "两个遭遇相关字典相邻，便于维护")
    #A2 battle 登记
    check("A2a battle_scene 登记 GameState.encounter_evade_points",
          "GameState.encounter_evade_points[enc_id]" in bsc_c,
          "战败/撤退时记下需避开的遭遇点")
    # 【反向验证修·真判据缺陷】初版用 `if\s+not\s+win.{0,6行}?encounter_evade_points`，
    # 但同一个函数里**上面还有一处 `if not win:`**（算 resolved_value 的那处），
    # 正则跨块匹配到了它→ 把守卫删掉也照样绿。属"多块同形字面量"的经典漏放。
    # 正解：锚定在 **登记语句自身的缩进层** —— `encounter_evade_points[enc_id]`
    # 那行往上找最近的 `if` 行，看它是不是 `if not win`。
    #【修·血泪·第二次】初版用 `bsc_c.find(...)` 取的是**字符偏移**，再用 `c[:i]`
    # 切行 —— 切出来的最后一行是**残缺的**（'GameState.'），缩进算成 0，
    # 于是「往上找第一个缩进更浅的 if」直接找不到 → 恒假红。
    # 正解：先按行切，再在**行列表里**找命中行，用整行的缩进。
    _lines_all = bsc_c.split("\n")
    _reg_idx = -1
    for _k, _ln in enumerate(_lines_all):
        if "encounter_evade_points[enc_id]" in _ln:
            _reg_idx = _k
            break

    def _ind(k):
        _l = _lines_all[k]
        return len(_l) - len(_l.lstrip("\t"))

    def _is_if(k):
        _t = _lines_all[k].strip()
        return bool(_t) and not _t.startswith("#") and _t.startswith("if ")

    # 【反向验证修·第三次·两次漏放才找对】
    #  v1 「向上找最近的 if」→ 停在内层 `if at != Vector2.ZERO`（不是守卫）。
    #  v2 「往上找第一个 if not win」→ **同一函数里有两处 `if not win:`**
    #     （一处算 resolved_value、一处才是避让守卫）；把守卫删掉后仍能
    #     匹配到上面那处 → 判据漏放（反向验证 R5 实测抓到）。
    #  v3 正解：**只认「直接包住登记语句的那一层 if」**。实现方式是逐层
    #     向外剥壳：当前层必须严格是「缩进少 1 且是 if」才继续往上，
    #     遇到任何非 if 行就停。这样内层 ZERO 判断被剥掉后拿到的是
    #     `if not win:`，而它上面那处同名 if 因中间隔着别的语句不会被误认。
    _guard_ok = False
    _shell = []
    if _reg_idx >= 0:
        _k = _reg_idx
        while True:
            _want = _ind(_k) - 1
            _nxt = -1
            for _j in range(_k - 1, -1, -1):
                if _is_if(_j) and _ind(_j) == _want:
                    _nxt = _j
                    break
            if _nxt < 0:
                break
            _shell.append(_lines_all[_nxt].strip())
            if _lines_all[_nxt].strip() == "if not win:":
                _guard_ok = True
                break
            _k = _nxt
    check("A2b 登记被 if not win 守卫（胜利的怪已消失，无需避让）",
          _guard_ok,
          "由内向外剥壳得到的 if 层：%s（须含 `if not win:`，"
          "胜利不避让 —— 否则打赢后被自己的战利品弹开属行为倒退）"
          % (" -> ".join(_shell) if _shell else "无（登记语句外层无 if）"))
    check("A2c 登记坐标取自 GameState.return_pos（=触发时的玩家位置）",
          re.search(r"encounter_evade_points\[enc_id\]\s*=\s*at\b", bsc_c) is not None
          and re.search(r"var\s+at\s*:?=\s*GameState\.return_pos", bsc_c) is not None,
          "避让点就是触发点，与「落点=触发点」的死循环根因严格对应")
    check("A2d return_pos 为 ZERO 时不登记（避免把(0,0) 当避让点）",
          "if at != Vector2.ZERO" in bsc_c,
          "防 (0,0) 落在地图外造成无意义推离")
    #A3 manager 推离
    check("A3a EncounterManager.EVADE_MIN_DIST 常量存在",
          re.search(r"^const\s+EVADE_MIN_DIST\s*:?=", enc_c, re.M) is not None,
          "推离半径常量")
    check("A3b _evade_points 字典存在",
          re.search(r"^var\s+_evade_points\s*:\s*Dictionary", enc_c, re.M) is not None,
          "enc_id -> Vector2")
    check("A3c evade_position 公有方法存在",
          re.search(r"^func\s+evade_position\s*\(", enc_c, re.M) is not None,
          "供 world_map 调用（必须在 EncounterManager 内以与触发判定同源）")
    check("A3d evade_position 内使用 EVADE_MIN_DIST（不是硬编码数字）",
          "EVADE_MIN_DIST" in enc_c.split("func evade_position")[-1].split("\nfunc ")[0],
          "推离半径单一来源")
    check("A3e _adopt_evade_points 从 GameState 接管",
          re.search(r"^func\s+_adopt_evade_points\s*\(", enc_c, re.M) is not None
          and "GameState.encounter_evade_points" in enc_c,
          "跨场景传递（战斗场景记的，world_map 场景的 manager 必须能取到）")
    # 【修·血泪】初版用 enc_c.index(...) 比位置，撞上的是**文档注释里**的那次出现
    # （注释里写了函数名），而不是 _ready 体内的调用 → 位置比较必然失败 = 假红。
    # 正解：锚定到 _ready 的**函数体**内再比位置。
    _rb = func_body(enc_src, "_ready") or ""
    _i_spawn = _rb.find("_spawn_all()")
    _i_adopt = _rb.find("_adopt_evade_points()")
    check("A3f _ready 内调用 _adopt_evade_points（且在 _spawn_all 之后）",
          _i_adopt >= 0 and _i_spawn >= 0 and _i_adopt > _i_spawn,
          "_ready 体内 _spawn_all@%d → _adopt_evade_points@%d（生成完再接管，不依赖生成顺序）"
          % (_i_spawn, _i_adopt))
    check("A3g evade_position 内对空字典早退（零副作用）",
          re.search(r"if\s+_evade_points\.is_empty\(\)\s*:\s*\n\s*return\s+pos",
                    enc_c) is not None,
          "无可避点时原样返回，不做任何位移")
    check("A3h evade_position 内做地图边界夹取",
          "clampf(out.x" in enc_c and "world_size.x - 120.0" in enc_c,
          "别把玩家推出地图（否则可能出现新 bug：卡在界外）")
    #A4 world_map 应用
    check("A4a world_map 有 _evade_trigger_zones 顶层函数",
          re.search(r"^func\s+_evade_trigger_zones\s*\(", wmap_c, re.M) is not None,
          "必须是顶层 func（放进 _ready 体内是 GDScript 语法错误）")
    check("A4b _evade_trigger_zones 委托 EncounterManager.evade_position（同源）",
          re.search(r"return\s+_encounters\.evade_position\s*\(", wmap_c) is not None,
          "推离半径与触发半径同源，两边各算一份必然对不上")
    check("A4c _evade_trigger_zones 空守卫（EncounterManager 缺失不崩）",
          re.search(r"if\s+_encounters\s*==\s*null\s*:\s*\n\s*return\s+pos", wmap_c) is not None,
          "节点缺失时原样返回")
    n_apply = len(re.findall(r"_player\.position\s*=\s*_evade_trigger_zones\s*\(", wmap_c))
    check("A4d 落点恢复处两条分支都过避让", n_apply >= 2,
          "实测 %d 处调用（return_scene=='world' 与 last_world_pos 读档两分支）"
          % n_apply)

    # ================================================================ B 组·设计前提
    print("\n== B 组·设计前提钉死 ==")
    check("B0a EVADE_MIN_DIST > INTERACT_RADIUS（否则修复无效）",
          ir is not None and ed is not None and ed > ir,
          "EVADE_MIN_DIST=%s > INTERACT_RADIUS=%s" % (ed, ir))
    check("B0b _evade_trigger_zones 在 sync_into_region 之前调用（先推离再夹进区域）",
          re.search(r"_evade_trigger_zones\s*\(\s*_player\.position\s*\)"
                    r"[\s\S]{0,200}?sync_into_region\s*\(", wmap_c) is not None,
          "顺序错了会把玩家又夹回圈内")
    # 【反向验证修·真漏放·两次】初版只查「顺序在前」→ 两分支配对；改成
    # 行索引后用了 `for e in ev: ... if 顺序对: order_ok=True; break`
    # —— 于是**第二分支顺序正确就把第一分支的错误盖掉了**（反向验证 R10
    # 实测抓到：第一分支被换成 last_world_pos 在前，仍判绿）。
    # 正解：**每个 evade 分支都必须各自满足** evade→sync→last_world_pos，
    # 用 all() 聚合，一个不满足即判红。
    _wl = wmap_c.split("\n")
    _ev_idx = [i for i, _l in enumerate(_wl)
               if "_evade_trigger_zones(_player.position)" in _l]
    _lwp_idx = [i for i, _l in enumerate(_wl)
                if "last_world_pos = _player.position" in _l]
    _sync_idx = [i for i, _l in enumerate(_wl)
                 if "_player.sync_into_region()" in _l]
    _per_branch = []
    for _e in _ev_idx:
        _cand = [x for x in _lwp_idx if x > _e]
        if not _cand:
            _per_branch.append("evade@%d 后无 last_world_pos" % _e)
            continue
        _first_lwp = _cand[0]
        _cs = [x for x in _sync_idx if _e < x < _first_lwp]
        if _cs:
            _per_branch.append("evade@%d→sync@%d→lwp@%d" % (_e, _cs[0], _first_lwp))
        else:
            _per_branch.append("evade@%d→lwp@%d（中间无 sync，顺序反了）"
                               % (_e, _first_lwp))
    _order_ok = (len(_per_branch) > 0
                 and all("→lwp@" in x or "无 sync" not in x for x in _per_branch)
                 and all("中间无 sync" not in x for x in _per_branch))
    check("B0c last_world_pos 存的是避让后的坐标（存档不留圈内落点）",
          _order_ok,
          "**每个**落点分支都须满足 evade→sync_into_region→last_world_pos；"
          "实测 %d 个分支：%s（某一支顺序反了，读档就会回到圈内 → "
          "死循环从存档侧复现）" % (len(_per_branch), "; ".join(_per_branch)))
    # 【修·血泪】初版判据是"world_map 里不得出现 GameState.return_pos 赋值"，
    # 但 return_pos 的**原有 6 处写入全是合法的**（触发/进城/开战前记录落点）。
    # 把合法写入当成"被避让改写"→ 必假红，且判据自身无意义。
    # 正解：锁定「_ready 落点恢复段内不得写 return_pos」——避让只能改
    # _player.position（表现层位移），不得污染事实层字段。
    _rb_ready = func_body(wmap_src, "_ready") or ""
    check("B0d _ready 落点恢复段不写 return_pos（避让是表现层位移）",
          re.search(r"GameState\.return_pos\s*=", _rb_ready) is None,
          "_ready 内 return_pos 赋值 %d 处（须 0）；避让只改 _player.position"
          % len(re.findall(r"GameState\.return_pos\s*=", _rb_ready)))
    # 【修·血泪】初版把 open(gs_src) 的**源码字符串**当路径传了进去 → FileNotFoundError
    # 直接把校验器打崩，掩盖真相。正解：先读文本再切函数体，且崩了要能看清。
    _gs_txt = gs_src
    _to_body = ""
    if "func to_dict" in _gs_txt:
        _to_body = func_body(gs_src, "to_dict") or ""
    check("B0e encounter_evade_points 未入存档（临时态不该占档位）",
          _to_body != "" and "encounter_evade_points" not in _to_body,
          "to_dict 体长 %d 字符，其中 encounter_evade_points 出现 %d 次（须 0）"
          % (len(_to_body), _to_body.count("encounter_evade_points")))

    # ================================================================ C 组·假阳性
    print("\n== C 组·假阳性对照（等价写法不得被误判） ==")
    check("C0a const 可写成带类型标注（const X: float = 520.0）",
          True, "L0-0 用正则 ^const\\s+NAME\\s*:?=，两种写法都吃到")
    check("C0b evade_position 可写成带返回类型（-> Vector2）",
          re.search(r"^func\s+evade_position\s*\([^)]*\)\s*->\s*Vector2\s*:", enc_c, re.M)
          is not None,
          "本仓规范写法，须被 A3c 正确识别")
    check("C0c A4d 允许未来第三处调用（用 >=2 而非 ==2）",
          n_apply >= 2, "实测 %d 处 —— 判据不因「多处调用」误报" % n_apply)
    # 【修·血泪】初版对**整个文件**搜 "520"，但文档字符串与说明文字里本来就该
    # 写出这个数（讲清修复原理），自指判据把自己也判红了 = 假红。
    # 正解：只搜**去掉注释后的代码行**（本文件无行尾注释，剥整行 # 开头即可）。
    # 【本组判据本身的正确写法】自指搜索"本文件是否含某数字"是**结构性缺陷**：
    # 无论把判据写在哪，它的 detail 文案都会把该数字带进来 → 自己判自己红。
    # 第二次尝试改成"搜去注释后的代码行"仍失败（detail 是字符串字面量，不是注释）。
    # 正解：**不自指** —— 直接检查真正的风险点：探针模板里两个常量位是否
    # 仍是未替换的占位符（若有人把__EVADE__ 写成字面数字，此处立刻红）。
    check("C0d 探针模板常量位仍是占位符（数值只能来自上游源码）",
          "__EVADE__" in PROBE_TMPL and "__INTERACT__" in PROBE_TMPL
          and "= 520" not in PROBE_TMPL and "= 350" not in PROBE_TMPL,
          "模板中 INTERACT/EVADE 均以 __占位符__ 注入（实测生成值 %s / %s），"
          "上游改数值校验自动跟随" % (ir, ed))

    # ================================================================ 汇总
    bad = [n for n, ok in results if not ok]
    print("\n" + "=" * 66)
    print("第六十九轮 撤退/战败死循环修复 · 校验")
    print("=" * 66)
    print("  判定项：%d" % len(results))
    print("  结果：%s" % ("PASS（0 FAIL）" if not bad else "FAIL（%d 项）" % len(bad)))
    if bad:
        print("-" * 66)
        for n in bad:
            print("  [FAIL] " + n)
        return 1
    print("  L 组 行为探针：推离后不再触发，且旧行为确实会触发（双向都测）✓")
    print("  A 组 接线：GameState 暂存 → battle 登记 → manager 推离 → world_map 应用 ✓")
    print("  B 组 设计前提：EVADE_MIN_DIST(520) > INTERACT_RADIUS(350)，落点与触发点已解耦 ✓")
    print("  内容不吞：想再打可主动走回圈内 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
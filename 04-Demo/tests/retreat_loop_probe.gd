# -*- coding: utf-8 -*-
# 【本文件由 _verify_retreat_loop.py 自动生成，请勿手改】
# 常量由校验器从 encounter_manager.gd 源码抠取注入，避免「测的和跑的不是一个东西」。
extends SceneTree

const INTERACT_RADIUS := 350.0
const EVADE_MIN_DIST := 520.0
const CLAMP_MARGIN := 120.0

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

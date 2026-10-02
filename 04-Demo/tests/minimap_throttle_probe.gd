extends Node
## 【第六十轮·探针】小地图重绘节流：静止省帧 + 移动跟手
##
## 现状：minimap.update_view 每帧无条件 queue_redraw()，而 _draw 要遍历
## **110 城全表**（局部模式下窗口内其实只有 0 座，仍全表扫一遍做剔除）
## + 地貌纹理 + 边框 + 标题。触发每帧重绘的**唯一逐帧变化**是
## _draw_player 里半径约 8px 的呼吸光晕 sin(t*3.0)。
##
## 改造：光晕脉动节流到 PULSE_FPS(12fps)，其余真实变化（玩家位置/朝向/
## 相机视野/几何输入）**立即重绘、零延迟** —— 跟手优先于省帧。
##
## 判定：
##   A 玩家位置变→ 必须同帧重绘（节流不得引入滞后）
##   B 玩家朝向变 → 必须同帧重绘（箭头不能停在旧方向）
##   C 几何输入变 → 必须同帧重绘
##   D 静止时节流生效（1 秒内重绘次数落在 12±6区间）
##   E 移动时不得被节流吞帧（60 帧移动应重绘 ≥48 次）
##   F _redraw_needed 不得复用有副作用的 _static_geometry_dirty()

const REPORT := "res://minimap_throttle_result.txt"

var _fails: Array[String] = []
var _detail: Array[String] = []


func _fail(tag: String, msg: String) -> void:
	_fails.append("[" + tag + "] " + msg)


func _okd(msg: String) -> void:
	_detail.append("OK " + msg)


func _ready() -> void:
	var lines: Array[String] = []
	lines.append("=== MINIMAP_THROTTLE_PROBE ===")

	var src := FileAccess.get_file_as_string("res://scripts/ui/minimap.gd")
	lines.append("SRC_LEN=" + str(src.length()))
	lines.append("FUNC_FOUND_update_view=" + str(src.find("func update_view") >= 0))
	lines.append("FUNC_FOUND_redraw_needed=" + str(src.find("func _redraw_needed") >= 0))
	lines.append("FUNC_FOUND_consume=" + str(src.find("func _consume_redraw_state") >= 0))

	# 【铁律·一】下面五个判定含 await，调用处必须写 await，否则 Parse Error
	#   导致整个脚本加载失败、场景空跑、进程永不退出。
	# 【铁律·二】判定函数返回 String（"true"/"false"）而不是 bool ——
	#   bool 与 String 不能用 + 拼接（Invalid operands "String" and "bool"），
	#   同样是 Parse Error → 同样表现为「挂死」而非明确报错。
	lines.append("A_MOVE_IMMEDIATE=" + await _check_move())
	lines.append("B_FACING_IMMEDIATE=" + await _check_facing())
	lines.append("C_GEOM_IMMEDIATE=" + await _check_geometry())
	lines.append("D_IDLE_THROTTLED=" + await _check_idle())
	lines.append("E_MOVE_NOT_THROTTLED=" + await _check_move_frames())
	lines.append_array(_detail)

	if _fails.is_empty():
		lines.append("MINIMAP_THROTTLE_OK")
	else:
		lines.append("MINIMAP_THROTTLE_FAIL")
		for f in _fails:
			lines.append("  " + f)
	_write(lines)


func _make_map() -> MiniMap:
	var m := MiniMap.new()
	add_child(m)
	m.size = Vector2(320.0, 220.0)
	m._map_size = Vector2(4000.0, 3000.0)
	m.view_mode = MiniMap.MODE_LOCAL
	m._player_pos = Vector2(800.0, 800.0)
	m._player_facing = Vector2.RIGHT
	m._recalc_geometry()
	# 先吃掉一次「已重绘」状态，之后再逐项改动做单点验证
	m._consume_redraw_state()
	return m


## A：玩家位置变 → 同帧必须重绘
func _check_move() -> String:
	var m := _make_map()
	m._player_pos = Vector2(1000.0, 1000.0)
	var drew := m._redraw_needed()
	if not drew:
		_fail("A", "玩家位置已变但 _redraw_needed() 返回 false ——节流把"
			+ "移动重绘也延迟了，玩家会看到小地图滞后于角色（拖影）")
		m.queue_free()
		return "false"
	_okd("A 玩家位置变化 → 同帧立即重绘")
	m.queue_free()
	return "true"


## B：朝向变 → 同帧必须重绘（否则箭头停在旧方向）
func _check_facing() -> String:
	var m := _make_map()
	m._player_facing = Vector2.DOWN
	var drew := m._redraw_needed()
	if not drew:
		_fail("B", "玩家朝向变了但 _redraw_needed() 返回 false —— "
			+ "小地图上的朝向箭头会停在旧方向")
		m.queue_free()
		return "false"
	_okd("B 玩家朝向变化 → 同帧立即重绘")
	m.queue_free()
	return "true"


## C：几何输入变（此处用 _zoom）→ 同帧必须重绘
func _check_geometry() -> String:
	var m := _make_map()
	m._zoom = 2.5
	var drew := m._redraw_needed()
	if not drew:
		_fail("C", "缩放倍率变了但 _redraw_needed() 返回 false —— "
			+ "小地图不会按新倍率重画（内容与控件不匹配）")
		m.queue_free()
		return "false"
	_okd("C 几何输入变化（_zoom）→ 同帧立即重绘")
	m.queue_free()
	return "true"


## D：静止 60 帧（≈1 秒 @60fps），重绘次数应落在 12±6
func _check_idle() -> String:
	var m := _make_map()
	var draws := 0
	for i in range(60):
		if m._redraw_needed():
			draws += 1
		#让时间推进（PULSE_INTERVAL_MS 依赖 get_ticks_msec）
		await get_tree().process_frame
	_detail.append("D_DETAIL idle_draws_60frames=" + str(draws))
	m.queue_free()
	if draws > 30:
		_fail("D", "静止 60 帧仍重绘 " + str(draws) + " 次（应≤30）—— "
			+ "节流没生效，每帧仍在重画整张 110 城地图")
		return "false"
	if draws < 3:
		_fail("D", "静止 60 帧只重绘 " + str(draws) + " 次 —— "
			+ "呼吸光晕被节流得几乎不更新，视觉上会「突然停住」")
		return "false"
	_okd("D 静止 60 帧重绘 " + str(draws) + " 次（节流生效，非 60 次全帧）")
	return "true"


## E：移动 60 帧，节流不得吞帧（应 ≥48 次）
func _check_move_frames() -> String:
	var m := _make_map()
	var draws := 0
	for i in range(60):
		m._player_pos = Vector2(800.0 + float(i) * 4.0, 800.0)
		if m._redraw_needed():
			draws += 1
		await get_tree().process_frame
	_detail.append("E_DETAIL move_draws_60frames=" + str(draws))
	m.queue_free()
	if draws < 48:
		_fail("E", "移动 60 帧只重绘 " + str(draws) + " 次（应≥48）—— "
			+ "节流吞掉了移动帧，节流必须只作用于光晕、不得作用于移动")
		return "false"
	_okd("E 移动 60 帧重绘 " + str(draws) + " 次（跟手，未被节流吞帧）")
	return "true"


func _write(lines: Array[String]) -> void:
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	get_tree().quit(0 if _fails.is_empty() else 1)

extends Node
## 【第五十九轮·探针】WalkAnim 影子联动：站定误动
##
## 缺陷：walk_anim._process 的影子联动用 `lift_k = -bob_offset / bob_amp`，
## 而 bob_offset = bob(move_k 加权) + idle((1-move_k) 加权·站定仍生效)。
## 静止时 move_k=0 → bob 贡献 0，bob_offset 退化为纯 idle 呼吸项，
## 于是「完全站定」时影子仍在周期性缩小/变淡 —— 无意义的呼吸抖动。
## 正确判据应是**抬脚量**（随 move_k 归零），而非合成后的 bob_offset。
##
## 本探针真跑量化：站定 120 帧，统计影子 scale/alpha 的波动幅度。
## A 站定时波动必须为0
## B 行走时必须 > 0（防止修 A 时矫枉过正成「影子永不动」）
## C idle_amp 与 bob_amp 的量级关系自检

const REPORT := "res://walk_shadow_result.txt"

var _fails: Array[String] = []
var _detail: Array[String] = []


func _fail(tag: String, msg: String) -> void:
	_fails.append("[" + tag + "] " + msg)


func _ready() -> void:
	var lines: Array[String] = []
	lines.append("=== WALK_SHADOW_PROBE ===")

	var src := FileAccess.get_file_as_string("res://scripts/world/walk_anim.gd")
	lines.append("SRC_LEN=" + str(src.length()))
	lines.append("FUNC_FOUND=" + str(src.find("func _process") >= 0))

	# 【铁律】下面三个判定函数是协程（含 await），调用处必须写 await，
	# 否则 Parse Error: "Function ... is a coroutine, so it must be called
	# with await" → 整个脚本加载失败 → 场景空跑 → 进程永不退出（表现为超时）。
	lines.append("A_IDLE_SHADOW_STILL=" + await _check_idle_still())
	lines.append("B_WALK_SHADOW_MOVES=" + await _check_walk_moves())
	lines.append("C_AMPLITUDE_ORDER=" + _check_amplitude())
	lines.append_array(_detail)

	if _fails.is_empty():
		lines.append("WALK_SHADOW_OK")
	else:
		lines.append("WALK_SHADOW_FAIL")
		for f in _fails:
			lines.append("  " + f)
	_write(lines)


## 造一个挂 WalkAnim 的最小宿主：body + shadow
func _make_rig(bob: float) -> Array:
	var host := Node2D.new()
	add_child(host)
	var body := Node2D.new()
	body.name = "Art"
	host.add_child(body)
	var shadow := Polygon2D.new()
	shadow.name = "Shadow"
	shadow.scale = Vector2(1.0, 0.45)
	shadow.modulate = Color(0, 0, 0, 0.22)
	host.add_child(shadow)

	var wa := WalkAnim.attach(host, body)
	wa.bob_amp = bob
	wa.shadow_node = shadow
	# 关掉腿与旋转/缩放驱动，隔离出影子这一条通路
	wa.drive_rotation = false
	wa.drive_scale = false
	return [host, wa, shadow]


## A：完全站定 120 帧，影子 scale 与 alpha 必须纹丝不动
func _check_idle_still() -> String:
	var rig := _make_rig(9.8)   # 取 npc_manager 大地图立绘分支的真实值
	var host: Node2D = rig[0]
	var shadow: Polygon2D = rig[2]
	var base_scale := shadow.scale.x
	var base_a := shadow.modulate.a

	var min_s := base_scale
	var max_s := base_scale
	var min_a := base_a
	var max_a := base_a
	# 先跑几帧让 _speed 收敛到 0（位置恒定 → 速度 0）
	for i in range(20):
		host.position = Vector2(500.0, 500.0)
		await get_tree().process_frame
	for i in range(120):
		host.position = Vector2(500.0, 500.0)
		await get_tree().process_frame
		min_s = minf(min_s, shadow.scale.x)
		max_s = maxf(max_s, shadow.scale.x)
		min_a = minf(min_a, shadow.modulate.a)
		max_a = maxf(max_a, shadow.modulate.a)

	var s_span: float = max_s - min_s
	var a_span: float = max_a - min_a
	_detail.append("A_DETAIL scale_span=" + str(s_span) + " alpha_span="
		+ str(a_span) + " base_scale=" + str(base_scale)
		+ " base_alpha=" + str(base_a))
	if s_span > 0.0001 or a_span > 0.0001:
		_fail("A", "完全站定 120 帧，影子仍在动：scale 波动 " + str(s_span)
			+ "（基准 " + str(base_scale) + "），alpha 波动 " + str(a_span)
			+ "（基准 " + str(base_a) + "）。根因：影子联动用合成后的 bob_offset"
			+ "（含站定仍生效的 idle 呼吸项）算抬脚量，没有乘 move_k。")
		return "FAIL"
	host.queue_free()
	return "OK"


## B：行走时影子必须跟着动（防止把 A 修成「影子永不动」）
func _check_walk_moves() -> String:
	var rig := _make_rig(9.8)
	var host: Node2D = rig[0]
	var shadow: Polygon2D = rig[2]
	var base_scale := shadow.scale.x

	var min_s := base_scale
	var max_s := base_scale
	for i in range(90):
		# 持续横向移动 → 速度稳定非零
		host.position = Vector2(300.0 + float(i) * 3.0, 500.0)
		await get_tree().process_frame
		min_s = minf(min_s, shadow.scale.x)
		max_s = maxf(max_s, shadow.scale.x)
	var s_span: float = max_s - min_s
	_detail.append("B_DETAIL walk_scale_span=" + str(s_span)
		+ " base_scale=" + str(base_scale))
	# 迈步时影子必须有可见起伏（至少 0.5%），否则说明联动被写死成 0
	if s_span < 0.005:
		_fail("B", "行走 90 帧影子 scale 几乎不动（波动 " + str(s_span)
			+ "）—— 若为修 A 而误把抬脚量判成恒 0，就是矫枉过正：影子失去联动")
		return "FAIL"
	host.queue_free()
	return "OK"


## C：站定时的呼吸不得压过踏步（idle 与 bob 量级关系自检）
func _check_amplitude() -> String:
	var wa := WalkAnim.new()
	wa.bob_amp = 9.8
	var idle_v: float = wa.idle_amp
	_detail.append("C_DETAIL idle_amp=" + str(idle_v) + " bob_amp=" + str(wa.bob_amp))
	if idle_v >= wa.bob_amp:
		_fail("C", "idle_amp(" + str(idle_v) + ") >= bob_amp(" + str(wa.bob_amp)
			+ ")：站定时合成 bob_offset 完全由呼吸项支配，影子误动幅度最大")
		return "FAIL"
	wa.free()
	return "OK"


func _write(lines: Array[String]) -> void:
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	get_tree().quit(0 if _fails.is_empty() else 1)

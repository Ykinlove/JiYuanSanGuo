extends Node
## UI 返回流程探针（2026-09-28 用户反馈验证）
## 运行：godot --headless --path <工程> res://tests/ui_return_probe.gd 所挂场景
##
## 验证三件事：
##   A. 轮盘入口面板（QuestPanel）标题行存在「返 回」按钮，点击 → 面板隐藏 + 发 menu_return_requested
##   B. 人物志 → 详情 转换：hero_dex 选人后先关列表再开详情（hero_dex.gd _on_pick 的既定流程），
##      转换帧「有其他界面打开」——轮询守卫条件下不得回菜单（修复「点人物弹菜单」严重 BUG 的依据）
##   C. 面板正常关闭且无任何界面打开 → 守卫条件允许回菜单（轮盘真实 open 成功）
##
## 结果写 res://ui_probe_result.txt（终端编码不可靠，以文件为准）。

var _fails := 0
var _lines: Array[String] = []


func _say(text: String) -> void:
	print(text)
	_lines.append(text)


func _check(tag: String, cond: bool) -> void:
	_say("  [%s] %s" % ["OK" if cond else "FAIL", tag])
	if not cond:
		_fails += 1


func _ready() -> void:
	_say("================ UI 返回流程探针 ================")
	await _run_a_return_button()
	await _run_b_hero_transition()
	await _run_c_close_reopens()
	_say("")
	_say("UI_PROBE_RESULT=%s" % ["PASS" if _fails == 0 else "FAIL (fails=%d)" % _fails])
	var f := FileAccess.open("res://ui_probe_result.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()
	get_tree().quit()


## 找出控件子树里的「返 回」按钮
func _find_back_btn(root: Node) -> Button:
	if root is Button and (root as Button).text == "返 回":
		return root as Button
	for c in root.get_children():
		var hit := _find_back_btn(c)
		if hit != null:
			return hit
	return null


## A. 返回按钮存在 + 信号通路
func _run_a_return_button() -> void:
	_say("")
	_say("== A. QuestPanel 返回按钮与信号 ==")
	var p := QuestPanel.new()
	add_child(p)
	await get_tree().process_frame
	var btn := _find_back_btn(p)
	_check("标题行存在「返 回」按钮", btn != null)
	var got := { "v": false }
	p.menu_return_requested.connect(func(): got["v"] = true)
	if btn != null:
		p.open()
		await get_tree().process_frame
		_check("面板打开（visible=true）", p.visible)
		btn.pressed.emit()
		await get_tree().process_frame
		_check("点击返回 → 面板隐藏", not p.visible)
		_check("点击返回 → 发出 menu_return_requested", bool(got["v"]))
	p.queue_free()
	await get_tree().process_frame


## B. 人物志→详情 转换期不得回菜单（守卫依据：有其他界面打开）
func _run_b_hero_transition() -> void:
	_say("")
	_say("== B. 人物志选人转换期守卫 ==")
	var dex := HeroDex.new()
	var detail := CharacterPanel.new()
	add_child(dex)
	add_child(detail)
	await get_tree().process_frame

	dex.open()
	await get_tree().process_frame
	_check("人物志打开", dex.visible)

	# 与 world_map._on_hero_picked 相同的承接：picked → 详情 open
	dex.picked.connect(func(h: Dictionary):
		detail.open({ "type": "hero", "name": str(h.get("name", "")),
			"title": "", "data": { "role_id": int(h.get("id", 0)) } }, true))

	# 取列表第一个真实武将触发选人（走真实 _on_pick：先关列表再开详情）
	var first: Button = null
	for c in dex.get_children():
		first = _find_first_list_button(dex)
		if first != null:
			break
	if first != null:
		first.pressed.emit()
		await get_tree().process_frame
		await get_tree().process_frame
		_check("选人后列表已关（hero_dex 不可见）", not dex.visible)
		_check("选人后人物详情已打开", detail.visible)
		# 守卫条件复算（与 world_map/city_scene _process 相同）：
		# pending=hero_dex 已隐藏，但此时「有其他界面打开」→ 不得弹菜单
		var any_open: bool = detail.visible
		_check("转换帧有界面打开 → 轮询守卫不放行（不弹菜单）", any_open)
	else:
		_check("人物志列表为空（无法触发选人）", false)
	dex.queue_free()
	detail.queue_free()
	await get_tree().process_frame


func _find_first_list_button(root: Node) -> Button:
	if root is Button and (root as Button).custom_minimum_size.y >= 84.0 \
			and (root as Button).text != "返 回" and (root as Button).text != "✕":
		return root as Button
	for c in root.get_children():
		var hit := _find_first_list_button(c)
		if hit != null:
			return hit
	return null


## C. 面板关闭且无界面打开 → 轮询守卫放行，轮盘真实打开
func _run_c_close_reopens() -> void:
	_say("")
	_say("== C. 关闭后面板回菜单 ==")
	var wheel := MainMenuWheel.new()
	var p := QuestPanel.new()
	add_child(wheel)
	add_child(p)
	await get_tree().process_frame

	p.open()
	await get_tree().process_frame
	# 模拟 world_map._process 轮询（与实现相同的守卫条件）
	var pending: Control = p
	p.close_panel()
	await get_tree().process_frame
	var hidden: bool = not is_instance_valid(pending) or not pending.visible
	var any_open: bool = wheel.is_open() or (is_instance_valid(p) and p.visible)
	if hidden and not any_open:
		wheel.open()
	await get_tree().process_frame
	_check("面板已关且无界面打开", hidden and not any_open)
	_check("轮盘菜单已重新打开", wheel.is_open())
	wheel.queue_free()
	p.queue_free()
	await get_tree().process_frame

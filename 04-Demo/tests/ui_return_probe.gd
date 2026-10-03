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
	await _run_d_wheel_center()
	_say("")
	_say("UI_PROBE_RESULT=%s" % ["PASS" if _fails == 0 else "FAIL (fails=%d)" % _fails])
	var f := FileAccess.open("res://ui_probe_result.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()
	get_tree().quit()


## 找出控件子树里的「返 回」按钮
## 【第六十四轮·修探针过时】原判据找的是 `text == "←"`，但第五十轮 UI 规范统一后
## UITheme.make_modal 的 menu_cb 分支建的是 `button("返 回", ...)`（ui_theme.gd:418）。
## 判据与实现形态不一致 → 恒为 null → A 段假 FAIL。**这不是产品回归，是探针没跟上改名。**
func _find_back_btn(root: Node) -> Button:
	# 两种文本都接受：万一将来回退成符号图标，判据不至于再次失效
	if root is Button:
		var t := (root as Button).text
		if t == "返 回" or t == "←":
			return root as Button
	for c in root.get_children():
		var hit := _find_back_btn(c)
		if hit != null:
			return hit
	return null


## 【第六十四轮·修探针过时】等待 modal 退出补间播完。
## QuestPanel.close_panel() / _on_menu_return() 都走 UITheme.modal_exit()，
## 它是 0.14s 的 Tween，`visible = false` 在 tw.finished 回调里才置位（ui_theme.gd:335-347）。
## 原探针只 `await process_frame` 一帧（约 0.016s）就断言 visible，
## 于是「面板已关」恒为 false —— 同样是探针没跟上实现，不是产品回归。
## 帧数按 0.14s @60fps 再留余量取 20 帧；超时不抛错，交给判定项报 FAIL。
func _await_modal_exit() -> void:
	for i in range(20):
		await get_tree().process_frame


## A. 返回按钮存在 + 信号通路
func _run_a_return_button() -> void:
	_say("")
	_say("== A. QuestPanel 返回按钮与信号 ==")
	var p := QuestPanel.new()
	add_child(p)
	await get_tree().process_frame
	var btn := _find_back_btn(p)
	_check("标题行存在「←」回退按钮", btn != null)
	var got := { "v": false }
	p.menu_return_requested.connect(func(): got["v"] = true)
	if btn != null:
		p.open()
		await get_tree().process_frame
		_check("面板打开（visible=true）", p.visible)
		btn.pressed.emit()
		# 【第六十四轮】_on_menu_return 走 modal_exit 补间，必须等播完再断言
		await _await_modal_exit()
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
	# 【第六十四轮·修探针过时】原判据只排除了 "←" 与 "✕"，但第五十轮后返回按钮
	# 文本改成了 "返 回"（ui_theme.gd:418 的 button("返 回", ...)），
	# 它 custom_minimum_size.y = CLOSE_SIZE.y ≥ 84，于是**先于任何武将行被匹配到** ——
	# 探针按下的是「返 回」而不是武将，picked 永不发射，详情页当然不打开。
	# 证伪过程：DBG first=true text=返 回 / DBG fired=false。
	# 修法：把标题行控件全部排除，只取 _list 容器内的行按钮。
	if root is Button:
		var t := (root as Button).text
		if t == "←" or t == "✕" or t == "返 回" or t == "返 回 ":
			return null
		if (root as Button).custom_minimum_size.y >= 84.0:
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
	# 【第六十四轮】close_panel 走 modal_exit(0.14s) 补间，visible 在 finished 才置 false，
	# 原来只等 1 帧就断言 → 「面板已关」恒 false。等补间播完。
	await _await_modal_exit()
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


## D. 菜单轮盘居中校验：【2026-09-28 修复】改用控件自身 size 居中，
## 不再用 get_viewport_rect()（与设计坐标系不一致会整盘偏移/出屏）。
## 探针根节点是普通 Node，手动把轮盘 size 设为视口尺寸、左上角对齐，模拟运行时 FULL_RECT 表现。
func _run_d_wheel_center() -> void:
	_say("")
	_say("== D. 菜单轮盘居中（size 坐标系修复） ==")
	var wheel := MainMenuWheel.new()
	# 模拟运行时：轮盘作为 FULL_RECT 控件，size == 视口、左上角 (0,0)
	var vsz := get_viewport().get_visible_rect().size
	wheel.size = vsz
	wheel.position = Vector2.ZERO
	add_child(wheel)
	await get_tree().process_frame
	wheel.open()
	await get_tree().process_frame

	var vp := get_viewport().get_visible_rect()
	var cx := vp.size.x * 0.5
	var cy := vp.size.y * 0.5
	_check("菜单已打开", wheel.is_open())

	var entries := []
	for c in wheel.get_children():
		# 入口按钮：直接子 Button，text 为空串（文字在 VBox 子节点里）；
		# 排除中心关闭键（text="✕"）与遮罩 ColorRect。
		if c is Button and c.text != "✕":
			entries.append(c)
	_check("找到 7 枚入口按钮", entries.size() == 7)

	var dist_sum := 0.0
	var all_inside := true
	for b in entries:
		var r: Rect2 = b.get_global_rect()
		var bc: Vector2 = r.position + r.size * 0.5
		dist_sum += bc.distance_to(Vector2(cx, cy))
		if r.position.x < -2.0 or r.position.y < -2.0 \
				or r.end.x > vp.size.x + 2.0 or r.end.y > vp.size.y + 2.0:
			all_inside = false
			_say("    出界按钮 %s rect=%s" % [b.text, str(r)])
	_check("全部入口按钮在视口内", all_inside)

	var avg := dist_sum / maxf(float(entries.size()), 1.0)
	_say("  入口按钮平均离屏心距离=%.0f（半径基准约 300）" % avg)
	# 坐标错乱时平均距离会极小（挤中心）或极大（偏角）；合理区间 120~360
	_check("按钮均匀环绕屏心（非挤中心/偏角）", avg > 120.0 and avg < 360.0)
	wheel.queue_free()
	await get_tree().process_frame

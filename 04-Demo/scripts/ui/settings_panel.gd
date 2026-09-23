extends Control
class_name SettingsPanel
## 系统设置面板（SettingsPanel）
## 世界地图 / 城池圆形菜单「系统」入口，主菜单「设置」入口。
## 职责：音量调节、手动存档入口、返回主菜单。音量一律走 AudioManager，
## 存档一律走 SaveManager / SaveMenu，UI 层不持任何数值公式。

signal closed

const PANEL_SIZE := Vector2(1400, 860)
const ROW_H := 62

var _title: Label
var _save_box: VBoxContainer
var _back_btn: Button
var _confirm: ConfirmationDialog


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# 半透明遮罩：点空白处关闭
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.02, 0.03, 0.7)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent):
		if (e is InputEventMouseButton and (e as InputEventMouseButton).pressed) \
				or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed):
			close())
	add_child(dim)

	var panel := PanelContainer.new()
	# 用中心锚定代替手写 1920/1080 居中（横屏拉伸视口下写死会偏）
	panel.custom_minimum_size = PANEL_SIZE
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.09, 0.08, 0.98)
	sb.border_color = Color(0.70, 0.56, 0.28, 0.95)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	# 标题 + 关闭
	var head := HBoxContainer.new()
	_title = Label.new()
	_title.text = "系统设置"
	_title.add_theme_font_size_override("font_size", 30)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.pressed.connect(close)
	head.add_child(close_btn)
	root.add_child(head)

	# 音量区
	root.add_child(_make_section_label("—— 音量 ——"))
	root.add_child(_make_volume_row("主音量", func(): return AudioManager.master_volume,
		func(v: float): AudioManager.set_master_volume(v)))
	root.add_child(_make_volume_row("背景音乐", func(): return AudioManager.bgm_volume,
		func(v: float): AudioManager.set_bgm_volume(v)))
	root.add_child(_make_volume_row("战斗音效", func(): return AudioManager.sfx_volume,
		func(v: float): AudioManager.set_sfx_volume(v)))

	# 存档区（仅在游戏内打开时显示）
	_save_box = VBoxContainer.new()
	_save_box.add_theme_constant_override("separation", 10)
	root.add_child(_save_box)

	_save_box.add_child(_make_section_label("—— 存档 ——"))
	var save_row := HBoxContainer.new()
	save_row.add_theme_constant_override("separation", 14)
	save_row.add_child(_make_action_btn("保存游戏", func():
		SaveMenu.open_as("save", "world")))
	save_row.add_child(_make_action_btn("读取存档", func():
		SaveMenu.open_as("load", "world")))
	_save_box.add_child(save_row)

	# 返回主菜单（仅在游戏内打开时显示）
	_back_btn = _make_action_btn("返回主菜单", _ask_back_to_menu)
	_back_btn.custom_minimum_size = Vector2(0, ROW_H)
	root.add_child(_back_btn)

	_confirm = ConfirmationDialog.new()
	_confirm.dialog_text = "返回主菜单？未保存的进度将丢失（自动存档已保留）。"
	_confirm.title = "返回主菜单"
	_confirm.confirmed.connect(func():
		AudioManager.sfx_confirm()
		close()
		SceneRouter.goto("main_menu"))
	_confirm.canceled.connect(func(): AudioManager.sfx_cancel())
	add_child(_confirm)


## 打开面板。in_game=false 时（主菜单入口）隐藏存档与返回主菜单区。
func open(in_game: bool = true) -> void:
	_save_box.visible = in_game
	_back_btn.visible = in_game
	visible = true


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _ask_back_to_menu() -> void:
	AudioManager.sfx_click()
	_confirm.popup_centered(Vector2(560, 200))


func _make_section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 20)
	return lbl


## 一行音量滑块：getter 取当前值，setter 写回 AudioManager
func _make_volume_row(label: String, getter: Callable, setter: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_H)
	row.add_theme_constant_override("separation", 16)

	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(150, 0)
	lbl.add_theme_font_size_override("font_size", 22)
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = float(getter.call())
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(0, 44)
	row.add_child(slider)

	var val := Label.new()
	val.custom_minimum_size = Vector2(86, 0)
	val.add_theme_font_size_override("font_size", 22)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.text = "%d%%" % int(round(slider.value * 100.0))
	row.add_child(val)

	slider.value_changed.connect(func(v: float):
		setter.call(v)
		val.text = "%d%%" % int(round(v * 100.0)))
	return row


func _make_action_btn(text: String, action: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 52)
	btn.add_theme_font_size_override("font_size", 22)
	btn.pressed.connect(func():
		AudioManager.sfx_click()
		action.call())
	return btn

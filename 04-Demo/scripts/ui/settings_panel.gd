extends Control
class_name SettingsPanel
## 系统设置面板（SettingsPanel）
## 世界地图 / 城池圆形菜单「系统」入口，主菜单「设置」入口。
## 职责：音量调节、手动存档入口、返回主菜单。音量一律走 AudioManager，
## 存档一律走 SaveManager / SaveMenu，UI 层不持任何数值公式。

signal closed

const ROW_H := 62

var _title: Label
var _save_box: VBoxContainer
var _back_btn: Button
var _confirm: ConfirmationDialog


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# 原实现硬编码 PANEL_SIZE(1400×860) + 中心锚定，本批次改为 UITheme 模态（响应式尺寸）
	var m := UITheme.make_modal(self, "系统设置", close, null, UITheme.CITY_PANEL_SIZE)
	_title = m["title"]
	# 点遮罩关闭（保留原交互）
	m["dim"].gui_input.connect(func(e: InputEvent):
		if (e is InputEventMouseButton and (e as InputEventMouseButton).pressed) \
				or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed):
			close())

	var body: VBoxContainer = m["body"]

	# 音量区
	body.add_child(_make_section_label("—— 音量 ——"))
	body.add_child(_make_volume_row("主音量", func(): return AudioManager.master_volume,
		func(v: float): AudioManager.set_master_volume(v)))
	body.add_child(_make_volume_row("背景音乐", func(): return AudioManager.bgm_volume,
		func(v: float): AudioManager.set_bgm_volume(v)))
	body.add_child(_make_volume_row("战斗音效", func(): return AudioManager.sfx_volume,
		func(v: float): AudioManager.set_sfx_volume(v)))

	# 存档区（仅在游戏内打开时显示）
	# 【M4 修复】返回目标此前写死 "world"：城内开系统→存读档→返回会落到
	# 大地图而不是城内。改为传当前真实场景 key。
	_save_box = VBoxContainer.new()
	_save_box.add_theme_constant_override("separation", 10)
	body.add_child(_save_box)

	_save_box.add_child(_make_section_label("—— 存档 ——"))
	var save_row := HBoxContainer.new()
	save_row.add_theme_constant_override("separation", 14)
	save_row.add_child(_make_action_btn("保存游戏", func():
		SaveMenu.open_as("save", SceneRouter.current_key)))
	save_row.add_child(_make_action_btn("读取存档", func():
		SaveMenu.open_as("load", SceneRouter.current_key)))
	_save_box.add_child(UITheme.row_wrap(save_row))

	# 返回主菜单（仅在游戏内打开时显示）
	_back_btn = _make_action_btn("返回主菜单", _ask_back_to_menu)
	_back_btn.custom_minimum_size = Vector2(0, ROW_H)
	m["outer"].add_child(_back_btn)

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
	return UITheme.label(text, UITheme.FS_BODY, UITheme.GOLD)


## 一行音量滑块：getter 取当前值，setter 写回 AudioManager（外包市场同款圆角行底）
func _make_volume_row(label: String, getter: Callable, setter: Callable) -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_H)
	row.add_theme_constant_override("separation", 16)

	var lbl := UITheme.label(label)
	lbl.custom_minimum_size = Vector2(150, 0)
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = float(getter.call())
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(0, 44)
	row.add_child(slider)

	var val := UITheme.label("")
	val.custom_minimum_size = Vector2(86, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.text = "%d%%" % int(round(slider.value * 100.0))
	row.add_child(val)

	slider.value_changed.connect(func(v: float):
		setter.call(v)
		val.text = "%d%%" % int(round(v * 100.0)))
	# 【L1 修复】写盘移到这里：拖动结束才 save 一次（原来每个 value_changed
	# tick 都整份重写 ConfigFile，一次拖动写盘几十次）
	slider.drag_ended.connect(func(_changed: bool):
		AudioManager.save_settings())
	return UITheme.row_wrap(row)


func _make_action_btn(text: String, action: Callable) -> Button:
	var btn := UITheme.button(text, UITheme.FS_BODY, Vector2(0, UITheme.TOUCH_H))   ## 【触控铁律】52→84
	btn.pressed.connect(func():
		AudioManager.sfx_click()
		action.call())
	return btn

extends Control
class_name AchievementPanel
## 成就面板：读取 AchievementService.definitions()（含解锁状态与进度），逐条展示。
## 解锁由 AchievementService.check_all() 在游戏中触发（交易/战斗/升级等），本面板仅展示 + 实时刷新。

signal closed

const C_CARD := Color(0.13, 0.11, 0.085, 0.97)
const C_BORDER := Color(0.72, 0.58, 0.28, 0.95)
const C_GOLD := Color(0.93, 0.80, 0.45)
const C_TEXT := Color(0.92, 0.88, 0.80)
const C_DIM := Color(0.63, 0.58, 0.50)
const C_GOOD := Color(0.62, 0.86, 0.62)

var _card: PanelContainer
var _title_label: Label
var _list: VBoxContainer


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.02, 0.015, 0.62)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_card = PanelContainer.new()
	var vp := get_viewport_rect().size
	var pw := minf(1400.0, maxf(800.0, vp.x - 40.0))
	var ph := minf(860.0, maxf(500.0, vp.y - 40.0))
	_card.custom_minimum_size = Vector2(pw, ph)
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_CARD
	sb.border_color = C_BORDER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 28.0
	sb.content_margin_right = 28.0
	sb.content_margin_top = 22.0
	sb.content_margin_bottom = 22.0
	_card.add_theme_stylebox_override("panel", sb)
	center.add_child(_card)
	_card.add_child(_build())

	EventBus.achievement_unlocked.connect(_on_unlocked)


func _build() -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 38)
	_title_label.add_theme_color_override("font_color", C_GOLD)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title_label)
	var close := Button.new()
	close.text = "✕"
	close.custom_minimum_size = Vector2(64, 64)
	close.add_theme_font_size_override("font_size", 28)
	close.pressed.connect(close_panel)
	head.add_child(close)
	root.add_child(head)
	root.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)
	root.add_child(scroll)

	return root


func _refresh() -> void:
	var defs: Array = AchievementService.definitions()
	var total := defs.size()
	var got := AchievementService.unlocked_count()
	_title_label.text = "成就　已解锁 %d / %d" % [got, total]
	_clear_list()
	for a in defs:
		_list.add_child(_make_row(a))


func _clear_list() -> void:
	for c in _list.get_children():
		c.queue_free()


## 一行：左侧名称+描述；右侧进度条 + 解锁状态/奖励
func _make_row(a: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.17, 0.14, 0.11, 0.92)
	sb.border_color = Color(0.4, 0.34, 0.22, 0.5)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)

	# 左侧：名称 + 描述
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 4)
	var name := Label.new()
	name.text = str(a.get("name", "?"))
	name.add_theme_font_size_override("font_size", 24)
	name.add_theme_color_override("font_color", C_TEXT)
	left.add_child(name)
	var desc := Label.new()
	desc.text = str(a.get("desc", ""))
	desc.add_theme_font_size_override("font_size", 19)
	desc.add_theme_color_override("font_color", C_DIM)
	left.add_child(desc)
	row.add_child(left)

	# 右侧：进度条 + 状态
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(360, 0)
	right.add_theme_constant_override("separation", 6)
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = float(a.get("progress", 0.0))
	bar.show_percentage = true
	bar.custom_minimum_size = Vector2(360, 22)
	right.add_child(bar)
	var status := Label.new()
	var unlocked := bool(a.get("unlocked", false))
	if unlocked:
		var rw := ""
		if int(a.get("reward_gold", 0)) > 0:
			rw += "金 %d " % int(a.get("reward_gold", 0))
		if int(a.get("attr_points", 0)) > 0:
			rw += "属性点 %d" % int(a.get("attr_points", 0))
		status.text = "已达成 ✦  " + rw
		status.add_theme_color_override("font_color", C_GOOD)
	else:
		var need := ""
		if int(a.get("reward_gold", 0)) > 0:
			need += "金 %d " % int(a.get("reward_gold", 0))
		if int(a.get("attr_points", 0)) > 0:
			need += "属性点 %d" % int(a.get("attr_points", 0))
		status.text = "未达成 · 奖励：%s" % need
		status.add_theme_color_override("font_color", C_DIM)
	status.add_theme_font_size_override("font_size", 18)
	right.add_child(status)
	row.add_child(right)

	panel.add_child(row)
	return panel


func _on_unlocked(_id: String) -> void:
	if visible:
		_refresh()


func open() -> void:
	visible = true
	_refresh()


func close_panel() -> void:
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close_panel()
		get_viewport().set_input_as_handled()

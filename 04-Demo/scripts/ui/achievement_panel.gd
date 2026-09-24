extends Control
class_name AchievementPanel
## 成就面板：读取 AchievementService.definitions()（含解锁状态与进度），逐条展示。
## 解锁由 AchievementService.check_all() 在游戏中触发（交易/战斗/升级等），本面板仅展示 + 实时刷新。

signal closed

## 配色/字号/容器一律走 UITheme（P3-6）

var _card: PanelContainer
var _title_label: Label
var _list: VBoxContainer


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var m := UITheme.make_modal(self, "成就", close_panel, null, UITheme.CITY_PANEL_SIZE)
	_card = m["card"]
	_title_label = m["title"]
	# 直接拿模态的滚动内容区当列表容器（模态已自带滚动）
	_list = m["body"]
	_list.add_theme_constant_override("separation", 8)

	EventBus.achievement_unlocked.connect(_on_unlocked)


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


## 一行：左侧名称+描述；右侧进度条 + 解锁状态/奖励（市场同款深色圆角行底）
func _make_row(a: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UITheme.row_style())

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)

	# 左侧：名称 + 描述
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 4)
	var name := Label.new()
	name.text = str(a.get("name", "?"))
	name.add_theme_font_size_override("font_size", UITheme.FS_BODY)
	name.add_theme_color_override("font_color", UITheme.TEXT)
	left.add_child(name)
	var desc := Label.new()
	desc.text = str(a.get("desc", ""))
	desc.add_theme_font_size_override("font_size", UITheme.FS_NOTE)
	desc.add_theme_color_override("font_color", UITheme.DIM)
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
		status.add_theme_color_override("font_color", UITheme.GOOD)
	else:
		var need := ""
		if int(a.get("reward_gold", 0)) > 0:
			need += "金 %d " % int(a.get("reward_gold", 0))
		if int(a.get("attr_points", 0)) > 0:
			need += "属性点 %d" % int(a.get("attr_points", 0))
		status.text = "未达成 · 奖励：%s" % need
		status.add_theme_color_override("font_color", UITheme.DIM)
	status.add_theme_font_size_override("font_size", UITheme.FS_NOTE)
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

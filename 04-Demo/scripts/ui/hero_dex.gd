extends Control
class_name HeroDex
## 人物志浏览器（HeroDex）
## 遍历 heroes6（825 人），按姓名搜索，点击某位武将 → 回调 picked(hero)，
## 由调用方打开人物详情面板（CharacterPanel）。本面板不含任何数值公式。

signal picked(hero: Dictionary)
signal closed

const MAX_ROWS := 300      ## 单次最多渲染的结果数，避免一次性建 825 个节点卡顿

var _search: LineEdit
var _list: VBoxContainer
var _title: Label


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# 全屏遮罩
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.02, 0.03, 0.72)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent):
		if (e is InputEventMouseButton and (e as InputEventMouseButton).pressed) \
				or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed):
			close())
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var card := PanelContainer.new()
	var vp := get_viewport_rect().size
	var pw := minf(1400.0, maxf(800.0, vp.x - 40.0))
	var ph := minf(860.0, maxf(500.0, vp.y - 40.0))
	card.custom_minimum_size = Vector2(pw, ph)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.10, 0.08, 0.98)
	sb.border_color = Color(0.70, 0.56, 0.28, 0.95)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 28.0
	sb.content_margin_right = 28.0
	sb.content_margin_top = 22.0
	sb.content_margin_bottom = 22.0
	card.add_theme_stylebox_override("panel", sb)
	center.add_child(card)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	card.add_child(root)

	# 头部
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	_title = Label.new()
	_title.text = "人物志 · 群英录"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.add_theme_font_size_override("font_size", 38)
	_title.add_theme_color_override("font_color", Color(0.93, 0.80, 0.45))
	head.add_child(_title)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(64, 64)
	close_btn.add_theme_font_size_override("font_size", 28)
	close_btn.pressed.connect(close)
	head.add_child(close_btn)
	root.add_child(head)

	# 搜索框
	_search = LineEdit.new()
	_search.placeholder_text = "输入姓名搜索（如：赵云 / 曹操）"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.custom_minimum_size = Vector2(0, 64)
	_search.add_theme_font_size_override("font_size", 26)
	_search.text_submitted.connect(_build_list)
	_search.text_changed.connect(_build_list)
	root.add_child(_search)

	# 列表
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)
	root.add_child(scroll)


func open() -> void:
	visible = true
	_search.text = ""
	_build_list("")


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func _faction_name(fid: int) -> String:
	if fid <= 0:
		return ""
	var f := DataManager.get_faction6(fid)
	if f.is_empty():
		return ""
	return str(f.get("name", ""))


func _build_list(q: String) -> void:
	for c in _list.get_children():
		c.queue_free()
	var heroes: Array = DataManager.get_heroes6()
	var shown := 0
	for h in heroes:
		var name := str(h.get("name", ""))
		if not q.is_empty() and not name.contains(q):
			continue
		_add_row(h, name)
		shown += 1
		if shown >= MAX_ROWS:
			break
	if shown == 0:
		var hint := Label.new()
		hint.text = "未找到「%s」相关人物。" % q
		hint.add_theme_font_size_override("font_size", 22)
		hint.add_theme_color_override("font_color", Color(0.62, 0.57, 0.50))
		_list.add_child(hint)
	else:
		var cnt := Label.new()
		cnt.text = "共 %d 人（最多显示 %d）" % [shown, MAX_ROWS]
		cnt.add_theme_font_size_override("font_size", 18)
		cnt.add_theme_color_override("font_color", Color(0.62, 0.57, 0.50))
		_list.add_child(cnt)


func _add_row(h: Dictionary, name: String) -> void:
	var faction := _faction_name(int(h.get("faction_id", 0)))
	var sub := str(h.get("title_id", ""))
	if not faction.is_empty():
		sub = (sub + "　" if not sub.is_empty() else "") + faction
	var b := Button.new()
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(0, 72)
	b.add_theme_font_size_override("font_size", 24)
	b.text = name if sub.is_empty() else "%s　·　%s" % [name, sub]
	b.pressed.connect(func(): _on_pick(h))
	_list.add_child(b)


func _on_pick(h: Dictionary) -> void:
	AudioManager.sfx_confirm()
	close()
	picked.emit(h)


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

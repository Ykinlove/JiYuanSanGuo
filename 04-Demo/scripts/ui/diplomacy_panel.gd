extends Control
class_name DiplomacyPanel
## 外交面板（DiplomacyPanel）
## 世界地图圆形菜单「外交」入口。展示各主要势力关系值 + 三个已实装外交手段
## （结盟/通商/宣战）+ 投靠势力入口。全部规则调 DiplomacyService / FactionService，
## UI 层不含任何公式。
## 消息经 EventBus.toast 广播（world_map 已连接 show_toast）。

signal closed

const PANEL_SIZE := Vector2(900, 640)
const ROW_H := 64

var _rows: VBoxContainer
var _join_rows: VBoxContainer
var _title: Label


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
	# 用「中心锚定」代替手写 1920/1080 居中：
	# stretch/aspect = expand 下视口可能不是 1920×1080（20:9 机型约 2400×1080），
	# 手写居中会让面板偏左，且窗口尺寸一变就错位。
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
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	# 标题 + 关闭
	var head := HBoxContainer.new()
	_title = Label.new()
	_title.text = "外交"
	_title.add_theme_font_size_override("font_size", 30)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.pressed.connect(close)
	head.add_child(close_btn)
	root.add_child(head)

	# 投靠势力区
	var join_label := Label.new()
	join_label.text = "—— 投靠势力 ——"
	join_label.add_theme_font_size_override("font_size", 20)
	root.add_child(join_label)
	_join_rows = VBoxContainer.new()
	_join_rows.add_theme_constant_override("separation", 4)
	root.add_child(_join_rows)

	# 外交关系区（滚动）
	var rel_label := Label.new()
	rel_label.text = "—— 势力关系 ——"
	rel_label.add_theme_font_size_override("font_size", 20)
	root.add_child(rel_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 280)
	root.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 6)
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows)

func open() -> void:
	_refresh()
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


func _refresh() -> void:
	if GameState.affiliation == 0:
		_title.text = "外交 · 投靠"
		_show_join_list()
	else:
		_title.text = "外交 · %s（%s）" % [
			FactionService.faction_name(), FactionService.current_rank_name()]
		_refresh_join_rows()
	_refresh_relation_rows()


## 未投靠 → 显示可投靠势力；已投靠 → 隐藏投靠列表区
func _refresh_join_rows() -> void:
	for c in _join_rows.get_children():
		c.queue_free()


func _show_join_list() -> void:
	for c in _join_rows.get_children():
		c.queue_free()
	for a in FactionService.available_affiliations():
		_join_rows.add_child(_make_join_row(a))


func _make_join_row(a: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	var lbl := Label.new()
	var capital := str(a.get("capital_name", a.get("capital", "")))
	lbl.text = "【%s】%s" % [str(a.get("name", "")), capital]
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var fid := int(a.get("id", 0))
	var btn := Button.new()
	btn.text = "投靠"
	btn.pressed.connect(func():
		var r := FactionService.join(fid)
		EventBus.toast.emit(str(r.get("msg", "")))
		_refresh())
	row.add_child(btn)
	return row


## 重建关系区各行
func _refresh_relation_rows() -> void:
	for c in _rows.get_children():
		c.queue_free()
	for f in DiplomacyService.list_all():
		_rows.add_child(_make_relation_row(f))


func _make_relation_row(f: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_H)
	var lbl := Label.new()
	var fid := int(f.get("faction_id", 0))
	var st := str(f.get("status", "中立"))
	var st_color := Color(0.8, 0.8, 0.8)
	match st:
		"同盟": st_color = Color(0.72, 0.92, 0.75)
		"友好": st_color = Color(0.72, 0.86, 0.98)
		"中立": st_color = Color(0.85, 0.82, 0.78)
		"敌对": st_color = Color(0.98, 0.60, 0.55)
		"死敌": st_color = Color(0.95, 0.35, 0.35)
	var rel_text := " %s　关系 %d　[%s]" % [str(f.get("name", "")), int(f.get("value", 0)), st]
	lbl.text = rel_text
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.self_modulate = st_color
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	row.add_child(_make_action_btn(fid, "结盟", "alliance"))
	row.add_child(_make_action_btn(fid, "通商", "trade"))
	row.add_child(_make_action_btn(fid, "宣战", "war"))
	return row


func _make_action_btn(fid: int, label: String, method: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(80, 40)
	btn.pressed.connect(func():
		var r: Dictionary
		match method:
			"alliance":
				r = DiplomacyService.alliance(fid)
			"trade":
				r = DiplomacyService.trade(fid)
			"war":
				r = DiplomacyService.war(fid)
			_:
				r = { "ok": false, "msg": "未知外交手段。" }
		EventBus.toast.emit(str(r.get("msg", "")))
		_refresh())
	return btn

extends Control
class_name QuestPanel
## 任务中心面板：展示进行中任务的目标进度与已完成列表。
## 交付不在此处：目标全达成后回发布任务的 NPC 对话提交。
## 全屏深色遮罩 + 居中卡片 1400×900，代码动态构建（不往 tscn 堆控件）。

const C_BG := Color(0.08, 0.07, 0.06, 0.86)
const C_CARD := Color(0.94, 0.91, 0.84, 0.98)
const C_ROW := Color(0.98, 0.96, 0.90, 1.0)
const C_BORDER := Color(0.45, 0.38, 0.26, 0.55)
const C_TEXT := Color(0.22, 0.17, 0.11)
const C_SUB := Color(0.42, 0.35, 0.24)
const C_DONE := Color(0.20, 0.55, 0.30)
const C_ACCENT := Color(0.62, 0.30, 0.18)

var _list: VBoxContainer
var _npc_label: Label


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = C_BG
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(1400, 900)
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_CARD
	sb.border_color = C_BORDER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 28.0
	sb.content_margin_right = 28.0
	sb.content_margin_top = 20.0
	sb.content_margin_bottom = 20.0
	card.add_theme_stylebox_override("panel", sb)
	center.add_child(card)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	card.add_child(vbox)

	# 顶栏：标题 + 关闭
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	vbox.add_child(head)
	var title := Label.new()
	title.text = "任 务 中 心"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", C_TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close := Button.new()
	close.text = "✕ 关闭"
	close.custom_minimum_size = Vector2(140, 60)
	close.add_theme_font_size_override("font_size", 24)
	close.pressed.connect(close_panel)
	head.add_child(close)

	# 简介行
	_npc_label = Label.new()
	_npc_label.text = "任务目标全部达成后，回到发布任务的 NPC 处交谈即可提交。"
	_npc_label.add_theme_font_size_override("font_size", 22)
	_npc_label.add_theme_color_override("font_color", C_SUB)
	vbox.add_child(_npc_label)

	# 滚动列表
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 14)
	scroll.add_child(_list)


## 打开面板并刷新
func open() -> void:
	visible = true
	_refresh()


func close_panel() -> void:
	visible = false


func is_open() -> bool:
	return visible


func _refresh() -> void:
	for c in _list.get_children():
		c.queue_free()

	var active := 0
	for qid in GameState.active_quests:
		var q := QuestService.get_quest(str(qid))
		if q.is_empty():
			continue
		active += 1
		_list.add_child(_make_quest_card(q))

	if active == 0:
		var empty := Label.new()
		empty.text = "当前没有进行中的任务。去和城中 NPC 交谈，或许能接到委托。"
		empty.add_theme_font_size_override("font_size", 26)
		empty.add_theme_color_override("font_color", C_SUB)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_list.add_child(empty)

	# 已完成
	var done_header := Label.new()
	done_header.text = "—— 已完成 ——"
	done_header.add_theme_font_size_override("font_size", 24)
	done_header.add_theme_color_override("font_color", C_SUB)
	done_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_list.add_child(done_header)
	if GameState.completed_quests.is_empty():
		var none := Label.new()
		none.text = "（暂无）"
		none.add_theme_font_size_override("font_size", 22)
		none.add_theme_color_override("font_color", C_SUB)
		none.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_list.add_child(none)
	else:
		for qid in GameState.completed_quests:
			var q := QuestService.get_quest(str(qid))
			if q.is_empty():
				continue
			var row := Label.new()
			row.text = "✔ %s" % str(q.get("title", qid))
			row.add_theme_font_size_override("font_size", 24)
			row.add_theme_color_override("font_color", C_DONE)
			row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_list.add_child(row)


## 单个任务卡片：标题 + 描述 + 目标进度 + （可交付时）交付按钮
func _make_quest_card(q: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_ROW
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	panel.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var qid := str(q.get("id", ""))
	var title := Label.new()
	title.text = "【%s】%s" % [str(q.get("type", "side")), str(q.get("title", qid))]
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", C_TEXT)
	vbox.add_child(title)

	var desc := Label.new()
	desc.text = str(q.get("description", ""))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 22)
	desc.add_theme_color_override("font_color", C_SUB)
	vbox.add_child(desc)

	var ready := true
	for p in QuestService.progress(q):
		var obj := Label.new()
		if bool(p["done"]):
			obj.text = "✔ %s（%d/%d）" % [str(p["desc"]), int(p["cur"]), int(p["need"])]
			obj.add_theme_color_override("font_color", C_DONE)
		else:
			obj.text = "· %s（%d/%d）" % [str(p["desc"]), int(p["cur"]), int(p["need"])]
			obj.add_theme_color_override("font_color", C_TEXT)
			ready = false
		obj.add_theme_font_size_override("font_size", 24)
		vbox.add_child(obj)

	# 交付改在发布任务的 NPC 对话中进行（不走任务中心按钮）
	if ready and GameState.active_quests.has(qid):
		var hint := Label.new()
		hint.text = "✔ 目标已全部达成：回去找发布人提交吧"
		hint.add_theme_font_size_override("font_size", 22)
		hint.add_theme_color_override("font_color", C_ACCENT)
		vbox.add_child(hint)

	return panel

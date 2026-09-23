extends Control
class_name QuestPanel
## 任务中心面板：展示进行中任务的目标进度与已完成列表。
## 交付不在此处：目标全达成后回发布任务的 NPC 对话提交。
## 配色/字号/容器一律走 UITheme（P3-6）——原先这里是全局唯一的亮色卡片，
## 米白底 + 深棕字，与水墨描金暗色整体风格冲突，本批次已归入暗色。

var _list: VBoxContainer
var _npc_label: Label


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var m := UITheme.make_modal(self, "任 务 中 心", close_panel)
	var body: VBoxContainer = m["body"]

	# 简介行
	_npc_label = UITheme.label("任务目标全部达成后，回到发布任务的 NPC 处交谈即可提交。",
		UITheme.FS_NOTE, UITheme.DIM)
	_npc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_npc_label)

	# 滚动列表（刷新时只清这一层）
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 14)
	body.add_child(_list)


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
		var empty := UITheme.label("当前没有进行中的任务。去和城中 NPC 交谈，或许能接到委托。",
			UITheme.FS_BODY, UITheme.DIM)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_list.add_child(empty)

	# 已完成
	var done_header := UITheme.label("—— 已完成 ——", UITheme.FS_BODY, UITheme.DIM)
	done_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_list.add_child(done_header)
	if GameState.completed_quests.is_empty():
		var none := UITheme.label("（暂无）", UITheme.FS_NOTE, UITheme.DIM)
		none.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_list.add_child(none)
	else:
		for qid in GameState.completed_quests:
			var q := QuestService.get_quest(str(qid))
			if q.is_empty():
				continue
			var row := UITheme.label("✔ %s" % str(q.get("title", qid)), UITheme.FS_BODY, UITheme.GOOD)
			row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_list.add_child(row)


## 单个任务卡片：标题 + 描述 + 目标进度 + （全部达成时）回 NPC 提交的提示
func _make_quest_card(q: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UITheme.inner_style())

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var qid := str(q.get("id", ""))
	vbox.add_child(UITheme.label("【%s】%s" % [str(q.get("type", "side")), str(q.get("title", qid))],
		UITheme.FS_HEAD, UITheme.TEXT))

	var desc := UITheme.label(str(q.get("description", "")), UITheme.FS_NOTE, UITheme.DIM)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)

	var ready := true
	for p in QuestService.progress(q):
		var done := bool(p["done"])
		var obj := UITheme.label(
			("%s %s（%d/%d）" % ["✔" if done else "·", str(p["desc"]), int(p["cur"]), int(p["need"])]),
			UITheme.FS_BODY, UITheme.GOOD if done else UITheme.TEXT)
		vbox.add_child(obj)
		if not done:
			ready = false

	# 交付改在发布任务的 NPC 对话中进行（不走任务中心按钮）
	if ready and GameState.active_quests.has(qid):
		vbox.add_child(UITheme.label("✔ 目标已全部达成：回去找发布人提交吧",
			UITheme.FS_NOTE, UITheme.POINT))

	return panel

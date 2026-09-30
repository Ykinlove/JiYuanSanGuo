extends Control
class_name QuestPanel
## 任务中心面板：展示进行中任务的目标进度与已完成列表。
## 交付不在此处：目标全达成后回发布任务的 NPC 对话提交。
## 配色/字号/容器一律走 UITheme（P3-6）——原先这里是全局唯一的亮色卡片，
## 米白底 + 深棕字，与水墨描金暗色整体风格冲突，本批次已归入暗色。

## 【2026-09-28 用户反馈】标题行「返 回」按钮：关面板并要求场景重开轮盘菜单
signal menu_return_requested

var _list: VBoxContainer
var _npc_label: Label
var _scroll: ScrollContainer
var _modal: Dictionary
var _anim_tw: Tween = null


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var m := UITheme.make_modal(self, "任 务 中 心", close_panel, null, UITheme.CITY_PANEL_SIZE, _on_menu_return)
	_modal = m
	_scroll = m["scroll"]
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
	if _anim_tw != null and _anim_tw.is_valid():
		_anim_tw.kill()
	visible = true
	_anim_tw = UITheme.modal_enter(_modal)
	_refresh()
	_scroll.scroll_vertical = 0   ## 【M1】打开复位滚动


func close_panel() -> void:
	if _anim_tw != null and _anim_tw.is_valid():
		_anim_tw.kill()
	_anim_tw = UITheme.modal_exit(_modal, _finish_close)


func _finish_close() -> void:
	visible = false


## 「返 回」按钮：隐藏面板并通知场景重开轮盘菜单（由场景连接 menu_return_requested）
func _on_menu_return() -> void:
	if _anim_tw != null and _anim_tw.is_valid():
		_anim_tw.kill()
	_anim_tw = UITheme.modal_exit(_modal, _finish_menu_return)


func _finish_menu_return() -> void:
	visible = false
	menu_return_requested.emit()


func is_open() -> bool:
	return visible


func _refresh() -> void:
	for c in _list.get_children():
		# 先摘除再释放：queue_free 帧末才生效，旧按钮本帧仍可被点第二次
		_list.remove_child(c)
		c.queue_free()

	var active := 0
	# 投靠意向（两段式投靠的第一步）也作为一张「进行中任务」卡展示
	if GameState.join_intent > 0 and GameState.affiliation == 0:
		active += 1
		_list.add_child(_make_join_intent_card())
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


## 任务类型英文 id → 中文（quests.json 的 type 是 mainline/side 等原始 id，
## 直接显示会【mainline】这样中英夹杂）
func _type_cn(t: String) -> String:
	match t:
		"mainline": return "主线"
		"side": return "支线"
		"daily": return "日常"
		"join": return "投靠"
		"escort": return "护送"
		"gather": return "采集"
		_: return t if t.is_empty() else "委托"


## 投靠意向卡：提示去都城面见主公交投名状（放弃按钮提供反悔出口）
func _make_join_intent_card() -> PanelContainer:
	var fid := GameState.join_intent
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UITheme.inner_style())
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)
	vbox.add_child(UITheme.label("【投靠】投名状 · 面见 %s 主公"
		% FactionService._faction_name(fid), UITheme.FS_HEAD, UITheme.TEXT))
	var desc := UITheme.label(
		"你已向「%s」表明投靠意向。亲自前往其都城【%s】，面见主公献上投名状（金钱 %d），即可正式入门。"
		% [FactionService._faction_name(fid),
		FactionService._faction_capital_name(fid), FactionService.JOIN_PLEDGE_GOLD],
		UITheme.FS_NOTE, UITheme.DIM)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)
	vbox.add_child(UITheme.label("· 前往都城面见主公（未完成）", UITheme.FS_BODY, UITheme.TEXT))
	var cancel := UITheme.button("放弃投靠意向", UITheme.FS_NOTE, Vector2(200, UITheme.TOUCH_H))   ## 【触控铁律】48→84
	cancel.size_flags_horizontal = Control.SIZE_SHRINK_END
	cancel.pressed.connect(func():
		FactionService.cancel_join_intent()
		EventBus.toast.emit("已放弃投靠意向。")
		_refresh())
	vbox.add_child(cancel)
	return panel


## 单个任务卡片：标题 + 描述 + 目标进度 + （全部达成时）回 NPC 提交的提示
func _make_quest_card(q: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UITheme.inner_style())

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var qid := str(q.get("id", ""))
	vbox.add_child(UITheme.label("【%s】%s" % [_type_cn(str(q.get("type", "side"))),
		str(q.get("title", qid))], UITheme.FS_HEAD, UITheme.TEXT))

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
		# 可交付卡整卡金边高亮（与列表选中行同观感），一眼锁定「该去交任务了」
		panel.add_theme_stylebox_override("panel", UITheme.row_style(true))
		# 指名发布人：让玩家明确「去找谁」，而非笼统的「找发布人」。
		var giver_name := "发布人"
		var giver_id := str(q.get("giver_npc", ""))
		if not giver_id.is_empty():
			var giver := DataManager.get_record("npcs", giver_id)
			if not giver.is_empty():
				giver_name = str(giver.get("name", giver_name))
		vbox.add_child(UITheme.label("✔ 目标已全部达成：去找【%s】对话，选择「提交任务」" % giver_name,
			UITheme.FS_NOTE, UITheme.GOLD))

	return panel

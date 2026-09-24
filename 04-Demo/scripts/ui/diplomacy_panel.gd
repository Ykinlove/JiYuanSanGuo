extends Control
class_name DiplomacyPanel
## 外交面板（DiplomacyPanel）
## 世界地图圆形菜单「外交」入口。展示各主要势力关系值 + 三个已实装外交手段
## （结盟/通商/宣战）+ 投靠势力入口。全部规则调 DiplomacyService / FactionService，
## UI 层不含任何公式。
## 消息经 EventBus.toast 广播（world_map 已连接 show_toast）。

signal closed

const ROW_H := 64

var _rows: VBoxContainer
var _join_rows: VBoxContainer
var _title: Label


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# 原实现硬编码 PANEL_SIZE(1400×860) + 关系区嵌套一层滚动；
	# 本批次改为 UITheme 模态（响应式尺寸 + 单一滚动区），配色/字号统一。
	var m := UITheme.make_modal(self, "外交", close, null, UITheme.CITY_PANEL_SIZE)
	_title = m["title"]
	# 点遮罩关闭（保留原交互）
	m["dim"].gui_input.connect(func(e: InputEvent):
		if (e is InputEventMouseButton and (e as InputEventMouseButton).pressed) \
				or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed):
			close())

	var body: VBoxContainer = m["body"]

	# 投靠势力区
	body.add_child(UITheme.label("—— 投靠势力 ——", UITheme.FS_BODY, UITheme.GOLD))
	_join_rows = _make_block(4)
	body.add_child(_join_rows)

	# 外交关系区
	body.add_child(UITheme.label("—— 势力关系 ——", UITheme.FS_BODY, UITheme.GOLD))
	_rows = _make_block(6)
	body.add_child(_rows)


func _make_block(sep: int) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return v


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
	# 两段式投靠提示
	if GameState.join_intent > 0:
		var hint := UITheme.label(
			"已向「%s」表明投靠意向：前往其都城【%s】面见主公，献上投名状（金钱 %d）即可入门。"
			% [FactionService._faction_name(GameState.join_intent),
			FactionService._faction_capital_name(GameState.join_intent),
			FactionService.JOIN_PLEDGE_GOLD],
			UITheme.FS_NOTE, UITheme.POINT)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_join_rows.add_child(hint)


func _make_join_row(a: Dictionary) -> Control:
	var row := HBoxContainer.new()
	var lbl := UITheme.label("【%s】%s" % [str(a.get("name", "")),
		str(a.get("capital_name", a.get("capital", "")))])
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var fid := int(a.get("id", 0))
	if GameState.join_intent == fid:
		# 已表明意向：显示状态，按钮变「放弃」可反悔
		var state := UITheme.button("意向中", UITheme.FS_BODY, Vector2(120, 48))
		state.disabled = true
		row.add_child(state)
		var cancel := UITheme.button("放弃", UITheme.FS_BODY, Vector2(96, 48))
		cancel.pressed.connect(func():
			FactionService.cancel_join_intent()
			EventBus.toast.emit("已放弃投靠意向。")
			_refresh())
		row.add_child(cancel)
		return UITheme.row_wrap(row)
	var btn := UITheme.button("投靠", UITheme.FS_BODY, Vector2(120, 48))
	btn.pressed.connect(func():
		# 两段式投靠第一步：只表明意向，需亲自去都城面见主公完成投名状
		var r := FactionService.request_join(fid)
		EventBus.toast.emit(str(r.get("msg", "")))
		_refresh())
	row.add_child(btn)
	return UITheme.row_wrap(row)


## 重建关系区各行
func _refresh_relation_rows() -> void:
	for c in _rows.get_children():
		c.queue_free()
	for f in DiplomacyService.list_all():
		_rows.add_child(_make_relation_row(f))


func _make_relation_row(f: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_H)
	var fid := int(f.get("faction_id", 0))
	var st := str(f.get("status", "中立"))
	var st_color: Color = UITheme.REL_NEUTRAL
	match st:
		"同盟": st_color = UITheme.REL_ALLY
		"友好": st_color = UITheme.REL_FRIEND
		"中立": st_color = UITheme.REL_NEUTRAL
		"敌对": st_color = UITheme.REL_HOSTILE
		"死敌": st_color = UITheme.REL_MORTAL
	var lbl := UITheme.label(" %s　关系 %d　[%s]" % [
		str(f.get("name", "")), int(f.get("value", 0)), st], UITheme.FS_NOTE, st_color)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	row.add_child(_make_action_btn(fid, "结盟", "alliance"))
	row.add_child(_make_action_btn(fid, "通商", "trade"))
	row.add_child(_make_action_btn(fid, "宣战", "war"))
	return UITheme.row_wrap(row)


func _make_action_btn(fid: int, label: String, method: String) -> Button:
	var btn := UITheme.button(label, UITheme.FS_NOTE, Vector2(96, 44))
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

class_name SelfRulePanel
extends Control
## 自立为王面板（SelfRulePanel）
## 职责：在祠堂触发「自立为王」——展示自立状态（村庄声望/名声/恶名/判定值/信物）、
##       输入国号、选择旗帜、发起自立（走 SelfRuleService 规则层），或已自立后改国号/换旗。
## 规则与数值全部由 SelfRuleService 结算，本面板不内联公式。

signal closed
## 【2026-09-28 用户反馈】标题行「返 回」按钮：关面板并要求场景重开轮盘菜单
signal menu_return_requested

var _title: Label
var _status: Label
var _name_edit: LineEdit
var _flag_box: HBoxContainer
var _flag_selected: int = 1
var _confirm: Button
var _close: Button
var _flag_btns: Array = []
var _flag_group: ButtonGroup   ## 【M2】五面旗共享互斥组
var _self_rule_city := ""
## 【第六十三轮·防误触】自立建国是全局最重的不可逆操作，确认弹窗状态。
## 建国的代价（全部不可逆、且无任何撤销路径）：
##   ① GameState.is_self_rule 置真后，全工程仅 GameState.reset()（开新档）能写回 false
##      —— 本局内不可退；
##   ② 全部势力关系 DiplomacyService.modify(fid, -10)，不可逆（外交手段只加不返）；
##   ③ 已有投靠意向 join_intent 直接作废；
##   ④ 失败结局线自此开启（SelfRuleService.check_ending 逐月跑，infamy>=80 即终局）。
var _found_confirm: Control = null
var _pending_found_name := ""
var _pending_found_flag := 1
var _pending_found_city := ""

## 旗帜纹样数（D-09 选旗帜）
const FLAG_COUNT := 5


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()


func _build_ui() -> void:
	# 原实现是手写绝对坐标（position/size 硬编码 1920 布局）且没有全屏遮罩，
	# 本批次改为容器布局 + UITheme 模态，字号/配色统一。
	var m := UITheme.make_modal(self, "自 立 为 王", close, null, UITheme.CITY_PANEL_SIZE, _on_menu_return)
	_title = m["title"]
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var body: VBoxContainer = m["body"]

	_status = UITheme.label("", UITheme.FS_HEAD, UITheme.TEXT)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_status)

	# 国号
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 12)
	name_row.add_child(UITheme.label("国号：", UITheme.FS_HEAD))
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "输入国号（如 大燕 / 蜀汉）"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.custom_minimum_size = Vector2(0, 48)
	_name_edit.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	name_row.add_child(_name_edit)
	body.add_child(name_row)

	# 旗帜
	var flag_row := HBoxContainer.new()
	flag_row.add_theme_constant_override("separation", 12)
	flag_row.add_child(UITheme.label("旗帜：", UITheme.FS_HEAD))
	_flag_box = HBoxContainer.new()
	_flag_box.add_theme_constant_override("separation", 16)
	flag_row.add_child(_flag_box)
	body.add_child(flag_row)
	for i in range(1, FLAG_COUNT + 1):
		_flag_box.add_child(_make_flag_btn(i))

	# 底部按钮：固定在滚动区之外
	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_theme_constant_override("separation", 24)
	_confirm = UITheme.button("自立建国", UITheme.FS_HEAD, Vector2(200, UITheme.TOUCH_H))   ## 【触控铁律】56→84
	_confirm.pressed.connect(_on_confirm)
	btns.add_child(_confirm)
	_close = UITheme.button("返回", UITheme.FS_BODY, Vector2(120, UITheme.TOUCH_H))   ## 【触控铁律】56→84
	_close.pressed.connect(close)
	btns.add_child(_close)
	m["outer"].add_child(btns)


## 单个旗帜按钮（抽成函数，避免 lambda 捕获循环变量的老坑）
## 【M2】共享同一个 ButtonGroup——原先每键各建 group，五面旗可同时呈按下态
func _make_flag_btn(idx: int) -> Button:
	var b := UITheme.button("旗%d" % idx, UITheme.FS_BODY, Vector2(86, UITheme.TOUCH_H))   ## 【触控铁律】48→84
	b.toggle_mode = true
	if _flag_group == null:
		_flag_group = ButtonGroup.new()
	b.button_group = _flag_group
	b.pressed.connect(func(): _flag_selected = idx)
	_flag_btns.append(b)
	return b


## 打开面板：传入触发城池（祠堂所在）。
## 【需求 4】自立改为任务链触发：须先游历天下寻得杨雷鹏、杨子轩、李明三位名士，
## 完成其托付（story_flag self_rule_unlocked）后方可建国。未解锁时只给提示，不弹表单。
func open(city_id: String = "") -> void:
	if not GameState.is_self_rule and not SelfRuleService.chain_unlocked():
		var p := SelfRuleService.mentor_progress()
		EventBus.show_toast("欲自立为王，须先游历天下，寻得杨雷鹏、杨子轩、李明三位名士" \
			+ "（%d/%d 已托付），完成其托付方可建国。" % [int(p.get("done", 0)), int(p.get("total", 3))])
		return
	_self_rule_city = city_id
	if _self_rule_city.is_empty():
		_self_rule_city = GameState.current_city_id
	## 【M2】复位选择态：二次打开不残留上次的旗帜按下与选中值。
	## 【第六十三轮·防误触】连带清掉可能残留的建国确认遮罩：
	## close() 只是 visible=false，sub-modal 是本节点的子节点，会跟着一起隐藏但**并未释放**；
	## 下次打开时一个不可见的旧遮罩会挡住 _show_found_confirm 的幂等守卫，
	## 表现为「点自立建国毫无反应」。
	if _found_confirm != null and is_instance_valid(_found_confirm):
		_found_confirm.queue_free()
	_found_confirm = null
	_pending_found_city = ""
	_pending_found_name = ""
	_pending_found_flag = 1
	## 【修复】复位值写成 0 却没把任何一面旗设为按下（成员初值是 1，两处自相矛盾），
	## 玩家不选旗直接建国会落 self_rule_flag = 0，而合法纹样是 1~5。改默认选中 1 号旗。
	_flag_selected = 1
	for i in range(_flag_btns.size()):
		(_flag_btns[i] as Button).button_pressed = (i == 0)
	_refresh()
	visible = true


func is_open() -> bool:
	return visible


func close() -> void:
	visible = false
	closed.emit()


## 「返 回」按钮：隐藏面板并通知场景重开轮盘菜单
func _on_menu_return() -> void:
	visible = false
	menu_return_requested.emit()


func _refresh() -> void:
	var st := SelfRuleService.status(_self_rule_city)
	var lines: Array[String] = []
	if GameState.is_self_rule:
		lines.append("已自立为王：国号「%s」，都城「%s」，旗帜纹样 %d" % [
			GameState.self_rule_name, GameState.self_rule_city, GameState.self_rule_flag])
		lines.append("自立后天下势力视你为敌，外交关系普遍下降。")
		_name_edit.editable = true
		_confirm.text = "改国号"
	else:
		lines.append("自立判定值 = 村庄声望 + 名声 - 恶名")
		lines.append("  村庄声望 %d / 名声 %d / 恶名 %d" % [
			int(st.get("village_fame", 0)), int(st.get("fame", 0)), int(st.get("infamy", 0))])
		lines.append("  判定值 %d / 阈值 %d" % [
			int(st.get("judgment", 0)), int(st.get("threshold", 0))])
		lines.append("  建国信物：%s" % (
			"齐备（玉玺+虎符）" if st.get("seals_ok", false) else "未齐（玉玺+虎符）"))
		var pre := SelfRuleService.can_attempt(_self_rule_city)
		lines.append(str(pre.get("reason", "")) if not bool(pre.get("ok", false))
			else "条件已满足，可以自立建国！")
		_confirm.text = "自立建国"
	_status.text = char(10).join(lines)
	if not GameState.is_self_rule:
		_name_edit.text = ""
	else:
		_name_edit.text = GameState.self_rule_name


func _on_confirm() -> void:
	if GameState.is_self_rule:
		# 改国号/换旗是**可逆**的（随时能再改回来），不该加确认步骤。
		var r := SelfRuleService.rename(_name_edit.text)
		# 【修复】改国号失败时不能 _refresh()：它会拿 GameState 的旧国号覆盖输入框，
		# 玩家刚清空的内容被静默改写，还以为改成功了。只有成功才刷新。
		if bool(r.get("ok", false)):
			_refresh()
		EventBus.show_toast(str(r.get("reason", "")))
		return
	# 【第六十三轮·防误触】未自立时点「自立建国」= 不可逆操作，先确认再执行。
	# 拦截前先跑 can_attempt：前置不满足时本来就建不了国，
	# 此时弹「不可逆」确认窗是给玩家看一个根本执行不了的后果，纯属噪音。
	var pre := SelfRuleService.can_attempt(_self_rule_city)
	if not bool(pre.get("ok", false)):
		EventBus.show_toast(str(pre.get("reason", "")))
		return
	# 【修复】此处必须用 strip_edges().is_empty()，不能写 .text.is_empty()：
	# 玩家若只输入空格/制表符，is_empty() 为 false 会放行到「不可逆」确认窗，
	# 玩家点完确认才被 found_self_rule 的 name.is_empty() 拒掉 ——
	# 白白吓他一跳，代价却为零。与 _show_found_confirm 的快照口径保持一致。
	if _name_edit.text.strip_edges().is_empty():
		EventBus.show_toast("须定国号，方可称国。")
		return
	_show_found_confirm()


## 【第六十三轮】自立建国二次确认。
## 与城内的处死俘虏（_do_prisoner_execute）、解散部队（_do_disband）同一套 sub-modal。
## 弹窗内的国号/旗帜/都城信息取**入参快照**，不在确认态回查 _name_edit / _flag_selected
## —— 否则玩家在弹窗叠层下改不到输入框，状态却可能随外部刷新漂移。
func _show_found_confirm() -> void:
	if _found_confirm != null:
		return
	_pending_found_city = _self_rule_city
	_pending_found_name = _name_edit.text.strip_edges()
	_pending_found_flag = _flag_selected

	var m := UITheme.make_sub_modal(self, "自 立 建 国？",
		_close_found_confirm, Vector2(880, 640))
	_found_confirm = m["dim"]
	var body: VBoxContainer = m["body"]

	# 【GDScript 坑】`%` 的优先级高于 `+`：写成 `"a" + "b" % [x]` 时格式化只作用于最后一段
	# 字面量，前面的拼接结果被当成额外参数 → 运行时 "not all arguments converted"。
	# 多段拼接后格式化必须整体加括号。
	var tip := UITheme.label((
		"自立为王不可反悔，且以下后果一概无法撤销：\n\n"
		+ "　• 国号「%s」与旗帜一经确立，本局不可再退自立之身\n"
		+ "　• 天下 %d 家势力关系各降 %d 点，不因外交手段返还\n"
		+ "　• 已有投靠意向作废，无法再面见主公\n"
		+ "　• 恶名过高压线后自立政权即告覆灭，结局不可重开\n\n"
		+ "即将建国：国号「%s」　旗帜纹样 %d"
	) % [
			_pending_found_name, GameState.faction_relations.size(),
			SelfRuleService.RIVAL_RELATION_DELTA,
			_pending_found_name, _pending_found_flag,
		],
		UITheme.FS_BODY, UITheme.TEXT)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(tip)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 28)
	# 撤销放左（与处死/解散/删档/读档确认一致）
	var cancel := UITheme.button("再想想", UITheme.FS_BODY, Vector2(240, 84))
	cancel.pressed.connect(func():
		AudioManager.sfx_click()
		_close_found_confirm())
	var ok := UITheme.button("确认建国", UITheme.FS_BODY, Vector2(240, 84))
	ok.pressed.connect(func():
		AudioManager.sfx_confirm()
		var city := _pending_found_city
		var nm := _pending_found_name
		var fg := _pending_found_flag
		_close_found_confirm()
		if not city.is_empty():
			_do_found(city, nm, fg))
	row.add_child(cancel)
	row.add_child(ok)
	body.add_child(row)


## 确认后真正建国（与 _on_confirm 的可逆分支彻底分离，防止再次分叉）
func _do_found(city_id: String, name: String, flag: int) -> void:
	var r := SelfRuleService.found_self_rule(city_id, name, flag)
	EventBus.show_toast(str(r.get("reason", "")))
	if bool(r.get("ok", false)):
		_refresh()


func _close_found_confirm() -> void:
	if _found_confirm != null and is_instance_valid(_found_confirm):
		_found_confirm.queue_free()
	_found_confirm = null
	_pending_found_city = ""
	_pending_found_name = ""
	_pending_found_flag = 1

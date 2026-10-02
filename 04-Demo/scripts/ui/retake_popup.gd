class_name RetakePopup
extends Control
## 收复军来袭弹窗（RetakePopup）
## 职责：原属势力兵临城下时（#67），让玩家二选一 —— 迎战（进战场）或弃城（直接失地）。
##       本弹窗只做展示与二选一，兵力/战利全部由 CityService 算好传进来。

signal closed
## fight=true 迎战；false 弃城
signal decided(city_id: String, fight: bool)

var _title: Label
var _desc: Label
var _city_id := ""
var _fight_btn: Button
var _flee_btn: Button
## 【第五十五轮·防误触】弃城不可逆（失地 + 前功尽弃），而「迎 战 / 弃 城」
## 两个按钮同高同宽平级排列，手机上一次点错就永久丢城。
## 故点「弃 城」先进确认态，必须再点一次才真弃；「迎 战」直通不拦。
var _confirm_row: HBoxContainer
var _flee_btn_armed := false
## open() 的初始描述原文（确认态追加文案后可原样还原，取消时不会丢细节）
var _base_text := ""
## open() 传入的来夺方势力名快照。确认态文案必须用它，不能回头重查 GameState——
## 否则正文用快照、确认态用实时值，两次点击之间若势力被 AI 改写，
## 同一弹窗里会先后显示两个不同的势力名。
var _enemy_name := ""


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()


func _build_ui() -> void:
	var m := UITheme.make_modal(self, "兵 临 城 下", close, null, Vector2(860.0, 560.0))
	_title = m["title"]
	var body: VBoxContainer = m["body"]

	_desc = UITheme.label("", UITheme.FS_BODY, UITheme.TEXT)
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_desc)

	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_theme_constant_override("separation", 24)
	_fight_btn = UITheme.button("迎 战", UITheme.FS_HEAD, Vector2(200, UITheme.TOUCH_H))
	_fight_btn.pressed.connect(_on_fight_pressed)
	btns.add_child(_fight_btn)
	_flee_btn = UITheme.button("弃 城", UITheme.FS_BODY, Vector2(200, UITheme.TOUCH_H))
	_flee_btn.pressed.connect(_on_flee_pressed)
	btns.add_child(_flee_btn)
	m["outer"].add_child(btns)

	# 【第五十五轮】二次确认行：初始隐藏，点了「弃 城」才出现。
	# 「再点一次确认弃城」与「取消」并排，取消在左（误触概率最高的一侧留给撤销）。
	_confirm_row = HBoxContainer.new()
	_confirm_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_confirm_row.add_theme_constant_override("separation", 24)
	var cancel := UITheme.button("取 消", UITheme.FS_BODY, Vector2(200, UITheme.TOUCH_H))
	cancel.pressed.connect(_on_cancel_flee)
	_confirm_row.add_child(cancel)
	var confirm := UITheme.button("确认弃城", UITheme.FS_BODY, Vector2(240, UITheme.TOUCH_H))
	confirm.pressed.connect(_on_confirm_flee)
	_confirm_row.add_child(confirm)
	_confirm_row.visible = false
	m["outer"].add_child(_confirm_row)


func close() -> void:
	visible = false
	queue_free()


## 打开弹窗：city_id + 敌军情报（由 CityService.retake_battle_units 算好）
func open(city_id: String, city_name: String, faction_name: String, army: int, wall: int) -> void:
	_city_id = city_id
	_enemy_name = faction_name
	_title.text = "%s 告急" % city_name
	var txt := "%s 起兵 %d 人来夺 %s。" % [faction_name, army, city_name]
	if wall > 0:
		txt += "\n城中守军已先挫其锋，折损敌军 %d 人。" % wall
	txt += "\n\n迎战则据城一战，弃城则此地易主、前功尽弃。"
	_desc.text = txt
	var no_troops := GameState.get_total_troops() <= 0
	_fight_btn.disabled = no_troops
	if no_troops:
		_desc.text += "\n（麾下无兵，须先招募部队方可迎战）"
	_base_text = _desc.text
	# 每次 open 都要复位确认态：弹窗是按需 new 的，但复用时不能带上一次的确认态
	_flee_btn_armed = false
	_flee_btn.text = "弃 城"
	_flee_btn.disabled = false
	_confirm_row.visible = false
	visible = true


func _on_fight_pressed() -> void:
	_decide(true)


## 第一次点「弃 城」：只进确认态，不结算
func _on_flee_pressed() -> void:
	if _flee_btn_armed:
		_on_confirm_flee()   # 二次确认行已明确「确认弃城」，此处再点原按钮等价
		return
	_flee_btn_armed = true
	_flee_btn.text = "再点一次即弃城"
	_confirm_row.visible = true
	AudioManager.sfx_confirm()
	_desc.text += "\n\n弃城不可撤回：此地归 %s，你在此地的前功尽弃。" % _enemy_name


## 第二次确认：真弃城
func _on_confirm_flee() -> void:
	_decide(false)


func _on_cancel_flee() -> void:
	_flee_btn_armed = false
	_flee_btn.text = "弃 城"
	_confirm_row.visible = false
	AudioManager.sfx_cancel()
	_restore_desc()   # 撤掉确认态追加的那段，避免越叠越长


## 取消后把描述还原为 open() 时的原文（撤掉确认态追加的那段）
func _restore_desc() -> void:
	_desc.text = _base_text


func _decide(fight: bool) -> void:
	var cid := _city_id
	close()
	decided.emit(cid, fight)

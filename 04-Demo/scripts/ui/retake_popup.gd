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
	_fight_btn.pressed.connect(func(): _decide(true))
	btns.add_child(_fight_btn)
	_flee_btn = UITheme.button("弃 城", UITheme.FS_BODY, Vector2(200, UITheme.TOUCH_H))
	_flee_btn.pressed.connect(func(): _decide(false))
	btns.add_child(_flee_btn)
	m["outer"].add_child(btns)


func close() -> void:
	visible = false
	queue_free()


## 打开弹窗：city_id + 敌军情报（由 CityService.retake_battle_units 算好）
func open(city_id: String, city_name: String, faction_name: String, army: int, wall: int) -> void:
	_city_id = city_id
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
	visible = true


func _decide(fight: bool) -> void:
	var cid := _city_id
	close()
	decided.emit(cid, fight)

extends Control
class_name DuelPopup
## 战前单挑弹窗（纯代码构建，无 tscn）。
## 用法：battle_scene 持有一个实例，open(champ, enemy)；结束发 duel_finished(outcome)。
## 回合裁决全部走 DuelService，本脚本只负责展示与出招输入。

signal duel_finished(outcome: String)

const PANEL_W := 860.0
const PANEL_H := 640.0

var _panel: Panel
var _title_label: Label
var _hp_a_bar: ProgressBar
var _hp_b_bar: ProgressBar
var _hp_a_label: Label
var _hp_b_label: Label
var _round_label: Label
var _log_label: Label
var _move_box: HBoxContainer
var _confirm_btn: Button

var _state: Dictionary = {}


static func create() -> DuelPopup:
	var ui := DuelPopup.new()
	ui.name = "DuelPopup"
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.02, 0.02, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.add_child(dim)

	ui._panel = Panel.new()
	ui._panel.set_anchors_preset(Control.PRESET_CENTER)
	ui._panel.offset_left = -PANEL_W * 0.5
	ui._panel.offset_right = PANEL_W * 0.5
	ui._panel.offset_top = -PANEL_H * 0.5
	ui._panel.offset_bottom = PANEL_H * 0.5
	ui._panel.self_modulate = Color(0.09, 0.05, 0.04, 0.98)
	ui.add_child(ui._panel)

	var margin := 40.0
	var inner_w := PANEL_W - margin * 2.0

	ui._title_label = Label.new()
	ui._title_label.position = Vector2(margin, 24)
	ui._title_label.size = Vector2(inner_w, 44)
	ui._title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ui._title_label.add_theme_font_size_override("font_size", 32)
	ui._panel.add_child(ui._title_label)

	# 双方血条
	ui._hp_a_label = _mk_name_label()
	ui._hp_a_label.position = Vector2(margin, 86)
	ui._panel.add_child(ui._hp_a_label)
	ui._hp_a_bar = _mk_hp_bar()
	ui._hp_a_bar.position = Vector2(margin, 120)
	ui._panel.add_child(ui._hp_a_bar)

	ui._hp_b_label = _mk_name_label()
	ui._hp_b_label.position = Vector2(margin, 168)
	ui._panel.add_child(ui._hp_b_label)
	ui._hp_b_bar = _mk_hp_bar()
	ui._hp_b_bar.position = Vector2(margin, 202)
	ui._panel.add_child(ui._hp_b_bar)

	ui._round_label = Label.new()
	ui._round_label.position = Vector2(margin, 244)
	ui._round_label.size = Vector2(inner_w, 30)
	ui._round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ui._round_label.add_theme_font_size_override("font_size", 22)
	ui._round_label.modulate = Color(0.9, 0.82, 0.55)
	ui._panel.add_child(ui._round_label)

	ui._log_label = Label.new()
	ui._log_label.position = Vector2(margin, 284)
	ui._log_label.size = Vector2(inner_w, 220)
	ui._log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ui._log_label.add_theme_font_size_override("font_size", 21)
	ui._log_label.modulate = Color(0.88, 0.85, 0.78)
	ui._panel.add_child(ui._log_label)

	ui._move_box = HBoxContainer.new()
	ui._move_box.position = Vector2(margin, PANEL_H - 118)
	ui._move_box.size = Vector2(inner_w, 62)
	ui._move_box.add_theme_constant_override("separation", 16)
	ui._panel.add_child(ui._move_box)
	for mv in [DuelService.MOVE_ATTACK, DuelService.MOVE_GUARD, DuelService.MOVE_FEINT]:
		var btn := Button.new()
		btn.text = DuelService.move_name(mv)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0, 58)
		btn.add_theme_font_size_override("font_size", 26)
		btn.pressed.connect(ui._on_move.bind(mv))
		ui._move_box.add_child(btn)

	ui._confirm_btn = Button.new()
	ui._confirm_btn.text = "收兵回阵"
	ui._confirm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui._confirm_btn.custom_minimum_size = Vector2(0, 58)
	ui._confirm_btn.add_theme_font_size_override("font_size", 26)
	ui._confirm_btn.visible = false
	ui._confirm_btn.pressed.connect(ui._on_confirm)
	ui._move_box.add_child(ui._confirm_btn)

	ui.visible = false
	return ui


static func _mk_name_label() -> Label:
	var l := Label.new()
	l.size = Vector2(780, 28)
	l.add_theme_font_size_override("font_size", 22)
	return l


static func _mk_hp_bar() -> ProgressBar:
	var b := ProgressBar.new()
	b.size = Vector2(780, 28)
	b.min_value = 0
	b.max_value = 100
	b.show_percentage = false
	return b


func _ready() -> void:
	visible = false


## 开始单挑
func open(champ: Dictionary, enemy: Dictionary) -> void:
	_state = DuelService.start(champ, enemy)
	_title_label.text = "阵前单挑"
	_confirm_btn.visible = false
	for c in _move_box.get_children():
		if c is Button:
			(c as Button).disabled = false
	_refresh()
	visible = true


func _refresh() -> void:
	var a: Dictionary = _state.get("a", {})
	var b: Dictionary = _state.get("b", {})
	_hp_a_label.text = "%s（武勇 %d）" % [str(a.get("name", "我将")), int(a.get("force", 0))]
	_hp_b_label.text = "%s（武勇 %d）" % [str(b.get("name", "敌将")), int(b.get("force", 0))]
	_hp_a_bar.max_value = 100
	_hp_b_bar.max_value = 100
	_hp_a_bar.value = int(_state.get("hp_a", 100))
	_hp_b_bar.value = int(_state.get("hp_b", 100))
	var rule_text := "猛攻克佯攻 · 佯攻克稳守 · 稳守克猛攻"
	if bool(_state.get("over", false)):
		_round_label.text = "已战 %d 合 · %s" % [int(_state.get("round", 0)), rule_text]
	else:
		_round_label.text = "第 %d / %d 合　%s" % [
			int(_state.get("round", 0)) + 1, int(_state.get("max_rounds", 3)), rule_text]
	# 最近 7 行战报
	var lines: Array = _state.get("log", [])
	var tail: Array = lines.slice(maxi(0, lines.size() - 7))
	_log_label.text = "\n".join(tail)


func _on_move(mv: String) -> void:
	if bool(_state.get("over", false)):
		return
	AudioManager.sfx_confirm()
	_state = DuelService.play_round(_state, mv)
	_refresh()
	if bool(_state.get("over", false)):
		for c in _move_box.get_children():
			if c is Button and c != _confirm_btn:
				(c as Button).disabled = true
		_confirm_btn.visible = true


func _on_confirm() -> void:
	AudioManager.sfx_click()
	visible = false
	duel_finished.emit(str(_state.get("outcome", "draw")))

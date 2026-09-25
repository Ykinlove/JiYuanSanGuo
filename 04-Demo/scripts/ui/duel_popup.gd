extends Control
class_name DuelPopup
## 战前单挑弹窗（纯代码构建，无 tscn）。
## 用法：battle_scene 持有一个实例，open(champ, enemy)；结束发 duel_finished(outcome)。
## 回合裁决全部走 DuelService，本脚本只负责展示与出招输入。

signal duel_finished(outcome: String)

const PANEL_SIZE := UITheme.CITY_PANEL_SIZE

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
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_STOP

	# 统一为与水墨描金交互面板同款的 1040×780 模态（CITY_PANEL_SIZE）
	var m := UITheme.make_modal(ui, "阵前单挑", Callable(), null, PANEL_SIZE)
	ui._title_label = m["title"]
	ui._title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var body: VBoxContainer = m["body"]
	body.add_theme_constant_override("separation", 10)

	# 双方血条
	ui._hp_a_label = _mk_name_label()
	body.add_child(ui._hp_a_label)
	ui._hp_a_bar = _mk_hp_bar()
	body.add_child(ui._hp_a_bar)

	ui._hp_b_label = _mk_name_label()
	body.add_child(ui._hp_b_label)
	ui._hp_b_bar = _mk_hp_bar()
	body.add_child(ui._hp_b_bar)

	ui._round_label = UITheme.label("", UITheme.FS_NOTE, UITheme.GOLD)
	ui._round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ui._round_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(ui._round_label)

	ui._log_label = UITheme.label("", UITheme.FS_BODY, UITheme.TEXT)
	ui._log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ui._log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(ui._log_label)

	# 出招按钮区：固定在滚动区之外
	ui._move_box = HBoxContainer.new()
	ui._move_box.add_theme_constant_override("separation", 16)
	ui._move_box.alignment = BoxContainer.ALIGNMENT_CENTER
	for mv in [DuelService.MOVE_ATTACK, DuelService.MOVE_GUARD, DuelService.MOVE_FEINT]:
		ui._move_box.add_child(_mk_move_btn(ui, mv))
	ui._confirm_btn = UITheme.button("收兵回阵", UITheme.FS_BODY, Vector2(0, UITheme.TOUCH_H))   ## 【触控铁律】58→84
	ui._confirm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui._confirm_btn.visible = false
	ui._confirm_btn.pressed.connect(ui._on_confirm)
	ui._move_box.add_child(ui._confirm_btn)
	m["outer"].add_child(ui._move_box)

	ui.visible = false
	return ui


## 单个出招按钮（抽成函数，避免 lambda 捕获循环变量）
static func _mk_move_btn(ui: DuelPopup, mv: String) -> Button:
	var btn := UITheme.button(DuelService.move_name(mv), UITheme.FS_BODY, Vector2(0, UITheme.TOUCH_H))   ## 【触控铁律】58→84
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(ui._on_move.bind(mv))
	return btn


static func _mk_name_label() -> Label:
	var l := UITheme.label("", UITheme.FS_BODY)
	l.custom_minimum_size = Vector2(0, 28)
	return l


static func _mk_hp_bar() -> ProgressBar:
	var b := ProgressBar.new()
	b.custom_minimum_size = Vector2(0, 28)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
		# 【结果醒目化】单挑结束直接把标题改成胜负判定 —— 旧版结束只禁用出招
		# 按钮冒一个「收兵回阵」，胜负信息埋在战报流水里，玩家以为「没判定」。
		var oc := str(_state.get("outcome", "draw"))
		match oc:
			"win":
				_title_label.text = "单挑获胜！"
				_title_label.add_theme_color_override("font_color", Color(0.98, 0.86, 0.54))
			"lose":
				_title_label.text = "单挑失利"
				_title_label.add_theme_color_override("font_color", Color(0.92, 0.48, 0.42))
			_:
				_title_label.text = "不分胜负"
				_title_label.add_theme_color_override("font_color", Color(0.78, 0.80, 0.86))
	else:
		_title_label.text = "阵前单挑"
		_title_label.add_theme_color_override("font_color", Color(0.98, 0.86, 0.54))
		_round_label.text = "第 %d / %d 合　%s" % [
			int(_state.get("round", 0)) + 1, int(_state.get("max_rounds", 3)), rule_text]
	# 最近 7 行战报
	var lines: Array = _state.get("log", [])
	var tail: Array = lines.slice(maxi(0, lines.size() - 7))
	_log_label.text = "\n".join(tail)


func _on_move(mv: String) -> void:
	if bool(_state.get("over", false)):
		return
	AudioManager.play_sfx("res://assets/audio/sfx/duel_round.ogg")   # 【音频三批】出招音替换通用 confirm
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
	var outcome := str(_state.get("outcome", "draw"))
	# 【音频三批】单挑获胜复用结算胜利短曲（音频规划 §3 表 5）
	if outcome == "win":
		AudioManager.play_sfx("res://assets/audio/sfx/victory.ogg")
	duel_finished.emit(outcome)

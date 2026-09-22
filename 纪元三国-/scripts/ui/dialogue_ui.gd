extends Control
class_name DialogueUI
## 对话界面（DialogueUI）
## 职责：显示对话文本（打字机效果）、六角形选项菜单、属性门槛置灰、执行对话动作。
## 视觉：水墨风对话框 + 六边形选项按钮。

signal dialogue_finished()

const TYPE_SPEED := 0.032   ## 每字间隔（秒）

@onready var _root_panel: Control = $RootPanel
@onready var _speaker_label: Label = $RootPanel/SpeakerLabel
@onready var _text_label: RichTextLabel = $RootPanel/TextBox/TextLabel
@onready var _options_box: VBoxContainer = $RootPanel/OptionsBox
@onready var _continue_hint: Label = $RootPanel/ContinueHint

var _current_id: String = ""
var _line_index: int = 0
var _lines: Array = []
var _options: Array = []
var _typing := false
var _type_timer := 0.0
var _full_text := ""


func _ready() -> void:
	visible = false
	_continue_hint.visible = false


## 开始一段对话
func start(dialogue_id: String) -> void:
	var data := _find_dialogue(dialogue_id)
	if data.is_empty():
		push_warning("[DialogueUI] 对话不存在：%s" % dialogue_id)
		return

	_current_id = dialogue_id
	_lines = data.get("lines", [])
	_options = data.get("options", [])
	_line_index = 0

	_speaker_label.text = str(data.get("speaker", ""))
	_root_panel.visible = true
	visible = true
	_clear_options()
	EventBus.dialogue_started.emit(dialogue_id)
	_show_line()


func _find_dialogue(id: String) -> Dictionary:
	for d in DataManager.get_table("dialogues"):
		if str(d.get("id", "")) == id:
			return d
	return {}


func _show_line() -> void:
	if _line_index >= _lines.size():
		_show_options()
		return
	_full_text = str(_lines[_line_index])
	_text_label.text = ""
	_typing = true
	_type_timer = 0.0


func _process(delta: float) -> void:
	if not _typing:
		return
	_type_timer += delta
	if _type_timer >= TYPE_SPEED:
		_type_timer = 0.0
		var shown := _text_label.text.length() + 1
		if shown <= _full_text.length():
			_text_label.text = _full_text.substr(0, shown)
		if _text_label.text.length() >= _full_text.length():
			_finish_typing()


## 点击/按键推进
func advance() -> void:
	if _typing:
		# 跳到全文
		_text_label.text = _full_text
		_finish_typing()
		return
	if _line_index < _lines.size() - 1:
		_line_index += 1
		_show_line()
	elif _options.is_empty():
		_close()
	# 有选项时由选项按钮驱动


func _finish_typing() -> void:
	_typing = false
	_text_label.text = _full_text
	# 是否显示「继续」提示
	if _line_index < _lines.size() - 1:
		_continue_hint.visible = true
	elif _options.is_empty():
		_continue_hint.text = "▼ 点击关闭"
		_continue_hint.visible = true
	else:
		_show_options()


func _clear_options() -> void:
	for c in _options_box.get_children():
		c.queue_free()


## 显示选项按钮（六角形风格 + 条件置灰）
func _show_options() -> void:
	_continue_hint.visible = false
	_clear_options()
	if _options.is_empty():
		return

	for opt in _options:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(620, 64)
		btn.add_theme_font_size_override("font_size", 26)
		btn.text = str(opt.get("text", "…"))

		# 条件校验（属性门槛置灰）
		var ok := _check_require(opt.get("require", {}))
		if not ok["pass"]:
			btn.disabled = true
			btn.text += "　（%s）" % ok["reason"]

		var next_id := str(opt.get("next", ""))
		var action := str(opt.get("action", ""))
		btn.pressed.connect(func(): _on_option_chosen(next_id, action))
		_options_box.add_child(btn)


## 校验选项条件
func _check_require(req: Dictionary) -> Dictionary:
	if req.is_empty():
		return { "pass": true, "reason": "" }
	if req.has("gold") and GameState.gold < int(req["gold"]):
		return { "pass": false, "reason": "需金钱 %d" % int(req["gold"]) }
	if req.has("fame") and GameState.fame < int(req["fame"]):
		return { "pass": false, "reason": "需名声 %d" % int(req["fame"]) }
	if req.has("charisma") and int(GameState.player_stats.get("charisma", 0)) < int(req["charisma"]):
		return { "pass": false, "reason": "需魅力 %d" % int(req["charisma"]) }
	return { "pass": true, "reason": "" }


func _on_option_chosen(next_id: String, action: String) -> void:
	AudioManager.sfx_confirm()
	_execute_action(action)
	if next_id.is_empty():
		_close()
	else:
		start(next_id)


## 执行对话动作
func _execute_action(action: String) -> void:
	if action.is_empty():
		return
	var parts := action.split(":", false, 1)
	if parts.size() < 2:
		return
	var cmd := parts[0]
	var arg := parts[1]

	match cmd:
		"accept_quest":
			if not GameState.active_quests.has(arg):
				GameState.active_quests.append(arg)
				var q := DataManager.get_record("quests", arg)
				EventBus.quest_accepted.emit(arg)
				EventBus.show_toast("接受任务：%s" % str(q.get("title", arg)))
		"give_gold":
			var amount := int(arg)
			if GameState.gold >= amount:
				GameState.add_gold(-amount)
				EventBus.show_toast("失去金钱 %d" % amount)
		"open_shop":
			EventBus.show_toast("商店界面（待实装）")
		_:
			EventBus.show_toast("动作：%s" % action)


func _close() -> void:
	var closed_id := _current_id
	visible = false
	_root_panel.visible = false
	_clear_options()
	EventBus.dialogue_ended.emit(closed_id)
	dialogue_finished.emit()


func is_open() -> bool:
	return visible

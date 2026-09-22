extends Control
class_name EventPopup
## 大地图随机事件弹窗（纯代码构建，无 tscn）。
## 用法：world_map 持有一个实例，event 遭遇触发时 open(event_def)。
## 结算全部走 WorldEventService，本脚本只负责展示与禁用态。

signal popup_closed

const PANEL_W := 920.0
const OPT_HEIGHT := 78.0
const OPT_GAP := 12.0

var _panel: Panel
var _title_label: Label
var _desc_label: Label
var _result_label: Label
var _options_box: VBoxContainer
var _confirm_btn: Button
var _event_def: Dictionary = {}


## 代码构建一份 EventPopup
static func create() -> EventPopup:
	var ui := EventPopup.new()
	ui.name = "EventPopup"
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_STOP

	# 半透明遮罩，点遮罩不关闭（必须做出选择）
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.add_child(dim)

	ui._panel = Panel.new()
	ui._panel.set_anchors_preset(Control.PRESET_CENTER)
	ui._panel.offset_left = -PANEL_W * 0.5
	ui._panel.offset_right = PANEL_W * 0.5
	ui._panel.offset_top = -300.0
	ui._panel.offset_bottom = 300.0
	ui._panel.self_modulate = Color(0.07, 0.06, 0.05, 0.97)
	ui.add_child(ui._panel)

	var margin := 40.0
	var inner_w := PANEL_W - margin * 2.0

	ui._title_label = Label.new()
	ui._title_label.position = Vector2(margin, 28)
	ui._title_label.size = Vector2(inner_w, 44)
	ui._title_label.add_theme_font_size_override("font_size", 34)
	ui._panel.add_child(ui._title_label)

	ui._desc_label = Label.new()
	ui._desc_label.position = Vector2(margin, 84)
	ui._desc_label.size = Vector2(inner_w, 120)
	ui._desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ui._desc_label.add_theme_font_size_override("font_size", 24)
	ui._desc_label.modulate = Color(0.88, 0.85, 0.78)
	ui._panel.add_child(ui._desc_label)

	ui._options_box = VBoxContainer.new()
	ui._options_box.position = Vector2(margin, 218)
	ui._options_box.size = Vector2(inner_w, 240)
	ui._options_box.add_theme_constant_override("separation", OPT_GAP)
	ui._panel.add_child(ui._options_box)

	ui._result_label = Label.new()
	ui._result_label.position = Vector2(margin, 218)
	ui._result_label.size = Vector2(inner_w, 200)
	ui._result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ui._result_label.add_theme_font_size_override("font_size", 26)
	ui._result_label.modulate = Color(0.95, 0.88, 0.62)
	ui._result_label.visible = false
	ui._panel.add_child(ui._result_label)

	ui._confirm_btn = Button.new()
	ui._confirm_btn.text = "继续赶路"
	ui._confirm_btn.custom_minimum_size = Vector2(280, 64)
	ui._confirm_btn.position = Vector2((PANEL_W - 280) * 0.5, 500)
	ui._confirm_btn.add_theme_font_size_override("font_size", 26)
	ui._confirm_btn.visible = false
	ui._confirm_btn.pressed.connect(ui._on_confirm)
	ui._panel.add_child(ui._confirm_btn)

	ui.visible = false
	return ui


func _ready() -> void:
	# create() 中 add_child 时本节点还没进树，visible=false 初始态保险
	visible = false


## 打开事件
func open(event_def: Dictionary) -> void:
	_event_def = event_def
	_title_label.text = "◆ %s" % str(event_def.get("title", event_def.get("name", "遭遇事件")))
	_desc_label.text = str(event_def.get("desc", event_def.get("description", "")))
	_result_label.visible = false
	_confirm_btn.visible = false
	_clear_buttons()

	for opt in event_def.get("options", []):
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(0, OPT_HEIGHT)
		btn.add_theme_font_size_override("font_size", 24)
		btn.text = str(opt.get("text", "…"))
		var gate := WorldEventService.can_pick(opt)
		if not gate["ok"]:
			btn.disabled = true
			btn.text += "（%s）" % str(gate["reason"])
		var oid := str(opt.get("id", ""))
		btn.pressed.connect(_on_option.bind(oid))
		_options_box.add_child(btn)

	visible = true


func _clear_buttons() -> void:
	for c in _options_box.get_children():
		c.queue_free()


func _on_option(option_id: String) -> void:
	AudioManager.sfx_confirm()
	var r: Dictionary = WorldEventService.resolve(_event_def, option_id)
	if not r["ok"]:
		EventBus.show_toast(str(r.get("msg", "无法选择")))
		return
	AudioManager.sfx_confirm()
	_options_box.visible = false
	_result_label.text = str(r.get("msg", ""))
	_result_label.visible = true
	_confirm_btn.visible = true


func _on_confirm() -> void:
	AudioManager.sfx_click()
	_options_box.visible = true
	visible = false
	popup_closed.emit()

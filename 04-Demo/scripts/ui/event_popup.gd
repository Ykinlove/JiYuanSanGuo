extends Control
class_name EventPopup
## 大地图随机事件弹窗（纯代码构建，无 tscn）。
## 用法：world_map 持有一个实例，event 遭遇触发时 open(event_def)。
## 结算全部走 WorldEventService，本脚本只负责展示与禁用态。

signal popup_closed

const PANEL_W := 920.0
const OPT_HEIGHT := 78.0
const OPT_GAP := 12.0

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
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_STOP

	# 原实现是手写绝对坐标（position/size 一排硬编码），本批次改为容器布局 + UITheme 小尺寸模态
	var m := UITheme.make_modal(ui, "遭遇事件", Callable(), null, Vector2(PANEL_W, 620.0))
	ui._title_label = m["title"]
	var body: VBoxContainer = m["body"]

	ui._desc_label = UITheme.label("", UITheme.FS_BODY, UITheme.TEXT)
	ui._desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(ui._desc_label)

	ui._options_box = VBoxContainer.new()
	ui._options_box.add_theme_constant_override("separation", OPT_GAP)
	ui._options_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(ui._options_box)

	ui._result_label = UITheme.label("", UITheme.FS_HEAD, UITheme.POINT)
	ui._result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ui._result_label.visible = false
	body.add_child(ui._result_label)

	ui._confirm_btn = UITheme.button("继续赶路", UITheme.FS_BODY, Vector2(280, 64))
	ui._confirm_btn.visible = false
	ui._confirm_btn.pressed.connect(ui._on_confirm)
	m["outer"].add_child(ui._confirm_btn)

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
		var btn := UITheme.button(str(opt.get("text", "…")), UITheme.FS_BODY, Vector2(0, OPT_HEIGHT))
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

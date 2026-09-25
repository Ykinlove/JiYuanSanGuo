extends Control
class_name EventPopup
## 大地图随机事件弹窗（纯代码构建，无 tscn）。
## 用法：world_map 持有一个实例，event 遭遇触发时 open(event_def)。
## 结算全部走 WorldEventService，本脚本只负责展示与禁用态。

signal popup_closed

const PANEL_W := 920.0
const OPT_HEIGHT := 84.0   ## 【触控铁律】对话/事件选项 ≥84px，78 抬高后会挤到选项数上限
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
	# 【修复】旧代码传空 Callable，make_modal 只在 close_cb.is_valid() 时生成 ✕，
	# 于是本弹窗没有任何关闭键；遮罩又是 STOP，选项一旦不可用玩家就彻底卡死。
	var m := UITheme.make_modal(ui, "遭遇事件", ui._on_confirm, null, Vector2(PANEL_W, 620.0))
	# 点遮罩空白处也能关闭，作为 ✕ 之外的第二重退路
	(m["dim"] as Control).gui_input.connect(ui._on_dim_input)
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

	ui._confirm_btn = UITheme.button("继续赶路", UITheme.FS_BODY, Vector2(280, UITheme.TOUCH_H))   ## 【触控铁律】64→84
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
	_options_box.visible = true
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

	# 兜底：选项表为空或全部被资源门槛置灰时，直接亮出「继续赶路」。
	# 全屏遮罩会吞掉所有输入，没有出口就等于强制杀进程。
	if not _has_enabled_option():
		_confirm_btn.visible = true

	visible = true


## 选项区是否存在可点按钮
func _has_enabled_option() -> bool:
	for c in _options_box.get_children():
		if c is Button and not (c as Button).disabled:
			return true
	return false


func _clear_buttons() -> void:
	for c in _options_box.get_children():
		# 先摘除再释放：queue_free 帧末才生效，旧按钮本帧仍可被点第二次
		_options_box.remove_child(c)
		c.queue_free()


## 点遮罩空白处 → 视作「继续赶路」
func _on_dim_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		_on_confirm()


func _on_option(option_id: String) -> void:
	# 【P7】选项点击只在成功结算后响一次 confirm；失败走 toast 提示，不再连响两声
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

class_name SelfRulePanel
extends Control
## 自立为王面板（SelfRulePanel）
## 职责：在祠堂触发「自立为王」——展示自立状态（村庄声望/名声/恶名/判定值/信物）、
##       输入国号、选择旗帜、发起自立（走 SelfRuleService 规则层），或已自立后改国号/换旗。
## 规则与数值全部由 SelfRuleService 结算，本面板不内联公式。

signal closed

var _title: Label
var _status: Label
var _name_edit: LineEdit
var _flag_box: HBoxContainer
var _flag_selected: int = 1
var _confirm: Button
var _close: Button
var _flag_btns: Array = []
var _self_rule_city := ""

## 旗帜纹样数（D-09 选旗帜）
const FLAG_COUNT := 5


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()


func _build_ui() -> void:
	# 原实现是手写绝对坐标（position/size 硬编码 1920 布局）且没有全屏遮罩，
	# 本批次改为容器布局 + UITheme 模态，字号/配色统一。
	var m := UITheme.make_modal(self, "自 立 为 王", close)
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
	_confirm = UITheme.button("自立建国", UITheme.FS_HEAD, Vector2(200, 56))
	_confirm.pressed.connect(_on_confirm)
	btns.add_child(_confirm)
	_close = UITheme.button("返回", UITheme.FS_BODY, Vector2(120, 56))
	_close.pressed.connect(close)
	btns.add_child(_close)
	m["outer"].add_child(btns)


## 单个旗帜按钮（抽成函数，避免 lambda 捕获循环变量的老坑）
func _make_flag_btn(idx: int) -> Button:
	var b := UITheme.button("旗%d" % idx, UITheme.FS_BODY, Vector2(86, 48))
	b.toggle_mode = true
	b.button_group = ButtonGroup.new()
	b.pressed.connect(func(): _flag_selected = idx)
	_flag_btns.append(b)
	return b


## 打开面板：传入触发城池（祠堂所在）。
func open(city_id: String = "") -> void:
	_self_rule_city = city_id
	if _self_rule_city.is_empty():
		_self_rule_city = GameState.current_city_id
	_refresh()
	visible = true


func is_open() -> bool:
	return visible


func close() -> void:
	visible = false
	closed.emit()


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
		var r := SelfRuleService.rename(_name_edit.text)
		_refresh()
		EventBus.show_toast(str(r.get("reason", "")))
		return
	var r := SelfRuleService.found_self_rule(_self_rule_city, _name_edit.text, _flag_selected)
	EventBus.show_toast(str(r.get("reason", "")))
	if bool(r.get("ok", false)):
		_refresh()

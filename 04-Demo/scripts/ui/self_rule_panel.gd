class_name SelfRulePanel
extends Control
## 自立为王面板（SelfRulePanel）
## 职责：在祠堂触发「自立为王」——展示自立状态（村庄声望/名声/恶名/判定值/信物）、
##       输入国号、选择旗帜、发起自立（走 SelfRuleService 规则层），或已自立后改国号/换旗。
## 规则与数值全部由 SelfRuleService 结算，本面板不内联公式。

signal closed

var _bg: Panel
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
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()


func _build_ui() -> void:
	_bg = Panel.new()
	_bg.size = Vector2(760, 640)
	_bg.position = Vector2((1920 - 760) / 2.0, (1080 - 640) / 2.0)
	_bg.self_modulate = Color(0.06, 0.05, 0.06, 0.96)
	add_child(_bg)

	_title = Label.new()
	_title.text = "自 立 为 王"
	_title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_title.add_theme_font_size_override("font_size", 40)
	_title.add_theme_color_override("font_color", Color(0.98, 0.82, 0.42))
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bg.add_child(_title)

	_status = Label.new()
	_status.text = ""
	_status.position = Vector2(30, 92)
	_status.size = Vector2(700, 280)
	_status.add_theme_font_size_override("font_size", 26)
	_status.add_theme_color_override("font_color", Color(0.94, 0.92, 0.86))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_bg.add_child(_status)

	var name_lab := Label.new()
	name_lab.text = "国号："
	name_lab.position = Vector2(30, 392)
	name_lab.add_theme_font_size_override("font_size", 26)
	_bg.add_child(name_lab)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "输入国号（如 大燕 / 蜀汉）"
	_name_edit.position = Vector2(120, 384)
	_name_edit.size = Vector2(470, 44)
	_name_edit.add_theme_font_size_override("font_size", 26)
	_bg.add_child(_name_edit)

	var flag_lab := Label.new()
	flag_lab.text = "旗帜："
	flag_lab.position = Vector2(30, 456)
	flag_lab.add_theme_font_size_override("font_size", 26)
	_bg.add_child(flag_lab)
	_flag_box = HBoxContainer.new()
	_flag_box.position = Vector2(120, 450)
	_flag_box.add_theme_constant_override("separation", 16)
	_bg.add_child(_flag_box)
	for _i in range(1, FLAG_COUNT + 1):
		var b := Button.new()
		b.text = "旗%d" % _i
		b.custom_minimum_size = Vector2(86, 48)
		b.add_theme_font_size_override("font_size", 24)
		b.toggle_mode = true
		b.button_group = ButtonGroup.new()
		b.pressed.connect(func(): _flag_selected = _i)
		_flag_btns.append(b)
		_flag_box.add_child(b)

	var btns := HBoxContainer.new()
	btns.position = Vector2(120, 536)
	btns.add_theme_constant_override("separation", 24)
	_bg.add_child(btns)
	_confirm = Button.new()
	_confirm.text = "自立建国"
	_confirm.custom_minimum_size = Vector2(200, 56)
	_confirm.add_theme_font_size_override("font_size", 26)
	_confirm.pressed.connect(_on_confirm)
	btns.add_child(_confirm)
	_close = Button.new()
	_close.text = "返回"
	_close.custom_minimum_size = Vector2(120, 56)
	_close.add_theme_font_size_override("font_size", 24)
	_close.pressed.connect(close)
	btns.add_child(_close)


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

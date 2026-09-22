extends Control
class_name AttributePanel
## 主角成长 / 属性加点面板。
## 读取 GameState.player_stats / player_attr_points / player_level / player_exp。
## 四属性：体质(constitution) / 力量(strength) / 智力(intelligence) / 魅力(charisma)，
## 每个 ＋ 按钮消耗 1 点属性点（GameState.spend_attr_point）。UI 不含任何加点规则。

signal closed

const STAT_DEFS := [
	{ "key": "constitution", "name": "体质", "desc": "影响生命与负重" },
	{ "key": "strength",     "name": "力量", "desc": "影响物理攻击与带兵" },
	{ "key": "intelligence", "name": "智力", "desc": "影响策略与计谋" },
	{ "key": "charisma",     "name": "魅力", "desc": "影响招募与外交" },
]

const C_CARD := Color(0.13, 0.11, 0.085, 0.97)
const C_BORDER := Color(0.72, 0.58, 0.28, 0.95)
const C_GOLD := Color(0.93, 0.80, 0.45)
const C_TEXT := Color(0.92, 0.88, 0.80)
const C_DIM := Color(0.63, 0.58, 0.50)
const C_GOOD := Color(0.62, 0.86, 0.62)
const C_POINT := Color(0.96, 0.82, 0.40)

var _card: PanelContainer
var _lv_label: Label
var _exp_label: Label
var _point_label: Label
var _rows: Array = []   ## 每行缓存 { key, value: Label, btn: Button }


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.02, 0.015, 0.62)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_card = PanelContainer.new()
	_card.custom_minimum_size = Vector2(1080, 720)
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_CARD
	sb.border_color = C_BORDER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 28.0
	sb.content_margin_right = 28.0
	sb.content_margin_top = 22.0
	sb.content_margin_bottom = 22.0
	_card.add_theme_stylebox_override("panel", sb)
	center.add_child(_card)
	_card.add_child(_build())

	EventBus.player_stats_changed.connect(_on_stats_changed)


func _build() -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)

	# ---- 头部：标题 + 关闭 ----
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	var title := Label.new()
	title.text = "主角成长"
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", C_GOLD)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close := Button.new()
	close.text = "✕"
	close.custom_minimum_size = Vector2(64, 64)
	close.add_theme_font_size_override("font_size", 28)
	close.pressed.connect(close_panel)
	head.add_child(close)
	root.add_child(head)
	root.add_child(HSeparator.new())

	# ---- 概览：等级 / 经验 / 可分配点数 ----
	var sum := HBoxContainer.new()
	sum.add_theme_constant_override("separation", 36)
	_lv_label = Label.new()
	_lv_label.add_theme_font_size_override("font_size", 26)
	_lv_label.add_theme_color_override("font_color", C_TEXT)
	_exp_label = Label.new()
	_exp_label.add_theme_font_size_override("font_size", 22)
	_exp_label.add_theme_color_override("font_color", C_DIM)
	_point_label = Label.new()
	_point_label.add_theme_font_size_override("font_size", 26)
	_point_label.add_theme_color_override("font_color", C_POINT)
	sum.add_child(_lv_label)
	sum.add_child(_exp_label)
	sum.add_child(_point_label)
	root.add_child(sum)
	root.add_child(HSeparator.new())

	# ---- 四属性加点行 ----
	for sd in STAT_DEFS:
		root.add_child(_make_stat_row(sd))

	return root


## 一行：属性名 + 当前值 + ＋加点按钮
func _make_stat_row(sd: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)

	var name := Label.new()
	name.text = "%s　%s" % [str(sd["name"]), str(sd["desc"])]
	name.add_theme_font_size_override("font_size", 24)
	name.add_theme_color_override("font_color", C_TEXT)
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name)

	var val := Label.new()
	val.add_theme_font_size_override("font_size", 30)
	val.add_theme_color_override("font_color", C_GOOD)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.custom_minimum_size = Vector2(72, 0)
	row.add_child(val)

	var btn := Button.new()
	btn.text = "＋ 加点"
	btn.custom_minimum_size = Vector2(150, 60)
	btn.add_theme_font_size_override("font_size", 24)
	btn.pressed.connect(func(): _on_add(str(sd["key"])))
	row.add_child(btn)

	_rows.append({ "key": str(sd["key"]), "value": val, "btn": btn })
	return row


func _on_add(key: String) -> void:
	if GameState.spend_attr_point(key):
		AudioManager.sfx_confirm()
		_refresh()
		EventBus.toast.emit("属性点已投入「%s」。" % key)
	else:
		AudioManager.sfx_cancel()
		EventBus.toast.emit("没有可分配的属性点了。")


func _refresh() -> void:
	_lv_label.text = "等级　Lv.%d" % GameState.player_level
	_exp_label.text = "经验　%d" % GameState.player_exp
	var pts := GameState.player_attr_points
	_point_label.text = "可分配属性点　%d" % pts
	for r in _rows:
		var k := str(r["key"])
		(r["value"] as Label).text = str(int(GameState.player_stats.get(k, 0)))
		(r["btn"] as Button).disabled = (pts <= 0)


func _on_stats_changed(_v = null) -> void:
	if visible:
		_refresh()


func open() -> void:
	visible = true
	_refresh()


func close_panel() -> void:
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close_panel()
		get_viewport().set_input_as_handled()

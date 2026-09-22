extends Control
class_name CharacterPanel
## 独立人物 / 城池详情面板（全屏卡片，替代旧的横屏弹字）。
## 左：立绘位 + 招募条件；右：四维 / 派生属性 / 特技 / 生平。
## 底部动作区随对象类型变化：NPC（对话/交易/送礼/切磋/结交）、城池（进入）。
## 面板整体代码动态构建（工程纪律：不往 tscn 堆控件）。

signal action_requested(action: String, target: Dictionary)
signal closed

const C_CARD := Color(0.13, 0.11, 0.085, 0.97)
const C_BORDER := Color(0.72, 0.58, 0.28, 0.95)
const C_GOLD := Color(0.93, 0.80, 0.45)
const C_TEXT := Color(0.92, 0.88, 0.80)
const C_DIM := Color(0.63, 0.58, 0.50)
const C_STAT := Color(0.55, 0.78, 0.62)
const C_SLOT := Color(0.20, 0.17, 0.13, 0.9)

const STAT_KEYS := ["统率", "武力", "智力", "政治"]
const DERIVED_KEYS := ["攻击", "防御", "暴击", "命中"]
## 城池模式下的标签头（复用同一排控件，标签动态换字）
const CITY_STAT_KEYS := ["城防", "民心", "人口", "驻军"]
const CITY_DERIVED_KEYS := ["特产", "势力", "规模", "等级"]
const TYPE_CN := {"city": "城池", "village": "村落", "pass": "关隘", "ruin": "遗迹"}

var _target: Dictionary = {}
var _is_npc_mode := false

var _card: PanelContainer
var _close_btn: Button
var _portrait_box: PanelContainer
var _portrait_tex: TextureRect
var _portrait_char: Label
var _name_label: Label
var _sub_label: Label
var _stat_values: Array[Label] = []
var _stat_grades: Array[Label] = []
var _derived_values: Array[Label] = []
var _stat_names: Array[Label] = []     ## 四维标签头（城池模式要换字）
var _derived_names: Array[Label] = []  ## 派生标签头
var _skill_label: Label
var _bio_label: Label
var _req_label: Label
var _action_box: HBoxContainer


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.015, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_card = PanelContainer.new()
	_card.custom_minimum_size = Vector2(1460, 860)
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_CARD
	sb.border_color = C_BORDER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 30.0
	sb.content_margin_right = 30.0
	sb.content_margin_top = 24.0
	sb.content_margin_bottom = 24.0
	_card.add_theme_stylebox_override("panel", sb)
	center.add_child(_card)

	_card.add_child(_build_content())


func _build_content() -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)

	# ---- 头部：姓名 + 关闭 ----
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 42)
	_name_label.add_theme_color_override("font_color", C_GOLD)
	title_box.add_child(_name_label)
	_sub_label = Label.new()
	_sub_label.add_theme_font_size_override("font_size", 22)
	_sub_label.add_theme_color_override("font_color", C_DIM)
	title_box.add_child(_sub_label)
	head.add_child(title_box)
	_close_btn = Button.new()
	_close_btn.text = "✕"
	_close_btn.custom_minimum_size = Vector2(64, 64)
	_close_btn.add_theme_font_size_override("font_size", 28)
	_close_btn.pressed.connect(_on_close)
	head.add_child(_close_btn)
	root.add_child(head)

	root.add_child(HSeparator.new())

	# ---- 主体：左立绘 / 右数据 ----
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 28)

	# 左列：立绘 + 招募条件
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(380, 0)
	left.add_theme_constant_override("separation", 10)
	_portrait_box = PanelContainer.new()
	_portrait_box.custom_minimum_size = Vector2(380, 470)
	var psb := StyleBoxFlat.new()
	psb.bg_color = Color(0.09, 0.075, 0.06, 0.95)
	psb.border_color = Color(0.45, 0.38, 0.24, 0.8)
	psb.set_border_width_all(1)
	psb.set_corner_radius_all(10)
	_portrait_box.add_theme_stylebox_override("panel", psb)
	_portrait_tex = TextureRect.new()
	_portrait_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait_tex.set_anchors_preset(Control.PRESET_FULL_RECT)
	_portrait_tex.visible = false
	_portrait_char = Label.new()
	_portrait_char.set_anchors_preset(Control.PRESET_FULL_RECT)
	_portrait_char.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_portrait_char.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_portrait_char.add_theme_font_size_override("font_size", 150)
	_portrait_char.add_theme_color_override("font_color", Color(0.5, 0.44, 0.32, 0.85))
	_portrait_box.add_child(_portrait_tex)
	_portrait_box.add_child(_portrait_char)
	left.add_child(_portrait_box)
	_req_label = Label.new()
	_req_label.add_theme_font_size_override("font_size", 20)
	_req_label.add_theme_color_override("font_color", C_DIM)
	_req_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_req_label)
	body.add_child(left)

	# 右列：数据
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 12)

	# 四维
	var stat_row := HBoxContainer.new()
	stat_row.add_theme_constant_override("separation", 22)
	for i in range(4):
		var blk := VBoxContainer.new()
		blk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var nm := Label.new()
		nm.text = STAT_KEYS[i]
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nm.add_theme_font_size_override("font_size", 22)
		nm.add_theme_color_override("font_color", C_DIM)
		blk.add_child(nm)
		var val := Label.new()
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		val.add_theme_font_size_override("font_size", 48)
		val.add_theme_color_override("font_color", C_TEXT)
		blk.add_child(val)
		var gr := Label.new()
		gr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		gr.add_theme_font_size_override("font_size", 20)
		gr.add_theme_color_override("font_color", C_STAT)
		blk.add_child(gr)
		_stat_values.append(val)
		_stat_grades.append(gr)
		_stat_names.append(nm)
		stat_row.add_child(blk)
	right.add_child(stat_row)

	# 派生属性
	var drv := HBoxContainer.new()
	drv.add_theme_constant_override("separation", 22)
	for i in range(4):
		var blk2 := PanelContainer.new()
		blk2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var ssb := StyleBoxFlat.new()
		ssb.bg_color = C_SLOT
		ssb.set_corner_radius_all(8)
		blk2.add_theme_stylebox_override("panel", ssb)
		var v := VBoxContainer.new()
		var dn := Label.new()
		dn.text = DERIVED_KEYS[i]
		dn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		dn.add_theme_font_size_override("font_size", 18)
		dn.add_theme_color_override("font_color", C_DIM)
		v.add_child(dn)
		var dv := Label.new()
		dv.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		dv.add_theme_font_size_override("font_size", 30)
		dv.add_theme_color_override("font_color", C_TEXT)
		v.add_child(dv)
		_derived_values.append(dv)
		_derived_names.append(dn)
		blk2.add_child(v)
		drv.add_child(blk2)
	right.add_child(drv)

	# 特技
	var skill_title := Label.new()
	skill_title.text = "特技"
	skill_title.add_theme_font_size_override("font_size", 20)
	skill_title.add_theme_color_override("font_color", C_GOLD)
	right.add_child(skill_title)
	_skill_label = Label.new()
	_skill_label.add_theme_font_size_override("font_size", 24)
	_skill_label.add_theme_color_override("font_color", C_TEXT)
	_skill_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_skill_label)

	# 生平
	var bio_title := Label.new()
	bio_title.text = "生平"
	bio_title.add_theme_font_size_override("font_size", 20)
	bio_title.add_theme_color_override("font_color", C_GOLD)
	right.add_child(bio_title)
	_bio_label = Label.new()
	_bio_label.add_theme_font_size_override("font_size", 21)
	_bio_label.add_theme_color_override("font_color", C_DIM)
	_bio_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bio_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_bio_label)
	body.add_child(right)
	root.add_child(body)

	# ---- 底部动作区 ----
	_action_box = HBoxContainer.new()
	_action_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_action_box.add_theme_constant_override("separation", 20)
	root.add_child(_action_box)
	return root


# ------------------------------------------------------------------
# 对外接口
# ------------------------------------------------------------------

func open(target: Dictionary) -> void:
	_target = target
	_is_npc_mode = str(target.get("type", "")) == "npc" \
		or not _resolve_character(target).is_empty()
	_refresh()
	visible = true
	action_enabled_check()


func close() -> void:
	visible = false
	_target = {}
	closed.emit()


func close_silently() -> void:
	visible = false


func is_open() -> bool:
	return visible


func get_target() -> Dictionary:
	return _target


func _on_close() -> void:
	AudioManager.sfx_click()
	close()


## 城池详情不需要隐藏移动入口等，这里预留扩展位
func action_enabled_check() -> void:
	pass


# ------------------------------------------------------------------
# 数据填充
# ------------------------------------------------------------------

func _resolve_character(target: Dictionary) -> Dictionary:
	var data: Dictionary = target.get("data", {})
	# v6 官方表：按数字 role_id 查 heroes6（825 人）
	var rid := int(data.get("role_id", 0))
	if rid > 0:
		var hero6 := DataManager.get_hero6(rid)
		if not hero6.is_empty():
			return hero6
	# legacy 自研表
	var hid := str(data.get("hero_id", ""))
	if hid.is_empty():
		hid = str(data.get("character_id", ""))
	return CharacterService.find_character(hid)


func _refresh() -> void:
	if _is_npc_mode:
		_refresh_npc()
	else:
		_refresh_place()
	_rebuild_actions()


func _refresh_npc() -> void:
	# 标签头切回个人属性（城池模式可能改过）
	for i in range(4):
		_stat_names[i].text = STAT_KEYS[i]
		_derived_names[i].text = DERIVED_KEYS[i]
	var data: Dictionary = _target.get("data", {})
	var ch := _resolve_character(_target)
	var name_txt := str(_target.get("name", ""))
	_name_label.text = "【人物】" + name_txt
	var faction := str(ch.get("faction_name", ""))
	var title := str(_target.get("title", ""))
	_sub_label.text = title + ("　·　" + faction if not faction.is_empty() else "")

	# 立绘：npc_id → hero_id → role_id（heroes6 数字 id）依次尝试
	_load_portrait([
		"res://assets/sprites/npcs/%s.png" % str(data.get("id", "")),
		"res://assets/sprites/npcs/%s.png" % str(data.get("hero_id", "")),
		"res://assets/sprites/npcs/%s.png" % str(data.get("role_id", "")),
	])
	_portrait_char.text = name_txt.left(1)

	if ch.is_empty():
		for i in range(4):
			_stat_values[i].text = "—"
			_stat_grades[i].text = ""
			_derived_values[i].text = "—"
		_skill_label.text = "不详"
		_bio_label.text = _npc_bio(data)
		_req_label.text = ""
		return

	# 四维按数据源自动适配：
	#   v6 官方表 → 强壮/武力/智力/魅力；legacy 自研表 → 统率/武力/智力/政治
	var fs := CharacterService.four_stats(ch)
	var labels: Array = fs.get("labels", []) as Array
	var vals: Array = fs.get("values", []) as Array
	for i in range(4):
		if i < labels.size():
			_stat_names[i].text = str(labels[i])
		var v: float = float(vals[i]) if i < vals.size() else 0.0
		_stat_values[i].text = str(int(v))
		_stat_grades[i].text = CharacterService.grade(v)
	var dv := CharacterService.derived(ch)
	_derived_values[0].text = str(dv["attack"])
	_derived_values[1].text = str(dv["defense"])
	_derived_values[2].text = str(dv["crit"])
	_derived_values[3].text = str(dv["hit"])
	_skill_label.text = CharacterService.traits_text(ch)
	_bio_label.text = str(ch.get("bio", _npc_bio(data)))
	_req_label.text = _recruit_req_text(data)


func _npc_bio(data: Dictionary) -> String:
	var lines: Array[String] = []
	var d := str(data.get("description", ""))
	if not d.is_empty():
		lines.append(d)
	var lore := str(data.get("lore", ""))
	if not lore.is_empty():
		lines.append(lore)
	return "　".join(lines) if not lines.is_empty() else "（暂无记载）"


func _recruit_req_text(data: Dictionary) -> String:
	var hid := str(data.get("hero_id", ""))
	if hid.is_empty():
		return ""
	var e := CharacterService.find_recruit_entry(hid)
	if e.is_empty():
		return ""
	var req := CharacterService.recruit_requirements(e)
	return "结交条件：金钱 %d　名声 %d" % [int(req["gold"]), int(req["fame"])]


func _refresh_place() -> void:
	var data: Dictionary = _target.get("data", {})
	var name_txt := str(_target.get("name", ""))
	_name_label.text = "【城池】" + name_txt
	_sub_label.text = "%s　·　%s" % [
		str(_target.get("title", "")), str(data.get("faction_name", ""))]

	_load_portrait([
		"res://assets/sprites/map/%s.png" % str(data.get("id", "")),
	])
	_portrait_char.text = name_txt.left(1)

	# 标签头切换为城池字段，绝不显示个人四维
	for i in range(4):
		_stat_names[i].text = CITY_STAT_KEYS[i]
		_derived_names[i].text = CITY_DERIVED_KEYS[i]
		_stat_grades[i].text = ""
	# 大数值位：城防 / 民心 / 人口 / 驻军
	var values := [
		str(int(data.get("defense", 0))),
		str(int(data.get("morale", 0))),
		str(int(data.get("population", 0))),
		str(int(data.get("garrison", 0))),
	]
	for i in range(4):
		_stat_values[i].text = values[i]
	# 小卡位：特产 / 势力 / 规模 / 等级
	var t := str(data.get("type", "city"))
	var scale_txt := str(TYPE_CN.get(t, t))
	if bool(data.get("is_capital", false)):
		scale_txt += " · 都城"
	var drv2 := [
		str(data.get("specialty", "—")),
		str(data.get("faction_name", "—")),
		scale_txt,
		"Lv." + str(int(data.get("level", 1))),
	]
	for i in range(4):
		_derived_values[i].text = drv2[i]
	_skill_label.text = "太守：暂未设置"
	_bio_label.text = str(data.get("description", "（暂无介绍）"))
	_req_label.text = ""


func _load_portrait(paths: Array) -> void:
	_portrait_tex.visible = false
	_portrait_char.visible = true
	for p in paths:
		var path := str(p)
		if path.ends_with(".png") and ResourceLoader.exists(path):
			var tex: Texture2D = load(path)
			if tex != null:
				_portrait_tex.texture = tex
				_portrait_tex.visible = true
				_portrait_char.visible = false
			return


func _rebuild_actions() -> void:
	for c in _action_box.get_children():
		c.queue_free()
	if _is_npc_mode:
		var data: Dictionary = _target.get("data", {})
		if not str(data.get("dialogue_root", "")).is_empty():
			_add_action("对 话", "talk_to")
		_add_action("交 易", "trade", not str(data.get("shop_table", "")).is_empty())
		_add_action("送 礼", "gift")
		_add_action("切 磋", "spar")
		var tags: Array = _target.get("tags", [])
		if tags.has("recruitable") or tags.has("hero"):
			_add_action("结 交", "recruit")
	else:
		var t := str(_target.get("type", ""))
		if t == "city" or t == "village":
			_add_action("进 入", "enter")
		_add_action("情 报", "info_detail")


func _add_action(text: String, action: String, enabled: bool = true) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(170, 66)
	b.add_theme_font_size_override("font_size", 26)
	b.disabled = not enabled
	if enabled:
		b.pressed.connect(_on_action.bind(action))
	else:
		b.add_theme_color_override("font_color", Color(0.45, 0.42, 0.38))
	_action_box.add_child(b)


func _on_action(action: String) -> void:
	AudioManager.sfx_click()
	var t := _target
	# 面板先收起，交由 world_map 决定后续（开对话 / 切场景 / toast）
	close_silently()
	action_requested.emit(action, t)

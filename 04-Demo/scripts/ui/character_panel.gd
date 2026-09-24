extends Control
class_name CharacterPanel
## 独立人物 / 城池详情面板（全屏卡片，替代旧的横屏弹字）。
## 左：立绘位 + 招募条件；右：四维 / 派生属性 / 特技 / 生平。
## 底部动作区随对象类型变化：NPC（对话/交易/送礼/切磋/结交）、城池（进入）。
## 面板整体代码动态构建（工程纪律：不往 tscn 堆控件）。

signal action_requested(action: String, target: Dictionary)
signal closed
signal back_requested   ## 「返回列表」：从人物志进来的详情页返回列表（不整页关闭）

## 配色/字号/容器一律走 UITheme（P3-6）

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
var _back_btn: Button   ## 「返回列表」按钮（仅从人物志进入时显示）


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# 自定义头：大号姓名 + 副标题 + ✕
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_label = UITheme.label("", UITheme.FS_TITLE, UITheme.GOLD)
	title_box.add_child(_name_label)
	_sub_label = UITheme.label("", UITheme.FS_BODY, UITheme.DIM)
	title_box.add_child(_sub_label)
	head.add_child(title_box)
	_close_btn = UITheme.button("✕", UITheme.FS_HEAD, UITheme.CLOSE_SIZE)
	_close_btn.pressed.connect(_on_close)
	head.add_child(_close_btn)

	var m := UITheme.make_modal(self, "", _on_close, head)
	_card = m["card"]
	m["body"].add_child(_build_content())
	# 底部动作区固定在滚动区之外，滚动内容时按钮始终可见
	_action_box = HBoxContainer.new()
	_action_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_action_box.add_theme_constant_override("separation", 20)
	m["outer"].add_child(_action_box)
	# 「返回列表」：从人物志选人进来时显示，点了回列表而不是整个关掉重来
	_back_btn = UITheme.button("◀ 返回列表", UITheme.FS_BODY, Vector2(220, 64))
	_back_btn.visible = false
	_back_btn.pressed.connect(func():
		AudioManager.sfx_click()
		visible = false
		_target = {}
		closed.emit()
		back_requested.emit())
	_action_box.add_child(_back_btn)


func _build_content() -> Control:
	var root := HBoxContainer.new()
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 28)

	# ---- 左立绘 / 右数据 ----
	# 左列：立绘 + 招募条件
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(380, 0)
	left.add_theme_constant_override("separation", 10)
	_portrait_box = PanelContainer.new()
	_portrait_box.custom_minimum_size = Vector2(380, 470)
	_portrait_box.add_theme_stylebox_override("panel", UITheme.inner_style())
	_portrait_tex = TextureRect.new()
	_portrait_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait_tex.set_anchors_preset(Control.PRESET_FULL_RECT)
	_portrait_tex.visible = false
	_portrait_char = Label.new()
	_portrait_char.set_anchors_preset(Control.PRESET_FULL_RECT)
	_portrait_char.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_portrait_char.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_portrait_char.add_theme_font_size_override("font_size", UITheme.FS_WATERMARK)
	_portrait_char.add_theme_color_override("font_color", UITheme.GOLD_DIM)
	_portrait_box.add_child(_portrait_tex)
	_portrait_box.add_child(_portrait_char)
	left.add_child(_portrait_box)
	_req_label = UITheme.label("", UITheme.FS_NOTE, UITheme.DIM)
	_req_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_req_label)
	root.add_child(left)

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
		var nm := UITheme.label(STAT_KEYS[i], UITheme.FS_NOTE, UITheme.DIM)
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		blk.add_child(nm)
		var val := UITheme.label("", UITheme.FS_NUM, UITheme.TEXT)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		blk.add_child(val)
		var gr := UITheme.label("", UITheme.FS_NOTE, UITheme.GOOD)
		gr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
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
		blk2.add_theme_stylebox_override("panel", UITheme.inner_style())
		var v := VBoxContainer.new()
		var dn := UITheme.label(DERIVED_KEYS[i], UITheme.FS_NOTE, UITheme.DIM)
		dn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(dn)
		var dv := UITheme.label("", UITheme.FS_HEAD, UITheme.TEXT)
		dv.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(dv)
		_derived_values.append(dv)
		_derived_names.append(dn)
		blk2.add_child(v)
		drv.add_child(blk2)
	right.add_child(drv)

	# 特技
	right.add_child(UITheme.label("特技", UITheme.FS_BODY, UITheme.GOLD))
	_skill_label = UITheme.label("", UITheme.FS_BODY, UITheme.TEXT)
	_skill_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_skill_label)

	# 生平
	right.add_child(UITheme.label("生平", UITheme.FS_BODY, UITheme.GOLD))
	_bio_label = UITheme.label("", UITheme.FS_NOTE, UITheme.DIM)
	_bio_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bio_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_bio_label)
	# 右列直接并入根（根就是原来的主体 HBox）；底部动作区在 _ready 里挂到 outer，不随滚动
	root.add_child(right)
	return root


# ------------------------------------------------------------------
# 对外接口
# ------------------------------------------------------------------

func open(target: Dictionary, show_back := false) -> void:
	_target = target
	_is_npc_mode = str(target.get("type", "")) == "npc" \
		or not _resolve_character(target).is_empty()
	_refresh()
	_back_btn.visible = show_back
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
	var bio := str(ch.get("bio", ""))
	if bio.is_empty():
		bio = CharacterService.bio_text(ch)
	if bio.is_empty():
		bio = _npc_bio(data)
	_bio_label.text = bio
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
	var b := UITheme.button(text, UITheme.FS_BODY, Vector2(170, 66))
	b.disabled = not enabled
	if enabled:
		b.pressed.connect(_on_action.bind(action))
	_action_box.add_child(b)


func _on_action(action: String) -> void:
	AudioManager.sfx_click()
	var t := _target
	# 面板先收起，交由 world_map 决定后续（开对话 / 切场景 / toast）
	close_silently()
	action_requested.emit(action, t)

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
var _avatar: Label          ## 主角头像占位（名字首字水印）
var _title_label: Label     ## 面板标题
var _sub_label: Label       ## 标题下副文字（名字 / 阵营）
var _lv_label: Label
var _exp_label: Label
var _point_label: Label
var _rows: Array = []   ## 每行缓存 { key, value: Label, btn: Button }
var _equip_rows: Array = []  ## { slot: String, info: Label }
var _picker: ColorRect = null  ## 装备更换弹层（含居中窗口）


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
	# 响应式：视口不足时按比例缩小面板，避免 1400×860 在小屏溢出
	var vp := get_viewport_rect().size
	var pw := minf(1400.0, maxf(800.0, vp.x - 40.0))
	var ph := minf(860.0, maxf(500.0, vp.y - 40.0))
	_card.custom_minimum_size = Vector2(pw, ph)
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_CARD
	sb.border_color = C_BORDER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 28.0
	sb.content_margin_right = 28.0
	sb.content_margin_top = 18.0
	sb.content_margin_bottom = 18.0
	_card.add_theme_stylebox_override("panel", sb)
	center.add_child(_card)
	# 内容可滚动：条目多（4 属性 + 6 装备槽）时不再溢出/被裁，全部可达。
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(pw, ph)
	_card.add_child(scroll)
	scroll.add_child(_build())

	EventBus.player_stats_changed.connect(_on_stats_changed)
	EventBus.equipment_changed.connect(_on_equipment_changed)


func _build() -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)

	# ---- 头部：头像 + 标题 + 关闭 ----
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 18)
	# 头像占位：无贴图时用主角名字首字作水印字（与对话立绘回退一致），
	# 保证「主角」页不因缺贴图而显示空白。
	_avatar = Label.new()
	_avatar.custom_minimum_size = Vector2(96, 96)
	_avatar.add_theme_font_size_override("font_size", 52)
	_avatar.add_theme_color_override("font_color", Color(0.66, 0.58, 0.40))
	_avatar.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_avatar.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var psb := StyleBoxFlat.new()
	psb.bg_color = Color(0.09, 0.075, 0.06, 0.95)
	psb.border_color = C_BORDER
	psb.set_border_width_all(2)
	psb.set_corner_radius_all(14)
	_avatar.add_theme_stylebox_override("normal", psb)
	head.add_child(_avatar)
	var title_col := VBoxContainer.new()
	title_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_col.add_theme_constant_override("separation", 2)
	_title_label = Label.new()
	_title_label.text = "主角成长"
	_title_label.add_theme_font_size_override("font_size", 40)
	_title_label.add_theme_color_override("font_color", C_GOLD)
	title_col.add_child(_title_label)
	_sub_label = Label.new()
	_sub_label.add_theme_font_size_override("font_size", 22)
	_sub_label.add_theme_color_override("font_color", C_DIM)
	title_col.add_child(_sub_label)
	head.add_child(title_col)
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

	# ---- 装备 6 槽 ----
	root.add_child(HSeparator.new())
	var eq_title := Label.new()
	eq_title.text = "装备（铁匠铺打造后可在此穿戴；武将装备为其自带）"
	eq_title.add_theme_font_size_override("font_size", 28)
	eq_title.add_theme_color_override("font_color", C_GOLD)
	root.add_child(eq_title)
	for slot in CharacterService.EQUIP_SLOTS:
		root.add_child(_make_equip_row(String(slot)))

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


## 一行：装备槽名 + 当前物品与加成摘要 + [更换]
func _make_equip_row(slot: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)

	var name := Label.new()
	name.text = String(CharacterService.SLOT_LABELS[slot])
	name.add_theme_font_size_override("font_size", 24)
	name.add_theme_color_override("font_color", C_TEXT)
	name.custom_minimum_size = Vector2(110, 0)
	row.add_child(name)

	var info := Label.new()
	info.add_theme_font_size_override("font_size", 22)
	info.add_theme_color_override("font_color", C_GOOD)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(info)

	var btn := Button.new()
	btn.text = "更换"
	btn.custom_minimum_size = Vector2(130, 52)
	btn.add_theme_font_size_override("font_size", 22)
	btn.pressed.connect(func(): _open_equip_picker(slot))
	row.add_child(btn)

	_equip_rows.append({ "slot": slot, "info": info })
	return row


func _refresh_equipment_rows() -> void:
	for r in _equip_rows:
		var slot := String(r["slot"])
		var info := r["info"] as Label
		var id := int(GameState.equipment.get(slot, 0))
		if id > 0:
			var item := DataManager.get_item6(id)
			info.text = "%s　%s" % [str(item.get("name", "?")),
				CharacterService.item_bonus_text(item, EnhanceService.level_of(id))]
		else:
			info.text = "（空）"
			info.add_theme_color_override("font_color", C_DIM)


## ---------- 装备更换弹层 ----------

func _open_equip_picker(slot: String) -> void:
	_close_equip_picker()
	AudioManager.sfx_click()

	_picker = ColorRect.new()
	_picker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_picker.color = Color(0.02, 0.02, 0.015, 0.62)
	_picker.mouse_filter = Control.MOUSE_FILTER_STOP
	_picker.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed:
			_close_equip_picker())
	add_child(_picker)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_picker.add_child(center)

	var win := PanelContainer.new()
	win.custom_minimum_size = Vector2(840, 760)
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_CARD
	sb.border_color = C_BORDER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 24.0
	sb.content_margin_right = 24.0
	sb.content_margin_top = 20.0
	sb.content_margin_bottom = 20.0
	win.add_theme_stylebox_override("panel", sb)
	center.add_child(win)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	win.add_child(vbox)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	var title := Label.new()
	title.text = "更换装备 · %s" % String(CharacterService.SLOT_LABELS[slot])
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", C_GOLD)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close := Button.new()
	close.text = "✕"
	close.custom_minimum_size = Vector2(56, 52)
	close.add_theme_font_size_override("font_size", 24)
	close.pressed.connect(_close_equip_picker)
	head.add_child(close)
	vbox.add_child(head)
	vbox.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	# 当前已装备 → 卸下
	var cur_id := int(GameState.equipment.get(slot, 0))
	if cur_id > 0:
		var cur_item := DataManager.get_item6(cur_id)
		list.add_child(_make_picker_row(
			"【已装备】%s　%s" % [str(cur_item.get("name", "?")),
				CharacterService.item_bonus_text(cur_item, EnhanceService.level_of(cur_id))],
			"卸下",
			func():
				GameState.unequip_item(slot)
				AudioManager.sfx_confirm()
				_close_equip_picker()
				_refresh()))

	# 背包中可装入此槽的物品（数字 id 或有兼容映射的旧 id）
	var any_goods := false
	for key in GameState.inventory.keys():
		var kid := String(key)
		if not GameState.can_equip(slot, kid):
			continue
		if GameState.get_item_count(kid) <= 0:
			continue
		any_goods = true
		var item := CharacterService.resolve_item6(kid)
		var iid := kid.to_int() if kid.is_valid_int() else CharacterService.legacy_item_mapped(kid)
		var s: String = slot
		list.add_child(_make_picker_row(
			"%s ×%d　%s" % [str(item.get("name", kid)), GameState.get_item_count(kid),
				CharacterService.item_bonus_text(item, EnhanceService.level_of(iid))],
			"装备",
			func():
				if GameState.equip_item(s, kid):
					AudioManager.sfx_confirm()
					EventBus.toast.emit("已装备。")
				else:
					AudioManager.sfx_cancel()
					EventBus.toast.emit("装备失败。")
				_close_equip_picker()
				_refresh()))

	if cur_id <= 0 and not any_goods:
		var hint := Label.new()
		hint.text = "背包中没有可装备此槽位的物品，去铁匠铺看看吧。"
		hint.add_theme_font_size_override("font_size", 22)
		hint.add_theme_color_override("font_color", C_DIM)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		list.add_child(hint)


func _make_picker_row(text: String, btn_text: String, on_pressed: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var lab := Label.new()
	lab.text = text
	lab.add_theme_font_size_override("font_size", 22)
	lab.add_theme_color_override("font_color", C_TEXT)
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lab)
	var btn := Button.new()
	btn.text = btn_text
	btn.custom_minimum_size = Vector2(120, 48)
	btn.add_theme_font_size_override("font_size", 22)
	btn.pressed.connect(on_pressed)
	row.add_child(btn)
	return row


func _close_equip_picker() -> void:
	if is_instance_valid(_picker):
		_picker.queue_free()
	_picker = null


func _on_add(key: String) -> void:
	if GameState.spend_attr_point(key):
		AudioManager.sfx_confirm()
		_refresh()
		EventBus.toast.emit("属性点已投入「%s」。" % key)
	else:
		AudioManager.sfx_cancel()
		EventBus.toast.emit("没有可分配的属性点了。")


func _refresh() -> void:
	# 头像与身份栏：主角名字首字作水印头像，副文字显示名字 + 势力，避免页面“空白无贴图”。
	var pname := str(GameState.player_name)
	if _avatar != null:
		_avatar.text = pname.left(1) if not pname.is_empty() else "主"
	if _title_label != null:
		_title_label.text = "主角成长 · %s" % pname
	if _sub_label != null:
		var sub := "Lv.%d　名声 %d" % [GameState.player_level, GameState.fame]
		_sub_label.text = sub
	_lv_label.text = "等级　Lv.%d" % GameState.player_level
	_exp_label.text = "经验　%d" % GameState.player_exp
	var pts := GameState.player_attr_points
	_point_label.text = "可分配属性点　%d" % pts
	for r in _rows:
		var k := str(r["key"])
		(r["value"] as Label).text = str(int(GameState.player_stats.get(k, 0)))
		(r["btn"] as Button).disabled = (pts <= 0)
	_refresh_equipment_rows()


func _on_stats_changed(_v = null) -> void:
	if visible:
		_refresh()


func _on_equipment_changed() -> void:
	if visible:
		_refresh()


func open() -> void:
	visible = true
	_refresh()


func close_panel() -> void:
	_close_equip_picker()
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close_panel()
		get_viewport().set_input_as_handled()

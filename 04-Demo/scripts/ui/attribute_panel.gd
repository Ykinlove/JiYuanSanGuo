extends Control
class_name AttributePanel
## 主角成长 / 属性加点面板。
## 读取 GameState.player_stats / player_attr_points / player_level / player_exp。
## 四属性：体质(constitution) / 力量(strength) / 智力(intelligence) / 魅力(charisma)，
## 每个 ＋ 按钮消耗 1 点属性点（GameState.spend_attr_point）。UI 不含任何加点规则。
## 配色/字号/容器一律走 UITheme（P3-6）。

signal closed

const STAT_DEFS := [
	{ "key": "constitution", "name": "体质", "desc": "影响生命与负重" },
	{ "key": "strength",     "name": "力量", "desc": "影响物理攻击与带兵" },
	{ "key": "intelligence", "name": "智力", "desc": "影响策略与计谋" },
	{ "key": "charisma",     "name": "魅力", "desc": "影响招募与外交" },
]

var _card: PanelContainer
var _avatar: Label          ## 主角头像占位（立绘缺失时的首字水印）
var _avatar_tex: TextureRect  ## 主角立绘（assets/sprites/player/<player_portrait>.png）
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

	var m := UITheme.make_modal(self, "主角成长", close_panel, _build_head())
	_card = m["card"]
	var body: VBoxContainer = m["body"]
	_build(body)

	EventBus.player_stats_changed.connect(_on_stats_changed)
	EventBus.equipment_changed.connect(_on_equipment_changed)


## 自定义头部：主角立绘（缺失回退首字水印）+ 「主角成长 · 名字」+ 副文字 + ✕
func _build_head() -> Control:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 18)
	# 头像位：优先读创角立绘（GameState.player_portrait → assets/sprites/player/），
	# 缺图时回退主角名字首字水印，保证「主角」页不空白。
	var avatar_box := PanelContainer.new()
	avatar_box.custom_minimum_size = Vector2(96, 96)
	avatar_box.add_theme_stylebox_override("panel", UITheme.inner_style())
	_avatar_tex = TextureRect.new()
	_avatar_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_avatar_tex.set_anchors_preset(Control.PRESET_FULL_RECT)
	_avatar_tex.visible = false
	_avatar = Label.new()
	_avatar.set_anchors_preset(Control.PRESET_FULL_RECT)
	_avatar.add_theme_font_size_override("font_size", 52)
	_avatar.add_theme_color_override("font_color", UITheme.GOLD_DIM)
	_avatar.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_avatar.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	avatar_box.add_child(_avatar_tex)
	avatar_box.add_child(_avatar)
	head.add_child(avatar_box)

	var title_col := VBoxContainer.new()
	title_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_col.add_theme_constant_override("separation", 2)
	_title_label = UITheme.label("主角成长", UITheme.FS_TITLE, UITheme.GOLD)
	title_col.add_child(_title_label)
	_sub_label = UITheme.label("", UITheme.FS_BODY, UITheme.DIM)
	title_col.add_child(_sub_label)
	head.add_child(title_col)

	var close := UITheme.button("✕", UITheme.FS_HEAD, UITheme.CLOSE_SIZE)
	close.pressed.connect(close_panel)
	head.add_child(close)
	return head


func _build(root: VBoxContainer) -> void:
	# ---- 概览：等级 / 经验 / 可分配点数 ----
	var sum := HBoxContainer.new()
	sum.add_theme_constant_override("separation", 36)
	_lv_label = UITheme.label("", UITheme.FS_HEAD, UITheme.TEXT)
	_exp_label = UITheme.label("", UITheme.FS_NOTE, UITheme.DIM)
	_point_label = UITheme.label("", UITheme.FS_HEAD, UITheme.POINT)
	sum.add_child(_lv_label)
	sum.add_child(_exp_label)
	sum.add_child(_point_label)
	root.add_child(UITheme.row_wrap(sum))
	root.add_child(HSeparator.new())

	# ---- 四属性加点行 ----
	for sd in STAT_DEFS:
		root.add_child(_make_stat_row(sd))

	# ---- 装备 6 槽 ----
	root.add_child(HSeparator.new())
	root.add_child(UITheme.label("装备（铁匠铺打造后可在此穿戴；武将装备为其自带）",
		UITheme.FS_HEAD, UITheme.GOLD))
	for slot in CharacterService.EQUIP_SLOTS:
		root.add_child(_make_equip_row(String(slot)))


## 一行：属性名 + 当前值 + ＋加点按钮
func _make_stat_row(sd: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)

	var name := UITheme.label("%s　%s" % [str(sd["name"]), str(sd["desc"])])
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name)

	var val := UITheme.label("", UITheme.FS_HEAD, UITheme.GOOD)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.custom_minimum_size = Vector2(72, 0)
	row.add_child(val)

	var btn := UITheme.button("＋ 加点", UITheme.FS_BODY, Vector2(150, 60))
	btn.pressed.connect(func(): _on_add(str(sd["key"])))
	row.add_child(btn)

	_rows.append({ "key": str(sd["key"]), "value": val, "btn": btn })
	return UITheme.row_wrap(row)


## 一行：装备槽名 + 当前物品与加成摘要 + [更换]
func _make_equip_row(slot: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)

	var name := UITheme.label(String(CharacterService.SLOT_LABELS[slot]))
	name.custom_minimum_size = Vector2(110, 0)
	row.add_child(name)

	var info := UITheme.label("", UITheme.FS_NOTE, UITheme.GOOD)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(info)

	var btn := UITheme.button("更换", UITheme.FS_BODY, Vector2(130, 52))
	btn.pressed.connect(func(): _open_equip_picker(slot))
	row.add_child(btn)

	_equip_rows.append({ "slot": slot, "info": info })
	return UITheme.row_wrap(row)


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
			info.add_theme_color_override("font_color", UITheme.DIM)


## ---------- 装备更换弹层 ----------

func _open_equip_picker(slot: String) -> void:
	_close_equip_picker()
	AudioManager.sfx_click()

	var m := UITheme.make_sub_modal(self, "更换装备 · %s" % String(CharacterService.SLOT_LABELS[slot]),
		_close_equip_picker, Vector2(840, 760))
	_picker = m["dim"]
	var list: VBoxContainer = m["body"]

	# 当前已装备 → 卸下
	var cur_id := int(GameState.equipment.get(slot, 0))
	if cur_id > 0:
		var cur_item := DataManager.get_item6(cur_id)
		list.add_child(UITheme.make_row(
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
		list.add_child(UITheme.make_row(
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
		var hint := UITheme.label("背包中没有可装备此槽位的物品，去铁匠铺看看吧。",
			UITheme.FS_BODY, UITheme.DIM)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		list.add_child(hint)


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
	# 头像：优先主角立绘（player_portrait 指向 assets/sprites/player/<id>.png），
	# 缺图回退主角名字首字水印。
	if _avatar_tex != null:
		var ppath := "res://assets/sprites/player/%s.png" % str(GameState.player_portrait)
		if ResourceLoader.exists(ppath):
			var tex: Texture2D = load(ppath)
			if tex != null:
				_avatar_tex.texture = tex
				_avatar_tex.visible = true
				_avatar.visible = false
		if not _avatar_tex.visible:
			_avatar_tex.visible = false
			_avatar.visible = true
	# 头像与身份栏：主角名字首字作水印头像，副文字显示名字 + 势力，避免页面“空白无贴图”。
	var pname := str(GameState.player_name)
	if _avatar != null and _avatar.visible:
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

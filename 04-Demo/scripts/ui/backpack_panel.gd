extends Control
class_name BackpackPanel
## 背包面板：查看 GameState.inventory（采集资源 / 装备武器 / 材料杂物）。
## 数据：inventory { String item_id: int count }，add_item/remove_item 维护；
## 解析顺序：CharacterService.resolve_item6（items6 数字 id / 旧 id 映射）
##           → DataManager.get_item（旧 items.json 字符串 id）
##           → 兜底显示原始 key。
## 面板为纯查看（装备穿戴走主角面板「更换装备」），不在此处做任何数值操作。
## 配色/字号/容器一律走 UITheme（水墨描金）。

signal closed
## 【2026-09-28 用户反馈】标题行「返 回」按钮：关面板并要求场景重开轮盘菜单
signal menu_return_requested

## items6 cat_major → 徽标单字（1 材料 / 2 头盔 / 3 食物 / 4 护甲 / 5 武器 / 6 宝物 / 7 坐骑 / 8 工具杂物）
const CAT_LABELS := {
	1: "材", 2: "盔", 3: "食", 4: "甲", 5: "武", 6: "宝", 7: "骑", 8: "杂",
}
## 可穿戴大类（排前展示；穿戴操作在主角面板）
const GEAR_CATS: Array[int] = [5, 2, 4, 6, 7]
## 品质名 → 字色（对齐 items6.quality_name 取值）
const QUALITY_COLORS := {
	"传说": UITheme.GOLD,
	"史诗": Color(0.82, 0.70, 0.92),
	"稀有": Color(0.72, 0.86, 0.98),
	"精良": UITheme.GOOD,
	"普通": UITheme.TEXT,
	"未知": UITheme.DIM,
}
## 旧 items.json category → 徽标单字
const LEGACY_CAT_LABELS := {
	"weapon": "武", "armor": "甲", "horse": "骑", "treasure": "宝",
	"material": "材", "food": "食", "tool": "杂", "quest": "任", "gift": "礼",
}

var _stat: Label
var _list: VBoxContainer
var _scroll: ScrollContainer
var _modal: Dictionary
var _anim_tw: Tween = null


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var m := UITheme.make_modal(self, "背包", close_panel, null, UITheme.CITY_PANEL_SIZE, _on_menu_return)
	_modal = m
	_scroll = m["scroll"]
	var body: VBoxContainer = m["body"]
	_stat = UITheme.label("", UITheme.FS_BODY, UITheme.DIM)
	body.add_child(_stat)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 8)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_list)

	EventBus.inventory_changed.connect(_on_inventory_changed)


## 「返 回」按钮：隐藏面板并通知场景重开轮盘菜单
func _on_menu_return() -> void:
	if _anim_tw != null and _anim_tw.is_valid():
		_anim_tw.kill()
	_anim_tw = UITheme.modal_exit(_modal, _finish_menu_return)


func _finish_menu_return() -> void:
	visible = false
	menu_return_requested.emit()


func open() -> void:
	if _anim_tw != null and _anim_tw.is_valid():
		_anim_tw.kill()
	_refresh()
	_scroll.scroll_vertical = 0   ## 【M1】打开复位滚动
	visible = true
	_anim_tw = UITheme.modal_enter(_modal)


func is_open() -> bool:
	return visible


func close_panel() -> void:
	if _anim_tw != null and _anim_tw.is_valid():
		_anim_tw.kill()
	_anim_tw = UITheme.modal_exit(_modal, _finish_close)


func _finish_close() -> void:
	visible = false
	closed.emit()


func _on_inventory_changed(_item_id: String, _count: int) -> void:
	if visible:
		_refresh()


## ---------- 数据装配 ----------

func _refresh() -> void:
	for c in _list.get_children():
		# 先摘除再释放：queue_free 帧末才生效，旧按钮本帧仍可被点第二次
		_list.remove_child(c)
		c.queue_free()

	var entries: Array[Dictionary] = []
	var total := 0
	for key in GameState.inventory.keys():
		var k := String(key)
		var cnt := GameState.get_item_count(k)
		if cnt <= 0:
			continue
		total += cnt
		entries.append(_resolve_entry(k, cnt))

	_stat.text = "共 %d 种 / %d 件" % [entries.size(), total]

	if entries.is_empty():
		var empty := UITheme.label("背包空空如也——去大地图采集、开宝箱或逛逛铁匠铺吧。",
			UITheme.FS_BODY, UITheme.DIM)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_list.add_child(empty)
		return

	entries.sort_custom(_entry_less)
	for e in entries:
		_list.add_child(_make_row(e))


## 单个背包 key → 展示条目
func _resolve_entry(key: String, count: int) -> Dictionary:
	var item6 := CharacterService.resolve_item6(key)
	if not item6.is_empty():
		var cm := int(item6.get("cat_major", 0))
		var lv := 0
		if key.is_valid_int():
			lv = EnhanceService.level_of(int(key))
		return {
			"key": key, "count": count,
			"name": str(item6.get("name", key)),
			"cat": cm, "cat_label": String(CAT_LABELS.get(cm, "杂")),
			"quality": str(item6.get("quality_name", "")),
			"bonus": CharacterService.item_bonus_text(item6, lv),
			"price": int(item6.get("price", 0)),
			"desc": "",
			"is_gear": cm in GEAR_CATS,
		}

	var old := DataManager.get_item(key)
	if not old.is_empty():
		var cat_s := str(old.get("category", ""))
		var parts: Array[String] = []
		if int(old.get("attack", 0)) > 0:
			parts.append("攻+%d" % int(old.get("attack", 0)))
		if int(old.get("defense", 0)) > 0:
			parts.append("防+%d" % int(old.get("defense", 0)))
		return {
			"key": key, "count": count,
			"name": str(old.get("name", key)),
			"cat": -1, "cat_label": String(LEGACY_CAT_LABELS.get(cat_s, "杂")),
			"quality": str(old.get("rarity", "")),
			"bonus": "　".join(parts),
			"price": int(old.get("price", 0)),
			"desc": str(old.get("description", "")),
			"is_gear": cat_s in ["weapon", "armor", "horse", "treasure"],
		}

	# 兜底：两表都查不到（特殊任务物 / 采集 id 未录表）——如实展示原始 id
	return {
		"key": key, "count": count, "name": key,
		"cat": 9, "cat_label": "杂", "quality": "",
		"bonus": "", "price": 0, "desc": "", "is_gear": false,
	}


## 排序：装备类在前（按 cat 顺序）→ 非装备按 cat → 同组按名称
func _entry_less(a: Dictionary, b: Dictionary) -> bool:
	var ga := bool(a["is_gear"])
	var gb := bool(b["is_gear"])
	if ga != gb:
		return ga
	var ca := int(a["cat"])
	var cb := int(b["cat"])
	if ca != cb:
		return ca < cb
	return str(a["name"]) < str(b["name"])


## ---------- 行 UI ----------

func _make_row(e: Dictionary) -> Control:
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 4)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 14)

	# 类别徽标（44×44 金边小方块；装备类金字、材料类灰字）
	var tag := UITheme.label(String(e["cat_label"]), UITheme.FS_HEAD,
		UITheme.GOLD if bool(e["is_gear"]) else UITheme.DIM)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var tag_box := PanelContainer.new()
	tag_box.custom_minimum_size = Vector2(44, 44)
	tag_box.add_theme_stylebox_override("panel", UITheme.btn_style(
		UITheme.GOLD_HOVER if bool(e["is_gear"]) else UITheme.INK_DEEP,
		UITheme.GOLD_LINE if bool(e["is_gear"]) else UITheme.GOLD_DIM))
	tag_box.add_child(tag)
	line.add_child(tag_box)

	# 名称 ×数量（品质上色）
	var qname := str(e["quality"])
	var name_color: Color = QUALITY_COLORS.get(qname, UITheme.TEXT) as Color
	var name_l := UITheme.label("%s ×%d" % [str(e["name"]), int(e["count"])],
		UITheme.FS_HEAD, name_color)
	name_l.custom_minimum_size = Vector2(300, 0)
	line.add_child(name_l)

	# 加成 / 价格摘要（弹性区，右对齐）
	var parts: Array[String] = []
	if not String(e["bonus"]).is_empty():
		parts.append(String(e["bonus"]))
	if int(e["price"]) > 0:
		parts.append("价 %d" % int(e["price"]))
	var info_l := UITheme.label("　".join(parts), UITheme.FS_BODY,
		UITheme.POINT if not String(e["bonus"]).is_empty() else UITheme.DIM)
	info_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.add_child(info_l)
	inner.add_child(line)

	# 描述（旧表物品带 description）
	var desc := String(e["desc"])
	if not desc.is_empty():
		var desc_l := UITheme.label(desc, UITheme.FS_NOTE, UITheme.DIM)
		desc_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		inner.add_child(desc_l)

	return UITheme.row_wrap(inner)

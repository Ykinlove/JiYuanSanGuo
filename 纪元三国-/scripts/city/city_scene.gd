extends Control
## 城池场景（CityScene）· M5
## 职责：城池经营总界面。五个建筑（酒馆/兵营/市场/铁匠铺/官府）各自打开独立面板，
##       所有规则判定交给 CityService，本文件只负责显示与交互。
##
## 布局（横屏 1920×1080）：
##   顶部 96px  城池名 + 城池信息 + 资源条（金/粮/木/铁）
##   中部       五个建筑入口（大卡片，触屏友好）
##   底部       离开 / 演练
##   面板层     点击建筑后从右侧滑出的功能面板，互不干扰

const C_BG := Color(0.12, 0.10, 0.08)
const C_PANEL := Color(0.16, 0.14, 0.11)
const C_PANEL_DARK := Color(0.11, 0.10, 0.09)
const C_ACCENT := Color(0.92, 0.80, 0.42)
const C_TEXT := Color(0.90, 0.88, 0.84)
const C_DIM := Color(0.62, 0.60, 0.56)
const C_GOOD := Color(0.55, 0.88, 0.55)
const C_BAD := Color(0.92, 0.52, 0.46)

const PANEL_W := 1180.0

@onready var _title: Label = %CityTitle
@onready var _info_label: Label = %CityInfo
@onready var _res_label: Label = %ResLabel
@onready var _place_grid: GridContainer = %PlaceGrid
@onready var _btn_leave: Button = %BtnLeave
@onready var _btn_drill: Button = %BtnDrill
@onready var _btn_menu: Button = %BtnMenu
@onready var _panel_layer: Control = %PanelLayer
@onready var _panel_title: Label = %PanelTitle
@onready var _panel_body: ScrollContainer = %PanelBody
@onready var _panel_content: VBoxContainer = %PanelContent
@onready var _panel_footer: HBoxContainer = %PanelFooter
@onready var _panel_root: Control = %PanelRoot
@onready var _btn_panel_close: Button = %PanelClose
@onready var _toast: Label = %ToastLabel

var _svc := CityService.new()
var _city: Dictionary = {}
var _city_id: String = ""
var _cur_panel: String = ""          ## tavern / barracks / market / smith / hall
var _place_buttons: Dictionary = {}  ## building_key -> Button


func _ready() -> void:
	_city_id = GameState.current_city_id
	_city = DataManager.get_city(_city_id)

	AudioManager.play_bgm("res://assets/audio/bgm/city.ogg")

	_build_place_buttons()
	_refresh_header()

	_btn_leave.pressed.connect(_on_leave)
	_btn_drill.pressed.connect(_open_drill)
	_btn_menu.pressed.connect(_open_menu)
	_btn_panel_close.pressed.connect(_close_panel)

	_panel_root.visible = false
	EventBus.toast.connect(show_toast)
	EventBus.gold_changed.connect(func(_v): _refresh_header())
	EventBus.food_changed.connect(func(_v): _refresh_header())
	EventBus.wood_changed.connect(func(_v): _refresh_header())
	EventBus.iron_changed.connect(func(_v): _refresh_header())
	EventBus.troop_changed.connect(func(_v): _refresh_header())
	EventBus.inventory_changed.connect(func(_a, _b): _on_inventory_changed())
	EventBus.party_changed.connect(_on_party_changed)


func _unhandled_input(event: InputEvent) -> void:
	# 安卓返回键 / Esc：优先关闭面板
	if event.is_action_pressed("ui_cancel"):
		if _panel_root.visible:
			_close_panel()
			get_viewport().set_input_as_handled()


## ---------- 顶部 ----------

func _refresh_header() -> void:
	var city_name := str(_city.get("name", "")) if not _city.is_empty() else "无名城镇"
	if city_name.is_empty():
		city_name = "无名城镇"
	_title.text = city_name

	if _city.is_empty():
		_info_label.text = "（无城池数据）"
	else:
		var lines: Array[String] = []
		lines.append("%s" % _type_cn(str(_city.get("type", "city"))))
		lines.append("等级 %d" % int(_city.get("level", 1)))
		lines.append("民心 %d" % GameState.get_city_morale(_city_id))
		lines.append("城防 %d" % GameState.get_city_defense(_city_id))
		lines.append("驻军 %d" % int(_city.get("garrison", 0)))
		lines.append("人口 %d" % int(_city.get("population", 0)))
		var spec := str(_city.get("specialty", ""))
		if not spec.is_empty():
			lines.append("特产 %s" % spec)
		_info_label.text = "　|　".join(lines)

	_res_label.text = "金 %d　　粮 %d　　木 %d　　铁 %d　　兵力 %d" % [
		GameState.gold, GameState.food, GameState.wood, GameState.iron,
		GameState.get_total_troops(),
	]


func _type_cn(t: String) -> String:
	match t:
		"city": return "城池"
		"village": return "村寨"
		"pass": return "关隘"
		"ruin": return "遗迹"
		_: return t


## ---------- 建筑入口 ----------

## 建筑定义：key -> { name, desc, building_field }
## building_field 对应 cities.json 里 buildings 数组的标识；空字符串表示无条件开放
const PLACES := [
	{ "key": "tavern",   "name": "酒  馆", "desc": "招募武将\n赠礼交好", "field": "tavern" },
	{ "key": "barracks", "name": "兵  营", "desc": "征兵练兵\n编入武将", "field": "barracks" },
	{ "key": "market",   "name": "市  场", "desc": "买卖物资\n补充给养", "field": "market" },
	{ "key": "smith",    "name": "铁匠铺", "desc": "打造装备\n购置神器", "field": "smith" },
	{ "key": "hall",     "name": "官  府", "desc": "内政建设\n演武操练", "field": "hall" },
]


func _build_place_buttons() -> void:
	for child in _place_grid.get_children():
		child.queue_free()
	_place_buttons.clear()

	var buildings: Array = _city.get("buildings", [])
	var is_city := str(_city.get("type", "city")) == "city"

	for p in PLACES:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(346, 200)
		btn.add_theme_font_size_override("font_size", 34)
		btn.text = "%s\n%s" % [str(p["name"]), str(p["desc"])]

		# 开放判定：城池才开放全部；村寨/关隘按 buildings 字段
		var field := str(p["field"])
		var open := true
		if not is_city:
			open = (field in buildings) or (field == "hall")
		else:
			# 城池：官府常开，其余看 buildings 字段（缺省视为开放）
			if field != "hall" and not buildings.is_empty():
				open = field in buildings

		btn.disabled = not open
		var key := str(p["key"])
		if open:
			btn.pressed.connect(func(): _open_panel(key))
		else:
			btn.text += "\n（未开放）"
		_place_grid.add_child(btn)
		_place_buttons[key] = btn


## ---------- 面板：通用 ----------

func _open_panel(key: String) -> void:
	if _cur_panel == key and _panel_root.visible:
		return
	AudioManager.sfx_click()
	_cur_panel = key
	_panel_root.visible = true
	_clear_panel()

	match key:
		"tavern":   _build_tavern()
		"barracks": _build_barracks()
		"market":   _build_market()
		"smith":    _build_smith()
		"hall":     _build_hall()


func _close_panel() -> void:
	AudioManager.sfx_cancel()
	_panel_root.visible = false
	_cur_panel = ""
	_clear_panel()
	_refresh_header()


func _clear_panel() -> void:
	for c in _panel_content.get_children():
		c.queue_free()
	for c in _panel_footer.get_children():
		if str(c.name) != "PanelClose":
			c.queue_free()


func _add_footer_btn(text: String, cb: Callable, primary: bool = false) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(230, 76)
	b.add_theme_font_size_override("font_size", 26)
	b.text = text
	if primary:
		b.add_theme_color_override("font_color", C_ACCENT)
	b.pressed.connect(cb)
	_panel_footer.add_child(b)
	return b


func _add_section(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 24)
	l.add_theme_color_override("font_color", C_ACCENT)
	_panel_content.add_child(l)


func _add_hint(text: String, color: Color = C_DIM) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 19)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_content.add_child(l)


func _add_row(text: String, cb: Callable, enabled: bool = true, sub: String = "") -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(1060, 74 if sub.is_empty() else 96)
	b.add_theme_font_size_override("font_size", 22)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text = text if sub.is_empty() else "%s\n%s" % [text, sub]
	b.disabled = not enabled
	if enabled:
		b.pressed.connect(cb)
	_panel_content.add_child(b)
	return b


## ---------- 面板：酒馆 ----------

func _build_tavern() -> void:
	_panel_title.text = "酒  馆"

	# 已入队武将
	_add_section("队伍武将（%d 人）" % GameState.party.size())
	if GameState.party.is_empty():
		_add_hint("尚无武将入队。招募武将为部队任命统兵，可大幅提升战力。")
	else:
		for h in GameState.party:
			var hero := DataManager.get_character(str(h.get("hero_id", "")))
			var stats: Dictionary = hero.get("stats", {})
			var cmd := (float(stats.get("intelligence", 50)) + float(stats.get("charisma", 50))) * 0.5
			_add_hint("· %s（%s）　统率约 %d　等级 %d　好感 %d" % [
				str(hero.get("name", "?")), str(hero.get("style_name", "")),
				int(cmd), int(h.get("level", 1)), int(h.get("intimacy", 0)),
			], C_TEXT)

	# 赠礼（若有美酒）
	if not GameState.party.is_empty() and GameState.get_item_count("consume_wine") > 0:
		_add_section("赠礼交好（美酒 ×%d）" % GameState.get_item_count("consume_wine"))
		for h in GameState.party:
			var hid := str(h.get("hero_id", ""))
			var hero := DataManager.get_character(hid)
			var hname := str(hero.get("name", hid))
			_add_row("赠 %s 美酒（好感 +30）" % hname,
				func(): _do_gift(hid))

	# 可招募
	_add_section("在野武将")
	var entries := DataManager.get_recruit_entries(_city_id)
	if entries.is_empty():
		_add_hint("此城暂无在野武将到访。")
		return
	for e in entries:
		var hero := DataManager.get_character(str(e.get("hero_id", "")))
		var hid := str(e.get("hero_id", ""))
		var terms := _svc.recruit_hero_terms(e)
		var gate := _svc.can_recruit_hero(e)
		var star := "★".repeat(int(e.get("difficulty", 1)))
		var head := "%s（%s）　%s" % [str(hero.get("name", hid)), str(hero.get("style_name", "")), star]
		var sub := "价 %d 金" % int(terms["gold"])
		if int(terms["fame"]) > 0:
			sub += "　需名声 %d" % int(terms["fame"])
		if int(terms["infamy"]) > 0:
			sub += "　需恶名 %d" % int(terms["infamy"])
		sub += "\n%s" % str(e.get("note", ""))
		if not gate["ok"]:
			sub += "　[%s]" % str(gate["reason"])
		_add_row(head, func(): _do_recruit_hero(e), bool(gate["ok"]), sub)

	_add_footer_btn("关闭", _close_panel)


func _do_gift(hero_id: String) -> void:
	var r := _svc.give_gift(hero_id, "consume_wine")
	AudioManager.sfx_click() if not r["ok"] else AudioManager.sfx_confirm()
	show_toast(str(r["msg"]))
	_reopen()


func _do_recruit_hero(entry: Dictionary) -> void:
	var r := _svc.recruit_hero(entry)
	if r["ok"]:
		AudioManager.sfx_confirm()
	else:
		AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_reopen()


## ---------- 面板：兵营 ----------

func _build_barracks() -> void:
	_panel_title.text = "兵  营"

	# 现有部队
	_add_section("现有部队（总兵力 %d）" % GameState.get_total_troops())
	if GameState.troops.is_empty():
		_add_hint("尚无部队，请先征兵。")
	else:
		for i in range(GameState.troops.size()):
			var t: Dictionary = GameState.troops[i]
			var unit := DataManager.get_unit(str(t.get("unit_id", "")))
			var hero_id := str(t.get("hero_id", ""))
			var hero := DataManager.get_character(hero_id) if not hero_id.is_empty() else {}
			var hname := str(hero.get("name", "")) if not hero.is_empty() else "无"
			var lv := int(t.get("level", 1))
			var exp := int(t.get("exp", 0))
			var idx := i
			var txt := "%s ×%d　等级 %d（经验 %d）\n统兵：%s" % [
				str(unit.get("name", "?")), int(t.get("count", 0)), lv, exp, hname,
			]
			_add_row(txt,
				func(): _open_train_menu(idx),
				true,
				"点击可练兵 / 换统兵武将 / 解散")

	# 征兵
	_add_section("征  兵")
	var quota := _svc.remaining_quota(_city_id)
	var morale := GameState.get_city_morale(_city_id)
	_add_hint("今日尚可征募 %d 人　|　当前民心 %d" % [quota, morale], C_DIM)

	var units_cfg: Array = DataManager.get_record("barracks", "root").get("units", [])
	for cfg in units_cfg:
		var uid := str(cfg.get("unit_id", ""))
		var unit := DataManager.get_unit(uid)
		if unit.is_empty():
			continue
		var gate := _svc.can_recruit_unit(_city_id, uid)
		var cost10 := _svc.recruit_cost(uid, 10)
		var sub := "10 兵 = 金 %d / 粮 %d" % [int(cost10["gold"]), int(cost10["food"])]
		if not gate["ok"]:
			sub += "　[%s]" % str(gate["reason"])
		else:
			sub += "　%s" % str(cfg.get("unlock_note", ""))
		_add_row("%s（%s）" % [str(unit.get("name", uid)), _cat_cn(str(unit.get("category", "")))],
			func(): _do_recruit(uid, 10), bool(gate["ok"]), sub)

	_add_footer_btn("关闭", _close_panel)


func _cat_cn(cat: String) -> String:
	match cat:
		"infantry": return "步兵"
		"cavalry": return "骑兵"
		"archer": return "弓兵"
		"beast": return "兽兵"
		"special": return "特殊"
		"navy": return "水军"
		"elite": return "精锐"
		_: return cat


func _do_recruit(unit_id: String, count: int) -> void:
	var r := _svc.recruit(_city_id, unit_id, count)
	if r["ok"]:
		AudioManager.sfx_confirm()
	else:
		AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_reopen()


## 单支部队的操作菜单（练兵 / 换将 / 解散）
func _open_train_menu(troop_index: int) -> void:
	if troop_index < 0 or troop_index >= GameState.troops.size():
		return
	AudioManager.sfx_click()
	_clear_panel()
	_panel_title.text = "部队管理"

	var t: Dictionary = GameState.troops[troop_index]
	var unit := DataManager.get_unit(str(t.get("unit_id", "")))
	_add_section("%s ×%d" % [str(unit.get("name", "?")), int(t.get("count", 0))])

	# 练兵
	var train_cost := int(DataManager.get_barracks_settings().get("train_food_per_10", 8))
	_add_row("练  兵（10 兵 → 耗粮 %d，积累经验）" % train_cost,
		func(): _do_train(troop_index))
	_add_hint("经验满 %d 后晋升为精锐，战力提升。" % int(DataManager.get_barracks_settings().get("veteran_threshold", 100)))

	# 换统兵武将
	_add_section("任命统兵武将")
	_add_row("（撤销当前统兵）", func(): _do_assign(troop_index, ""), not str(t.get("hero_id", "")).is_empty())
	for h in GameState.party:
		var hid := str(h.get("hero_id", ""))
		var hero := DataManager.get_character(hid)
		var stats: Dictionary = hero.get("stats", {})
		var cmd := (float(stats.get("intelligence", 50)) + float(stats.get("charisma", 50))) * 0.5
		var cur := str(t.get("hero_id", "")) == hid
		_add_row("%s%s（统率约 %d）" % ["✓ " if cur else "", str(hero.get("name", hid)), int(cmd)],
			func(): _do_assign(troop_index, hid), not cur)
	if GameState.party.is_empty():
		_add_hint("尚无武将，请先到酒馆招募。")

	# 解散
	_add_section("其他")
	_add_row("解  散  此  部  队", func(): _do_disband(troop_index))

	_add_footer_btn("返回兵营", func(): _open_panel("barracks"))


func _do_train(troop_index: int) -> void:
	var r := _svc.train(_city_id, troop_index, 10)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_train_menu(troop_index)


func _do_assign(troop_index: int, hero_id: String) -> void:
	var r := _svc.assign_hero(troop_index, hero_id)
	AudioManager.sfx_click() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_train_menu(troop_index)


func _do_disband(troop_index: int) -> void:
	if troop_index < 0 or troop_index >= GameState.troops.size():
		return
	var t: Dictionary = GameState.troops[troop_index]
	var unit := DataManager.get_unit(str(t.get("unit_id", "")))
	var n := int(t.get("count", 0))
	GameState.remove_troop(troop_index)
	AudioManager.sfx_cancel()
	show_toast("已解散 %s ×%d" % [str(unit.get("name", "?")), n])
	_open_panel("barracks")


## ---------- 面板：市场 ----------

func _build_market() -> void:
	_panel_title.text = "市  场"
	var level := int(_city.get("level", 1))

	_add_section("买  进")
	for g in DataManager.get_market_goods():
		var is_res := str(g.get("kind", "")) == "resource"
		if is_res:
			var res := str(g.get("resource", ""))
			var pack := int(g.get("pack", 10))
			var base := int(g.get("price", 0))
			var price := _svc.buy_price(base, level)
			var g2 := g
			_add_row("%s ×%d" % [str(g.get("name", res)), pack],
				func(): _do_buy_resource(res, pack, price, g2),
				GameState.gold >= price,
				"金 %d　%s" % [price, str(g.get("desc", ""))])
		else:
			var iid := str(g.get("item_id", ""))
			var item := DataManager.get_item(iid)
			if item.is_empty():
				continue
			var price2 := _svc.buy_price(int(item.get("price", 0)), level)
			var iid2 := iid
			_add_row("%s（库存 %d）" % [str(item.get("name", iid)), GameState.get_item_count(iid)],
				func(): _do_buy_item(iid2, 1, price2),
				GameState.gold >= price2,
				"金 %d　%s" % [price2, str(g.get("desc", ""))])

	# 卖出
	_add_section("卖  出")
	var has_any := false
	for g in DataManager.get_market_goods():
		if str(g.get("kind", "")) != "item":
			continue
		var iid3 := str(g.get("item_id", ""))
		var cnt := GameState.get_item_count(iid3)
		if cnt <= 0:
			continue
		has_any = true
		var item3 := DataManager.get_item(iid3)
		var sp := _svc.sell_price(int(item3.get("price", 0)), level)
		_add_row("售 %s ×1（+金 %d）" % [str(item3.get("name", iid3)), sp],
			func(): _do_sell_item(iid3, 1, sp))
	if not has_any:
		_add_hint("背包中没有可售出的商品。")

	# 卖出资源
	_add_section("售出物资")
	_add_resource_sell_rows("food", "粮草", 100, int(_svc.buy_price(200, level)))
	_add_resource_sell_rows("wood", "木材", 50, int(_svc.buy_price(150, level)))
	_add_resource_sell_rows("iron", "铁矿", 20, int(_svc.buy_price(160, level)))

	_add_footer_btn("关闭", _close_panel)


func _add_resource_sell_rows(res: String, name: String, pack: int, base_price: int) -> void:
	var have := 0
	match res:
		"food": have = GameState.food
		"wood": have = GameState.wood
		"iron": have = GameState.iron
	if have < pack:
		return
	var sp := _svc.sell_price(base_price, int(_city.get("level", 1)))
	_add_row("售 %s ×%d（+金 %d）" % [name, pack, sp],
		func(): _do_sell_resource(res, pack, sp))


func _do_buy_resource(res: String, pack: int, price: int, _g: Dictionary) -> void:
	var r := _svc.buy_resource(_city_id, res, pack, price)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("market")


func _do_sell_resource(res: String, pack: int, price: int) -> void:
	var r := _svc.sell_resource(_city_id, res, pack, price)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("market")


func _do_buy_item(item_id: String, count: int, price: int) -> void:
	var r := _svc.buy_item(_city_id, item_id, count, price)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("market")


func _do_sell_item(item_id: String, count: int, price: int) -> void:
	var r := _svc.sell_item(_city_id, item_id, count, price)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("market")


## ---------- 面板：铁匠铺 ----------

func _build_smith() -> void:
	_panel_title.text = "铁匠铺"
	var level := int(_city.get("level", 1))
	_add_hint("打造装备需城池等级达标。装备属性详见物品说明。")

	for g in DataManager.get_smith_goods():
		var iid := str(g.get("item_id", ""))
		var item := DataManager.get_item(iid)
		if item.is_empty():
			continue
		var gate := _svc.can_buy_smith(_city_id, g)
		var price := _svc.buy_price(int(item.get("price", 0)), level)
		var stat := _item_stat_text(item)
		var sub := "金 %d　%s" % [price, stat]
		if not gate["ok"]:
			sub += "　[%s]" % str(gate["reason"])
		var iid2 := iid
		var g2 := g
		_add_row("%s%s" % [str(item.get("name", iid)), _rarity_mark(str(item.get("rarity", "")))],
			func(): _do_buy_equipment(g2),
			bool(gate["ok"]) and GameState.gold >= price,
			sub)

	_add_footer_btn("关闭", _close_panel)


func _item_stat_text(item: Dictionary) -> String:
	var parts: Array[String] = []
	if int(item.get("attack", 0)) != 0:
		parts.append("攻 +%d" % int(item["attack"]))
	if int(item.get("defense", 0)) != 0:
		parts.append("防 +%d" % int(item["defense"]))
	if int(item.get("speed", 0)) != 0:
		parts.append("速 +%d" % int(item["speed"]))
	if bool(item.get("fire_vulnerable", false)):
		parts.append("惧火")
	if parts.is_empty():
		parts.append(str(item.get("description", "")))
	return "　".join(parts)


func _rarity_mark(rarity: String) -> String:
	match rarity:
		"legendary": return "　【传世】"
		"epic": return "　【珍品】"
		"rare": return "　【精良】"
		_: return ""


func _do_buy_equipment(entry: Dictionary) -> void:
	var r := _svc.buy_equipment(_city_id, entry)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("smith")


## ---------- 面板：官府 ----------

func _build_hall() -> void:
	_panel_title.text = "官  府"

	_add_section("城池状况")
	_add_hint("民心 %d　城防 %d　等级 %d" % [
		GameState.get_city_morale(_city_id),
		GameState.get_city_defense(_city_id),
		int(_city.get("level", 1)),
	], C_TEXT)
	_add_hint("民心影响征兵上限与价格；城防影响守城战。")

	_add_section("内  政")
	_add_row("开仓施赈（-金 200，民心 +5）", func(): _do_relieve(),
		GameState.gold >= 200 and GameState.get_city_morale(_city_id) < 100)
	_add_row("修缮城防（-木 50 / -金 150）", func(): _do_repair(),
		GameState.wood >= 50 and GameState.gold >= 150)

	_add_section("演武操练")
	_add_hint("进入演武场，可自由摆布阵型、以预设敌军试演，不消耗存档兵力。")
	_add_row("进  入  演  武  场", func(): _open_drill())

	_add_footer_btn("关闭", _close_panel)


func _do_relieve() -> void:
	var r := _svc.relieve_city(_city_id, 200)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("hall")


func _do_repair() -> void:
	var r := _svc.repair_city(_city_id, 50, 150)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("hall")


## ---------- 演练 ----------

## 打开演练选择：从官府进入时在面板内选；从底部按钮进入时用弹出列表
func _open_drill() -> void:
	AudioManager.sfx_click()
	_panel_root.visible = true
	_cur_panel = "drill"
	_clear_panel()
	_panel_title.text = "演  武  场"
	_add_section("选择假想敌")
	_add_hint("演练不消耗兵力、不给奖励，专为验证布阵与配兵思路。")

	for d in DataManager.get_drills():
		var did := str(d.get("id", ""))
		var diff := int(d.get("difficulty", 1))
		var names: Array[String] = []
		for u in d.get("enemy_units", []):
			var unit := DataManager.get_unit(str(u.get("unit_id", "")))
			if not unit.is_empty():
				names.append("%s×%d" % [str(unit.get("name", "?")), int(u.get("count", 0))])
		var sub := "%s　难度 %s\n%s" % [
			"、".join(names), "★".repeat(diff), str(d.get("description", "")),
		]
		_add_row("【%s】 建议等级 %d" % [str(d.get("name", did)), int(d.get("suggest_level", 1))],
			func(): _start_drill(did), true, sub)

	_add_footer_btn("关闭", _close_panel)


func _start_drill(drill_id: String) -> void:
	var enc := _svc.drill_as_encounter(drill_id)
	if enc.is_empty():
		show_toast("演练配置缺失")
		return
	AudioManager.sfx_confirm()
	GameState.drill_mode = true
	GameState.current_encounter = enc
	EventBus.drill_started.emit(drill_id)
	SceneRouter.push_scene("formation")


## ---------- 菜单 / 离开 ----------

func _open_menu() -> void:
	AudioManager.sfx_click()
	show_toast("菜单：角色 / 部队 / 任务 / 外交（后续里程碑）")


func _on_leave() -> void:
	AudioManager.sfx_click()
	EventBus.city_left.emit(_city_id)
	SceneRouter.back()


## ---------- 刷新辅助 ----------

## 重开当前面板（操作后刷新内容）
func _reopen() -> void:
	if _cur_panel.is_empty():
		return
	var key := _cur_panel
	_cur_panel = ""
	_open_panel(key)


func _on_inventory_changed() -> void:
	if _cur_panel in ["tavern", "market", "smith"]:
		_reopen()


func _on_party_changed() -> void:
	if _cur_panel == "tavern":
		_reopen()


## ---------- 提示 ----------

func show_toast(message: String) -> void:
	_toast.text = message
	_toast.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_interval(2.5)
	tween.tween_property(_toast, "modulate:a", 0.0, 0.5)

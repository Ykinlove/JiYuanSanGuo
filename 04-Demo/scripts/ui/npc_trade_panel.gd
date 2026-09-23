extends Control
class_name NpcTradePanel
## NPC 背包交易面板：全屏深色遮罩 + 居中卡片(1520×900) + 顶栏 + 双标签页【购买/出售】+ 滚动列表。
## 数据来源：TradeService（服务层返回 {ok,msg} 供 toast 展示），本文件不含任何价格公式。
## 与城池市场的差异：货单来自 NPC 自身背包（npc_stock.json），出售页遍历 GameState.inventory。

signal closed

const C_CARD := Color(0.12, 0.10, 0.08, 0.98)
const C_BORDER := Color(0.70, 0.56, 0.28, 0.95)
const C_GOLD := Color(0.93, 0.80, 0.45)
const C_TEXT := Color(0.92, 0.88, 0.82)
const C_DIM := Color(0.62, 0.57, 0.50)
const C_GOOD := Color(0.62, 0.86, 0.62)
const C_BAD := Color(0.92, 0.54, 0.48)

var _npc: Dictionary = {}
var _tab := "buy"

var _card: PanelContainer
var _title_label: Label
var _gold_label: Label
var _tab_buy: Button
var _tab_sell: Button
var _list: VBoxContainer
var _toast: Label
var _toast_tween: Tween


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# 全屏遮罩
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.02, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_card = PanelContainer.new()
	var vp := get_viewport_rect().size
	var pw := minf(1400.0, maxf(800.0, vp.x - 40.0))
	var ph := minf(860.0, maxf(500.0, vp.y - 40.0))
	_card.custom_minimum_size = Vector2(pw, ph)
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

	# 底部 toast
	_toast = Label.new()
	_toast.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.offset_top = -160.0
	_toast.offset_bottom = -112.0
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_color_override("font_color", C_TEXT)
	_toast.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_toast.add_theme_constant_override("shadow_offset_x", 2)
	_toast.add_theme_constant_override("shadow_offset_y", 2)
	_toast.add_theme_font_size_override("font_size", 28)
	_toast.modulate.a = 0.0
	add_child(_toast)


func _build_content() -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)

	# ---- 顶栏：NPC 名 + 金币 + 关闭 ----
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 40)
	_title_label.add_theme_color_override("font_color", C_GOLD)
	title_box.add_child(_title_label)
	_gold_label = Label.new()
	_gold_label.add_theme_font_size_override("font_size", 22)
	_gold_label.add_theme_color_override("font_color", C_DIM)
	title_box.add_child(_gold_label)
	head.add_child(title_box)
	var close := Button.new()
	close.text = "✕"
	close.custom_minimum_size = Vector2(68, 68)
	close.add_theme_font_size_override("font_size", 30)
	close.pressed.connect(_on_close)
	head.add_child(close)
	root.add_child(head)

	# ---- 双标签 ----
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 16)
	_tab_buy = _make_tab("购　买", "buy")
	_tab_sell = _make_tab("出　售", "sell")
	tabs.add_child(_tab_buy)
	tabs.add_child(_tab_sell)
	root.add_child(tabs)

	# ---- 滚动列表 ----
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)
	root.add_child(scroll)

	return root


func _make_tab(text: String, key: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(200, 66)
	b.add_theme_font_size_override("font_size", 28)
	b.toggle_mode = true
	b.pressed.connect(func(): _switch_tab(key))
	return b


func _switch_tab(key: String) -> void:
	if _tab == key:
		return
	_tab = key
	_tab_buy.button_pressed = (_tab == "buy")
	_tab_sell.button_pressed = (_tab == "sell")
	AudioManager.sfx_click()
	_refresh()


# ------------------------------------------------------------------
# 对外接口
# ------------------------------------------------------------------

func open(npc_data: Dictionary) -> void:
	_npc = npc_data
	_tab = "buy"
	visible = true
	_refresh()


func close() -> void:
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func _on_close() -> void:
	AudioManager.sfx_cancel()
	close()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and visible:
		close()
		get_viewport().set_input_as_handled()


# ------------------------------------------------------------------
# 数据填充
# ------------------------------------------------------------------

func _refresh() -> void:
	_title_label.text = "【交易】" + str(_npc.get("name", "商人"))
	_gold_label.text = "持有金钱  %d" % GameState.gold
	_tab_buy.button_pressed = (_tab == "buy")
	_tab_sell.button_pressed = (_tab == "sell")
	_clear_list()

	if _tab == "buy":
		_build_buy_list()
	else:
		_build_sell_list()


func _clear_list() -> void:
	for c in _list.get_children():
		c.queue_free()


func _build_buy_list() -> void:
	var info := TradeService.stock_for(_npc)
	_add_section_under("他随身携带的货物 —— %s" % str(info.get("label", "")))
	var goods: Array = info.get("goods", [])
	if goods.is_empty():
		_add_hint("此人身上并无货物。")
		return
	for g in goods:
		_add_goods_row(g)


## 出售页：遍历 GameState.inventory（字符串 key），转 int 查 items6，查不到就优雅跳过
func _build_sell_list() -> void:
	_add_section_under("你背包中可出售的物品")
	var keys: Array = GameState.inventory.keys()
	var shown := 0
	for raw in keys:
		var k := str(raw)
		var cnt := GameState.get_item_count(k)
		if cnt <= 0:
			continue
		# 旧遗留字符串 id（如 consume_wine）转不了 int 或查不到 → 跳过
		var id := _to_int(k)
		if id < 1:
			continue
		var item := DataManager.get_item6(id)
		if item.is_empty():
			continue
		_add_inv_row(id, str(item.get("name", k)), cnt, int(item.get("price", 0)))
		shown += 1
	if shown == 0:
		_add_hint("背包中没有可出售的货物。")


func _to_int(s: String) -> int:
	if s.is_valid_int():
		return int(s)
	return -1


# ------------------------------------------------------------------
# 行构件
# ------------------------------------------------------------------

func _add_section_under(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 24)
	l.add_theme_color_override("font_color", C_GOLD)
	_list.add_child(l)


func _add_hint(text: String, color: Color = C_DIM) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 21)
	l.add_theme_color_override("font_color", color)
	_list.add_child(l)


## 购买行：物品名 + 品质 + 单价 + 库存 + 买1 / 买10（售罄时按钮变补货提示）
func _add_goods_row(g: Dictionary) -> void:
	var name := str(g.get("name", "?"))
	var qual := str(g.get("quality_name", ""))
	var price := int(g.get("buy_price", 0))
	var left := int(g.get("left", 0))
	var qty := int(g.get("qty", 0))
	var row := _make_row()
	var label := Label.new()
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", C_TEXT)
	label.text = "%s　[%s]\n单价 %d 金　库存 %d/%d" % [name, qual, price, left, qty]
	row.add_child(label)
	if left <= 0:
		# 售罄：显示等待补货提示，不可购买
		var sold_out := Label.new()
		sold_out.text = "已售完\n待补货"
		sold_out.add_theme_font_size_override("font_size", 22)
		sold_out.add_theme_color_override("font_color", C_BAD)
		sold_out.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(sold_out)
	else:
		_add_qty_buttons(row, g, "buy")


## 出售行：物品名 + 拥有数 + 卖出单价 + 卖1 / 卖10
func _add_inv_row(id: int, name: String, cnt: int, base_price: int) -> void:
	var ratio: float = float(TradeService.stock_for(_npc).get("sell_ratio", 0.55))
	var unit := int(round(float(base_price) * float(ratio)))
	var row := _make_row()
	var label := Label.new()
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", C_TEXT)
	label.text = "%s　×%d\n出售单价 %d 金" % [name, cnt, unit]
	row.add_child(label)
	var g := { "item_id": id }
	_add_qty_buttons(row, g, "sell")


## 创建一行：带边框的 PanelContainer 内嵌一个 HBox（row）。
## row 挂到 panel，panel 挂到 _list；调用方把 label / 按钮加进 row 即可。
func _make_row() -> HBoxContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.17, 0.14, 0.11, 0.95)
	sb.border_color = Color(0.4, 0.34, 0.22, 0.5)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	panel.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(row)
	_list.add_child(panel)
	return row


## 在行右侧加「买1/买10」或「卖1/卖10」
func _add_qty_buttons(row: HBoxContainer, g: Dictionary, mode: String) -> void:
	var id := int(g.get("item_id", -1))
	var b1 := Button.new()
	b1.text = ("买1" if mode == "buy" else "卖1")
	b1.custom_minimum_size = Vector2(120, 64)
	b1.add_theme_font_size_override("font_size", 24)
	b1.pressed.connect(func(): _do_trade(mode, id, 1))
	row.add_child(b1)
	var b2 := Button.new()
	b2.text = ("买10" if mode == "buy" else "卖10")
	b2.custom_minimum_size = Vector2(120, 64)
	b2.add_theme_font_size_override("font_size", 24)
	b2.pressed.connect(func(): _do_trade(mode, id, 10))
	row.add_child(b2)


func _do_trade(mode: String, item_id: int, qty: int) -> void:
	var r: Dictionary
	if mode == "buy":
		r = TradeService.buy(_npc, item_id, qty)
		if bool(r.get("ok", false)):
			AudioManager.sfx_confirm()
		else:
			AudioManager.sfx_cancel()
	else:
		r = TradeService.sell(_npc, item_id, qty)
		if bool(r.get("ok", false)):
			AudioManager.sfx_confirm()
		else:
			AudioManager.sfx_cancel()
	show_toast(str(r.get("msg", "")))
	_refresh()


func show_toast(text: String) -> void:
	_toast.text = text
	_toast.modulate.a = 1.0
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(2.4)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.5)

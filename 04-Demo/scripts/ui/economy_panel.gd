extends Control
class_name EconomyPanel
## 商城面板（EconomyPanel）
## ------------------------------------------------------------------
## 【本轮·用户诉求】「将物质获取单独做到大地图的菜单栏旁边，入口名为商城」。
##
## 【为什么要独立成一个类而不是把城内的代码搬去 world_map】
## 集市/商城/观览三条途径的规则全在 `ItemEconomyService`（静态服务）里，
## 本类只做「取数据 → 摆行」。摆行依赖的 UI 原语只有三个（分区/提示/行按钮），
## 在城内与城外的实现完全一致。故把「摆行」抽成一份、两处各建一个实例 ——
## 复制粘贴的代价是**规则一改要改两处**，而这类经济数值本轮刚调过三轮。
##
## 【数据源单一真源】三条途径的定价与限次全部读 `ItemEconomyService`，
## 本类**不持有任何价格或限次常量**，也不读 item_economy.json ——
## 那是服务层的职责，绕过它就等于两份真源。
##
## 【用法】
##   var p := EconomyPanel.new()
##   add_child(p)                  # 挂到场景的 UI 容器下
##   p.open() / p.close() / p.is_open()
## 关闭后发 closed 信号（与 MainMenuWheel 等既有面板同一约定）。

signal closed

## 卡片尺寸：与城内面板同规格（UITheme.CITY_PANEL_SIZE），两处观感统一。
const CARD_SIZE := Vector2(1040.0, 780.0)
## 行按钮高度。**不得低于 UITheme.TOUCH_H(84)** —— 手指点不准是硬伤。
const ROW_H := 96.0
const ROW_H_PLAIN := 84.0

var _body: VBoxContainer
var _scroll: ScrollContainer


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	# 走 UITheme.make_modal：统一卡片样式、标题居中、✕、滚动条、开合音、
	# 淡入动效、安全区。**不自己拼 PanelContainer** —— 那会绕过这一整套约定，
	# 商城就会成为全工程唯一一个样式不一致的面板。
	var m := UITheme.make_modal(self, "商  城", close, null, CARD_SIZE)
	_body = m["body"] as VBoxContainer
	_scroll = m["scroll"] as ScrollContainer


func open() -> void:
	visible = true
	_rebuild()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


## 重建全部行。交易后也走这里，保证「价格/持有/限次」实时刷新。
func _rebuild() -> void:
	# 【先摘再弃】一次交易只重建一次：摘掉旧行再 queue_free，
	# 否则同帧内按钮仍可能收到触摸尾巴事件，落到已废节点上（MEMORY 铁律）。
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	_scroll.scroll_vertical = 0
	_build_exchange()
	_build_mall()
	_build_ad()


# ------------------------------------------------------------------
# 三条途径
# ------------------------------------------------------------------

## 集市：用做任务攒的钱兑换基础材料。
## 这些材料是全部锻造配方的唯一堵点 —— 换到手就能开炉。
func _build_exchange() -> void:
	_add_section("集市 · 粮秣院")
	var lim := ItemEconomyService.exchange_daily_limit()
	var left := ItemEconomyService.exchange_left_today()
	if left < 0:
		_add_hint("以金换料。")
	else:
		_add_hint("今日可兑 %d/%d。此处只收材料与吃食。" % [lim - left, lim])
	var goods := ItemEconomyService.exchange_goods()
	if goods.is_empty():
		_add_hint("暂无货品。")
		return
	var cur_tier := ""
	for g in goods:
		var gd: Dictionary = g
		var tier := str(gd.get("tier", "normal"))
		if tier != cur_tier:
			cur_tier = tier
			_add_hint(_tier_label(tier))
		var gate := ItemEconomyService.can_exchange(int(gd["item_id"]))
		var sub := "金 %d" % int(gd.get("price", 0))
		if not bool(gate.get("ok", false)):
			sub += "　[%s]" % str(gate["reason"])
		var iid := int(gd["item_id"])
		_add_row(_goods_label(gd, iid), _do_exchange.bind(iid),
			bool(gate.get("ok", false)), sub)


## 商城：强力装备与宝物。价格数倍于市价，不设每日限次
## （「贵」已经是这一侧的约束，再叠日限会变成双重门槛）。
func _build_mall() -> void:
	_add_section("珍玩阁 · 商城")
	_add_hint("天下奇珍。价钱高，须长久积贮。")
	var goods := ItemEconomyService.mall_goods()
	if goods.is_empty():
		_add_hint("暂无奇珍。")
		return
	var cur_tier := ""
	for g in goods:
		var gd: Dictionary = g
		var tier := str(gd.get("tier", "epic"))
		if tier != cur_tier:
			cur_tier = tier
			_add_hint(_tier_label(tier))
		var gate := ItemEconomyService.can_buy_mall(int(gd["item_id"]))
		var sub := "金 %d" % int(gd.get("price", 0))
		if not bool(gate.get("ok", false)):
			sub += "　[%s]" % str(gate["reason"])
		var iid := int(gd["item_id"])
		_add_row(_goods_label(gd, iid), _do_buy_mall.bind(iid),
			bool(gate.get("ok", false)), sub)


## 看广告换取补给。**只给材料/钱粮，绝不给装备** ——
## 装备是长期资产，能靠广告刷出来的话，商城与任务奖励的稀缺性全部归零。
func _build_ad() -> void:
	_add_section("观览 · 街市见闻")
	var lim := ItemEconomyService.ad_daily_limit()
	var left := ItemEconomyService.ad_left_today()
	if left < 0:
		_add_hint("观览无次数之限。")
	else:
		_add_hint("今日可观 %d/%d。各档每日一观，次日复起。" % [lim - left, lim])
	for t in ItemEconomyService.ad_tiers():
		var td: Dictionary = t
		var tid := str(td.get("id", ""))
		var gate := ItemEconomyService.can_watch_ad(tid)
		var sub := str(td.get("desc", ""))
		if not bool(gate.get("ok", false)):
			sub += "　[%s]" % str(gate["reason"])
		var mark := "　可观览" if bool(td.get("ready", false)) else ""
		_add_row(str(td.get("name", tid)) + mark, _do_watch_ad.bind(tid),
			bool(gate.get("ok", false)), sub)


# ------------------------------------------------------------------
# 交易
# ------------------------------------------------------------------

func _do_exchange(item_id6: int) -> void:
	_finish(ItemEconomyService.exchange(item_id6))


func _do_buy_mall(item_id6: int) -> void:
	_finish(ItemEconomyService.buy_mall(item_id6))


func _do_watch_ad(tier_id: String) -> void:
	_finish(ItemEconomyService.watch_ad(tier_id))


## 交易收尾：音效 + 提示 + 刷新。
## 【为什么单独一个函数】三条途径的收尾动作完全一致，写三遍就是三处
## 未来可能只改一处的隐患。
func _finish(r: Dictionary) -> void:
	if bool(r.get("ok", false)):
		AudioManager.play_sfx("res://assets/audio/sfx/coin_trade.ogg")
	else:
		AudioManager.sfx_cancel()
	EventBus.show_toast(str(r.get("msg", "")))
	_rebuild()


# ------------------------------------------------------------------
# UI 原语
# ------------------------------------------------------------------

func _goods_label(gd: Dictionary, iid: int) -> String:
	var label := str(gd.get("name", str(iid)))
	var q := str(gd.get("quality", ""))
	if not q.is_empty() and q != "未知":
		label += "　【%s】" % q
	return label


func _tier_label(tier: String) -> String:
	match tier:
		"legend": return "—— 传世 ——"
		"epic": return "—— 珍品 ——"
		"rare": return "—— 精良 ——"
	return "—— 寻常 ——"


func _add_section(text: String) -> void:
	_body.add_child(UITheme.label(text, UITheme.FS_HEAD, UITheme.GOLD))


func _add_hint(text: String) -> void:
	var l := UITheme.label(text, UITheme.FS_NOTE, UITheme.DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(0, 40)
	_body.add_child(l)


func _add_row(text: String, cb: Callable, enabled: bool, sub: String) -> Button:
	# 【单一来源】按钮样式与高度一律走 UITheme.button() 工厂，
	# 之后**不再覆写 custom_minimum_size**（第五十三轮就抓到过覆写回退）。
	var b := UITheme.button(text if sub.is_empty() else "%s\n%s" % [text, sub],
		22, Vector2(0, ROW_H_PLAIN if sub.is_empty() else ROW_H))
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.disabled = not enabled
	if enabled:
		b.pressed.connect(cb)
	_body.add_child(b)
	return b

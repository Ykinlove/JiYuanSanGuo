extends RefCounted
class_name TradeService
## NPC 背包交易规则层：读取 npc_stock.json，按 NPC 身份给出其随身货单，买卖结算金币。
## UI 只调 stock_for() / buy() / sell()，不在显示层写任何价格公式。
## 与城池市场不同：这里是「跟每个人交易」，货单来自 NPC 自身背包。
## 【限量】每种货有随身库存上限（qty），卖完后进入补货等待（restock_days 游戏日），
##         库存状态存于 GameState.npc_stock_state，随存档持久化。

## 从配置取某 NPC 的货单与折价参数（按 npc_type 匹配，缺省 merchant）
static func _entry_for(npc_data: Dictionary) -> Dictionary:
	var root := DataManager.get_record("npc_stock", "root")
	var stock: Dictionary = root.get("stock", {})
	var settings: Dictionary = root.get("settings", {})
	var key := str(npc_data.get("npc_type", ""))
	if not stock.has(key):
		key = "merchant"
		for t in npc_data.get("tags", []):
			if stock.has(str(t)):
				key = str(t)
				break
	var e: Dictionary = stock.get(key, {})
	var out := e.duplicate(true)
	out["buy_markup"] = float(e.get("buy_markup", float(settings.get("buy_markup", 1.15))))
	out["sell_ratio"] = float(e.get("sell_ratio", float(settings.get("default_sell_ratio", 0.55))))
	out["restock_days"] = int(e.get("restock_days", int(settings.get("restock_days", 15))))
	out["qty_map"] = e.get("qty", {})
	return out


## 该 NPC 某种货的库存上限（qty 表按 items6 id 的字符串 key 覆盖，缺省 default_qty）
static func _qty_limit(e: Dictionary, item_id: int) -> int:
	var qmap: Dictionary = e.get("qty_map", {})
	var settings: Dictionary = DataManager.get_record("npc_stock", "root").get("settings", {})
	return int(qmap.get(str(item_id), int(settings.get("default_qty", 20))))


## 库存状态的存档 key（NPC 个体维度）
static func _stock_key(npc_data: Dictionary, item_id: int) -> String:
	var nid := str(npc_data.get("id", ""))
	if nid.is_empty():
		nid = str(npc_data.get("npc_type", "npc")) + "_" + str(npc_data.get("name", ""))
	return nid + "|" + str(item_id)


## 取当前剩余量；售罄且已到补货日 → 自动回满
static func _remaining(e: Dictionary, npc_data: Dictionary, item_id: int) -> int:
	var limit := _qty_limit(e, item_id)
	var key := _stock_key(npc_data, item_id)
	var st: Dictionary = GameState.npc_stock_state.get(key, {})
	if st.is_empty():
		return limit
	var left := int(st.get("left", limit))
	if left <= 0 and GameState.total_days() >= int(st.get("restock_at", 0)):
		# 到补货日：回满并清除状态
		GameState.npc_stock_state.erase(key)
		return limit
	return left


## 扣减库存；减到 0 时登记补货日
static func _take(e: Dictionary, npc_data: Dictionary, item_id: int, qty: int) -> void:
	var limit := _qty_limit(e, item_id)
	var key := _stock_key(npc_data, item_id)
	var st: Dictionary = GameState.npc_stock_state.get(key, {})
	var left := int(st.get("left", limit)) - qty
	if left > 0:
		st["left"] = left
		GameState.npc_stock_state[key] = st
	else:
		# 售罄：登记补货日
		GameState.npc_stock_state[key] = {
			"left": 0,
			"restock_at": GameState.total_days() + int(e.get("restock_days", 15)),
		}


## 货单：{ label, goods:[{item_id,name,price,buy_price,quality_name,effects,qty,left}], sell_ratio }
static func stock_for(npc_data: Dictionary) -> Dictionary:
	var e := _entry_for(npc_data)
	var goods: Array = []
	for iid in e.get("buy", []):
		var id := int(iid)
		var item := DataManager.get_item6(id)
		if item.is_empty():
			continue
		var price := int(item.get("price", 0))
		goods.append({
			"item_id": id,
			"name": str(item.get("name", "?")),
			"price": price,
			"buy_price": int(round(float(price) * float(e.get("buy_markup", 1.15)))),
			"quality_name": str(item.get("quality_name", "")),
			"effects": item.get("effects", []),
			"qty": _qty_limit(e, id),
			"left": _remaining(e, npc_data, id),
		})
	return {
		"label": str(e.get("label", "货物")),
		"goods": goods,
		"sell_ratio": float(e.get("sell_ratio", 0.55)),
	}


## 买入：{ ok, msg, cost, name, count }
static func buy(npc_data: Dictionary, item_id: int, qty: int) -> Dictionary:
	var e := _entry_for(npc_data)
	var info := stock_for(npc_data)
	var chosen: Dictionary = {}
	for g in info.get("goods", []):
		if int(g.get("item_id", -1)) == item_id:
			chosen = g
			break
	if chosen.is_empty():
		return { "ok": false, "msg": "他随身没带此物。" }
	if qty <= 0:
		return { "ok": false, "msg": "数量有误。" }
	# 限量：售罄 / 不足量截断
	var left := int(chosen.get("left", 0))
	if left <= 0:
		var days := int(e.get("restock_days", 15))
		return { "ok": false, "msg": "%s已售完，约 %d 日后他再带货来。" % [str(chosen.get("name", "此货")), days] }
	var real_qty := qty
	if real_qty > left:
		real_qty = left
	var unit := int(chosen.get("buy_price", 0))
	var cost := unit * real_qty
	if GameState.gold < cost:
		return { "ok": false, "msg": "金钱不足（需 %d 金）。" % cost }
	GameState.add_gold(-cost)
	GameState.add_item(str(item_id), real_qty)
	_take(e, npc_data, item_id, real_qty)
	GameState.trades_done += 1
	AchievementService.check_all()
	var msg := "购入 %s ×%d（-%d 金）。" % [str(chosen.get("name", "?")), real_qty, cost]
	if real_qty < qty:
		msg += "（他只带了 %d 件）" % real_qty
	if left - real_qty <= 0:
		msg += "\n他的%s卖光了，需等他补货。" % str(chosen.get("name", "?"))
	return {
		"ok": true, "cost": cost, "name": str(chosen.get("name", "?")), "count": real_qty,
		"msg": msg,
	}


## 卖出：{ ok, msg, gain, name, count }
static func sell(npc_data: Dictionary, item_id: int, qty: int) -> Dictionary:
	var item := DataManager.get_item6(item_id)
	if item.is_empty():
		return { "ok": false, "msg": "此物他收不了。" }
	if qty <= 0:
		return { "ok": false, "msg": "数量有误。" }
	if not GameState.has_item(str(item_id), qty):
		return { "ok": false, "msg": "你身上没有此物。" }
	var ratio: float = float(stock_for(npc_data).get("sell_ratio", 0.55))
	var gain := int(round(float(item.get("price", 0)) * float(ratio))) * qty
	GameState.add_item(str(item_id), -qty)
	GameState.add_gold(gain)
	GameState.trades_done += 1
	AchievementService.check_all()
	return {
		"ok": true, "gain": gain, "name": str(item.get("name", "?")), "count": qty,
		"msg": "售出 %s ×%d（+%d 金）。" % [str(item.get("name", "?")), qty, gain],
	}

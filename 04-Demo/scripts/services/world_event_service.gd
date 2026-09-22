extends RefCounted
class_name WorldEventService
## 大地图随机事件规则层（遭遇表 type="event"）。
## 事件定义见 encounters.json：
##   options[] = { id, text, cost:{gold,food,wood,iron}, effects:{...}, result }
## effects 支持：gold/food/wood/iron/fame/infamy/exp（带符号整数）、
##   unit_add {unit_id: count}、item_add {item_id: count}
## UI 只调 can_pick()/resolve()，不自行扣资源或拼结算公式。

const RESOURCE_KEYS: Array[String] = ["gold", "food", "wood", "iron"]


## 取某选项（找不到返回空字典）
static func find_option(event_def: Dictionary, option_id: String) -> Dictionary:
	for opt in event_def.get("options", []):
		if str(opt.get("id", "")) == option_id:
			return opt
	return {}


## 是否可选（资源不足时返回原因供按钮置灰）
static func can_pick(opt: Dictionary) -> Dictionary:
	var cost: Dictionary = opt.get("cost", {})
	for k in RESOURCE_KEYS:
		var need := int(cost.get(k, 0))
		if need > 0 and _get_resource(k) < need:
			return { "ok": false, "reason": "%s不足（需 %d）" % [_resource_name(k), need] }
	return { "ok": true, "reason": "" }


## 结算一个选项：校验→扣消耗→应用效果。返回 {ok, msg}
static func resolve(event_def: Dictionary, option_id: String) -> Dictionary:
	var opt := find_option(event_def, option_id)
	if opt.is_empty():
		return { "ok": false, "msg": "事件选项缺失。" }
	var gate := can_pick(opt)
	if not gate["ok"]:
		return { "ok": false, "msg": str(gate["reason"]) }

	# 扣除消耗
	var cost: Dictionary = opt.get("cost", {})
	for k in RESOURCE_KEYS:
		var need := int(cost.get(k, 0))
		if need > 0:
			_add_resource(k, -need)

	# 应用效果
	var parts: Array[String] = []
	var eff: Dictionary = opt.get("effects", {})
	for k in ["gold", "food", "wood", "iron", "fame", "infamy", "exp"]:
		var v := int(eff.get(k, 0))
		if v != 0:
			_apply_simple(k, v)
			parts.append("%s %s%d" % [_effect_name(k), "+" if v > 0 else "", v])

	var unit_add: Dictionary = eff.get("unit_add", {})
	for uid in unit_add:
		var n := int(unit_add[uid])
		if n > 0:
			GameState.add_troop(str(uid), n)
			EventBus.unit_added.emit(str(uid), n)
			var urec := DataManager.get_record("units", str(uid))
			var uname := str(urec.get("name", uid)) if not urec.is_empty() else str(uid)
			parts.append("%s +%d" % [uname, n])

	var item_add: Dictionary = eff.get("item_add", {})
	for iid in item_add:
		var n2 := int(item_add[iid])
		if n2 > 0:
			GameState.add_item(str(iid), n2)
			var irec := DataManager.get_item(str(iid))
			var iname := str(irec.get("name", iid)) if not irec.is_empty() else str(iid)
			parts.append("%s ×%d" % [iname, n2])

	# 文案优先用配置的 result，没有则按效果拼
	var msg := str(opt.get("result", ""))
	if msg.is_empty():
		if parts.is_empty():
			msg = "什么也没有发生。"
		else:
			msg = "、".join(parts)
	return { "ok": true, "msg": msg }


static func _get_resource(key: String) -> int:
	match key:
		"gold": return GameState.gold
		"food": return GameState.food
		"wood": return GameState.wood
		"iron": return GameState.iron
	return 0


static func _add_resource(key: String, delta: int) -> void:
	match key:
		"gold": GameState.add_gold(delta)
		"food": GameState.add_food(delta)
		"wood": GameState.add_wood(delta)
		"iron": GameState.add_iron(delta)


static func _apply_simple(key: String, v: int) -> void:
	match key:
		"gold": GameState.add_gold(v)
		"food": GameState.add_food(v)
		"wood": GameState.add_wood(v)
		"iron": GameState.add_iron(v)
		"fame": GameState.add_fame(v)
		"infamy": GameState.add_infamy(v)
		"exp": GameState.add_player_exp(v)


static func _resource_name(key: String) -> String:
	return String({
		"gold": "金钱", "food": "粮草", "wood": "木材", "iron": "铁矿",
	}.get(key, key))


static func _effect_name(key: String) -> String:
	return String({
		"gold": "金钱", "food": "粮草", "wood": "木材", "iron": "铁矿",
		"fame": "名声", "infamy": "恶名", "exp": "经验",
	}.get(key, key))
